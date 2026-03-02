import os
from typing import Any, Dict, List, Optional

import psycopg2
import psycopg2.extras
from fastapi import APIRouter, Header, HTTPException
from pydantic import BaseModel, Field

router = APIRouter(prefix="/profile", tags=["Profil"])
DATABASE_URL = os.getenv("DATABASE_URL", "").strip()


def _db_conn():
    if not DATABASE_URL:
        raise HTTPException(status_code=500, detail="DATABASE_URL eksik")
    return psycopg2.connect(DATABASE_URL, cursor_factory=psycopg2.extras.RealDictCursor)


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


def _friend_pair(a: int, b: int) -> tuple[int, int]:
    return (a, b) if a < b else (b, a)


def init_profile_settings_table():
    conn = _db_conn()
    try:
        cur = conn.cursor()
        cur.execute(
            """
            CREATE TABLE IF NOT EXISTS mobile_profile_settings (
                account_id INTEGER PRIMARY KEY,
                username VARCHAR(40),
                preferred_language VARCHAR(8),
                notifications_enabled BOOLEAN,
                updated_at TIMESTAMP WITHOUT TIME ZONE DEFAULT NOW()
            )
            """
        )
        conn.commit()
    except Exception:
        conn.rollback()
    finally:
        conn.close()


def _get_settings(conn, account_id: int) -> Dict[str, Any]:
    cur = conn.cursor()
    cur.execute(
        """
        SELECT username, preferred_language, notifications_enabled, updated_at
        FROM mobile_profile_settings
        WHERE account_id=%s
        LIMIT 1
        """,
        (int(account_id),),
    )
    row = cur.fetchone() or {}
    return {
        "username": (row.get("username") or "").strip(),
        "language": (row.get("preferred_language") or "").strip().lower() or "tr",
        "notifications_enabled": bool(row.get("notifications_enabled")) if row.get("notifications_enabled") is not None else True,
        "updated_at": (row.get("updated_at") or ""),
    }


class ProfileSettingsUpdateRequest(BaseModel):
    username: Optional[str] = Field(default=None)
    language: Optional[str] = Field(default=None)
    notifications_enabled: Optional[bool] = Field(default=None)


@router.get("", summary="Profil özeti")
def profile_summary(authorization: Optional[str] = Header(default=None)):
    if not authorization:
        return {
            "section": "profil",
            "name": None,
            "email": None,
            "friend_count": 0,
            "message": "Profil bilgileri burada dönecek.",
        }

    conn = _db_conn()
    try:
        account_id = _require_account_id(conn, authorization)
        cur = conn.cursor()
        cur.execute("SELECT COALESCE(name,'') AS name, COALESCE(email,'') AS email FROM accounts WHERE id=%s LIMIT 1", (account_id,))
        user = cur.fetchone() or {}
        cur.execute(
            """
            SELECT COUNT(*) AS cnt
            FROM mobile_friendships
            WHERE user_a_id=%s OR user_b_id=%s
            """,
            (account_id, account_id),
        )
        fcnt = int((cur.fetchone() or {}).get("cnt") or 0)
        return {
            "section": "profil",
            "account_id": account_id,
            "name": _display_name((user.get("name") or ""), (user.get("email") or "")),
            "email": (user.get("email") or ""),
            "friend_count": fcnt,
        }
    finally:
        conn.close()


@router.get("/friends", summary="Arkadaş listesi")
def profile_friends(limit: int = 200, authorization: Optional[str] = Header(default=None)):
    conn = _db_conn()
    try:
        account_id = _require_account_id(conn, authorization)
        cur = conn.cursor()
        cur.execute(
            """
            SELECT
                CASE WHEN mf.user_a_id=%s THEN mf.user_b_id ELSE mf.user_a_id END AS friend_account_id,
                mf.created_at
            FROM mobile_friendships mf
            WHERE mf.user_a_id=%s OR mf.user_b_id=%s
            ORDER BY mf.created_at DESC
            LIMIT %s
            """,
            (account_id, account_id, account_id, max(1, min(int(limit), 500))),
        )
        rows = cur.fetchall() or []
        friend_ids = [int(r["friend_account_id"]) for r in rows]
        details: Dict[int, Dict[str, Any]] = {}
        if friend_ids:
            cur.execute(
                """
                SELECT id, COALESCE(name,'') AS name, COALESCE(email,'') AS email
                FROM accounts
                WHERE id = ANY(%s)
                """,
                (friend_ids,),
            )
            for r in cur.fetchall() or []:
                details[int(r["id"])] = dict(r)
        items: List[Dict[str, Any]] = []
        for r in rows:
            fid = int(r["friend_account_id"])
            d = details.get(fid, {})
            items.append(
                {
                    "account_id": fid,
                    "name": _display_name((d.get("name") or ""), (d.get("email") or "")),
                    "email": (d.get("email") or ""),
                    "friends_since": (r.get("created_at") or ""),
                }
            )
        return {"items": items}
    finally:
        conn.close()


