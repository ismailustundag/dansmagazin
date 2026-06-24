import os
from datetime import datetime
from typing import Any, Dict, List, Optional
import logging

import psycopg2
import psycopg2.extras
from fastapi import APIRouter, Header, HTTPException
from app.utils import get_db_connection, display_name, get_blocked_peer_ids
from pydantic import BaseModel
# Changed _db_conn to db_conn
router = APIRouter(prefix="/messages", tags=["Mesajlar"])
DATABASE_URL = os.getenv("DATABASE_URL", "").strip()
logger = logging.getLogger("uvicorn.error")


class SendMessageRequest(BaseModel):
    to_account_id: int
    body: str
    reply_to_message_id: Optional[int] = None


class TypingStateRequest(BaseModel):
    to_account_id: int
    is_typing: bool = False


class EditMessageRequest(BaseModel):
    body: str


class ClearConversationRequest(BaseModel):
    peer_account_id: int


db_conn = get_db_connection

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


def _is_friend(conn, a: int, b: int) -> bool:
    if get_blocked_peer_ids(conn, a) or get_blocked_peer_ids(conn, b): # Changed _block_exists_any to get_blocked_peer_ids
        return False
    x, y = (a, b) if a < b else (b, a)
    cur = conn.cursor()
    cur.execute(
        "SELECT 1 FROM mobile_friendships WHERE user_a_id=%s AND user_b_id=%s LIMIT 1",
        (x, y),
    )
    return bool(cur.fetchone())


def init_message_read_state_table():
    conn = db_conn()
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


def init_message_typing_state_table():
    conn = db_conn()
    try:
        cur = conn.cursor()
        cur.execute(
            """
            CREATE TABLE IF NOT EXISTS mobile_message_typing_state (
                account_id INTEGER NOT NULL,
                peer_account_id INTEGER NOT NULL,
                is_typing BOOLEAN NOT NULL DEFAULT FALSE,
                updated_at TIMESTAMP WITHOUT TIME ZONE NOT NULL DEFAULT NOW(),
                PRIMARY KEY (account_id, peer_account_id)
            )
            """
        )
        cur.execute(
            """
            CREATE INDEX IF NOT EXISTS idx_msg_typing_state_peer
            ON mobile_message_typing_state(peer_account_id, updated_at DESC)
            """
        )
        conn.commit()
    except Exception:
        conn.rollback()
    finally:
        conn.close()


