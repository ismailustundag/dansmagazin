import base64
import hashlib
import hmac
import os
import secrets
from datetime import datetime, timedelta, timezone
from typing import Any, Dict, Optional

import httpx
import psycopg2
import psycopg2.extras
from fastapi import APIRouter, Header, HTTPException
from pydantic import BaseModel

router = APIRouter(prefix="/auth", tags=["Auth"])

DATABASE_URL = os.getenv("DATABASE_URL", "").strip()
WP_BASE_URL = os.getenv("WP_BASE_URL", "https://www.dansmagazin.net").rstrip("/")
WOO_BASE_URL = os.getenv("WOO_BASE_URL", WP_BASE_URL).rstrip("/")
WOO_CONSUMER_KEY = os.getenv("WOO_CONSUMER_KEY", "").strip()
WOO_CONSUMER_SECRET = os.getenv("WOO_CONSUMER_SECRET", "").strip()
WP_JWT_TOKEN_URL = os.getenv("WP_JWT_TOKEN_URL", f"{WP_BASE_URL}/wp-json/jwt-auth/v1/token").strip()


class LoginRequest(BaseModel):
    username_or_email: str
    password: str
    remember_me: bool = True


class RegisterRequest(BaseModel):
    email: str
    password: str
    name: str = ""
    remember_me: bool = True


class SessionResponse(BaseModel):
    session_token: str
    expires_at: str
    account_id: int
    email: str
    name: str
    wp_user_id: Optional[int] = None
    wp_roles: list[str] = []


class MeResponse(BaseModel):
    account_id: int
    email: str
    name: str
    wp_user_id: Optional[int] = None
    wp_roles: list[str] = []


def _db_conn():
    if not DATABASE_URL:
        raise HTTPException(status_code=500, detail="DATABASE_URL eksik")
    return psycopg2.connect(
        DATABASE_URL,
        connect_timeout=3,
        cursor_factory=psycopg2.extras.RealDictCursor,
    )


def _pbkdf2_hash(password: str, salt: bytes) -> bytes:
    return hashlib.pbkdf2_hmac("sha256", password.encode("utf-8"), salt, 120_000)


def _hash_password(password: str) -> str:
    salt = secrets.token_bytes(16)
    dk = _pbkdf2_hash(password, salt)
    return base64.b64encode(salt + dk).decode("utf-8")


def _session_expiry(remember_me: bool) -> str:
    dt = datetime.now(timezone.utc) + (timedelta(days=30) if remember_me else timedelta(days=1))
    return dt.isoformat(timespec="seconds")


async def _wp_login(username_or_email: str, password: str) -> Dict[str, Any]:
    payload = {"username": username_or_email, "password": password}
    async with httpx.AsyncClient(timeout=15.0) as c:
        r = await c.post(WP_JWT_TOKEN_URL, json=payload)
    if r.status_code != 200:
        detail = "WP login başarısız"
        try:
            body = r.json()
            detail = body.get("message") or body.get("detail") or detail
        except Exception:
            pass
        raise HTTPException(status_code=401, detail=detail)
    return r.json()


async def _wp_me(jwt_token: str) -> Dict[str, Any]:
    url = f"{WP_BASE_URL}/wp-json/wp/v2/users/me?context=edit"
    headers = {"Authorization": f"Bearer {jwt_token}"}
    async with httpx.AsyncClient(timeout=15.0) as c:
        r = await c.get(url, headers=headers)
    if r.status_code != 200:
        raise HTTPException(status_code=401, detail="WP kullanıcı detayı alınamadı")
    return r.json()


