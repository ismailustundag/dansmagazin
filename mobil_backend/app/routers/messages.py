import os
from datetime import datetime
from typing import Any, Dict, List, Optional

import psycopg2
import psycopg2.extras
from fastapi import APIRouter, Header, HTTPException
from pydantic import BaseModel

router = APIRouter(prefix="/messages", tags=["Mesajlar"])
DATABASE_URL = os.getenv("DATABASE_URL", "").strip()


class SendMessageRequest(BaseModel):
    to_account_id: int
    body: str


def _db_conn():
    if not DATABASE_URL:
        raise HTTPException(status_code=500, detail="DATABASE_URL eksik")
    return psycopg2.connect(DATABASE_URL, cursor_factory=psycopg2.extras.RealDictCursor)


def _iso_now() -> str:
    return datetime.utcnow().isoformat(timespec="seconds") + "Z"


def _require_account_id(conn, authorization: Optional[str]) -> int:
    if not authorization or not authorization.lower().startswith("bearer "):
        raise HTTPException(status_code=401, detail="Bearer token gerekli")
    token = authorization.split(" ", 1)[1].strip()
    if not token:
        raise HTTPException(status_code=401, detail="Token boş")
    cur = conn.cursor()
    cur.execute(
        """
        SELECT s.account_id
        FROM sessions s
        JOIN accounts a ON a.id=s.account_id
        WHERE s.session_token=%s AND COALESCE(a.is_active,1)=1
        LIMIT 1
        """,
        (token,),
    )
    row = cur.fetchone()
    if not row:
        raise HTTPException(status_code=401, detail="Geçersiz oturum")
    return int(row["account_id"])


def _display_name(name: str, email: str) -> str:
    n = (name or "").strip()
    if n:
        return n
    e = (email or "").strip()
    if "@" in e:
        return e.split("@", 1)[0]
    return "user"


def _is_friend(conn, a: int, b: int) -> bool:
    x, y = (a, b) if a < b else (b, a)
    cur = conn.cursor()
    cur.execute(
        "SELECT 1 FROM mobile_friendships WHERE user_a_id=%s AND user_b_id=%s LIMIT 1",
        (x, y),
    )
    return bool(cur.fetchone())


def init_message_read_state_table():
    conn = _db_conn()
    try:
        cur = conn.cursor()
        cur.execute(
            """
            CREATE TABLE IF NOT EXISTS mobile_message_read_state (
                account_id INTEGER NOT NULL,
                peer_account_id INTEGER NOT NULL,
                last_read_message_id BIGINT NOT NULL DEFAULT 0,
                last_read_at TEXT,
                PRIMARY KEY (account_id, peer_account_id)
            )
            """
        )
        cur.execute(
            """
            CREATE INDEX IF NOT EXISTS idx_msg_read_state_account
            ON mobile_message_read_state(account_id)
            """
        )
        conn.commit()
    except Exception:
        conn.rollback()
    finally:
        conn.close()


def unread_messages_count(conn, account_id: int) -> int:
    cur = conn.cursor()
    cur.execute(
        """
        SELECT COALESCE(SUM(t.unread_count), 0) AS unread_total
        FROM (
            SELECT
                m.sender_account_id AS peer_id,
                COUNT(*)::INTEGER AS unread_count
            FROM mobile_direct_messages m
            LEFT JOIN mobile_message_read_state rs
              ON rs.account_id=%s
             AND rs.peer_account_id=m.sender_account_id
            WHERE m.receiver_account_id=%s
              AND m.id > COALESCE(rs.last_read_message_id, 0)
            GROUP BY m.sender_account_id
        ) t
        """,
        (int(account_id), int(account_id)),
    )
    row = cur.fetchone() or {}
    return int(row.get("unread_total") or 0)