def init_message_extra_tables():
    conn = db_conn()
    try:
        cur = conn.cursor()
        cur.execute(
            """
            DO $$
            BEGIN
                IF NOT EXISTS (
                    SELECT 1 FROM information_schema.columns
                    WHERE table_name='mobile_direct_messages' AND column_name='edited_at'
                ) THEN
                    ALTER TABLE mobile_direct_messages ADD COLUMN edited_at TEXT;
                END IF;
                IF NOT EXISTS (
                    SELECT 1 FROM information_schema.columns
                    WHERE table_name='mobile_direct_messages' AND column_name='deleted_at'
                ) THEN
                    ALTER TABLE mobile_direct_messages ADD COLUMN deleted_at TEXT;
                END IF;
                IF NOT EXISTS (
                    SELECT 1 FROM information_schema.columns
                    WHERE table_name='mobile_direct_messages' AND column_name='reply_to_message_id'
                ) THEN
                    ALTER TABLE mobile_direct_messages ADD COLUMN reply_to_message_id INTEGER REFERENCES mobile_direct_messages(id) ON DELETE SET NULL;
                END IF;
            END$$;
            """
        )
        cur.execute(
            """
            CREATE TABLE IF NOT EXISTS mobile_message_reactions (
                message_id INTEGER NOT NULL REFERENCES mobile_direct_messages(id) ON DELETE CASCADE,
                account_id INTEGER NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
                reaction TEXT NOT NULL DEFAULT 'like',
                created_at TEXT NOT NULL,
                PRIMARY KEY (message_id, account_id, reaction)
            )
            """
        )
        cur.execute(
            """
            CREATE TABLE IF NOT EXISTS mobile_message_thread_clears (
                account_id INTEGER NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
                peer_account_id INTEGER NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
                cleared_before_message_id BIGINT NOT NULL DEFAULT 0,
                cleared_at TEXT,
                PRIMARY KEY (account_id, peer_account_id)
            )
            """
        )
        cur.execute(
            "CREATE INDEX IF NOT EXISTS idx_msg_reactions_message ON mobile_message_reactions(message_id)"
        )
        cur.execute(
            "CREATE INDEX IF NOT EXISTS idx_msg_thread_clears_account ON mobile_message_thread_clears(account_id, peer_account_id)"
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
            LEFT JOIN mobile_message_thread_clears tc
              ON tc.account_id=%s
             AND tc.peer_account_id=m.sender_account_id
            WHERE m.receiver_account_id=%s
              AND m.id > COALESCE(tc.cleared_before_message_id, 0)
              AND m.id > COALESCE(rs.last_read_message_id, 0)
            GROUP BY m.sender_account_id
        ) t
        """,
        (int(account_id), int(account_id), int(account_id)),
    )
    row = cur.fetchone() or {}
    return int(row.get("unread_total") or 0)


@router.get("", summary="Mesaj kutusu")
def list_messages(with_account_id: Optional[int] = None, limit: int = 100, authorization: Optional[str] = Header(default=None)):
    conn = db_conn()
    try:
        me = _require_account_id(conn, authorization)
        cur = conn.cursor() # Changed _blocked_peer_ids to get_blocked_peer_ids
        if with_account_id is None:
            blocked_ids = get_blocked_peer_ids(conn, me)
            cur.execute(
                """
                SELECT
                    CASE WHEN m.sender_account_id=%s THEN m.receiver_account_id ELSE m.sender_account_id END AS peer_id,
                    MAX(m.created_at) AS last_at
                FROM mobile_direct_messages m
                LEFT JOIN mobile_message_thread_clears tc
                  ON tc.account_id=%s
                 AND tc.peer_account_id=(CASE WHEN m.sender_account_id=%s THEN m.receiver_account_id ELSE m.sender_account_id END)
                WHERE (m.sender_account_id=%s OR m.receiver_account_id=%s)
                  AND m.id > COALESCE(tc.cleared_before_message_id, 0)
                GROUP BY peer_id
                ORDER BY MAX(m.created_at) DESC
                LIMIT %s
                """,
                (me, me, me, me, me, max(1, min(int(limit), 500))),
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
            if blocked_ids:
                merged_rows = [row for row in merged_rows if int(row["peer_id"]) not in blocked_ids]
            merged_rows.sort(key=lambda x: str(x.get("last_at") or ""), reverse=True)

            peer_ids = [int(r["peer_id"]) for r in merged_rows]
            details: Dict[int, Dict[str, Any]] = {}
            if peer_ids:
                cur.execute(
                    """
                    SELECT
                        a.id,
                        COALESCE(a.name,'') AS name,
                        COALESCE(a.email,'') AS email,
                        COALESCE(a.role,'') AS role,
                        COALESCE(ps.username,'') AS app_username,
                        COALESCE(ps.is_verified, FALSE) AS is_verified,
                        COALESCE(ps.avatar_url,'') AS avatar_url
                    FROM accounts a
                    LEFT JOIN mobile_profile_settings ps ON ps.account_id=a.id
                    WHERE a.id = ANY(%s)
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
                LEFT JOIN mobile_message_thread_clears tc
                  ON tc.account_id=%s
                 AND tc.peer_account_id=m.sender_account_id
                WHERE m.receiver_account_id=%s
                  AND m.id > COALESCE(tc.cleared_before_message_id, 0)
                  AND m.id > COALESCE(rs.last_read_message_id, 0)
                GROUP BY m.sender_account_id
                """,
                (me, me, me),
            )
            for rr in cur.fetchall() or []:
                unread_by_peer[int(rr["peer_id"])] = int(rr["unread_count"] or 0)

            out: List[Dict[str, Any]] = []
            for r in merged_rows:
                pid = int(r["peer_id"])
                d = details.get(pid, {})
                out.append(
                    { # Changed _display_name to display_name
                        "account_id": pid,
                        "name": display_name((d.get("name") or ""), (d.get("email") or ""), (d.get("app_username") or "")),
                        "last_at": (r.get("last_at") or ""),
                        "is_verified": bool(d.get("is_verified")) or str(d.get("role") or "").strip().lower() in {"super_admin", "editor"},
                        "avatar_url": (d.get("avatar_url") or ""),
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
            SELECT
                m.id,
                m.sender_account_id,
                m.receiver_account_id,
                m.body,
                m.created_at,
                COALESCE(m.edited_at, '') AS edited_at,
                COALESCE(m.deleted_at, '') AS deleted_at,
                m.reply_to_message_id,
                COALESCE((
                    SELECT COUNT(*)::INTEGER
                    FROM mobile_message_reactions mr
                    WHERE mr.message_id=m.id AND mr.reaction='like'
                ), 0) AS like_count,
                EXISTS(
                    SELECT 1
                    FROM mobile_message_reactions mr2
                    WHERE mr2.message_id=m.id
                      AND mr2.account_id=%s
                      AND mr2.reaction='like'
                ) AS liked_by_me,
                rm.id AS reply_message_id,
                rm.sender_account_id AS reply_sender_account_id,
                COALESCE(rm.body, '') AS reply_body,
                COALESCE(rm.deleted_at, '') AS reply_deleted_at
            FROM mobile_direct_messages
            m
            LEFT JOIN mobile_direct_messages rm ON rm.id=m.reply_to_message_id
            LEFT JOIN mobile_message_thread_clears tc
              ON tc.account_id=%s
             AND tc.peer_account_id=%s
            WHERE ((m.sender_account_id=%s AND m.receiver_account_id=%s)
               OR (m.sender_account_id=%s AND m.receiver_account_id=%s))
              AND m.id > COALESCE(tc.cleared_before_message_id, 0)
            ORDER BY m.id DESC
            LIMIT %s
            """,
            (me, me, peer, me, peer, peer, me, max(1, min(int(limit), 500))),
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

        cur.execute(
            """
            SELECT COALESCE(last_read_message_id, 0) AS peer_last_read_message_id
            FROM mobile_message_read_state
            WHERE account_id=%s AND peer_account_id=%s
            LIMIT 1
            """,
            (peer, me),
        )
        rr = cur.fetchone() or {}
        peer_last_read_message_id = int(rr.get("peer_last_read_message_id") or 0)

        cur.execute(
            """
            SELECT 1
            FROM mobile_message_typing_state
            WHERE account_id=%s
              AND peer_account_id=%s
              AND is_typing=TRUE
              AND updated_at >= (NOW() - INTERVAL '8 seconds')
            LIMIT 1
            """,
            (peer, me),
        )
        peer_typing = bool(cur.fetchone())

        conn.commit()
        return {
            "section": "mesajlar",
            "with_account_id": peer,
            "me_account_id": me,
            "items": rows,
            "peer_last_read_message_id": peer_last_read_message_id,
            "peer_typing": peer_typing,
        }
    finally:
        conn.close()