async def _woo_create_customer(email: str, password: str, name: str) -> Dict[str, Any]:
    if not (WOO_BASE_URL and WOO_CONSUMER_KEY and WOO_CONSUMER_SECRET):
        raise HTTPException(status_code=500, detail="Woo ayarları eksik (WOO_BASE_URL/CK/CS)")

    fn, ln = "", ""
    parts = [p for p in name.strip().split(" ") if p]
    if parts:
        fn = parts[0]
        ln = " ".join(parts[1:]) if len(parts) > 1 else ""

    username = email.split("@", 1)[0]
    payload = {
        "email": email,
        "username": username,
        "password": password,
        "first_name": fn,
        "last_name": ln,
    }
    url = f"{WOO_BASE_URL}/wp-json/wc/v3/customers"
    params = {"consumer_key": WOO_CONSUMER_KEY, "consumer_secret": WOO_CONSUMER_SECRET}

    async with httpx.AsyncClient(timeout=20.0) as c:
        r = await c.post(url, params=params, json=payload)

    if r.status_code in (200, 201):
        return r.json()

    # already exists gibi durumlar
    try:
        body = r.json()
        msg = body.get("message") or "Woo kullanıcı oluşturulamadı"
    except Exception:
        msg = "Woo kullanıcı oluşturulamadı"
    raise HTTPException(status_code=400, detail=msg)


def _role_from_wp_roles(wp_roles: list[str]) -> str:
    roles = {str(x).strip().lower() for x in (wp_roles or [])}
    if "administrator" in roles:
        return "super_admin"
    return "customer"


def _upsert_local_account(conn, email: str, name: str, role: str, raw_password: str) -> int:
    c = conn.cursor()
    c.execute("SELECT id FROM accounts WHERE LOWER(email)=LOWER(%s) LIMIT 1", (email,))
    row = c.fetchone()
    if row:
        aid = int(row["id"])
        c.execute(
            "UPDATE accounts SET name=COALESCE(NULLIF(%s,''), name), role=COALESCE(NULLIF(%s,''), role), is_active=1 WHERE id=%s",
            (name.strip(), role.strip(), aid),
        )
        return aid

    c.execute(
        """
        INSERT INTO accounts (email, password_hash, role, is_active, photo_credit, name, created_at)
        VALUES (%s,%s,%s,1,0,%s,%s)
        RETURNING id
        """,
        (email.strip().lower(), _hash_password(raw_password), role, name.strip(), datetime.now(timezone.utc).isoformat(timespec="seconds")),
    )
    return int(c.fetchone()["id"])


def _upsert_identity_map(conn, wp_user_id: Optional[int], app_account_id: int, strategy: str, confidence: int, note: str):
    if not wp_user_id:
        return
    c = conn.cursor()
    c.execute(
        """
        INSERT INTO identity_map (wp_user_id, app_account_id, match_strategy, confidence, note, is_active)
        VALUES (%s,%s,%s,%s,%s,TRUE)
        ON CONFLICT (wp_user_id) DO UPDATE
        SET app_account_id=EXCLUDED.app_account_id,
            match_strategy=EXCLUDED.match_strategy,
            confidence=EXCLUDED.confidence,
            note=EXCLUDED.note,
            linked_at=NOW(),
            is_active=TRUE
        """,
        (int(wp_user_id), int(app_account_id), strategy, int(confidence), note),
    )


def _create_session(conn, account_id: int, remember_me: bool) -> tuple[str, str]:
    token = secrets.token_urlsafe(32)
    expires_at = _session_expiry(remember_me)
    c = conn.cursor()
    c.execute(
        "INSERT INTO sessions (account_id, session_token, expires_at, created_at) VALUES (%s,%s,%s,%s)",
        (int(account_id), token, expires_at, datetime.now(timezone.utc).isoformat(timespec="seconds")),
    )
    return token, expires_at


def _get_session(conn, token: str) -> Optional[Dict[str, Any]]:
    c = conn.cursor()
    c.execute(
        """
        SELECT s.account_id, s.expires_at, a.email, COALESCE(a.name,'') AS name
        FROM sessions s
        JOIN accounts a ON a.id=s.account_id
        WHERE s.session_token=%s
        LIMIT 1
        """,
        (token,),
    )
    return c.fetchone()


