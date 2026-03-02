import base64
import hashlib
import hmac
import json
import os
import secrets
import threading
import time
from datetime import datetime, timedelta, timezone
from typing import Any, Dict, Optional
from urllib.parse import parse_qsl, urlencode, urlparse, urlunparse

import httpx
import psycopg2
import psycopg2.extras
from fastapi import APIRouter, Header, HTTPException, Request
from pydantic import BaseModel

router = APIRouter(prefix="/auth", tags=["Auth"])

DATABASE_URL = os.getenv("DATABASE_URL", "").strip()
WP_BASE_URL = os.getenv("WP_BASE_URL", "https://www.dansmagazin.net").rstrip("/")
WOO_BASE_URL = os.getenv("WOO_BASE_URL", WP_BASE_URL).rstrip("/")
WOO_CONSUMER_KEY = os.getenv("WOO_CONSUMER_KEY", "").strip()
WOO_CONSUMER_SECRET = os.getenv("WOO_CONSUMER_SECRET", "").strip()
WP_JWT_TOKEN_URL = os.getenv("WP_JWT_TOKEN_URL", f"{WP_BASE_URL}/wp-json/jwt-auth/v1/token").strip()
WP_MOBILE_SSO_URL = os.getenv("WP_MOBILE_SSO_URL", f"{WP_BASE_URL}/?mobile_sso=1").strip()
WP_MOBILE_SSO_SECRET = os.getenv("WP_MOBILE_SSO_SECRET", "").strip()
WOO_SSO_RATE_LIMIT_WINDOW_SEC = int(os.getenv("WOO_SSO_RATE_LIMIT_WINDOW_SEC", "60"))
WOO_SSO_RATE_LIMIT_MAX_PER_WINDOW = int(os.getenv("WOO_SSO_RATE_LIMIT_MAX_PER_WINDOW", "20"))
DEFAULT_SYSTEM_FRIEND_EMAIL = os.getenv("DEFAULT_SYSTEM_FRIEND_EMAIL", "info@dansmagazin.net").strip().lower()
DEFAULT_SYSTEM_FRIEND_NAME = os.getenv("DEFAULT_SYSTEM_FRIEND_NAME", "Dansmagazin").strip()

_WOO_SSO_RATE_LOCK = threading.Lock()
_WOO_SSO_RATE_BUCKETS: dict[str, list[float]] = {}


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
    roles = {str(r).strip().lower() for r in (wp_roles or []) if str(r).strip()}
    if "administrator" in roles:
        return "super_admin"
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
                is_active=1,
                can_create_mobile_event=CASE WHEN role='super_admin' THEN 1 ELSE %s END
            WHERE id=%s
            """,
            (name.strip(), role_norm, can_create, aid),
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
    conn = _db_conn()
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
        SELECT s.account_id, s.expires_at, a.email, COALESCE(a.name,'') AS name
        FROM sessions s
        JOIN accounts a ON a.id=s.account_id
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
        SELECT COALESCE(role,'customer') AS role
        FROM accounts
        WHERE id=%s
        LIMIT 1
        """,
        (int(account_id),),
    )
    row = c.fetchone() or {}
    role = str(row.get("role") or "customer").strip().lower() or "customer"
    # Tek kaynak politikasi: etkinlik olusturma yetkisi yalnızca WP role map'ten gelir.
    can_create = role in {"editor", "super_admin"}
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


def _sign_mobile_sso_payload(payload: Dict[str, Any]) -> str:
    if not WP_MOBILE_SSO_SECRET:
        raise HTTPException(status_code=503, detail="WP_MOBILE_SSO_SECRET eksik")
    body = _b64url(json.dumps(payload, separators=(",", ":"), ensure_ascii=True).encode("utf-8"))
    sig = hmac.new(WP_MOBILE_SSO_SECRET.encode("utf-8"), body.encode("utf-8"), hashlib.sha256).digest()
    return f"{body}.{_b64url(sig)}"


def _build_mobile_sso_url(sso_token: str) -> str:
    base = WP_MOBILE_SSO_URL or f"{WP_BASE_URL}/?mobile_sso=1"
    p = urlparse(base)
    q = dict(parse_qsl(p.query, keep_blank_values=True))
    q["sso"] = sso_token
    return urlunparse((p.scheme, p.netloc, p.path, p.params, urlencode(q), p.fragment))


def _enforce_woo_sso_rate_limit(account_id: int, request: Request):
    if WOO_SSO_RATE_LIMIT_WINDOW_SEC <= 0 or WOO_SSO_RATE_LIMIT_MAX_PER_WINDOW <= 0:
        return
    fwd = (request.headers.get("x-forwarded-for") or "").split(",")[0].strip()
    client_ip = fwd or (request.client.host if request.client else "unknown")
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
        if not _is_account_active(conn, account_id):
            conn.rollback()
            raise HTTPException(status_code=403, detail="Hesap pasif. Lütfen yöneticiyle iletişime geçin.")
        _upsert_identity_map(conn, wp_user_id, account_id, "wp_jwt_login", 100, "live_login")
        _ensure_default_system_friendship(conn, account_id)
        session_token, expires_at = _create_session(conn, account_id, payload.remember_me)
        app_role, can_create_mobile_event = _get_account_permissions(conn, account_id)
        conn.commit()
        return SessionResponse(
            session_token=session_token,
            expires_at=expires_at,
            account_id=account_id,
            email=wp_email,
            name=wp_name,
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
    token = _require_bearer_token(authorization)

    conn = _db_conn()
    try:
        s = _get_session(conn, token)
        if not s:
            raise HTTPException(status_code=401, detail="Geçersiz oturum")

        wp_user_id, wp_roles = _find_wp_by_account(conn, int(s["account_id"]))
        app_role, can_create_mobile_event = _get_account_permissions(conn, int(s["account_id"]))
        return MeResponse(
            account_id=int(s["account_id"]),
            email=(s.get("email") or "").strip().lower(),
            name=(s.get("name") or "").strip(),
            wp_user_id=wp_user_id,
            wp_roles=wp_roles,
            app_role=app_role,
            can_create_mobile_event=can_create_mobile_event,
        )
    finally:
        conn.close()


@router.get("/woo-auto-login-url", response_model=CheckoutLinkResponse)
def woo_auto_login_url(
    target_url: str,
    request: Request,
    authorization: Optional[str] = Header(default=None),
):
    token = _require_bearer_token(authorization)
    redirect_url = _normalize_checkout_target(target_url)

    conn = _db_conn()
    try:
        s = _get_session(conn, token)
        if not s:
            raise HTTPException(status_code=401, detail="Geçersiz oturum")
        account_id = int(s["account_id"])
        wp_user_id, _ = _find_wp_by_account(conn, account_id)
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
        return CheckoutLinkResponse(
            url=_build_mobile_sso_url(sso_token),
            expires_at=datetime.fromtimestamp(exp, tz=timezone.utc).isoformat(timespec="seconds"),
        )
    finally:
        conn.close()