@router.post("/typing", summary="Yaziyor durumu guncelle")
def set_typing_state(payload: TypingStateRequest, authorization: Optional[str] = Header(default=None)):
    conn = db_conn()
    try:
        me = _require_account_id(conn, authorization)
        to_id = int(payload.to_account_id)
        if to_id == me:
            raise HTTPException(status_code=400, detail="Kendiniz icin yaziyor durumu guncellenemez")
        if not _is_friend(conn, me, to_id):
            raise HTTPException(status_code=403, detail="Sadece arkadaslar arasinda mesajlasma acik")

        cur = conn.cursor()
        cur.execute(
            """
            INSERT INTO mobile_message_typing_state (account_id, peer_account_id, is_typing, updated_at)
            VALUES (%s, %s, %s, NOW())
            ON CONFLICT (account_id, peer_account_id) DO UPDATE
            SET is_typing=EXCLUDED.is_typing,
                updated_at=EXCLUDED.updated_at
            """,
            (int(me), int(to_id), bool(payload.is_typing)),
        )
        conn.commit()
        return {"ok": True, "is_typing": bool(payload.is_typing)}
    finally:
        conn.close()


@router.post("/send", summary="Arkadaşa mesaj gönder")
def send_message(payload: SendMessageRequest, authorization: Optional[str] = Header(default=None)):
    body = (payload.body or "").strip()
    if not body:
        raise HTTPException(status_code=400, detail="Mesaj boş olamaz")
    if len(body) > 2000:
        raise HTTPException(status_code=400, detail="Mesaj çok uzun")

    conn = db_conn()
    try:
        me = _require_account_id(conn, authorization)
        to_id = int(payload.to_account_id)
        reply_to_message_id = int(payload.reply_to_message_id or 0)
        if to_id == me:
            raise HTTPException(status_code=400, detail="Kendinize mesaj gönderemezsiniz")
        if not _is_friend(conn, me, to_id):
            raise HTTPException(status_code=403, detail="Sadece arkadaşlara mesaj gönderilebilir")
        cur = conn.cursor()
        reply_ref = None
        if reply_to_message_id > 0:
            cur.execute(
                """
                SELECT id
                FROM mobile_direct_messages
                WHERE id=%s
                  AND (
                        (sender_account_id=%s AND receiver_account_id=%s)
                     OR (sender_account_id=%s AND receiver_account_id=%s)
                  )
                LIMIT 1
                """,
                (reply_to_message_id, me, to_id, to_id, me),
            )
            rr = cur.fetchone()
            if not rr:
                raise HTTPException(status_code=404, detail="Yanıtlanacak mesaj bulunamadı")
            reply_ref = int(rr["id"])
        cur.execute(
            """
            INSERT INTO mobile_direct_messages (sender_account_id, receiver_account_id, body, created_at, reply_to_message_id)
            VALUES (%s,%s,%s,%s,%s)
            RETURNING id
            """,
            (me, to_id, body, _iso_now(), reply_ref),
        )
        mid = int(cur.fetchone()["id"])

        # Mesaj gonderildiginde "yaziyor..." durumunu kapat.
        cur.execute(
            """
            INSERT INTO mobile_message_typing_state (account_id, peer_account_id, is_typing, updated_at)
            VALUES (%s, %s, FALSE, NOW())
            ON CONFLICT (account_id, peer_account_id) DO UPDATE
            SET is_typing=FALSE,
                updated_at=EXCLUDED.updated_at
            """,
            (int(me), int(to_id)),
        )

        # Alıcıya uygulama içi bildirim kaydı + push gönderimi (mesaj bildirimi)
        sender_display = "Bir arkadaşın"
        try:
            cur.execute(
                """
                SELECT
                    COALESCE(a.name,'') AS name,
                    COALESCE(a.email,'') AS email,
                    COALESCE(ps.username,'') AS app_username
                FROM accounts a
                LEFT JOIN mobile_profile_settings ps ON ps.account_id=a.id
                WHERE a.id=%s
                LIMIT 1
                """,
                (int(me),),
            )
            srow = cur.fetchone() or {}
            sender_display = display_name(
                (srow.get("name") or ""),
                (srow.get("email") or ""), # Changed _display_name to display_name
                (srow.get("app_username") or ""),
            )
        except Exception:
            sender_display = "Bir arkadaşın"

        preview = body if len(body) <= 120 else (body[:117] + "...")
        notif_title = "Yeni bir mesajın var"
        notif_body = f"{sender_display}: {preview}"

        try:
            cur.execute(
                """
                INSERT INTO mobile_user_notifications
                    (account_id, title, body, notification_type, sent_by_account_id, send_batch_id, send_to_all, target_route, created_at)
                VALUES (%s, %s, %s, 'message', %s, NULL, FALSE, %s, NOW())
                """,
                (int(to_id), notif_title, notif_body, int(me), "/profile/notifications"),
            )
        except Exception as exc:
            logger.warning("message_notification_insert_failed to=%s err=%s", int(to_id), str(exc))

        try:
            # Local import: profile.py bu modulu import ettigi icin dairesel importu
            # module-levelde degil, runtime'da burada aciyoruz.
            from app.routers import profile as profile_router

            push_result = profile_router._dispatch_push_for_accounts(
                conn=conn,
                account_ids=[int(to_id)],
                title=notif_title,
                body=notif_body,
                sender_account_id=int(me),
                route="/profile/notifications",
                notification_type="message",
                extra_data={
                    "from_account_id": int(me),
                    "message_id": int(mid),
                },
            )
            logger.info(
                "message_push_send sender=%s receiver=%s message_id=%s result=%s",
                int(me),
                int(to_id),
                int(mid),
                push_result,
            )
        except Exception as exc:
            logger.warning(
                "message_push_send_failed sender=%s receiver=%s message_id=%s err=%s",
                int(me),
                int(to_id),
                int(mid),
                str(exc),
            )

        conn.commit()
        return {"ok": True, "message_id": mid}
    finally:
        conn.close()