@router.get("", summary="Mesaj kutusu")
def list_messages(with_account_id: Optional[int] = None, limit: int = 100, authorization: Optional[str] = Header(default=None)):
    conn = _db_conn()
    try:
        me = _require_account_id(conn, authorization)
        cur = conn.cursor()
        if with_account_id is None:
            cur.execute(
                """
                SELECT
                    CASE WHEN m.sender_account_id=%s THEN m.receiver_account_id ELSE m.sender_account_id END AS peer_id,
                    MAX(m.created_at) AS last_at
                FROM mobile_direct_messages m
                WHERE m.sender_account_id=%s OR m.receiver_account_id=%s
                GROUP BY peer_id
                ORDER BY MAX(m.created_at) DESC
                LIMIT %s
                """,
                (me, me, me, max(1, min(int(limit), 500))),
            )
            rows = cur.fetchall() or []
            by_peer: Dict[int, Dict[str, Any]] = {int(r["peer_id"]): dict(r) for r in rows}

            # Mesajı olmasa bile arkadaşları listeye ekle.
            cur.execute(
                """
                SELECT CASE WHEN mf.user_a_id=%s THEN mf.user_b_id ELSE mf.user_a_id END AS peer_id
                FROM mobile_friendships mf
                WHERE mf.user_a_id=%s OR mf.user_b_id=%s
                """,
                (me, me, me),
            )
            for fr in cur.fetchall() or []:
                pid = int(fr["peer_id"])
                if pid not in by_peer:
                    by_peer[pid] = {"peer_id": pid, "last_at": ""}

            merged_rows = list(by_peer.values())
            merged_rows.sort(key=lambda x: str(x.get("last_at") or ""), reverse=True)

            peer_ids = [int(r["peer_id"]) for r in merged_rows]
            details: Dict[int, Dict[str, Any]] = {}
            if peer_ids:
                cur.execute(
                    """
                    SELECT id, COALESCE(name,'') AS name, COALESCE(email,'') AS email
                    FROM accounts
                    WHERE id = ANY(%s)
                    """,
                    (peer_ids,),
                )
                for r in cur.fetchall() or []:
                    details[int(r["id"])] = dict(r)
            unread_by_peer: Dict[int, int] = {}
            cur.execute(
                """
                SELECT
                    m.sender_account_id AS peer_id,
                    COUNT(*)::INTEGER AS unread_count
                FROM mobile_direct_messages m
                LEFT JOIN mobile_message_read_state rs
                  ON rs.account_id=%s
                 AND rs.peer_account_id=m.sender_account_id
                WHERE m.receiver_account_id=%s
                  AND m.id > COALESCE(rs.last_read_message_id, 0)
                GROUP BY m.sender_account_id
                """,
                (me, me),
            )
            for rr in cur.fetchall() or []:
                unread_by_peer[int(rr["peer_id"])] = int(rr["unread_count"] or 0)

            out: List[Dict[str, Any]] = []
            for r in merged_rows:
                pid = int(r["peer_id"])
                d = details.get(pid, {})
                out.append(
                    {
                        "account_id": pid,
                        "name": _display_name((d.get("name") or ""), (d.get("email") or "")),
                        "last_at": (r.get("last_at") or ""),
                        "unread_count": int(unread_by_peer.get(pid, 0)),
                    }
                )
            return {"section": "mesajlar", "items": out, "unread_count": int(sum(unread_by_peer.values()))}

        peer = int(with_account_id)
        if peer == me:
            raise HTTPException(status_code=400, detail="Kendinizle mesajlaşamazsınız")
        if not _is_friend(conn, me, peer):
            raise HTTPException(status_code=403, detail="Sadece arkadaşlar arasında mesajlaşma açık")
        cur.execute(
            """
            SELECT id, sender_account_id, receiver_account_id, body, created_at
            FROM mobile_direct_messages
            WHERE (sender_account_id=%s AND receiver_account_id=%s)
               OR (sender_account_id=%s AND receiver_account_id=%s)
            ORDER BY id DESC
            LIMIT %s
            """,
            (me, peer, peer, me, max(1, min(int(limit), 500))),
        )
        rows = list(reversed(cur.fetchall() or []))
        max_incoming_id = 0
        for r in rows:
            if int(r.get("sender_account_id") or 0) == peer and int(r.get("receiver_account_id") or 0) == me:
                max_incoming_id = max(max_incoming_id, int(r.get("id") or 0))
        if max_incoming_id > 0:
            cur.execute(
                """
                INSERT INTO mobile_message_read_state (account_id, peer_account_id, last_read_message_id, last_read_at)
                VALUES (%s, %s, %s, %s)
                ON CONFLICT (account_id, peer_account_id) DO UPDATE
                SET last_read_message_id = GREATEST(mobile_message_read_state.last_read_message_id, EXCLUDED.last_read_message_id),
                    last_read_at = EXCLUDED.last_read_at
                """,
                (me, peer, max_incoming_id, _iso_now()),
            )
            conn.commit()
        return {"section": "mesajlar", "with_account_id": peer, "me_account_id": me, "items": rows}
    finally:
        conn.close()


@router.post("/send", summary="Arkadaşa mesaj gönder")
def send_message(payload: SendMessageRequest, authorization: Optional[str] = Header(default=None)):
    body = (payload.body or "").strip()
    if not body:
        raise HTTPException(status_code=400, detail="Mesaj boş olamaz")
    if len(body) > 2000:
        raise HTTPException(status_code=400, detail="Mesaj çok uzun")

    conn = _db_conn()
    try:
        me = _require_account_id(conn, authorization)
        to_id = int(payload.to_account_id)
        if to_id == me:
            raise HTTPException(status_code=400, detail="Kendinize mesaj gönderemezsiniz")
        if not _is_friend(conn, me, to_id):
            raise HTTPException(status_code=403, detail="Sadece arkadaşlara mesaj gönderilebilir")
        cur = conn.cursor()
        cur.execute(
            """
            INSERT INTO mobile_direct_messages (sender_account_id, receiver_account_id, body, created_at)
            VALUES (%s,%s,%s,%s)
            RETURNING id
            """,
            (me, to_id, body, _iso_now()),
        )
        mid = int(cur.fetchone()["id"])
        conn.commit()
        return {"ok": True, "message_id": mid}
    finally:
        conn.close()