@router.get("/friends/{friend_account_id}", summary="Arkadaş profil detayı")
def profile_friend_detail(friend_account_id: int, authorization: Optional[str] = Header(default=None)):
    conn = _db_conn()
    try:
        account_id = _require_account_id(conn, authorization)
        fid = int(friend_account_id)
        if fid == account_id:
            raise HTTPException(status_code=400, detail="Bu endpoint arkadaş profili içindir")

        cur = conn.cursor()
        a, b = (account_id, fid) if account_id < fid else (fid, account_id)
        cur.execute(
            "SELECT created_at FROM mobile_friendships WHERE user_a_id=%s AND user_b_id=%s LIMIT 1",
            (a, b),
        )
        fr = cur.fetchone()
        if not fr:
            raise HTTPException(status_code=403, detail="Bu kullanıcı arkadaş listende değil")

        cur.execute(
            "SELECT id, COALESCE(name,'') AS name, COALESCE(email,'') AS email FROM accounts WHERE id=%s LIMIT 1",
            (fid,),
        )
        row = cur.fetchone()
        if not row:
            raise HTTPException(status_code=404, detail="Kullanıcı bulunamadı")
        return {
            "account_id": int(row["id"]),
            "name": _display_name((row.get("name") or ""), (row.get("email") or "")),
            "email": (row.get("email") or ""),
            "friends_since": (fr.get("created_at") or ""),
        }
    finally:
        conn.close()


@router.get("/friend-requests", summary="Arkadaşlık istekleri")
def profile_friend_requests(
    direction: str = "incoming",
    limit: int = 100,
    authorization: Optional[str] = Header(default=None),
):
    direction = (direction or "incoming").strip().lower()
    if direction not in {"incoming", "outgoing"}:
        direction = "incoming"
    conn = _db_conn()
    try:
        account_id = _require_account_id(conn, authorization)
        cur = conn.cursor()
        lim = max(1, min(int(limit), 500))
        if direction == "incoming":
            cur.execute(
                """
                SELECT r.id, r.requester_id AS peer_id, r.created_at, COALESCE(a.name,'') AS name, COALESCE(a.email,'') AS email
                FROM mobile_friend_requests r
                JOIN accounts a ON a.id=r.requester_id
                WHERE r.target_id=%s AND r.status='pending'
                ORDER BY r.id DESC
                LIMIT %s
                """,
                (account_id, lim),
            )
        else:
            cur.execute(
                """
                SELECT r.id, r.target_id AS peer_id, r.created_at, COALESCE(a.name,'') AS name, COALESCE(a.email,'') AS email
                FROM mobile_friend_requests r
                JOIN accounts a ON a.id=r.target_id
                WHERE r.requester_id=%s AND r.status='pending'
                ORDER BY r.id DESC
                LIMIT %s
                """,
                (account_id, lim),
            )
        rows = cur.fetchall() or []
        items: List[Dict[str, Any]] = []
        for r in rows:
            items.append(
                {
                    "request_id": int(r["id"]),
                    "peer_account_id": int(r["peer_id"]),
                    "peer_name": _display_name((r.get("name") or ""), (r.get("email") or "")),
                    "peer_email": (r.get("email") or ""),
                    "created_at": (r.get("created_at") or ""),
                }
            )
        return {"direction": direction, "items": items}
    finally:
        conn.close()