@router.post("/{message_id}/edit", summary="Kendi mesajını düzenle")
def edit_message(message_id: int, payload: EditMessageRequest, authorization: Optional[str] = Header(default=None)):
    body = (payload.body or "").strip()
    if not body:
        raise HTTPException(status_code=400, detail="Mesaj boş olamaz")
    if len(body) > 2000:
        raise HTTPException(status_code=400, detail="Mesaj çok uzun")
    conn = db_conn()
    try: # Changed _db_conn to db_conn
        me = _require_account_id(conn, authorization)
        cur = conn.cursor()
        cur.execute(
            """
            SELECT id, sender_account_id, deleted_at
            FROM mobile_direct_messages
            WHERE id=%s
            LIMIT 1
            """,
            (int(message_id),),
        )
        row = cur.fetchone()
        if not row:
            raise HTTPException(status_code=404, detail="Mesaj bulunamadı")
        if int(row.get("sender_account_id") or 0) != int(me):
            raise HTTPException(status_code=403, detail="Sadece kendi mesajınızı düzenleyebilirsiniz")
        if str(row.get("deleted_at") or "").strip():
            raise HTTPException(status_code=400, detail="Silinmiş mesaj düzenlenemez")
        cur.execute(
            """
            UPDATE mobile_direct_messages
            SET body=%s, edited_at=%s
            WHERE id=%s
            """,
            (body, _iso_now(), int(message_id)),
        )
        conn.commit()
        return {"ok": True, "message_id": int(message_id)}
    finally:
        conn.close()


