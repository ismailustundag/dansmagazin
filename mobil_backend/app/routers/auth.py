import base64
import hashlib
import hmac
import json
import logging
import os
import re
import secrets
import threading
import time
from datetime import datetime, timedelta, timezone
from typing import Any, Dict, Optional
from urllib.parse import parse_qsl, urlencode, urlparse, urlunparse

import httpx
import psycopg2
import psycopg2.extras
from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.asymmetric import padding, rsa
from fastapi import APIRouter, Header, HTTPException, Request
from app.utils import client_ip_from_request, display_name, get_db_connection
from fastapi.responses import RedirectResponse
from pydantic import BaseModel

router = APIRouter(prefix="/auth", tags=["Auth"])
logger = logging.getLogger("uvicorn.error")

DATABASE_URL = os.getenv("DATABASE_URL", "").strip()
WP_BASE_URL = os.getenv("WP_BASE_URL", "https://www.dansmagazin.net").rstrip("/")
WOO_BASE_URL = os.getenv("WOO_BASE_URL", WP_BASE_URL).rstrip("/")
WOO_CONSUMER_KEY = os.getenv("WOO_CONSUMER_KEY", "").strip()
WOO_CONSUMER_SECRET = os.getenv("WOO_CONSUMER_SECRET", "").strip()
WP_JWT_TOKEN_URL = os.getenv("WP_JWT_TOKEN_URL", f"{WP_BASE_URL}/wp-json/jwt-auth/v1/token").strip()
WP_TLS_VERIFY = os.getenv("WP_TLS_VERIFY", "true").strip().lower() not in {"0", "false", "no", "off"}
WP_MOBILE_SSO_URL = os.getenv("WP_MOBILE_SSO_URL", f"{WP_BASE_URL}/?mobile_sso=1").strip()
WP_MOBILE_SSO_SECRET = os.getenv("WP_MOBILE_SSO_SECRET", "").strip()
WOO_SSO_RATE_LIMIT_WINDOW_SEC = int(os.getenv("WOO_SSO_RATE_LIMIT_WINDOW_SEC", "60"))
WOO_SSO_RATE_LIMIT_MAX_PER_WINDOW = int(os.getenv("WOO_SSO_RATE_LIMIT_MAX_PER_WINDOW", "20"))
REGISTER_RATE_LIMIT_WINDOW_SEC = int(os.getenv("REGISTER_RATE_LIMIT_WINDOW_SEC", "900"))
REGISTER_RATE_LIMIT_MAX_PER_WINDOW = int(os.getenv("REGISTER_RATE_LIMIT_MAX_PER_WINDOW", "5"))
REGISTER_SIMILAR_WINDOW_SEC = int(os.getenv("REGISTER_SIMILAR_WINDOW_SEC", "3600"))
REGISTER_SIMILAR_MAX_PER_WINDOW = int(os.getenv("REGISTER_SIMILAR_MAX_PER_WINDOW", "3"))
REGISTER_ABUSE_WINDOW_SEC = int(os.getenv("REGISTER_ABUSE_WINDOW_SEC", "21600"))
REGISTER_ABUSE_MAX_PER_WINDOW = int(os.getenv("REGISTER_ABUSE_MAX_PER_WINDOW", "8"))
GOOGLE_LOGIN_URL = os.getenv("GOOGLE_LOGIN_URL", f"{WP_BASE_URL}/my-account/").strip()
GOOGLE_TOKENINFO_URL = os.getenv("GOOGLE_TOKENINFO_URL", "https://oauth2.googleapis.com/tokeninfo").strip()
_WP_SUPERADMIN_EMAIL_ALLOWLIST_RAW = (
    os.getenv("WP_SUPERADMIN_EMAIL_ALLOWLIST", "")
    or os.getenv("SUPERADMIN_EMAIL", "")
    or ""
).strip()
WP_SUPERADMIN_EMAIL_ALLOWLIST = {
    x.strip().lower()
    for x in _WP_SUPERADMIN_EMAIL_ALLOWLIST_RAW.split(",")
    if x and x.strip()
}
_GOOGLE_OAUTH_CLIENT_IDS_RAW = (
    os.getenv("GOOGLE_OAUTH_CLIENT_IDS", "")
    or os.getenv("GOOGLE_OAUTH_CLIENT_ID", "")
).strip()
GOOGLE_OAUTH_CLIENT_IDS = {
    x.strip()
    for x in _GOOGLE_OAUTH_CLIENT_IDS_RAW.split(",")
    if x and x.strip()
}
APPLE_JWKS_URL = os.getenv("APPLE_JWKS_URL", "https://appleid.apple.com/auth/keys").strip()
_APPLE_OAUTH_AUDIENCES_RAW = os.getenv("APPLE_OAUTH_AUDIENCES", "").strip()
APPLE_OAUTH_AUDIENCES = {
    x.strip()
    for x in _APPLE_OAUTH_AUDIENCES_RAW.split(",")
    if x and x.strip()
}
DEFAULT_SYSTEM_FRIEND_EMAIL = os.getenv("DEFAULT_SYSTEM_FRIEND_EMAIL", "info@dansmagazin.net").strip().lower()
DEFAULT_SYSTEM_FRIEND_NAME = os.getenv("DEFAULT_SYSTEM_FRIEND_NAME", "Dansmagazin").strip()

_WOO_SSO_RATE_LOCK = threading.Lock()
_WOO_SSO_RATE_BUCKETS: dict[str, list[float]] = {}
_REGISTER_RATE_LOCK = threading.Lock()
_REGISTER_RATE_BUCKETS: dict[str, list[float]] = {}
_APPLE_JWKS_CACHE: dict[str, Any] = {"by_kid": {}, "exp": 0.0}


class LoginRequest(BaseModel):
    email: str = ""
    username_or_email: str = ""
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
    app_role: str = "customer"
    can_create_mobile_event: bool = False


class MeResponse(BaseModel):
    account_id: int
    email: str
    name: str
    wp_user_id: Optional[int] = None
    wp_roles: list[str] = []
    app_role: str = "customer"
    can_create_mobile_event: bool = False


class CheckoutLinkResponse(BaseModel):
    url: str
    expires_at: str


class GoogleLoginUrlResponse(BaseModel):
    url: str


class GoogleNativeLoginRequest(BaseModel):
    id_token: str
    remember_me: bool = True


class AppleNativeLoginRequest(BaseModel):
    identity_token: str
    apple_user: str = ""
    email: str = ""
    name: str = ""
    remember_me: bool = True


def _append_query_params(url: str, params: Dict[str, str]) -> str:
    parsed = urlparse(url)
    q = dict(parse_qsl(parsed.query, keep_blank_values=True))
    q.update({k: v for k, v in params.items() if v is not None and str(v).strip() != ""})
    new_query = urlencode(q, doseq=True)
    return urlunparse((parsed.scheme, parsed.netloc, parsed.path, parsed.params, new_query, parsed.fragment))


def _canonical_mobile_callback(callback_url: str) -> str:
    """Normalize known mobile callback variants to a single canonical URL."""
    try:
        p = urlparse(callback_url)
    except Exception:
        return callback_url
    path = (p.path or "").rstrip("/")
    if path == "/mobil-donus":
        return f"{WP_BASE_URL}/mobil-donus/"
    return callback_url


db_conn = get_db_connection


def _pbkdf2_hash(password: str, salt: bytes) -> bytes:
    return hashlib.pbkdf2_hmac("sha256", password.encode("utf-8"), salt, 120_000)


def _hash_password(password: str) -> str:
    salt = secrets.token_bytes(16)
    dk = _pbkdf2_hash(password, salt)
    return base64.b64encode(salt + dk).decode("utf-8")


def _session_expiry(remember_me: bool) -> str:
    dt = datetime.now(timezone.utc) + (timedelta(days=30) if remember_me else timedelta(days=1))
    return dt.isoformat(timespec="seconds")