@router.post("/friend-requests/{request_id}/accept", summary="Arkadaşlık isteğini kabul et")
def accept_friend_request(request_id: int, authorization: Optional[str] = Header(default=None)):
    conn = _db_conn()
    try:
        account_id = _require_account_id(conn, authorization)
        cur = conn.cursor()
        cur.execute(
            """
            SELECT requester_id, target_id, status
            FROM mobile_friend_requests
            WHERE id=%s
            LIMIT 1
            """,
            (int(request_id),),
        )
        row = cur.fetchone()
        if not row:
            raise HTTPException(status_code=404, detail="Arkadaşlık isteği bulunamadı")
        if (row.get("status") or "") != "pending":
            raise HTTPException(status_code=400, detail="Bu istek artık beklemede değil")
        requester_id = int(row["requester_id"])
        target_id = int(row["target_id"])
        if target_id != account_id:
            raise HTTPException(status_code=403, detail="Bu isteği kabul etme yetkiniz yok")

        a, b = _friend_pair(requester_id, target_id)
        cur.execute(
            """
            INSERT INTO mobile_friendships (user_a_id, user_b_id, created_at)
            VALUES (%s,%s,NOW()::text)
            ON CONFLICT (user_a_id, user_b_id) DO NOTHING
            """,
            (a, b),
        )
        cur.execute(
            """
            UPDATE mobile_friend_requests
            SET status='accepted', responded_at=NOW()::text
            WHERE id=%s
            """,
            (int(request_id),),
        )
        conn.commit()
        return {"ok": True, "request_id": int(request_id), "status": "accepted"}
    finally:
        conn.close()


@router.get("/tickets", summary="Kullanıcının biletleri")
def profile_tickets(limit: int = 200, authorization: Optional[str] = Header(default=None)):
    conn = _db_conn()
    try:
        account_id = _require_account_id(conn, authorization)
        cur = conn.cursor()
        cur.execute(
            """
            SELECT
                t.id,
                t.submission_id,
                t.event_name,
                t.event_slug,
                t.qr_token,
                t.woo_order_id,
                t.status,
                t.created_at,
                t.used_at
            FROM mobile_tickets t
            WHERE t.account_id=%s
            ORDER BY t.created_at DESC, t.id DESC
            LIMIT %s
            """,
            (int(account_id), max(1, min(int(limit), 1000))),
        )
        rows = cur.fetchall() or []
        return {
            "items": [
                {
                    "ticket_id": int(r["id"]),
                    "submission_id": int(r["submission_id"]),
                    "event_name": (r.get("event_name") or ""),
                    "event_slug": (r.get("event_slug") or ""),
                    "qr_token": (r.get("qr_token") or ""),
                    "woo_order_id": (r.get("woo_order_id") or ""),
                    "status": (r.get("status") or "active"),
                    "created_at": (r.get("created_at") or ""),
                    "used_at": (r.get("used_at") or ""),
                    "is_used": bool((r.get("used_at") or "").strip()),
                }
                for r in rows
            ]
        }
    finally:
        conn.close()


@router.get("/tickets/{ticket_id}", summary="Tek bilet detayı")
def profile_ticket_detail(ticket_id: int, authorization: Optional[str] = Header(default=None)):
    conn = _db_conn()
    try:
        account_id = _require_account_id(conn, authorization)
        cur = conn.cursor()
        cur.execute(
            """
            SELECT
                t.id,
                t.submission_id,
                t.event_name,
                t.event_slug,
                t.qr_token,
                t.woo_order_id,
                t.status,
                t.created_at,
                t.used_at
            FROM mobile_tickets t
            WHERE t.id=%s AND t.account_id=%s
            LIMIT 1
            """,
            (int(ticket_id), int(account_id)),
        )
        row = cur.fetchone()
        if not row:
            raise HTTPException(status_code=404, detail="Bilet bulunamadı")
        return {
            "ticket_id": int(row["id"]),
            "submission_id": int(row["submission_id"]),
            "event_name": (row.get("event_name") or ""),
            "event_slug": (row.get("event_slug") or ""),
            "qr_token": (row.get("qr_token") or ""),
            "woo_order_id": (row.get("woo_order_id") or ""),
            "status": (row.get("status") or "active"),
            "created_at": (row.get("created_at") or ""),
            "used_at": (row.get("used_at") or ""),
            "is_used": bool((row.get("used_at") or "").strip()),
        }
    finally:
        conn.close()