@router.post("/{message_id}/delete", summary="Kendi mesajını sil")
def delete_message(message_id: int, authorization: Optional[str] = Header(default=None)):
    conn = db_conn()
    try: # Changed _db_conn to db_conn
        me = _require_account_id(conn, authorization)
        cur = conn.cursor()
        cur.execute(
            """
            SELECT id, sender_account_id
            FROM mobile_direct_messages
            WHERE id=%s
            LIMIT 1
            """,
            (int(message_id),),
        )
        row = cur.fetchone()
        if not row:
            raise HTTPException(status_code=404, detail="Mesaj bulunamadı")
        if int(row.get("sender_account_id") or 0) != int(me):
            raise HTTPException(status_code=403, detail="Sadece kendi mesajınızı silebilirsiniz")
        cur.execute(
            """
            UPDATE mobile_direct_messages
            SET body='', deleted_at=%s, edited_at=NULL
            WHERE id=%s
            """,
            (_iso_now(), int(message_id)),
        )
        conn.commit()
        return {"ok": True, "message_id": int(message_id)}
    finally:
        conn.close()


@router.post("/{message_id}/like", summary="Mesajı beğen")
def like_message(message_id: int, authorization: Optional[str] = Header(default=None)):
    conn = db_conn()
    try: # Changed _db_conn to db_conn
        me = _require_account_id(conn, authorization)
        cur = conn.cursor()
        cur.execute(
            """
            SELECT id, sender_account_id, receiver_account_id, deleted_at
            FROM mobile_direct_messages
            WHERE id=%s
            LIMIT 1
            """,
            (int(message_id),),
        )
        row = cur.fetchone()
        if not row:
            raise HTTPException(status_code=404, detail="Mesaj bulunamadı")
        sender_id = int(row.get("sender_account_id") or 0)
        receiver_id = int(row.get("receiver_account_id") or 0)
        if me not in {sender_id, receiver_id}:
            raise HTTPException(status_code=403, detail="Bu mesaja erişim yok")
        if sender_id == me:
            raise HTTPException(status_code=400, detail="Kendi mesajınızı beğenemezsiniz")
        if str(row.get("deleted_at") or "").strip():
            raise HTTPException(status_code=400, detail="Silinmiş mesaj beğenilemez")
        cur.execute(
            """
            INSERT INTO mobile_message_reactions (message_id, account_id, reaction, created_at)
            VALUES (%s, %s, 'like', %s)
            ON CONFLICT (message_id, account_id, reaction) DO NOTHING
            """,
            (int(message_id), int(me), _iso_now()),
        )
        conn.commit()
        return {"ok": True, "message_id": int(message_id), "liked_by_me": True}
    finally:
        conn.close()