def _register_email_localpart(email: str) -> str:
    return (email.strip().lower().split("@", 1)[0] if "@" in (email or "") else (email or "").strip().lower())[:120]


def _canonical_register_localpart(email: str) -> str:
    local = _register_email_localpart(email)
    compact = re.sub(r"[^a-z0-9]+", "", local)
    if not compact:
        return "user"
    without_digits = re.sub(r"\d+$", "", compact)
    normalized = without_digits if len(without_digits) >= 3 else compact
    return normalized[:80]


def ensure_register_guard_tables():
    conn = db_conn()
    try:
        cur = conn.cursor()
        cur.execute(
            """
            CREATE TABLE IF NOT EXISTS mobile_register_attempts (
                id BIGSERIAL PRIMARY KEY,
                client_ip TEXT NOT NULL,
                email TEXT NOT NULL,
                email_local TEXT NOT NULL,
                email_local_canonical TEXT NOT NULL,
                display_name TEXT NOT NULL DEFAULT '',
                outcome TEXT NOT NULL,
                detail TEXT NOT NULL DEFAULT '',
                created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
            )
            """
        )
        cur.execute(
            """
            CREATE INDEX IF NOT EXISTS idx_mobile_register_attempts_ip_created
            ON mobile_register_attempts (client_ip, created_at DESC)
            """
        )
        cur.execute(
            """
            CREATE INDEX IF NOT EXISTS idx_mobile_register_attempts_ip_canonical_created
            ON mobile_register_attempts (client_ip, email_local_canonical, created_at DESC)
            """
        )
        conn.commit()
    except Exception:
        conn.rollback()
        raise
    finally:
        conn.close()


def _record_register_attempt(client_ip: str, email: str, name: str, outcome: str, detail: str = ""):
    conn = None
    try:
        conn = db_conn()
        cur = conn.cursor()
        cur.execute(
            """
            INSERT INTO mobile_register_attempts (
                client_ip,
                email,
                email_local,
                email_local_canonical,
                display_name,
                outcome,
                detail
            )
            VALUES (%s,%s,%s,%s,%s,%s,%s)
            """,
            (
                (client_ip or "").strip() or "unknown",
                (email or "").strip().lower(),
                _register_email_localpart(email),
                _canonical_register_localpart(email),
                " ".join((name or "").split())[:120],
                (outcome or "unknown").strip()[:40],
                (detail or "").strip()[:240],
            ),
        )
        conn.commit()
    except Exception as exc:
        logger.warning("register_attempt_log_failed ip=%s email=%s err=%s", client_ip, email, exc)
    finally:
        try:
            if conn is not None:
                conn.close()
        except Exception:
            pass


def _enforce_register_pattern_guard(client_ip: str, email: str):
    conn = db_conn()
    try:
        cur = conn.cursor()
        normalized_ip = (client_ip or "").strip() or "unknown"
        canonical_local = _canonical_register_localpart(email)

        if REGISTER_ABUSE_WINDOW_SEC > 0 and REGISTER_ABUSE_MAX_PER_WINDOW > 0:
            cur.execute(
                """
                SELECT COUNT(*) AS cnt
                FROM mobile_register_attempts
                WHERE client_ip=%s
                  AND created_at >= NOW() - (%s * INTERVAL '1 second')
                """,
                (normalized_ip, int(REGISTER_ABUSE_WINDOW_SEC)),
            )
            total_cnt = int((cur.fetchone() or {}).get("cnt") or 0)
            if total_cnt >= REGISTER_ABUSE_MAX_PER_WINDOW:
                raise HTTPException(
                    status_code=429,
                    detail="Bu bağlantıdan kısa sürede çok fazla kayıt denemesi yapıldı. Lütfen daha sonra tekrar deneyin.",
                )

        if REGISTER_SIMILAR_WINDOW_SEC > 0 and REGISTER_SIMILAR_MAX_PER_WINDOW > 0:
            cur.execute(
                """
                SELECT COUNT(*) AS cnt
                FROM mobile_register_attempts
                WHERE client_ip=%s
                  AND email_local_canonical=%s
                  AND created_at >= NOW() - (%s * INTERVAL '1 second')
                """,
                (normalized_ip, canonical_local, int(REGISTER_SIMILAR_WINDOW_SEC)),
            )
            similar_cnt = int((cur.fetchone() or {}).get("cnt") or 0)
            if similar_cnt >= REGISTER_SIMILAR_MAX_PER_WINDOW:
                raise HTTPException(
                    status_code=429,
                    detail="Ayni baglantidan benzer hesap adlariyla seri kayit tespit edildi. Lutfen daha sonra tekrar deneyin.",
                )
    finally:
        conn.close()


async def _wp_login(username_or_email: str, password: str) -> Dict[str, Any]:
    payload = {"username": username_or_email, "password": password}
    async with httpx.AsyncClient(timeout=15.0, verify=WP_TLS_VERIFY) as c:
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
    async with httpx.AsyncClient(timeout=15.0, verify=WP_TLS_VERIFY) as c:
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

    email_lc = email.strip().lower()
    local = email_lc.split("@", 1)[0]
    local = re.sub(r"[^a-z0-9._-]+", "", local)
    local = local.strip("._-") or "user"
    digest = hashlib.sha1(email_lc.encode("utf-8")).hexdigest()[:6]
    base_username = f"{local}_{digest}"[:40]

    url = f"{WOO_BASE_URL}/wp-json/wc/v3/customers"
    params = {"consumer_key": WOO_CONSUMER_KEY, "consumer_secret": WOO_CONSUMER_SECRET}

    last_msg = "Woo kullanıcı oluşturulamadı"
    async with httpx.AsyncClient(timeout=20.0, verify=WP_TLS_VERIFY) as c:
        for attempt in range(3):
            username = base_username if attempt == 0 else f"{base_username[:34]}_{secrets.token_hex(2)}"
            payload = {
                "email": email_lc,
                "username": username,
                "password": password,
                "first_name": fn,
                "last_name": ln,
            }
            r = await c.post(url, params=params, json=payload)
            if r.status_code in (200, 201):
                return r.json()

            err_code = ""
            msg = "Woo kullanıcı oluşturulamadı"
            try:
                body = r.json()
                msg = (body.get("message") or msg).strip()
                err_code = str(body.get("code") or "").strip().lower()
            except Exception:
                pass
            last_msg = msg

            msg_l = msg.lower()
            username_conflict = (
                "username" in msg_l
                or "kullanıcı adı" in msg_l
                or "registration-error-username-exists" in err_code
            )
            if attempt < 2 and _is_existing_user_error(msg) and username_conflict:
                continue

            raise HTTPException(status_code=400, detail=msg)

    raise HTTPException(status_code=400, detail=last_msg)


async def _woo_find_customer_by_email(email: str) -> Optional[Dict[str, Any]]:
    if not (WOO_BASE_URL and WOO_CONSUMER_KEY and WOO_CONSUMER_SECRET):
        return None
    email_lc = (email or "").strip().lower()
    if not email_lc:
        return None

    url = f"{WOO_BASE_URL}/wp-json/wc/v3/customers"
    params = {
        "consumer_key": WOO_CONSUMER_KEY,
        "consumer_secret": WOO_CONSUMER_SECRET,
        "email": email_lc,
        "per_page": 20,
    }
    try:
        async with httpx.AsyncClient(timeout=20.0, verify=WP_TLS_VERIFY) as c:
            r = await c.get(url, params=params)
    except Exception:
        return None
    if r.status_code != 200:
        return None

    try:
        data = r.json()
    except Exception:
        return None
    if isinstance(data, list):
        for item in data:
            if not isinstance(item, dict):
                continue
            em = str(item.get("email") or "").strip().lower()
            if em == email_lc:
                return item
        return data[0] if data and isinstance(data[0], dict) else None
    if isinstance(data, dict):
        em = str(data.get("email") or "").strip().lower()
        if em == email_lc:
            return data
    return None