def _find_wp_by_account(conn, account_id: int) -> tuple[Optional[int], list[str]]:
    c = conn.cursor()
    c.execute("SELECT wp_user_id FROM identity_map WHERE app_account_id=%s AND is_active=TRUE LIMIT 1", (int(account_id),))
    row = c.fetchone()
    wp_user_id = int(row["wp_user_id"]) if row and row.get("wp_user_id") is not None else None
    return wp_user_id, []


@router.post("/login", response_model=SessionResponse)
async def login(payload: LoginRequest):
    if not payload.username_or_email.strip() or not payload.password:
        raise HTTPException(status_code=400, detail="username/email ve şifre zorunlu")

    wp_token_payload = await _wp_login(payload.username_or_email.strip(), payload.password)
    jwt_token = (wp_token_payload.get("token") or "").strip()
    wp_email = (wp_token_payload.get("user_email") or "").strip().lower()
    wp_name = (wp_token_payload.get("user_display_name") or "").strip()

    wp_user_id = None
    wp_roles: list[str] = []

    if jwt_token:
        try:
            me = await _wp_me(jwt_token)
            wp_user_id = int(me.get("id")) if me.get("id") is not None else None
            wp_email = (me.get("email") or wp_email or "").strip().lower()
            wp_name = (me.get("name") or wp_name or "").strip()
            wp_roles = [str(x) for x in (me.get("roles") or [])]
        except Exception:
            # me endpoint yoksa token payload ile devam
            pass

    if not wp_email:
        raise HTTPException(status_code=400, detail="WP kullanıcı email alınamadı")

    role = _role_from_wp_roles(wp_roles)

    conn = _db_conn()
    try:
        account_id = _upsert_local_account(conn, wp_email, wp_name, role, payload.password)
        _upsert_identity_map(conn, wp_user_id, account_id, "wp_jwt_login", 100, "live_login")
        session_token, expires_at = _create_session(conn, account_id, payload.remember_me)
        conn.commit()
        return SessionResponse(
            session_token=session_token,
            expires_at=expires_at,
            account_id=account_id,
            email=wp_email,
            name=wp_name,
            wp_user_id=wp_user_id,
            wp_roles=wp_roles,
        )
    except HTTPException:
        conn.rollback()
        raise
    except Exception:
        conn.rollback()
        raise HTTPException(status_code=500, detail="Login sırasında sistem hatası")
    finally:
        conn.close()


@router.post("/register", response_model=SessionResponse)
async def register(payload: RegisterRequest):
    email = payload.email.strip().lower()
    name = payload.name.strip()
    if '@' not in email or '.' not in email.split('@')[-1]:
        raise HTTPException(status_code=400, detail='Geçerli email gerekli')

    # 1) Woo/WP üzerinde kullanıcı oluştur
    await _woo_create_customer(email=email, password=payload.password, name=name)

    # 2) Aynı credentials ile WP login yapıp yerelde map/session oluştur
    return await login(
        LoginRequest(
            username_or_email=email,
            password=payload.password,
            remember_me=payload.remember_me,
        )
    )


@router.get("/me", response_model=MeResponse)
def me(authorization: Optional[str] = Header(default=None)):
    if not authorization or not authorization.lower().startswith("bearer "):
        raise HTTPException(status_code=401, detail="Bearer token gerekli")
    token = authorization.split(" ", 1)[1].strip()
    if not token:
        raise HTTPException(status_code=401, detail="Token boş")

    conn = _db_conn()
    try:
        s = _get_session(conn, token)
        if not s:
            raise HTTPException(status_code=401, detail="Geçersiz oturum")

        wp_user_id, wp_roles = _find_wp_by_account(conn, int(s["account_id"]))
        return MeResponse(
            account_id=int(s["account_id"]),
            email=(s.get("email") or "").strip().lower(),
            name=(s.get("name") or "").strip(),
            wp_user_id=wp_user_id,
            wp_roles=wp_roles,
        )
    finally:
        conn.close()