@router.post("/friend-requests/{request_id}/reject", summary="Arkadaşlık isteğini reddet")
def reject_friend_request(request_id: int, authorization: Optional[str] = Header(default=None)):
    conn = _db_conn()
    try:
        account_id = _require_account_id(conn, authorization)
        cur = conn.cursor()
        cur.execute(
            """
            SELECT requester_id, target_id, status
            FROM mobile_friend_requests
            WHERE id=%s
            LIMIT 1
            """,
            (int(request_id),),
        )
        row = cur.fetchone()
        if not row:
            raise HTTPException(status_code=404, detail="Arkadaşlık isteği bulunamadı")
        if (row.get("status") or "") != "pending":
            raise HTTPException(status_code=400, detail="Bu istek artık beklemede değil")
        target_id = int(row["target_id"])
        if target_id != account_id:
            raise HTTPException(status_code=403, detail="Bu isteği reddetme yetkiniz yok")
        cur.execute(
            """
            UPDATE mobile_friend_requests
            SET status='rejected', responded_at=NOW()::text
            WHERE id=%s
            """,
            (int(request_id),),
        )
        conn.commit()
        return {"ok": True, "request_id": int(request_id), "status": "rejected"}
    finally:
        conn.close()


@router.get("/settings", summary="Profil ayarları")
def profile_settings(authorization: Optional[str] = Header(default=None)):
    conn = _db_conn()
    try:
        account_id = _require_account_id(conn, authorization)
        cur = conn.cursor()
        cur.execute(
            "SELECT COALESCE(name,'') AS name, COALESCE(email,'') AS email FROM accounts WHERE id=%s LIMIT 1",
            (int(account_id),),
        )
        user = cur.fetchone() or {}
        settings = _get_settings(conn, account_id)
        username = settings.get("username") or ""
        if not username:
            username = _display_name((user.get("name") or ""), (user.get("email") or ""))
        return {
            "account_id": int(account_id),
            "username": username,
            "email": (user.get("email") or ""),
            "language": settings.get("language") or "tr",
            "notifications_enabled": bool(settings.get("notifications_enabled")),
            "updated_at": (settings.get("updated_at") or ""),
        }
    finally:
        conn.close()


@router.put("/settings", summary="Profil ayarlarını güncelle")
def update_profile_settings(
    payload: ProfileSettingsUpdateRequest,
    authorization: Optional[str] = Header(default=None),
):
    conn = _db_conn()
    try:
        account_id = _require_account_id(conn, authorization)
        username = (payload.username or "").strip()
        language = (payload.language or "").strip().lower()
        if username and (len(username) < 3 or len(username) > 40):
            raise HTTPException(status_code=400, detail="Kullanıcı adı 3-40 karakter olmalı")
        if username and any(ch.isspace() for ch in username):
            raise HTTPException(status_code=400, detail="Kullanıcı adı boşluk içeremez")
        if language and language not in {"tr", "en"}:
            raise HTTPException(status_code=400, detail="Geçersiz dil seçimi")

        cur = conn.cursor()
        cur.execute(
            """
            INSERT INTO mobile_profile_settings (account_id, username, preferred_language, notifications_enabled, updated_at)
            VALUES (%s, NULLIF(%s,''), NULLIF(%s,''), %s, NOW())
            ON CONFLICT (account_id) DO UPDATE
            SET username = COALESCE(EXCLUDED.username, mobile_profile_settings.username),
                preferred_language = COALESCE(EXCLUDED.preferred_language, mobile_profile_settings.preferred_language),
                notifications_enabled = COALESCE(EXCLUDED.notifications_enabled, mobile_profile_settings.notifications_enabled),
                updated_at = NOW()
            """,
            (
                int(account_id),
                username if payload.username is not None else "",
                language if payload.language is not None else "",
                payload.notifications_enabled,
            ),
        )
        conn.commit()
    finally:
        conn.close()
    return profile_settings(authorization=authorization)