async def _ensure_wp_identity_for_account(conn, account_id: int, email: str, name: str) -> Optional[int]:
    current_wp_user_id, _ = _find_wp_by_account(conn, int(account_id))
    if current_wp_user_id:
        return current_wp_user_id

    existing_customer = await _woo_find_customer_by_email(email)
    if isinstance(existing_customer, dict) and existing_customer.get("id") is not None:
        try:
            found_wp_user_id = int(existing_customer.get("id"))
        except Exception:
            found_wp_user_id = None
        if found_wp_user_id:
            _upsert_identity_map(conn, found_wp_user_id, int(account_id), "woo_email_lookup", 95, "woo_email_lookup")
            return found_wp_user_id

    random_password = secrets.token_urlsafe(24)
    try:
        created_customer = await _woo_create_customer(email=email, password=random_password, name=name)
    except HTTPException as exc:
        # "zaten var" türü hatalarda email üzerinden tekrar eşleşmeyi dene.
        detail = str(exc.detail)
        if _is_existing_user_error(detail):
            retry_customer = await _woo_find_customer_by_email(email)
            if isinstance(retry_customer, dict) and retry_customer.get("id") is not None:
                try:
                    retry_wp_user_id = int(retry_customer.get("id"))
                except Exception:
                    retry_wp_user_id = None
                if retry_wp_user_id:
                    _upsert_identity_map(conn, retry_wp_user_id, int(account_id), "woo_email_lookup_retry", 95, "woo_email_lookup_retry")
                    return retry_wp_user_id
        logger.warning("ensure_wp_identity failed account_id=%s email=%s detail=%s", account_id, email, detail)
        return None

    try:
        created_wp_user_id = int(created_customer.get("id")) if created_customer.get("id") is not None else None
    except Exception:
        created_wp_user_id = None
    if created_wp_user_id:
        _upsert_identity_map(conn, created_wp_user_id, int(account_id), "woo_create_customer", 95, "woo_create_customer")
    return created_wp_user_id


def _email_can_be_super_admin(email: str) -> bool:
    e = (email or "").strip().lower()
    if not e:
        return False
    allow = set(WP_SUPERADMIN_EMAIL_ALLOWLIST)
    allow.update({
        (os.getenv("SUPERADMIN_EMAIL", "") or "").strip().lower(),
        "ism.ustundag@gmail.com",
        "info@dansmagazin.net",
    })
    allow.discard("")
    return e in allow


def _role_from_wp_roles(wp_roles: list[str], email: str = "") -> str:
    roles = {str(r).strip().lower() for r in (wp_roles or []) if str(r).strip()}
    if "administrator" in roles:
        return "super_admin" if _email_can_be_super_admin(email) else "customer"
    if "editor" in roles or "shop_manager" in roles:
        return "editor"
    return "customer"