@router.post("/{message_id}/unlike", summary="Mesaj beğenisini geri al")
def unlike_message(message_id: int, authorization: Optional[str] = Header(default=None)):
    conn = db_conn()
    try: # Changed _db_conn to db_conn
        me = _require_account_id(conn, authorization)
        cur = conn.cursor()
        cur.execute(
            "DELETE FROM mobile_message_reactions WHERE message_id=%s AND account_id=%s AND reaction='like'",
            (int(message_id), int(me)),
        )
        conn.commit()
        return {"ok": True, "message_id": int(message_id), "liked_by_me": False}
    finally:
        conn.close()


@router.post("/clear", summary="Sohbeti benim görünümümden temizle")
def clear_conversation(payload: ClearConversationRequest, authorization: Optional[str] = Header(default=None)):
    conn = db_conn()
    try: # Changed _db_conn to db_conn
        me = _require_account_id(conn, authorization)
        peer = int(payload.peer_account_id)
        if peer == me:
            raise HTTPException(status_code=400, detail="Geçersiz kullanıcı")
        cur = conn.cursor()
        cur.execute(
            """
            SELECT COALESCE(MAX(id), 0) AS max_id
            FROM mobile_direct_messages
            WHERE (sender_account_id=%s AND receiver_account_id=%s)
               OR (sender_account_id=%s AND receiver_account_id=%s)
            """,
            (int(me), int(peer), int(peer), int(me)),
        )
        max_id = int((cur.fetchone() or {}).get("max_id") or 0)
        cur.execute(
            """
            INSERT INTO mobile_message_thread_clears (account_id, peer_account_id, cleared_before_message_id, cleared_at)
            VALUES (%s, %s, %s, %s)
            ON CONFLICT (account_id, peer_account_id) DO UPDATE
            SET cleared_before_message_id = GREATEST(mobile_message_thread_clears.cleared_before_message_id, EXCLUDED.cleared_before_message_id),
                cleared_at = EXCLUDED.cleared_at
            """,
            (int(me), int(peer), int(max_id), _iso_now()),
        )
        if max_id > 0:
            cur.execute(
                """
                INSERT INTO mobile_message_read_state (account_id, peer_account_id, last_read_message_id, last_read_at)
                VALUES (%s, %s, %s, %s)
                ON CONFLICT (account_id, peer_account_id) DO UPDATE
                SET last_read_message_id = GREATEST(mobile_message_read_state.last_read_message_id, EXCLUDED.last_read_message_id),
                    last_read_at = EXCLUDED.last_read_at
                """,
                (int(me), int(peer), int(max_id), _iso_now()),
            )
        conn.commit()
        return {"ok": True, "peer_account_id": int(peer), "cleared_before_message_id": int(max_id)}
    finally:
        conn.close()