def _upsert_local_account(conn, email: str, name: str, role: str, raw_password: str) -> int:
    c = conn.cursor()
    c.execute("SELECT id FROM accounts WHERE LOWER(email)=LOWER(%s) LIMIT 1", (email,))
    row = c.fetchone()
    role_norm = (role or "customer").strip().lower()
    can_create = 1 if role_norm in {"editor", "super_admin"} else 0
    if row:
        aid = int(row["id"])
        c.execute(
            """
            UPDATE accounts
            SET name=COALESCE(NULLIF(%s,''), name),
                role=CASE WHEN role='super_admin' THEN role ELSE COALESCE(NULLIF(%s,''), role) END,
                can_create_mobile_event=
                    CASE
                        WHEN role='super_admin' THEN 1
                        WHEN COALESCE(can_create_mobile_event,0)=1 AND COALESCE(NULLIF(%s,''),'customer')='customer' THEN 1
                        ELSE %s
                    END
            WHERE id=%s
            """,
            (name.strip(), role_norm, role_norm, can_create, aid),
        )
        return aid

    c.execute(
        """
        INSERT INTO accounts (email, password_hash, role, is_active, photo_credit, name, created_at, can_create_mobile_event)
        VALUES (%s,%s,%s,1,0,%s,%s,%s)
        RETURNING id
        """,
        (
            email.strip().lower(),
            _hash_password(raw_password),
            role_norm,
            name.strip(),
            datetime.now(timezone.utc).isoformat(timespec="seconds"),
            can_create,
        ),
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


def _ensure_default_system_friendship(conn, account_id: int):
    if not DEFAULT_SYSTEM_FRIEND_EMAIL:
        return
    cur = conn.cursor()
    cur.execute("SELECT id FROM accounts WHERE LOWER(email)=LOWER(%s) LIMIT 1", (DEFAULT_SYSTEM_FRIEND_EMAIL,))
    row = cur.fetchone()
    if row:
        support_id = int(row["id"])
    else:
        cur.execute(
            """
            INSERT INTO accounts (email, password_hash, role, is_active, photo_credit, name, created_at, can_create_mobile_event)
            VALUES (%s,%s,'customer',1,0,%s,%s,0)
            RETURNING id
            """,
            (
                DEFAULT_SYSTEM_FRIEND_EMAIL,
                _hash_password(secrets.token_urlsafe(24)),
                DEFAULT_SYSTEM_FRIEND_NAME or "Dansmagazin",
                datetime.now(timezone.utc).isoformat(timespec="seconds"),
            ),
        )
        support_id = int(cur.fetchone()["id"])

    aid = int(account_id)
    if support_id == aid:
        return
    user_a, user_b = (support_id, aid) if support_id < aid else (aid, support_id)
    cur.execute(
        """
        INSERT INTO mobile_friendships (user_a_id, user_b_id, created_at)
        VALUES (%s, %s, NOW()::text)
        ON CONFLICT (user_a_id, user_b_id) DO NOTHING
        """,
        (user_a, user_b),
    )


def ensure_default_friendships_for_all_users():
    """
    Tüm mevcut/aktif kullanıcıları info@dansmagazin.net hesabıyla arkadaş yapar.
    Startup'ta bir kez çağrılır.
    """
    if not DEFAULT_SYSTEM_FRIEND_EMAIL:
        return
    conn = db_conn()
    try:
        cur = conn.cursor()
        cur.execute("SELECT id FROM accounts WHERE LOWER(email)=LOWER(%s) LIMIT 1", (DEFAULT_SYSTEM_FRIEND_EMAIL,))
        row = cur.fetchone()
        if row:
            support_id = int(row["id"])
        else:
            cur.execute(
                """
                INSERT INTO accounts (email, password_hash, role, is_active, photo_credit, name, created_at, can_create_mobile_event)
                VALUES (%s,%s,'customer',1,0,%s,%s,0)
                RETURNING id
                """,
                (
                    DEFAULT_SYSTEM_FRIEND_EMAIL,
                    _hash_password(secrets.token_urlsafe(24)),
                    DEFAULT_SYSTEM_FRIEND_NAME or "Dansmagazin",
                    datetime.now(timezone.utc).isoformat(timespec="seconds"),
                ),
            )
            support_id = int(cur.fetchone()["id"])
        cur.execute(
            """
            INSERT INTO mobile_friendships (user_a_id, user_b_id, created_at)
            SELECT
                LEAST(a.id, %s) AS user_a_id,
                GREATEST(a.id, %s) AS user_b_id,
                NOW()::text
            FROM accounts a
            WHERE a.id <> %s AND COALESCE(a.is_active,1)=1
            ON CONFLICT (user_a_id, user_b_id) DO NOTHING
            """,
            (support_id, support_id, support_id),
        )
        conn.commit()
    except Exception:
        conn.rollback()
    finally:
        conn.close()


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
        SELECT s.account_id, s.expires_at, a.email, COALESCE(a.name,'') AS name, COALESCE(ps.username,'') AS username
        FROM sessions s
        JOIN accounts a ON a.id=s.account_id
        LEFT JOIN mobile_profile_settings ps ON ps.account_id=a.id
        WHERE s.session_token=%s AND COALESCE(a.is_active,1)=1
        LIMIT 1
        """,
        (token,),
    )
    return c.fetchone()


def _get_account_permissions(conn, account_id: int) -> tuple[str, bool]:
    c = conn.cursor()
    c.execute(
        """
        SELECT
            COALESCE(role,'customer') AS role,
            COALESCE(can_create_mobile_event,0) AS can_create_mobile_event
        FROM accounts
        WHERE id=%s
        LIMIT 1
        """,
        (int(account_id),),
    )
    row = c.fetchone() or {}
    role = str(row.get("role") or "customer").strip().lower() or "customer"
    can_create_flag = bool(int(row.get("can_create_mobile_event") or 0))
    # Editor/super_admin rolü veya explicit yetki flag'i varsa mobil etkinlik
    # oluşturma menüleri açık olmalı.
    can_create = role in {"editor", "super_admin"} or can_create_flag
    return role, can_create


def _is_account_active(conn, account_id: int) -> bool:
    c = conn.cursor()
    c.execute("SELECT COALESCE(is_active,1) AS is_active FROM accounts WHERE id=%s LIMIT 1", (int(account_id),))
    row = c.fetchone()
    return bool(row and int(row.get("is_active") or 0) == 1)


def _find_wp_by_account(conn, account_id: int) -> tuple[Optional[int], list[str]]:
    c = conn.cursor()
    c.execute("SELECT wp_user_id FROM identity_map WHERE app_account_id=%s AND is_active=TRUE LIMIT 1", (int(account_id),))
    row = c.fetchone()
    wp_user_id = int(row["wp_user_id"]) if row and row.get("wp_user_id") is not None else None
    return wp_user_id, []


def _require_bearer_token(authorization: Optional[str]) -> str:
    if not authorization or not authorization.lower().startswith("bearer "):
        raise HTTPException(status_code=401, detail="Bearer token gerekli")
    token = authorization.split(" ", 1)[1].strip()
    if not token:
        raise HTTPException(status_code=401, detail="Token boş")
    return token


def _normalize_checkout_target(target_url: str) -> str:
    raw = (target_url or "").strip()
    if not raw:
        raise HTTPException(status_code=400, detail="target_url zorunlu")

    parsed = urlparse(raw)
    if parsed.scheme and parsed.netloc:
        target = raw
    elif raw.startswith("/"):
        target = f"{WP_BASE_URL}{raw}"
    else:
        target = f"{WP_BASE_URL}/{raw.lstrip('/')}"
    p = urlparse(target)
    if p.scheme not in {"http", "https"} or not p.netloc:
        raise HTTPException(status_code=400, detail="Geçersiz target_url")

    wp_host = (urlparse(WP_BASE_URL).hostname or "").lower()
    t_host = (p.hostname or "").lower()
    allowed_hosts = set()
    if wp_host:
        allowed_hosts.add(wp_host)
        if wp_host.startswith("www."):
            allowed_hosts.add(wp_host[4:])
        else:
            allowed_hosts.add(f"www.{wp_host}")
    if allowed_hosts and t_host not in allowed_hosts:
        raise HTTPException(status_code=400, detail="target_url yalnızca WordPress domaininde olmalı")

    # App WebView icin WordPress tarafina "minimal layout" sinyali.
    # WP theme/mu-plugin bu parametreyi okuyup header/footer gizleyebilir.
    q = dict(parse_qsl(p.query, keep_blank_values=True))
    q["app"] = "1"
    target = urlunparse((p.scheme, p.netloc, p.path, p.params, urlencode(q), p.fragment))
    return target


def _b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).decode("utf-8").rstrip("=")


def _b64url_decode(value: str) -> bytes:
    pad = "=" * ((4 - len(value) % 4) % 4)
    return base64.urlsafe_b64decode((value + pad).encode("utf-8"))


def _sign_mobile_sso_payload(payload: Dict[str, Any]) -> str:
    if not WP_MOBILE_SSO_SECRET:
        raise HTTPException(status_code=503, detail="WP_MOBILE_SSO_SECRET eksik")
    body = _b64url(json.dumps(payload, separators=(",", ":"), ensure_ascii=True).encode("utf-8"))
    sig = hmac.new(WP_MOBILE_SSO_SECRET.encode("utf-8"), body.encode("utf-8"), hashlib.sha256).digest()
    return f"{body}.{_b64url(sig)}"


def _verify_mobile_sso_payload(sso_token: str) -> Dict[str, Any]:
    token = (sso_token or "").strip()
    if not token or "." not in token:
        raise HTTPException(status_code=400, detail="Geçersiz SSO token")
    body, sig = token.split(".", 1)
    expected_sig = _b64url(
        hmac.new(WP_MOBILE_SSO_SECRET.encode("utf-8"), body.encode("utf-8"), hashlib.sha256).digest()
    )
    if not hmac.compare_digest(expected_sig, sig):
        raise HTTPException(status_code=400, detail="SSO imza doğrulaması başarısız")
    try:
        payload = json.loads(_b64url_decode(body).decode("utf-8"))
    except Exception:
        raise HTTPException(status_code=400, detail="SSO payload çözümlenemedi")
    if not isinstance(payload, dict):
        raise HTTPException(status_code=400, detail="SSO payload geçersiz")
    exp = int(payload.get("exp") or 0)
    now = int(datetime.now(timezone.utc).timestamp())
    if exp and exp < now:
        raise HTTPException(status_code=400, detail="SSO token süresi dolmuş")
    return payload


def _ensure_google_identity_schema(conn):
    c = conn.cursor()
    c.execute(
        """
        CREATE TABLE IF NOT EXISTS google_identity_map (
            google_sub TEXT PRIMARY KEY,
            account_id INTEGER NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
            email TEXT NOT NULL DEFAULT '',
            is_active BOOLEAN NOT NULL DEFAULT TRUE,
            linked_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
        )
        """
    )
    c.execute(
        """
        CREATE UNIQUE INDEX IF NOT EXISTS uq_google_identity_active_account
        ON google_identity_map (account_id)
        WHERE is_active = TRUE
        """
    )
    c.execute(
        """
        CREATE INDEX IF NOT EXISTS idx_google_identity_email
        ON google_identity_map ((LOWER(email)))
        """
    )


def _ensure_apple_identity_schema(conn):
    c = conn.cursor()
    c.execute(
        """
        CREATE TABLE IF NOT EXISTS apple_identity_map (
            apple_sub TEXT PRIMARY KEY,
            account_id INTEGER NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
            email TEXT NOT NULL DEFAULT '',
            is_active BOOLEAN NOT NULL DEFAULT TRUE,
            linked_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
        )
        """
    )
    c.execute(
        """
        CREATE UNIQUE INDEX IF NOT EXISTS uq_apple_identity_active_account
        ON apple_identity_map (account_id)
        WHERE is_active = TRUE
        """
    )
    c.execute(
        """
        CREATE INDEX IF NOT EXISTS idx_apple_identity_email
        ON apple_identity_map ((LOWER(email)))
        """
    )


def _find_account_by_google_sub(conn, google_sub: str) -> Optional[int]:
    c = conn.cursor()
    c.execute(
        """
        SELECT account_id
        FROM google_identity_map
        WHERE google_sub=%s AND is_active=TRUE
        LIMIT 1
        """,
        (google_sub,),
    )
    row = c.fetchone()
    return int(row["account_id"]) if row and row.get("account_id") is not None else None


def _upsert_google_identity(conn, google_sub: str, account_id: int, email: str):
    c = conn.cursor()
    c.execute(
        """
        UPDATE google_identity_map
        SET is_active=FALSE, updated_at=NOW()
        WHERE account_id=%s AND google_sub<>%s AND is_active=TRUE
        """,
        (int(account_id), google_sub),
    )
    c.execute(
        """
        INSERT INTO google_identity_map (google_sub, account_id, email, is_active, linked_at, updated_at)
        VALUES (%s,%s,%s,TRUE,NOW(),NOW())
        ON CONFLICT (google_sub) DO UPDATE
        SET account_id=EXCLUDED.account_id,
            email=EXCLUDED.email,
            is_active=TRUE,
            updated_at=NOW()
        """,
        (google_sub, int(account_id), email.strip().lower()),
    )


def _find_account_by_apple_sub(conn, apple_sub: str) -> Optional[int]:
    c = conn.cursor()
    c.execute(
        """
        SELECT account_id
        FROM apple_identity_map
        WHERE apple_sub=%s AND is_active=TRUE
        LIMIT 1
        """,
        (apple_sub,),
    )
    row = c.fetchone()
    return int(row["account_id"]) if row and row.get("account_id") is not None else None


def _upsert_apple_identity(conn, apple_sub: str, account_id: int, email: str):
    c = conn.cursor()
    c.execute(
        """
        UPDATE apple_identity_map
        SET is_active=FALSE, updated_at=NOW()
        WHERE account_id=%s AND apple_sub<>%s AND is_active=TRUE
        """,
        (int(account_id), apple_sub),
    )
    c.execute(
        """
        INSERT INTO apple_identity_map (apple_sub, account_id, email, is_active, linked_at, updated_at)
        VALUES (%s,%s,%s,TRUE,NOW(),NOW())
        ON CONFLICT (apple_sub) DO UPDATE
        SET account_id=EXCLUDED.account_id,
            email=EXCLUDED.email,
            is_active=TRUE,
            updated_at=NOW()
        """,
        (apple_sub, int(account_id), email.strip().lower()),
    )


def _is_existing_user_error(message: str) -> bool:
    s = (message or "").strip().lower()
    if not s:
        return False
    patterns = [
        "exist",
        "already",
        "zaten",
        "kullanılıyor",
        "kayıtlı",
        "registered",
        "in use",
    ]
    return any(p in s for p in patterns)


async def _verify_google_id_token(id_token_value: str) -> Dict[str, Any]:
    token = (id_token_value or "").strip()
    if not token:
        raise HTTPException(status_code=400, detail="Google id_token zorunlu")

    try:
        async with httpx.AsyncClient(timeout=12.0) as c:
            r = await c.get(GOOGLE_TOKENINFO_URL, params={"id_token": token})
    except Exception:
        raise HTTPException(status_code=502, detail="Google token doğrulama servisine erişilemedi")

    if r.status_code != 200:
        try:
            body = r.json()
            msg = (body.get("error_description") or body.get("error") or "").strip()
        except Exception:
            msg = ""
        raise HTTPException(status_code=401, detail=msg or "Google token doğrulanamadı")

    try:
        body = r.json()
    except Exception:
        raise HTTPException(status_code=401, detail="Google token cevabı çözümlenemedi")
    if not isinstance(body, dict):
        raise HTTPException(status_code=401, detail="Google token cevabı geçersiz")

    iss = str(body.get("iss") or "").strip()
    aud = str(body.get("aud") or "").strip()
    sub = str(body.get("sub") or "").strip()
    email = str(body.get("email") or "").strip().lower()
    name = str(body.get("name") or "").strip()
    email_verified_raw = body.get("email_verified")
    exp_raw = body.get("exp")

    if iss not in {"accounts.google.com", "https://accounts.google.com"}:
        raise HTTPException(status_code=401, detail="Google issuer geçersiz")
    if GOOGLE_OAUTH_CLIENT_IDS and aud not in GOOGLE_OAUTH_CLIENT_IDS:
        raise HTTPException(status_code=401, detail="Google audience geçersiz")
    if not GOOGLE_OAUTH_CLIENT_IDS:
        logger.warning("google_native_login audience check disabled: GOOGLE_OAUTH_CLIENT_IDS not set")
    if not sub:
        raise HTTPException(status_code=401, detail="Google subject eksik")
    if not email:
        raise HTTPException(status_code=400, detail="Google email bilgisi eksik")

    email_verified = False
    if isinstance(email_verified_raw, bool):
        email_verified = email_verified_raw
    elif isinstance(email_verified_raw, str):
        email_verified = email_verified_raw.strip().lower() == "true"
    if not email_verified:
        raise HTTPException(status_code=403, detail="Google email doğrulanmamış")

    try:
        exp = int(str(exp_raw or "0"))
    except Exception:
        exp = 0
    now = int(datetime.now(timezone.utc).timestamp())
    if exp <= now:
        raise HTTPException(status_code=401, detail="Google token süresi dolmuş")

    return {
        "sub": sub,
        "email": email,
        "name": name,
        "aud": aud,
        "iss": iss,
    }


async def _fetch_apple_jwks_by_kid() -> dict[str, Dict[str, Any]]:
    now = time.time()
    cached = _APPLE_JWKS_CACHE.get("by_kid") or {}
    if cached and float(_APPLE_JWKS_CACHE.get("exp") or 0.0) > now:
        return cached

    try:
        async with httpx.AsyncClient(timeout=12.0) as c:
            r = await c.get(APPLE_JWKS_URL)
    except Exception:
        raise HTTPException(status_code=502, detail="Apple anahtar servisine erişilemedi")

    if r.status_code != 200:
        raise HTTPException(status_code=502, detail="Apple anahtarları alınamadı")

    try:
        body = r.json()
    except Exception:
        raise HTTPException(status_code=502, detail="Apple anahtar cevabı çözümlenemedi")

    keys = body.get("keys") if isinstance(body, dict) else None
    if not isinstance(keys, list) or not keys:
        raise HTTPException(status_code=502, detail="Apple anahtar listesi boş")

    by_kid: dict[str, Dict[str, Any]] = {}
    for item in keys:
        if not isinstance(item, dict):
            continue
        kid = str(item.get("kid") or "").strip()
        if kid:
            by_kid[kid] = item
    if not by_kid:
        raise HTTPException(status_code=502, detail="Apple anahtarları geçersiz")

    _APPLE_JWKS_CACHE["by_kid"] = by_kid
    _APPLE_JWKS_CACHE["exp"] = now + 3600
    return by_kid


def _jwt_segments(token: str) -> tuple[Dict[str, Any], Dict[str, Any], bytes, bytes]:
    parts = (token or "").strip().split(".")
    if len(parts) != 3:
        raise HTTPException(status_code=401, detail="Apple token formatı geçersiz")
    try:
        header = json.loads(_b64url_decode(parts[0]).decode("utf-8"))
        claims = json.loads(_b64url_decode(parts[1]).decode("utf-8"))
        signature = _b64url_decode(parts[2])
    except Exception:
        raise HTTPException(status_code=401, detail="Apple token çözümlenemedi")
    if not isinstance(header, dict) or not isinstance(claims, dict):
        raise HTTPException(status_code=401, detail="Apple token geçersiz")
    signing_input = f"{parts[0]}.{parts[1]}".encode("utf-8")
    return header, claims, signing_input, signature


def _rsa_public_key_from_jwk(jwk: Dict[str, Any]):
    try:
        n = int.from_bytes(_b64url_decode(str(jwk.get("n") or "")), "big")
        e = int.from_bytes(_b64url_decode(str(jwk.get("e") or "")), "big")
        return rsa.RSAPublicNumbers(e, n).public_key()
    except Exception:
        raise HTTPException(status_code=401, detail="Apple imza anahtarı geçersiz")


async def _verify_apple_identity_token(identity_token_value: str) -> Dict[str, Any]:
    token = (identity_token_value or "").strip()
    if not token:
        raise HTTPException(status_code=400, detail="Apple identity token zorunlu")

    header, claims, signing_input, signature = _jwt_segments(token)
    alg = str(header.get("alg") or "").strip()
    kid = str(header.get("kid") or "").strip()
    if alg != "RS256" or not kid:
        raise HTTPException(status_code=401, detail="Apple token header geçersiz")

    jwks = await _fetch_apple_jwks_by_kid()
    jwk = jwks.get(kid)
    if not jwk:
        raise HTTPException(status_code=401, detail="Apple imza anahtarı bulunamadı")

    public_key = _rsa_public_key_from_jwk(jwk)
    try:
        public_key.verify(signature, signing_input, padding.PKCS1v15(), hashes.SHA256())
    except Exception:
        raise HTTPException(status_code=401, detail="Apple token imzası doğrulanamadı")

    iss = str(claims.get("iss") or "").strip()
    aud = str(claims.get("aud") or "").strip()
    sub = str(claims.get("sub") or "").strip()
    email = str(claims.get("email") or "").strip().lower()
    email_verified_raw = claims.get("email_verified")

    if iss != "https://appleid.apple.com":
        raise HTTPException(status_code=401, detail="Apple issuer geçersiz")
    if APPLE_OAUTH_AUDIENCES and aud not in APPLE_OAUTH_AUDIENCES:
        raise HTTPException(status_code=401, detail="Apple audience geçersiz")
    if not APPLE_OAUTH_AUDIENCES:
        logger.warning("apple_native_login audience check disabled: APPLE_OAUTH_AUDIENCES not set")
    if not sub:
        raise HTTPException(status_code=401, detail="Apple subject eksik")

    try:
        exp = int(str(claims.get("exp") or "0"))
    except Exception:
        exp = 0
    now = int(datetime.now(timezone.utc).timestamp())
    if exp <= now:
        raise HTTPException(status_code=401, detail="Apple token süresi dolmuş")

    email_verified = False
    if isinstance(email_verified_raw, bool):
        email_verified = email_verified_raw
    elif isinstance(email_verified_raw, str):
        email_verified = email_verified_raw.strip().lower() == "true"
    elif email_verified_raw is None:
        email_verified = True
    if email and not email_verified:
        raise HTTPException(status_code=403, detail="Apple email doğrulanmamış")

    return {
        "sub": sub,
        "email": email,
        "aud": aud,
        "iss": iss,
    }


def _build_mobile_sso_url(sso_token: str) -> str:
    base = WP_MOBILE_SSO_URL or f"{WP_BASE_URL}/?mobile_sso=1"
    p = urlparse(base)
    q = dict(parse_qsl(p.query, keep_blank_values=True))
    q["sso"] = sso_token
    return urlunparse((p.scheme, p.netloc, p.path, p.params, urlencode(q), p.fragment))


def _enforce_woo_sso_rate_limit(account_id: int, request: Request):
    if WOO_SSO_RATE_LIMIT_WINDOW_SEC <= 0 or WOO_SSO_RATE_LIMIT_MAX_PER_WINDOW <= 0:
        return
    client_ip = client_ip_from_request(request)
    key = f"{int(account_id)}|{client_ip}"
    now = time.time()
    cutoff = now - WOO_SSO_RATE_LIMIT_WINDOW_SEC
    with _WOO_SSO_RATE_LOCK:
        arr = _WOO_SSO_RATE_BUCKETS.get(key, [])
        arr = [x for x in arr if x >= cutoff]
        if len(arr) >= WOO_SSO_RATE_LIMIT_MAX_PER_WINDOW:
            raise HTTPException(status_code=429, detail="Çok sık bilet yönlendirme isteği. Lütfen biraz sonra tekrar deneyin.")
        arr.append(now)
        _WOO_SSO_RATE_BUCKETS[key] = arr
def _enforce_register_rate_limit(request: Request):
    if REGISTER_RATE_LIMIT_WINDOW_SEC <= 0 or REGISTER_RATE_LIMIT_MAX_PER_WINDOW <= 0:
        return
    client_ip = client_ip_from_request(request)
    now = time.time()
    cutoff = now - REGISTER_RATE_LIMIT_WINDOW_SEC
    with _REGISTER_RATE_LOCK:
        arr = _REGISTER_RATE_BUCKETS.get(client_ip, [])
        arr = [x for x in arr if x >= cutoff]
        if len(arr) >= REGISTER_RATE_LIMIT_MAX_PER_WINDOW:
            logger.warning("register_rate_limited client_ip=%s count=%s", client_ip, len(arr))
            raise HTTPException(
                status_code=429,
                detail="Kısa sürede çok fazla kayıt denemesi yapıldı. Lütfen daha sonra tekrar deneyin.",
            )
        arr.append(now)
        _REGISTER_RATE_BUCKETS[client_ip] = arr


@router.post("/login", response_model=SessionResponse)
async def login(payload: LoginRequest):
    login_email = (payload.email or payload.username_or_email or "").strip().lower()
    if not login_email or not payload.password:
        raise HTTPException(status_code=400, detail="E-posta ve şifre zorunlu")
    if "@" not in login_email or "." not in login_email.split("@", 1)[-1]:
        raise HTTPException(status_code=400, detail="Lütfen e-posta adresinizle giriş yapın")

    wp_token_payload = await _wp_login(login_email, payload.password)
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

    role = _role_from_wp_roles(wp_roles, wp_email)

    conn = db_conn()
    try:
        account_id = _upsert_local_account(conn, wp_email, wp_name, role, payload.password)
        if not _is_account_active(conn, account_id):
            conn.rollback()
            raise HTTPException(status_code=403, detail="Hesap pasif. Lütfen yöneticiyle iletişime geçin.")
        _upsert_identity_map(conn, wp_user_id, account_id, "wp_jwt_login", 100, "live_login")
        _ensure_default_system_friendship(conn, account_id)
        session_token, expires_at = _create_session(conn, account_id, payload.remember_me)
        app_role, can_create_mobile_event = _get_account_permissions(conn, account_id)
        s = _get_session(conn, session_token) or {} # Changed _display_name to display_name
        conn.commit()
        return SessionResponse(
            session_token=session_token,
            expires_at=expires_at,
            account_id=account_id,
            email=((s.get("email") or wp_email or "").strip().lower()),
            name=display_name((s.get("name") or wp_name or "").strip(), (s.get("email") or wp_email or "").strip().lower(), (s.get("username") or "").strip()),
            wp_user_id=wp_user_id,
            wp_roles=wp_roles,
            app_role=app_role,
            can_create_mobile_event=can_create_mobile_event,
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
async def register(payload: RegisterRequest, request: Request):
    client_ip = client_ip_from_request(request)
    email = payload.email.strip().lower()
    name = payload.name.strip()
    try:
        _enforce_register_rate_limit(request)
        if '@' not in email or '.' not in email.split('@')[-1]:
            raise HTTPException(status_code=400, detail='Geçerli email gerekli')
        _enforce_register_pattern_guard(client_ip, email)
        if len(name) < 2:
            raise HTTPException(status_code=400, detail='Ad soyad gerekli')
        if len(name) > 120:
            raise HTTPException(status_code=400, detail='Ad soyad çok uzun')
        if len(payload.password or "") < 6:
            raise HTTPException(status_code=400, detail='Şifre en az 6 karakter olmalı')

        # 1) Woo/WP üzerinde kullanıcı oluştur
        await _woo_create_customer(email=email, password=payload.password, name=name)

        # 2) Aynı credentials ile WP login yapıp yerelde map/session oluştur
        session = await login(
            LoginRequest(
                username_or_email=email,
                password=payload.password,
                remember_me=payload.remember_me,
            )
        )
        _record_register_attempt(client_ip, email, name, "success", "")
        return session
    except HTTPException as exc:
        detail = str(exc.detail)
        outcome = "blocked" if exc.status_code == 429 else "failed"
        _record_register_attempt(client_ip, email, name, outcome, detail)
        raise
    except Exception as exc:
        _record_register_attempt(client_ip, email, name, "failed_internal", str(exc))
        raise


@router.post("/google/native", response_model=SessionResponse)
async def google_native_login(payload: GoogleNativeLoginRequest):
    claims = await _verify_google_id_token(payload.id_token)
    google_sub = str(claims["sub"])
    email = str(claims["email"]).strip().lower()
    name = str(claims.get("name") or "").strip()

    conn = db_conn()
    try:
        _ensure_google_identity_schema(conn)

        # 1) Önce Google subject eşleşmesiyle login
        account_id = _find_account_by_google_sub(conn, google_sub)
        created_new_account = False
        wp_user_id: Optional[int] = None
        wp_roles: list[str] = []

        # 2) Subject map yoksa email ile mevcut hesabı bul
        if not account_id:
            cur = conn.cursor()
            cur.execute("SELECT id FROM accounts WHERE LOWER(email)=LOWER(%s) LIMIT 1", (email,))
            row = cur.fetchone()
            if row and row.get("id") is not None:
                account_id = int(row["id"])
            else:
                # 3) Hiç hesap yoksa yeni kullanıcı oluştur (Google ile kayıt)
                created_new_account = True
                random_password = secrets.token_urlsafe(24)
                woo_customer = None
                try:
                    woo_customer = await _woo_create_customer(email=email, password=random_password, name=name)
                except HTTPException as exc:
                    # Woo tarafında aynı email zaten varsa local hesabı yine açıp Google ile devam et.
                    detail = str(exc.detail)
                    if not _is_existing_user_error(detail):
                        logger.warning("google_native_login woo_create skipped: %s", detail)
                if isinstance(woo_customer, dict) and woo_customer.get("id") is not None:
                    try:
                        wp_user_id = int(woo_customer.get("id"))
                    except Exception:
                        wp_user_id = None
                account_id = _upsert_local_account(conn, email, name, "customer", random_password)

        if account_id is None:
            raise HTTPException(status_code=500, detail="Google kullanıcı eşleştirme başarısız")
        if not _is_account_active(conn, account_id):
            conn.rollback()
            raise HTTPException(status_code=403, detail="Hesap pasif. Lütfen yöneticiyle iletişime geçin.")

        # Mevcut hesapta isim boşsa Google ismini doldur.
        cur = conn.cursor()
        cur.execute(
            """
            UPDATE accounts
            SET name=CASE WHEN COALESCE(name,'')='' THEN %s ELSE name END
            WHERE id=%s
            """,
            (name, int(account_id)),
        )

        # Google identity map güncelle
        _upsert_google_identity(conn, google_sub, account_id, email)

        wp_user_id_final, wp_roles_final = _find_wp_by_account(conn, account_id)
        if wp_user_id_final is None:
            wp_user_id_final = await _ensure_wp_identity_for_account(conn, account_id, email, name)
        # Yeni kayıtta WP eşleşmesi kurulamıyorsa rollback ile lokal kayıt bırakma.
        if created_new_account and wp_user_id_final is None:
            raise HTTPException(status_code=502, detail="WordPress hesabı oluşturulamadı. Lütfen tekrar deneyin.")

        _ensure_default_system_friendship(conn, account_id)
        session_token, expires_at = _create_session(conn, account_id, payload.remember_me)
        app_role, can_create_mobile_event = _get_account_permissions(conn, account_id)

        # Response için canonical email/name
        session_row = _get_session(conn, session_token) or {}
        res_email = (session_row.get("email") or email or "").strip().lower()
        res_name = display_name( # Changed _display_name to display_name
            (session_row.get("name") or name or "").strip(),
            res_email,
            (session_row.get("username") or "").strip(),
        )

        conn.commit()
        return SessionResponse(
            session_token=session_token,
            expires_at=expires_at,
            account_id=int(account_id),
            email=res_email,
            name=res_name,
            wp_user_id=wp_user_id_final,
            wp_roles=wp_roles_final if isinstance(wp_roles_final, list) else wp_roles,
            app_role=app_role,
            can_create_mobile_event=can_create_mobile_event,
        )
    except HTTPException:
        conn.rollback()
        raise
    except Exception:
        conn.rollback()
        raise HTTPException(status_code=500, detail="Google giriş sırasında sistem hatası")
    finally:
        conn.close()


@router.post("/apple/native", response_model=SessionResponse)
async def apple_native_login(payload: AppleNativeLoginRequest):
    claims = await _verify_apple_identity_token(payload.identity_token)
    apple_sub = str(claims["sub"])
    email = (payload.email or claims.get("email") or "").strip().lower()
    name = (payload.name or "").strip()

    conn = db_conn()
    try:
        _ensure_apple_identity_schema(conn)

        account_id = _find_account_by_apple_sub(conn, apple_sub)
        created_new_account = False
        wp_user_id: Optional[int] = None
        wp_roles: list[str] = []

        if not account_id and email:
            cur = conn.cursor()
            cur.execute("SELECT id FROM accounts WHERE LOWER(email)=LOWER(%s) LIMIT 1", (email,))
            row = cur.fetchone()
            if row and row.get("id") is not None:
                account_id = int(row["id"])

        if not account_id:
            if not email:
                raise HTTPException(
                    status_code=400,
                    detail="Apple e-posta bilgisi alınamadı. Lütfen Apple ile girişi yeniden onaylayın.",
                )
            created_new_account = True
            random_password = secrets.token_urlsafe(24)
            woo_customer = None
            try:
                woo_customer = await _woo_create_customer(email=email, password=random_password, name=name)
            except HTTPException as exc:
                detail = str(exc.detail)
                if not _is_existing_user_error(detail):
                    logger.warning("apple_native_login woo_create skipped: %s", detail)
            if isinstance(woo_customer, dict) and woo_customer.get("id") is not None:
                try:
                    wp_user_id = int(woo_customer.get("id"))
                except Exception:
                    wp_user_id = None
            account_id = _upsert_local_account(conn, email, name, "customer", random_password)

        if account_id is None:
            raise HTTPException(status_code=500, detail="Apple kullanıcı eşleştirme başarısız")
        if not _is_account_active(conn, account_id):
            conn.rollback()
            raise HTTPException(status_code=403, detail="Hesap pasif. Lütfen yöneticiyle iletişime geçin.")

        cur = conn.cursor()
        cur.execute(
            "SELECT COALESCE(email,'') AS email, COALESCE(name,'') AS name FROM accounts WHERE id=%s LIMIT 1",
            (int(account_id),),
        )
        existing_account = cur.fetchone() or {}
        if not email:
            email = (existing_account.get("email") or "").strip().lower()
        if not name:
            name = (existing_account.get("name") or "").strip()

        cur.execute(
            """
            UPDATE accounts
            SET name=CASE WHEN COALESCE(name,'')='' THEN %s ELSE name END
            WHERE id=%s
            """,
            (name, int(account_id)),
        )

        _upsert_apple_identity(conn, apple_sub, account_id, email)

        wp_user_id_final, wp_roles_final = _find_wp_by_account(conn, account_id)
        if wp_user_id_final is None:
            wp_user_id_final = await _ensure_wp_identity_for_account(conn, account_id, email, name)
        if created_new_account and wp_user_id_final is None:
            raise HTTPException(status_code=502, detail="WordPress hesabı oluşturulamadı. Lütfen tekrar deneyin.")

        _ensure_default_system_friendship(conn, account_id)
        session_token, expires_at = _create_session(conn, account_id, payload.remember_me)
        app_role, can_create_mobile_event = _get_account_permissions(conn, account_id)

        session_row = _get_session(conn, session_token) or {}
        res_email = (session_row.get("email") or email or "").strip().lower()
        res_name = display_name(
            (session_row.get("name") or name or "").strip(),
            res_email,
            (session_row.get("username") or "").strip(),
        )

        conn.commit()
        return SessionResponse(
            session_token=session_token,
            expires_at=expires_at,
            account_id=int(account_id),
            email=res_email,
            name=res_name,
            wp_user_id=wp_user_id_final,
            wp_roles=wp_roles_final if isinstance(wp_roles_final, list) else wp_roles,
            app_role=app_role,
            can_create_mobile_event=can_create_mobile_event,
        )
    except HTTPException:
        conn.rollback()
        raise
    except Exception:
        conn.rollback()
        raise HTTPException(status_code=500, detail="Apple giriş sırasında sistem hatası")
    finally:
        conn.close()


@router.get("/me", response_model=MeResponse)
def me(authorization: Optional[str] = Header(default=None)):
    token = _require_bearer_token(authorization)

    conn = db_conn()
    try:
        s = _get_session(conn, token)
        if not s:
            raise HTTPException(status_code=401, detail="Geçersiz oturum")

        wp_user_id, wp_roles = _find_wp_by_account(conn, int(s["account_id"]))
        app_role, can_create_mobile_event = _get_account_permissions(conn, int(s["account_id"]))
        return MeResponse(
            account_id=int(s["account_id"]),
            email=(s.get("email") or "").strip().lower(),
            name=display_name((s.get("name") or "").strip(), (s.get("email") or "").strip().lower(), (s.get("username") or "").strip()), # Changed _display_name to display_name
            wp_user_id=wp_user_id,
            wp_roles=wp_roles,
            app_role=app_role,
            can_create_mobile_event=can_create_mobile_event,
        )
    finally:
        conn.close()


@router.get("/woo-auto-login-url", response_model=CheckoutLinkResponse)
async def woo_auto_login_url(
    target_url: str,
    request: Request,
    authorization: Optional[str] = Header(default=None),
):
    token = _require_bearer_token(authorization)
    redirect_url = _normalize_checkout_target(target_url)

    conn = db_conn()
    try:
        s = _get_session(conn, token)
        if not s:
            raise HTTPException(status_code=401, detail="Geçersiz oturum")
        account_id = int(s["account_id"])
        app_role, _ = _get_account_permissions(conn, account_id)
        if app_role in {"editor", "super_admin"}:
            # Yonetici/editor hesaplari Woo tarafinda dashboard'a dusmemeli.
            # Bu hesaplarda SSO yerine dogrudan urun sayfasina gitmek daha guvenli.
            conn.commit()
            return CheckoutLinkResponse(
                url=redirect_url,
                expires_at=datetime.now(timezone.utc).isoformat(timespec="seconds"),
            )
        wp_user_id, _ = _find_wp_by_account(conn, account_id)
        if not wp_user_id:
            if not (WOO_BASE_URL and WOO_CONSUMER_KEY and WOO_CONSUMER_SECRET):
                raise HTTPException(status_code=500, detail="Woo ayarları eksik (WOO_BASE_URL/CK/CS)")
            wp_user_id = await _ensure_wp_identity_for_account(
                conn,
                account_id=account_id,
                email=(s.get("email") or "").strip().lower(),
                name=(s.get("name") or "").strip(),
            )
            if not wp_user_id:
                raise HTTPException(status_code=409, detail="Kullanıcı WordPress hesabıyla eşleşmiyor")
        _enforce_woo_sso_rate_limit(account_id, request)

        now = int(datetime.now(timezone.utc).timestamp())
        exp = now + (5 * 60)
        payload = {
            "iss": "api2.dansmagazin.net",
            "typ": "mobile_wp_sso",
            "account_id": account_id,
            "wp_user_id": int(wp_user_id),
            "email": (s.get("email") or "").strip().lower(),
            "iat": now,
            "exp": exp,
            "nonce": secrets.token_urlsafe(12),
            "redirect": redirect_url,
        }
        sso_token = _sign_mobile_sso_payload(payload)
        conn.commit()
        return CheckoutLinkResponse(
            url=_build_mobile_sso_url(sso_token),
            expires_at=datetime.fromtimestamp(exp, tz=timezone.utc).isoformat(timespec="seconds"),
        )
    except HTTPException:
        conn.rollback()
        raise
    except Exception:
        conn.rollback()
        raise
    finally:
        conn.close()


@router.get("/google-login-url", response_model=GoogleLoginUrlResponse)
def google_login_url(callback: Optional[str] = None):
    url = (GOOGLE_LOGIN_URL or "").strip()
    if not url:
        raise HTTPException(status_code=503, detail="Google login URL tanımlı değil")
    if not (url.startswith("http://") or url.startswith("https://")):
        raise HTTPException(status_code=500, detail="Google login URL geçersiz")
    callback_url = (callback or "").strip()
    if callback_url:
        if callback_url.startswith("dansmagazin://"):
            pass
        else:
            p = urlparse(callback_url)
            wp_host = (urlparse(WP_BASE_URL).hostname or "").lower()
            cb_host = (p.hostname or "").lower()
            allowed_hosts = {wp_host}
            if wp_host.startswith("www."):
                allowed_hosts.add(wp_host[4:])
            elif wp_host:
                allowed_hosts.add(f"www.{wp_host}")
            if p.scheme not in {"http", "https"} or not cb_host or cb_host not in allowed_hosts:
                raise HTTPException(status_code=400, detail="Geçersiz callback")
            callback_url = _canonical_mobile_callback(callback_url)
        url = _append_query_params(
            url,
            {
                "redirect_to": callback_url,
            },
        )
    return GoogleLoginUrlResponse(url=url)


@router.get("/google-mobile-complete")
def google_mobile_complete(sso: str):
    if not WP_MOBILE_SSO_SECRET:
        raise HTTPException(status_code=503, detail="WP_MOBILE_SSO_SECRET eksik")
    payload = _verify_mobile_sso_payload(sso)

    wp_email = str(payload.get("email") or "").strip().lower()
    wp_name = str(payload.get("name") or "").strip()
    wp_user_id = payload.get("wp_user_id")
    wp_roles = payload.get("wp_roles") or []
    if not wp_email:
        raise HTTPException(status_code=400, detail="Email eksik")
    if not isinstance(wp_roles, list):
        wp_roles = []
    wp_roles = [str(r).strip() for r in wp_roles if str(r).strip()]
    role = _role_from_wp_roles(wp_roles, wp_email)

    conn = db_conn()
    try:
        # random secret, because Google callback path has no password
        random_password = secrets.token_urlsafe(24)
        account_id = _upsert_local_account(conn, wp_email, wp_name, role, random_password)
        if not _is_account_active(conn, account_id):
            conn.rollback()
            raise HTTPException(status_code=403, detail="Hesap pasif")
        wp_uid_int = int(wp_user_id) if wp_user_id is not None else None
        _upsert_identity_map(conn, wp_uid_int, account_id, "wp_google_sso", 100, "mobile_google_callback")
        _ensure_default_system_friendship(conn, account_id)
        session_token, _ = _create_session(conn, account_id, remember_me=True)
        app_role, can_create_mobile_event = _get_account_permissions(conn, account_id)
        session_row = _get_session(conn, session_token) or {} # Changed _display_name to display_name
        resolved_name = display_name(
            (session_row.get("name") or wp_name or "").strip(),
            (session_row.get("email") or wp_email or "").strip().lower(),
            (session_row.get("username") or "").strip(),
        )
        conn.commit()
    finally:
        conn.close()

    q = urlencode(
        {
            "session_token": session_token,
            "account_id": str(account_id),
            "email": wp_email,
            "name": resolved_name,
            "wp_user_id": "" if wp_user_id is None else str(wp_user_id),
            "wp_roles": ",".join(wp_roles),
            "app_role": app_role,
            "can_create_mobile_event": "1" if can_create_mobile_event else "0",
        }
    )
    target = f"dansmagazin://auth-callback?{q}"
    return RedirectResponse(url=target, status_code=307)
