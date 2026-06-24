import os
import re
import uuid
import json
import time
import logging
import base64
import hashlib
import hmac
import unicodedata
from datetime import date, datetime, timezone
from io import BytesIO
from typing import Any, Dict, List, Optional
from urllib import error as url_error
from urllib import request as url_request

import psycopg2
import psycopg2.extras
from fastapi import APIRouter, File, Header, HTTPException, Query, UploadFile
from pydantic import BaseModel, Field
from starlette.responses import FileResponse
from app.routers.events import (
    _clean_html_text,
    _cover_exists,
    _cover_url,
    _deserialize_dance_styles,
    _expire_past_event_tickets,
    _fetch_woo_order_statuses,
    _normalize_event_dt_text,
    _render_auto_event_notification,
    _split_venue_fields,
    _ticket_status_from_woo_status,
) # Changed _display_name to display_name, _blocked_peer_ids to get_blocked_peer_ids
from app.routers.messages import unread_messages_count # Changed _db_conn to get_db_connection
from app.utils import get_db_connection, display_name, get_blocked_peer_ids

router = APIRouter(prefix="/profile", tags=["Profil"])
DATABASE_URL = os.getenv("DATABASE_URL", "").strip()
BASE_DIR = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
MEDIA_DIR = os.path.join(BASE_DIR, "media")
PROFILE_AVATAR_DIR = os.path.join(MEDIA_DIR, "profile_avatars")
PROFILE_AVATAR_SIZE = 1080
SOCIAL_SEARCH_MIN_QUERY_LEN = max(1, int((os.getenv("SOCIAL_SEARCH_MIN_QUERY_LEN", "2") or "2").strip() or "2"))
SOCIAL_SEARCH_DEFAULT_LIMIT = max(1, min(int((os.getenv("SOCIAL_SEARCH_DEFAULT_LIMIT", "20") or "20").strip() or "20"), 50))
ALLOWED_AVATAR_CONTENT_TYPES = {
    "image/jpeg",
    "image/jpg",
    "image/png",
    "image/webp",
    "image/heic",
    "image/heif",
    "image/heic-sequence",
    "image/heif-sequence",
}
ALLOWED_AVATAR_EXTENSIONS = {".jpg", ".jpeg", ".png", ".webp", ".heic", ".heif"}
FCM_SERVER_KEY = os.getenv("FCM_SERVER_KEY", "").strip()
FCM_ENDPOINT = os.getenv("FCM_ENDPOINT", "https://fcm.googleapis.com/fcm/send").strip()
FCM_TIMEOUT_SECONDS = float(os.getenv("FCM_TIMEOUT_SECONDS", "8").strip() or "8")
FCM_PROJECT_ID = os.getenv("FCM_PROJECT_ID", "").strip()
FCM_SERVICE_ACCOUNT_FILE = os.getenv("FCM_SERVICE_ACCOUNT_FILE", "").strip()
MOBILE_ADMIN_TOKEN = os.getenv("MOBILE_ADMIN_TOKEN", "").strip()
QR_SIGNING_SECRET = (os.getenv("QR_SIGNING_SECRET", "").strip() or MOBILE_ADMIN_TOKEN or DATABASE_URL or "dansmagazin-ticket-secret")
SYSTEM_SENDER_ACCOUNT_ID = int((os.getenv("SYSTEM_SENDER_ACCOUNT_ID", "0") or "0").strip() or "0")
SYSTEM_SENDER_EMAIL = (os.getenv("SYSTEM_SENDER_EMAIL", "info@dansmagazin.net") or "info@dansmagazin.net").strip().lower()
SYSTEM_SENDER_NAME = (os.getenv("SYSTEM_SENDER_NAME", "Dans Magazin") or "Dans Magazin").strip()
_FCM_V1_TOKEN_CACHE: Dict[str, Any] = {"token": "", "exp": 0.0}
logger = logging.getLogger("uvicorn.error")

DEFAULT_NOTIFICATION_PREFERENCES: Dict[str, bool] = {
    "news": True,
    "dance_night": True,
    "festival": True,
    "competition": True,
    "promo_lesson": True,
    "system": True,
}
AUTO_VERIFIED_ROLES = {"super_admin", "editor"}
CANCELLED_TICKET_STATUSES = {"cancelled", "failed", "refunded", "trash"}
DEFAULT_DANCE_SCHOOL_SEEDS: List[Dict[str, Any]] = [
    {
        "name": "LaDance",
        "aliases": ["la dance", "ladance"],
    },
]


def _role_auto_verified(role: Any) -> bool:
    return str(role or "").strip().lower() in AUTO_VERIFIED_ROLES


def _effective_is_verified(raw_verified: Any, role: Any = None, can_create_mobile_event: Any = None) -> bool:
    return bool(raw_verified) or _role_auto_verified(role) or bool(can_create_mobile_event)


def _normalize_city_text(value: Any) -> str:
    txt = str(value or "").strip()
    if not txt:
        return ""
    txt = txt.casefold().replace("ı", "i")
    txt = unicodedata.normalize("NFKD", txt)
    txt = "".join(ch for ch in txt if not unicodedata.combining(ch))
    txt = (
        txt.replace("ş", "s")
        .replace("ğ", "g")
        .replace("ü", "u")
        .replace("ö", "o")
        .replace("ç", "c")
    )
    txt = re.sub(r"[^a-z0-9]+", " ", txt)
    return " ".join(txt.split())


def _normalize_dance_school_key(value: Any) -> str:
    txt = str(value or "").strip()
    if not txt:
        return ""
    txt = txt.casefold().replace("ı", "i")
    txt = unicodedata.normalize("NFKD", txt)
    txt = "".join(ch for ch in txt if not unicodedata.combining(ch))
    txt = (
        txt.replace("ş", "s")
        .replace("ğ", "g")
        .replace("ü", "u")
        .replace("ö", "o")
        .replace("ç", "c")
    )
    txt = re.sub(r"[^a-z0-9]+", "", txt)
    return txt


def _normalize_event_key(value: Any) -> str:
    txt = str(value or "").strip()
    if not txt:
        return ""
    txt = txt.casefold().replace("ı", "i")
    txt = unicodedata.normalize("NFKD", txt)
    txt = "".join(ch for ch in txt if not unicodedata.combining(ch))
    txt = (
        txt.replace("ş", "s")
        .replace("ğ", "g")
        .replace("ü", "u")
        .replace("ö", "o")
        .replace("ç", "c")
    )
    txt = re.sub(r"[^a-z0-9]+", "", txt)
    return txt


def _is_visnelik_ticket_event(event_name: Any, event_slug: Any = None) -> bool:
    return "visnelik" in _normalize_event_key(event_name) or "visnelik" in _normalize_event_key(event_slug)


def _school_qr_payload(
    *,
    ticket_id: int,
    submission_id: int,
    raw_token: str,
    account_id: int,
    event_name: str,
    event_slug: str,
    school_name: str,
    school_id: Optional[int],
) -> str:
    token = (raw_token or "").strip()
    if not token:
        return ""
    if not _is_visnelik_ticket_event(event_name, event_slug):
        return token
    payload = {
        "v": 1,
        "tk": token,
        "ti": int(ticket_id),
        "si": int(submission_id),
        "ai": int(account_id),
        "sn": str(school_name or "").strip()[:120],
        "sid": int(school_id or 0),
    }
    body = json.dumps(payload, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
    encoded = base64.urlsafe_b64encode(body).decode("ascii").rstrip("=")
    sig = hmac.new(
        QR_SIGNING_SECRET.encode("utf-8"),
        encoded.encode("utf-8"),
        hashlib.sha256,
    ).hexdigest()[:24]
    return f"dmqr1.{encoded}.{sig}"


def _slugify_dance_school(value: Any) -> str:
    txt = str(value or "").strip()
    if not txt:
        return ""
    txt = txt.casefold().replace("ı", "i")
    txt = unicodedata.normalize("NFKD", txt)
    txt = "".join(ch for ch in txt if not unicodedata.combining(ch))
    txt = (
        txt.replace("ş", "s")
        .replace("ğ", "g")
        .replace("ü", "u")
        .replace("ö", "o")
        .replace("ç", "c")
    )
    txt = re.sub(r"[^a-z0-9]+", "-", txt)
    txt = re.sub(r"-{2,}", "-", txt).strip("-")
    return txt


def _unique_dance_school_slug(cur, base_slug: str) -> str:
    slug = (base_slug or "").strip() or f"dance-school-{uuid.uuid4().hex[:8]}"
    candidate = slug
    suffix = 2
    while True:
        cur.execute(
            "SELECT 1 FROM mobile_dance_schools WHERE slug=%s LIMIT 1",
            (candidate,),
        )
        if not cur.fetchone():
            return candidate
        candidate = f"{slug}-{suffix}"
        suffix += 1


def _ensure_dance_school(cur, name: str, aliases: Optional[List[str]] = None) -> Optional[Dict[str, Any]]:
    cleaned_name = str(name or "").strip()
    lookup_key = _normalize_dance_school_key(cleaned_name)
    if not cleaned_name or not lookup_key:
        return None

    cur.execute(
        """
        SELECT ds.id AS school_id, ds.name, ds.slug, ds.is_active
        FROM mobile_dance_school_aliases a
        JOIN mobile_dance_schools ds ON ds.id = a.school_id
        WHERE a.alias_key=%s
        LIMIT 1
        """,
        (lookup_key,),
    )
    existing = cur.fetchone()
    if existing:
        school_id = int(existing["school_id"])
        school_name = (existing.get("name") or "").strip()
        school_slug = (existing.get("slug") or "").strip()
    else:
        school_slug = _unique_dance_school_slug(cur, _slugify_dance_school(cleaned_name) or lookup_key)
        cur.execute(
            """
            INSERT INTO mobile_dance_schools (name, slug, is_active, created_at, updated_at)
            VALUES (%s, %s, TRUE, NOW(), NOW())
            RETURNING id, name, slug, is_active
            """,
            (cleaned_name, school_slug),
        )
        created = cur.fetchone() or {}
        school_id = int(created.get("id") or 0)
        school_name = (created.get("name") or cleaned_name).strip()
        school_slug = (created.get("slug") or school_slug).strip()

    alias_values: List[str] = [cleaned_name]
    for alias in aliases or []:
        alias_txt = str(alias or "").strip()
        if alias_txt:
            alias_values.append(alias_txt)
    seen_aliases = set()
    for alias_name in alias_values:
        alias_key = _normalize_dance_school_key(alias_name)
        if not alias_key or alias_key in seen_aliases:
            continue
        seen_aliases.add(alias_key)
        cur.execute(
            """
            INSERT INTO mobile_dance_school_aliases (school_id, alias_name, alias_key, created_at)
            VALUES (%s, %s, %s, NOW())
            ON CONFLICT (alias_key) DO NOTHING
            """,
            (int(school_id), alias_name, alias_key),
        )

    return {
        "school_id": int(school_id),
        "name": school_name,
        "slug": school_slug,
        "is_active": bool(existing.get("is_active")) if existing else True,
    }


def _resolve_dance_school(
    conn,
    *,
    school_id: Optional[int] = None,
    raw_name: Optional[str] = None,
    active_only: bool = True,
) -> Optional[Dict[str, Any]]:
    cur = conn.cursor()
    if school_id and int(school_id) > 0:
        if active_only:
            cur.execute(
                """
                SELECT id AS school_id, name, slug, is_active
                FROM mobile_dance_schools
                WHERE id=%s AND is_active=TRUE
                LIMIT 1
                """,
                (int(school_id),),
            )
        else:
            cur.execute(
                """
                SELECT id AS school_id, name, slug, is_active
                FROM mobile_dance_schools
                WHERE id=%s
                LIMIT 1
                """,
                (int(school_id),),
            )
        row = cur.fetchone()
        if row:
            return {
                "school_id": int(row["school_id"]),
                "name": (row.get("name") or "").strip(),
                "slug": (row.get("slug") or "").strip(),
                "is_active": bool(row.get("is_active")),
            }

    lookup_key = _normalize_dance_school_key(raw_name)
    if not lookup_key:
        return None
    if active_only:
        cur.execute(
            """
            SELECT ds.id AS school_id, ds.name, ds.slug, ds.is_active
            FROM mobile_dance_school_aliases a
            JOIN mobile_dance_schools ds ON ds.id = a.school_id
            WHERE a.alias_key=%s AND ds.is_active=TRUE
            LIMIT 1
            """,
            (lookup_key,),
        )
    else:
        cur.execute(
            """
            SELECT ds.id AS school_id, ds.name, ds.slug, ds.is_active
            FROM mobile_dance_school_aliases a
            JOIN mobile_dance_schools ds ON ds.id = a.school_id
            WHERE a.alias_key=%s
            LIMIT 1
            """,
            (lookup_key,),
        )
    row = cur.fetchone()
    if not row:
        return None
    return {
        "school_id": int(row["school_id"]),
        "name": (row.get("name") or "").strip(),
        "slug": (row.get("slug") or "").strip(),
        "is_active": bool(row.get("is_active")),
    }


def _seed_dance_school_directory(conn) -> None:
    cur = conn.cursor()
    for seed in DEFAULT_DANCE_SCHOOL_SEEDS:
        _ensure_dance_school(cur, str(seed.get("name") or "").strip(), list(seed.get("aliases") or []))

    cur.execute(
        """
        SELECT DISTINCT COALESCE(dance_school, '') AS dance_school
        FROM mobile_profile_settings
        WHERE COALESCE(dance_school, '') <> ''
        ORDER BY dance_school ASC
        """
    )
    for row in cur.fetchall() or []:
        school_name = (row.get("dance_school") or "").strip()
        if not school_name:
            continue
        _ensure_dance_school(cur, school_name)

    cur.execute(
        """
        SELECT account_id, COALESCE(dance_school, '') AS dance_school
        FROM mobile_profile_settings
        WHERE dance_school_id IS NULL
          AND COALESCE(dance_school, '') <> ''
        """
    )
    for row in cur.fetchall() or []:
        resolved = _resolve_dance_school(conn, raw_name=row.get("dance_school"), active_only=False)
        if not resolved:
            continue
        cur.execute(
            """
            UPDATE mobile_profile_settings
            SET dance_school_id=%s,
                dance_school=%s,
                updated_at=NOW()
            WHERE account_id=%s
            """,
            (
                int(resolved["school_id"]),
                (resolved.get("name") or "").strip(),
                int(row["account_id"]),
            ),
        )


def _fetch_dance_school_items(conn, *, active_only: bool = True) -> List[Dict[str, Any]]:
    cur = conn.cursor()
    if active_only:
        cur.execute(
            """
            SELECT
                ds.id AS school_id,
                ds.name,
                ds.slug,
                ds.is_active,
                ds.created_at,
                ds.updated_at,
                COUNT(a.id)::INT AS alias_count
            FROM mobile_dance_schools ds
            LEFT JOIN mobile_dance_school_aliases a ON a.school_id = ds.id
            WHERE ds.is_active=TRUE
            GROUP BY ds.id
            ORDER BY LOWER(ds.name) ASC, ds.id ASC
            """
        )
    else:
        cur.execute(
            """
            SELECT
                ds.id AS school_id,
                ds.name,
                ds.slug,
                ds.is_active,
                ds.created_at,
                ds.updated_at,
                COUNT(a.id)::INT AS alias_count
            FROM mobile_dance_schools ds
            LEFT JOIN mobile_dance_school_aliases a ON a.school_id = ds.id
            GROUP BY ds.id
            ORDER BY LOWER(ds.name) ASC, ds.id ASC
            """
        )
    rows = cur.fetchall() or []
    return [
        {
            "school_id": int(row.get("school_id") or 0),
            "name": (row.get("name") or "").strip(),
            "slug": (row.get("slug") or "").strip(),
            "is_active": bool(row.get("is_active")),
            "alias_count": int(row.get("alias_count") or 0),
            "created_at": _json_time_text(row.get("created_at")),
            "updated_at": _json_time_text(row.get("updated_at")),
        }
        for row in rows
    ]


db_conn = get_db_connection
_db_conn = db_conn
_display_name = display_name
_blocked_peer_ids = get_blocked_peer_ids

def _reconcile_ticket_rows_with_woo(conn, account_id: int, rows: List[Dict[str, Any]]) -> List[Dict[str, Any]]:
    if not rows:
        return rows

    order_ids: List[str] = []
    seen = set()
    for row in rows:
        oid = str(row.get("woo_order_id") or "").strip()
        if not oid or not oid.isdigit() or oid in seen:
            continue
        seen.add(oid)
        order_ids.append(oid)

    if not order_ids:
        return rows

    status_map = _fetch_woo_order_statuses(order_ids)
    if not status_map:
        return rows

    cur = conn.cursor()
    changed = False
    for order_id, woo_status in status_map.items():
        ticket_status = _ticket_status_from_woo_status(woo_status)
        cur.execute(
            """
            UPDATE mobile_tickets
            SET woo_order_status=%s,
                status=CASE
                    WHEN %s='active' AND status IN ('payment_pending','active') THEN 'active'
                    WHEN %s='payment_pending' AND status IN ('payment_pending','active') THEN 'payment_pending'
                    WHEN %s='cancelled' THEN 'cancelled'
                    ELSE status
                END
            WHERE account_id=%s AND woo_order_id=%s
            """,
            (woo_status, ticket_status, ticket_status, ticket_status, int(account_id), order_id),
        )
        changed = changed or cur.rowcount > 0

        for row in rows:
            if str(row.get("woo_order_id") or "").strip() != order_id:
                continue
            row["woo_order_status"] = woo_status
            current_status = str(row.get("status") or "").strip().lower()
            if ticket_status == "active" and current_status in {"payment_pending", "active"}:
                row["status"] = "active"
            elif ticket_status == "payment_pending" and current_status in {"payment_pending", "active"}:
                row["status"] = "payment_pending"
            elif ticket_status == "cancelled":
                row["status"] = "cancelled"

    if changed:
        conn.commit()
    return rows


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


def _json_time_text(value: Any) -> str:
    if value is None:
        return ""
    if hasattr(value, "isoformat"):
        try:
            return value.isoformat()
        except Exception:
            pass
    return str(value)


def _require_guest_list_manager(conn, authorization: Optional[str]) -> Dict[str, Any]:
    account_id = _require_account_id(conn, authorization)
    cur = conn.cursor()
    cur.execute(
        """
        SELECT
            COALESCE(a.role,'') AS role,
            COALESCE(a.email,'') AS email,
            COALESCE(a.name,'') AS name,
            COALESCE(a.can_create_mobile_event,0) AS can_create_mobile_event
        FROM accounts a
        WHERE a.id=%s
        LIMIT 1
        """,
        (int(account_id),),
    )
    row = cur.fetchone() or {}
    role = (row.get("role") or "").strip().lower()
    can_create = bool(int(row.get("can_create_mobile_event") or 0))
    if role not in {"editor", "super_admin"} and not can_create:
        raise HTTPException(status_code=403, detail="Davetli listesi yonetimi icin editor yetkisi gerekli")
    return {
        "account_id": int(account_id),
        "role": role,
        "email": (row.get("email") or "").strip().lower(),
        "name": (row.get("name") or "").strip(),
    }


def _serialize_guest_list_summary(row: Dict[str, Any]) -> Dict[str, Any]:
    return {
        "guest_list_id": int(row.get("id") or 0),
        "name": (row.get("name") or "").strip(),
        "member_count": int(row.get("member_count") or 0),
        "created_at": _json_time_text(row.get("created_at")),
        "updated_at": _json_time_text(row.get("updated_at")),
    }


def _serialize_guest_list_member(row: Dict[str, Any]) -> Dict[str, Any]:
    return {
        "account_id": int(row.get("account_id") or 0),
        "name": display_name(
            (row.get("name") or ""),
            (row.get("email") or ""),
            (row.get("username") or ""),
        ),
        "email": (row.get("email") or "").strip(),
        "avatar_url": (row.get("avatar_url") or "").strip(),
        "is_verified": _effective_is_verified(
            row.get("is_verified"),
            row.get("role"),
            row.get("can_create_mobile_event"),
        ),
        "added_at": _json_time_text(row.get("created_at")),
    }


def _fetch_guest_list_detail(conn, owner_account_id: int, guest_list_id: int) -> Dict[str, Any]:
    cur = conn.cursor()
    cur.execute(
        """
        SELECT
            gl.id,
            gl.name,
            gl.created_at,
            gl.updated_at,
            COUNT(glm.account_id) AS member_count
        FROM mobile_guest_lists gl
        LEFT JOIN mobile_guest_list_members glm ON glm.list_id = gl.id
        WHERE gl.owner_account_id=%s AND gl.id=%s
        GROUP BY gl.id
        LIMIT 1
        """,
        (int(owner_account_id), int(guest_list_id)),
    )
    row = cur.fetchone()
    if not row:
        raise HTTPException(status_code=404, detail="Davetli listesi bulunamadi")

    cur.execute(
        """
        SELECT
            glm.account_id,
            glm.created_at,
            COALESCE(a.name,'') AS name,
            COALESCE(a.email,'') AS email,
            COALESCE(a.role,'') AS role,
            COALESCE(a.can_create_mobile_event,0) AS can_create_mobile_event,
            COALESCE(ps.username,'') AS username,
            COALESCE(ps.avatar_url,'') AS avatar_url,
            COALESCE(ps.is_verified, FALSE) AS is_verified
        FROM mobile_guest_list_members glm
        JOIN accounts a ON a.id = glm.account_id
        LEFT JOIN mobile_profile_settings ps ON ps.account_id = glm.account_id
        WHERE glm.list_id=%s
        ORDER BY glm.created_at ASC, glm.account_id ASC
        """,
        (int(guest_list_id),),
    )
    members = cur.fetchall() or []
    return {
        **_serialize_guest_list_summary(row),
        "members": [_serialize_guest_list_member(member) for member in members],
    }


def _notify_friend_request(
    conn,
    *,
    requester_id: int,
    target_account_id: int,
    request_id: int,
) -> None:
    cur = conn.cursor()
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
        (int(requester_id),),
    )
    sender = cur.fetchone() or {}
    sender_display = _display_name(
        (sender.get("name") or ""),
        (sender.get("email") or ""), # Changed _display_name to display_name
        (sender.get("app_username") or ""),
    )
    title = "Yeni bir arkadaslik istegin var"
    body = f"{sender_display} sana arkadaslik istegi gonderdi."
    route = "/social/add-friends"

    try:
        cur.execute(
            """
            INSERT INTO mobile_user_notifications
                (account_id, title, body, notification_type, sent_by_account_id, send_batch_id, send_to_all, target_route, created_at)
            VALUES (%s, %s, %s, 'friend_request', %s, NULL, FALSE, %s, NOW())
            """,
            (int(target_account_id), title, body, int(requester_id), route),
        )
    except Exception as exc:
        logger.warning(
            "friend_request_notification_insert_failed requester=%s target=%s request_id=%s err=%s",
            int(requester_id),
            int(target_account_id),
            int(request_id),
            str(exc),
        )

    try:
        push_result = _dispatch_push_for_accounts(
            conn=conn,
            account_ids=[int(target_account_id)],
            title=title,
            body=body,
            sender_account_id=int(requester_id),
            route=route,
            notification_type="friend_request",
            extra_data={
                "friend_request_id": int(request_id),
                "from_account_id": int(requester_id),
            },
        )
        logger.info(
            "friend_request_push_send requester=%s target=%s request_id=%s result=%s",
            int(requester_id),
            int(target_account_id),
            int(request_id),
            json.dumps(push_result, ensure_ascii=False),
        )
    except Exception as exc:
        logger.warning(
            "friend_request_push_failed requester=%s target=%s request_id=%s err=%s",
            int(requester_id),
            int(target_account_id),
            int(request_id),
            str(exc),
        )


def _normalize_notification_preferences(raw: Any) -> Dict[str, bool]:
    prefs = dict(DEFAULT_NOTIFICATION_PREFERENCES)
    if raw is None:
        return prefs
    src: Any = raw
    if isinstance(raw, str):
        txt = raw.strip()
        if not txt:
            return prefs
        try:
            src = json.loads(txt)
        except Exception:
            return prefs
    if not isinstance(src, dict):
        return prefs
    for key in DEFAULT_NOTIFICATION_PREFERENCES.keys():
        if key in src:
            prefs[key] = bool(src.get(key))
    return prefs


def _notification_preferences_json(raw: Any) -> str:
    return json.dumps(_normalize_notification_preferences(raw), ensure_ascii=False, separators=(",", ":"))


def _resolve_event_kind_from_route(conn, route: str) -> str:
    route_txt = (route or "").strip()
    m = re.match(r"^/events/(\d+)$", route_txt)
    if not m:
        return ""
    cur = conn.cursor()
    cur.execute(
        "SELECT COALESCE(event_kind,'') AS event_kind FROM mobile_event_submissions WHERE id=%s LIMIT 1",
        (int(m.group(1)),),
    )
    row = cur.fetchone() or {}
    return (row.get("event_kind") or "").strip().lower()


def _notification_category_for_push(
    conn,
    *,
    notification_type: str,
    route: str,
    extra_data: Optional[Dict[str, Any]] = None,
) -> str:
    route_txt = (route or "").strip().lower()
    data = extra_data or {}
    kind = ""
    raw_kind = data.get("event_kind")
    if isinstance(raw_kind, str):
        kind = raw_kind.strip().lower()
    if route_txt.startswith("/news/"):
        return "news"
    if route_txt.startswith("/events/"):
        if not kind:
            kind = _resolve_event_kind_from_route(conn, route_txt)
        if kind in {"dance_night", "festival", "competition", "promo_lesson"}:
            return kind
    return "system"


def _normalize_username(value: str) -> str:
    return " ".join((value or "").split())


def _friend_pair(a: int, b: int) -> tuple[int, int]:
    return (a, b) if a < b else (b, a)


def _friendship_exists(conn, a: int, b: int) -> bool:
    x, y = _friend_pair(int(a), int(b))
    cur = conn.cursor()
    cur.execute(
        "SELECT 1 FROM mobile_friendships WHERE user_a_id=%s AND user_b_id=%s LIMIT 1",
        (x, y),
    )
    return bool(cur.fetchone())


def _connect_friends(conn, a: int, b: int) -> None:
    x, y = _friend_pair(int(a), int(b))
    cur = conn.cursor()
    cur.execute(
        """
        INSERT INTO mobile_friendships (user_a_id, user_b_id, created_at)
        VALUES (%s, %s, NOW()::text)
        ON CONFLICT (user_a_id, user_b_id) DO NOTHING
        """,
        (x, y),
    )
    cur.execute(
        """
        UPDATE mobile_friend_requests
        SET status='accepted', responded_at=NOW()::text
        WHERE status='pending'
          AND (
            (requester_id=%s AND target_id=%s)
            OR (requester_id=%s AND target_id=%s)
          )
        """,
        (int(a), int(b), int(b), int(a)),
    )


def _parse_friend_qr_payload(payload: str) -> int:
    raw = (payload or "").strip()
    if not raw:
        raise HTTPException(status_code=400, detail="QR verisi boş")
    match = re.search(r"(\d+)\s*$", raw)
    if not match:
        raise HTTPException(status_code=400, detail="Geçersiz arkadaş QR kodu")
    try:
        target_account_id = int(match.group(1))
    except Exception:
        raise HTTPException(status_code=400, detail="Geçersiz arkadaş QR kodu")
    if target_account_id <= 0:
        raise HTTPException(status_code=400, detail="Geçersiz arkadaş QR kodu")
    return target_account_id


def _block_exists(conn, blocker_account_id: int, blocked_account_id: int) -> bool: # Changed _blocked_peer_ids to get_blocked_peer_ids
    cur = conn.cursor()
    cur.execute(
        """
        SELECT 1
        FROM mobile_user_blocks
        WHERE blocker_account_id=%s AND blocked_account_id=%s
        LIMIT 1
        """,
        (int(blocker_account_id), int(blocked_account_id)),
    )
    return bool(cur.fetchone())


def _block_exists_any(conn, account_a_id: int, account_b_id: int) -> bool:
    return _block_exists(conn, int(account_a_id), int(account_b_id)) or _block_exists(conn, int(account_b_id), int(account_a_id))


def _require_notification_sender_account_id(conn, authorization: Optional[str]) -> int:
    account_id = _require_account_id(conn, authorization)
    cur = conn.cursor()
    cur.execute(
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
    row = cur.fetchone() or {}
    role = str(row.get("role") or "customer").strip().lower()
    if role != "super_admin":
        raise HTTPException(status_code=403, detail="Bildirim gönderme yetkisi yok")
    return int(account_id)


def _require_mobile_admin(x_admin_token: Optional[str]) -> None:
    if not MOBILE_ADMIN_TOKEN:
        raise HTTPException(status_code=503, detail="MOBILE_ADMIN_TOKEN tanımlı değil")
    if not x_admin_token or x_admin_token.strip() != MOBILE_ADMIN_TOKEN:
        raise HTTPException(status_code=401, detail="Yetkisiz")


def _today_istanbul() -> date:
    try:
        from zoneinfo import ZoneInfo

        return datetime.now(ZoneInfo("Europe/Istanbul")).date()
    except Exception:
        return datetime.now(timezone.utc).date()


def _now_istanbul() -> datetime:
    try:
        from zoneinfo import ZoneInfo

        return datetime.now(ZoneInfo("Europe/Istanbul"))
    except Exception:
        return datetime.now(timezone.utc)


def _resolve_system_sender_account_id(conn) -> int:
    if SYSTEM_SENDER_ACCOUNT_ID > 0:
        return int(SYSTEM_SENDER_ACCOUNT_ID)
    cur = conn.cursor()
    cur.execute(
        """
        SELECT id
        FROM accounts
        WHERE LOWER(COALESCE(email,''))=%s
           OR LOWER(COALESCE(name,''))=%s
        ORDER BY id ASC
        LIMIT 1
        """,
        (SYSTEM_SENDER_EMAIL, SYSTEM_SENDER_NAME.lower()),
    )
    row = cur.fetchone() or {}
    return int(row.get("id") or 0)


def _birthday_schedule_key(now_local: datetime, reason: str) -> Optional[str]:
    normalized_reason = (reason or "").strip().lower()
    if normalized_reason in {"admin", "manual"}:
        return "manual"
    hour = int(now_local.hour)
    minute = int(now_local.minute)
    if hour == 0 and minute < 10:
        return "midnight"
    if hour == 10 and minute < 10:
        return "morning"
    return None


def _event_city_schedule_key(now_local: datetime, reason: str) -> Optional[str]:
    normalized_reason = (reason or "").strip().lower()
    if normalized_reason == "admin":
        return "manual"
    hour = int(now_local.hour)
    minute = int(now_local.minute)
    if hour == 12 and minute < 10:
        return "noon"
    if hour == 18 and minute < 10:
        return "evening"
    return None


def _avatar_file_allowed(upload: UploadFile) -> bool:
    content_type = (upload.content_type or "").lower().strip()
    if content_type in ALLOWED_AVATAR_CONTENT_TYPES:
        return True
    ext = os.path.splitext((upload.filename or "").lower())[1]
    return ext in ALLOWED_AVATAR_EXTENSIONS


def _convert_image_to_jpeg_bytes(raw: bytes) -> bytes:
    try:
        from PIL import Image
        from PIL import ImageOps
    except Exception as exc:
        raise HTTPException(status_code=500, detail=f"Gorsel donusumu icin Pillow gerekli: {exc}") from exc

    try:
        try:
            from pillow_heif import register_heif_opener

            register_heif_opener()
        except Exception:
            # HEIC acilimi pillow-heif yoksa acilamayabilir; asagida net hata donecek.
            pass

        with Image.open(BytesIO(raw)) as img:
            img = ImageOps.exif_transpose(img)
            if img.mode not in ("RGB", "L"):
                bg = Image.new("RGB", img.size, (255, 255, 255))
                if "A" in img.getbands():
                    bg.paste(img, mask=img.getchannel("A"))
                else:
                    bg.paste(img.convert("RGB"))
                img = bg
            elif img.mode == "L":
                img = img.convert("RGB")

            resample = getattr(getattr(Image, "Resampling", Image), "LANCZOS", Image.LANCZOS)
            img = ImageOps.fit(
                img,
                (PROFILE_AVATAR_SIZE, PROFILE_AVATAR_SIZE),
                method=resample,
                centering=(0.5, 0.5),
            )

            out = BytesIO()
            img.save(out, format="JPEG", quality=88, optimize=True)
            return out.getvalue()
    except HTTPException:
        raise
    except Exception:
        raise HTTPException(status_code=400, detail="Gorsel okunamadi. Lutfen gecerli bir fotograf secin.")


def init_profile_settings_table():
    conn = db_conn()
    try:
        os.makedirs(PROFILE_AVATAR_DIR, exist_ok=True)
        cur = conn.cursor()
        cur.execute(
            """
            CREATE TABLE IF NOT EXISTS mobile_profile_settings (
                account_id INTEGER PRIMARY KEY,
                username VARCHAR(40),
                store_title VARCHAR(80),
                city VARCHAR(80),
                birth_date DATE,
                gender VARCHAR(16),
                dance_interests TEXT,
                dance_school VARCHAR(120),
                dance_school_id BIGINT,
                about_text TEXT,
                is_verified BOOLEAN NOT NULL DEFAULT FALSE,
                store_enabled BOOLEAN NOT NULL DEFAULT FALSE,
                preferred_language VARCHAR(8),
                notifications_enabled BOOLEAN,
                notification_preferences TEXT,
                avatar_url TEXT,
                updated_at TIMESTAMP WITHOUT TIME ZONE DEFAULT NOW()
            )
            """
        )
        cur.execute("ALTER TABLE mobile_profile_settings ADD COLUMN IF NOT EXISTS avatar_url TEXT")
        cur.execute("ALTER TABLE mobile_profile_settings ADD COLUMN IF NOT EXISTS store_title VARCHAR(80)")
        cur.execute("ALTER TABLE mobile_profile_settings ADD COLUMN IF NOT EXISTS city VARCHAR(80)")
        cur.execute("ALTER TABLE mobile_profile_settings ADD COLUMN IF NOT EXISTS birth_date DATE")
        cur.execute("ALTER TABLE mobile_profile_settings ADD COLUMN IF NOT EXISTS gender VARCHAR(16)")
        cur.execute("ALTER TABLE mobile_profile_settings ADD COLUMN IF NOT EXISTS dance_interests TEXT")
        cur.execute("ALTER TABLE mobile_profile_settings ADD COLUMN IF NOT EXISTS dance_school VARCHAR(120)")
        cur.execute("ALTER TABLE mobile_profile_settings ADD COLUMN IF NOT EXISTS dance_school_id BIGINT")
        cur.execute("ALTER TABLE mobile_profile_settings ADD COLUMN IF NOT EXISTS about_text TEXT")
        cur.execute("ALTER TABLE mobile_profile_settings ADD COLUMN IF NOT EXISTS is_verified BOOLEAN NOT NULL DEFAULT FALSE")
        cur.execute("ALTER TABLE mobile_profile_settings ADD COLUMN IF NOT EXISTS store_enabled BOOLEAN NOT NULL DEFAULT FALSE")
        cur.execute("ALTER TABLE mobile_profile_settings ADD COLUMN IF NOT EXISTS notification_preferences TEXT")
        cur.execute(
            """
            CREATE TABLE IF NOT EXISTS mobile_dance_schools (
                id BIGSERIAL PRIMARY KEY,
                name VARCHAR(120) NOT NULL,
                slug VARCHAR(140) NOT NULL UNIQUE,
                is_active BOOLEAN NOT NULL DEFAULT TRUE,
                created_at TIMESTAMP WITHOUT TIME ZONE DEFAULT NOW(),
                updated_at TIMESTAMP WITHOUT TIME ZONE DEFAULT NOW()
            )
            """
        )
        cur.execute(
            """
            CREATE TABLE IF NOT EXISTS mobile_dance_school_aliases (
                id BIGSERIAL PRIMARY KEY,
                school_id BIGINT NOT NULL REFERENCES mobile_dance_schools(id) ON DELETE CASCADE,
                alias_name VARCHAR(120) NOT NULL,
                alias_key VARCHAR(140) NOT NULL UNIQUE,
                created_at TIMESTAMP WITHOUT TIME ZONE DEFAULT NOW()
            )
            """
        )
        cur.execute(
            """
            CREATE INDEX IF NOT EXISTS idx_mobile_profile_settings_dance_school_id
            ON mobile_profile_settings(dance_school_id)
            """
        )
        cur.execute(
            """
            CREATE INDEX IF NOT EXISTS idx_mobile_dance_schools_name_lower
            ON mobile_dance_schools (LOWER(name))
            """
        )
        cur.execute(
            """
            CREATE TABLE IF NOT EXISTS mobile_user_notifications (
                id BIGSERIAL PRIMARY KEY,
                account_id INTEGER NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
                title VARCHAR(160) NOT NULL,
                body TEXT NOT NULL,
                notification_type VARCHAR(32) NOT NULL DEFAULT 'manual',
                sent_by_account_id INTEGER REFERENCES accounts(id) ON DELETE SET NULL,
                created_at TIMESTAMP WITHOUT TIME ZONE DEFAULT NOW()
            )
            """
        )
        cur.execute(
            """
            CREATE INDEX IF NOT EXISTS idx_mobile_user_notifications_account_created
            ON mobile_user_notifications(account_id, created_at DESC)
            """
        )
        cur.execute("ALTER TABLE mobile_user_notifications ADD COLUMN IF NOT EXISTS send_batch_id VARCHAR(64)")
        cur.execute("ALTER TABLE mobile_user_notifications ADD COLUMN IF NOT EXISTS send_to_all BOOLEAN NOT NULL DEFAULT FALSE")
        cur.execute("ALTER TABLE mobile_user_notifications ADD COLUMN IF NOT EXISTS target_route TEXT")
        cur.execute("ALTER TABLE mobile_user_notifications ADD COLUMN IF NOT EXISTS read_at TIMESTAMP WITHOUT TIME ZONE")
        cur.execute(
            """
            SELECT EXISTS(
                SELECT 1
                FROM mobile_user_notifications
                WHERE read_at IS NOT NULL
                LIMIT 1
            ) AS has_any_read_marker
            """
        )
        if not bool((cur.fetchone() or {}).get("has_any_read_marker")):
            cur.execute(
                """
                UPDATE mobile_user_notifications
                SET read_at=created_at
                WHERE read_at IS NULL
                """
            )
        cur.execute(
            """
            CREATE INDEX IF NOT EXISTS idx_mobile_user_notifications_sender_batch
            ON mobile_user_notifications(sent_by_account_id, send_batch_id, created_at DESC)
            """
        )
        cur.execute(
            """
            CREATE INDEX IF NOT EXISTS idx_mobile_user_notifications_unread
            ON mobile_user_notifications(account_id, created_at DESC)
            WHERE read_at IS NULL
            """
        )
        cur.execute(
            """
            CREATE TABLE IF NOT EXISTS mobile_push_tokens (
                id BIGSERIAL PRIMARY KEY,
                account_id INTEGER NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
                device_token TEXT NOT NULL UNIQUE,
                platform VARCHAR(20) NOT NULL DEFAULT 'unknown',
                app_version VARCHAR(40) NOT NULL DEFAULT '',
                device_model VARCHAR(120) NOT NULL DEFAULT '',
                notifications_enabled BOOLEAN NOT NULL DEFAULT TRUE,
                is_active BOOLEAN NOT NULL DEFAULT TRUE,
                last_seen_at TIMESTAMP WITHOUT TIME ZONE DEFAULT NOW(),
                created_at TIMESTAMP WITHOUT TIME ZONE DEFAULT NOW(),
                updated_at TIMESTAMP WITHOUT TIME ZONE DEFAULT NOW()
            )
            """
        )
        cur.execute("ALTER TABLE mobile_push_tokens ADD COLUMN IF NOT EXISTS app_version VARCHAR(40) NOT NULL DEFAULT ''")
        cur.execute("ALTER TABLE mobile_push_tokens ADD COLUMN IF NOT EXISTS device_model VARCHAR(120) NOT NULL DEFAULT ''")
        cur.execute(
            """
            CREATE INDEX IF NOT EXISTS idx_mobile_push_tokens_account_active
            ON mobile_push_tokens(account_id, is_active, notifications_enabled)
            """
        )
        cur.execute(
            """
            CREATE TABLE IF NOT EXISTS mobile_birthday_push_log (
                account_id INTEGER NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
                notification_date DATE NOT NULL,
                created_at TIMESTAMP WITHOUT TIME ZONE DEFAULT NOW(),
                PRIMARY KEY (account_id, notification_date)
            )
            """
        )
        cur.execute(
            """
            CREATE TABLE IF NOT EXISTS mobile_birthday_delivery_log (
                account_id INTEGER NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
                notification_date DATE NOT NULL,
                schedule_key VARCHAR(32) NOT NULL,
                created_at TIMESTAMP WITHOUT TIME ZONE DEFAULT NOW(),
                PRIMARY KEY (account_id, notification_date, schedule_key)
            )
            """
        )
        cur.execute(
            """
            CREATE TABLE IF NOT EXISTS mobile_event_city_delivery_log (
                account_id BIGINT NOT NULL,
                submission_id BIGINT NOT NULL,
                notification_date DATE NOT NULL,
                schedule_key VARCHAR(24) NOT NULL,
                created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
                PRIMARY KEY (account_id, submission_id, notification_date, schedule_key)
            )
            """
        )
        cur.execute(
            """
            CREATE TABLE IF NOT EXISTS mobile_app_popups (
                id BIGSERIAL PRIMARY KEY,
                title VARCHAR(160) NOT NULL,
                body TEXT NOT NULL,
                cta_label VARCHAR(60) NOT NULL DEFAULT '',
                cta_target VARCHAR(500) NOT NULL DEFAULT '',
                minimum_app_version VARCHAR(40) NOT NULL DEFAULT '',
                dismissible BOOLEAN NOT NULL DEFAULT TRUE,
                show_to_guests BOOLEAN NOT NULL DEFAULT FALSE,
                force_update BOOLEAN NOT NULL DEFAULT FALSE,
                is_active BOOLEAN NOT NULL DEFAULT TRUE,
                created_by_account_id INTEGER REFERENCES accounts(id) ON DELETE SET NULL,
                created_at TIMESTAMP WITHOUT TIME ZONE DEFAULT NOW(),
                updated_at TIMESTAMP WITHOUT TIME ZONE DEFAULT NOW()
            )
            """
        )
        cur.execute("ALTER TABLE mobile_app_popups ADD COLUMN IF NOT EXISTS cta_label VARCHAR(60) NOT NULL DEFAULT ''")
        cur.execute("ALTER TABLE mobile_app_popups ADD COLUMN IF NOT EXISTS cta_target VARCHAR(500) NOT NULL DEFAULT ''")
        cur.execute("ALTER TABLE mobile_app_popups ADD COLUMN IF NOT EXISTS minimum_app_version VARCHAR(40) NOT NULL DEFAULT ''")
        cur.execute("ALTER TABLE mobile_app_popups ADD COLUMN IF NOT EXISTS dismissible BOOLEAN NOT NULL DEFAULT TRUE")
        cur.execute("ALTER TABLE mobile_app_popups ADD COLUMN IF NOT EXISTS show_to_guests BOOLEAN NOT NULL DEFAULT FALSE")
        cur.execute("ALTER TABLE mobile_app_popups ADD COLUMN IF NOT EXISTS force_update BOOLEAN NOT NULL DEFAULT FALSE")
        cur.execute("ALTER TABLE mobile_app_popups ADD COLUMN IF NOT EXISTS is_active BOOLEAN NOT NULL DEFAULT TRUE")
        cur.execute("ALTER TABLE mobile_app_popups ADD COLUMN IF NOT EXISTS created_by_account_id INTEGER REFERENCES accounts(id) ON DELETE SET NULL")
        cur.execute(
            """
            CREATE INDEX IF NOT EXISTS idx_mobile_app_popups_active_updated
            ON mobile_app_popups(is_active, updated_at DESC, id DESC)
            """
        )
        cur.execute(
            """
            CREATE TABLE IF NOT EXISTS mobile_featured_events (
                slot SMALLINT PRIMARY KEY,
                submission_id BIGINT NOT NULL REFERENCES mobile_event_submissions(id) ON DELETE CASCADE,
                updated_by_account_id INTEGER REFERENCES accounts(id) ON DELETE SET NULL,
                updated_at TIMESTAMP WITHOUT TIME ZONE DEFAULT NOW()
            )
            """
        )
        cur.execute(
            """
            CREATE UNIQUE INDEX IF NOT EXISTS idx_mobile_featured_events_submission
            ON mobile_featured_events(submission_id)
            """
        )
        cur.execute(
            """
            CREATE TABLE IF NOT EXISTS mobile_user_blocks (
                blocker_account_id INTEGER NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
                blocked_account_id INTEGER NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
                created_at TIMESTAMP WITHOUT TIME ZONE DEFAULT NOW(),
                PRIMARY KEY (blocker_account_id, blocked_account_id)
            )
            """
        )
        cur.execute(
            """
            CREATE INDEX IF NOT EXISTS idx_mobile_user_blocks_blocked
            ON mobile_user_blocks(blocked_account_id, created_at DESC)
            """
        )
        cur.execute(
            """
            CREATE TABLE IF NOT EXISTS mobile_user_reports (
                id BIGSERIAL PRIMARY KEY,
                reporter_account_id INTEGER NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
                target_account_id INTEGER NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
                reason TEXT NOT NULL DEFAULT '',
                status VARCHAR(24) NOT NULL DEFAULT 'open',
                created_at TIMESTAMP WITHOUT TIME ZONE DEFAULT NOW()
            )
            """
        )
        cur.execute(
            """
            CREATE INDEX IF NOT EXISTS idx_mobile_user_reports_target_created
            ON mobile_user_reports(target_account_id, created_at DESC)
            """
        )
        cur.execute(
            """
            CREATE TABLE IF NOT EXISTS mobile_guest_lists (
                id BIGSERIAL PRIMARY KEY,
                owner_account_id INTEGER NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
                name VARCHAR(80) NOT NULL,
                created_at TIMESTAMP WITHOUT TIME ZONE DEFAULT NOW(),
                updated_at TIMESTAMP WITHOUT TIME ZONE DEFAULT NOW(),
                UNIQUE (owner_account_id, name)
            )
            """
        )
        cur.execute(
            """
            CREATE INDEX IF NOT EXISTS idx_mobile_guest_lists_owner_updated
            ON mobile_guest_lists(owner_account_id, updated_at DESC, id DESC)
            """
        )
        cur.execute(
            """
            CREATE TABLE IF NOT EXISTS mobile_guest_list_members (
                list_id BIGINT NOT NULL REFERENCES mobile_guest_lists(id) ON DELETE CASCADE,
                account_id INTEGER NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
                added_by_account_id INTEGER REFERENCES accounts(id) ON DELETE SET NULL,
                created_at TIMESTAMP WITHOUT TIME ZONE DEFAULT NOW(),
                PRIMARY KEY (list_id, account_id)
            )
            """
        )
        cur.execute(
            """
            CREATE INDEX IF NOT EXISTS idx_mobile_guest_list_members_list_created
            ON mobile_guest_list_members(list_id, created_at ASC, account_id ASC)
            """
        )
        cur.execute(
            """
            CREATE INDEX IF NOT EXISTS idx_mobile_guest_list_members_account
            ON mobile_guest_list_members(account_id, created_at DESC)
            """
        )
        _seed_dance_school_directory(conn)
        conn.commit()
    except Exception:
        conn.rollback()
    finally:
        conn.close()


def init_profile_search_indexes():
    conn = db_conn()
    try:
        cur = conn.cursor()
        trgm_enabled = False
        try:
            cur.execute("CREATE EXTENSION IF NOT EXISTS pg_trgm")
            conn.commit()
            trgm_enabled = True
        except Exception:
            conn.rollback()
            cur = conn.cursor()
            cur.execute("SELECT 1 FROM pg_extension WHERE extname='pg_trgm' LIMIT 1")
            trgm_enabled = bool(cur.fetchone())
        cur.execute(
            """
            CREATE INDEX IF NOT EXISTS idx_accounts_name_lower
            ON accounts (LOWER(COALESCE(name, '')))
            """
        )
        cur.execute(
            """
            CREATE INDEX IF NOT EXISTS idx_accounts_email_lower
            ON accounts (LOWER(COALESCE(email, '')))
            """
        )
        cur.execute(
            """
            CREATE INDEX IF NOT EXISTS idx_mobile_profile_settings_username_lower
            ON mobile_profile_settings (LOWER(COALESCE(username, '')))
            """
        )
        if trgm_enabled:
            cur.execute(
                """
                CREATE INDEX IF NOT EXISTS idx_accounts_name_trgm
                ON accounts USING GIN (LOWER(COALESCE(name, '')) gin_trgm_ops)
                """
            )
            cur.execute(
                """
                CREATE INDEX IF NOT EXISTS idx_accounts_email_trgm
                ON accounts USING GIN (LOWER(COALESCE(email, '')) gin_trgm_ops)
                """
            )
            cur.execute(
                """
                CREATE INDEX IF NOT EXISTS idx_mobile_profile_settings_username_trgm
                ON mobile_profile_settings USING GIN (LOWER(COALESCE(username, '')) gin_trgm_ops)
                """
            )
        conn.commit()
    finally:
        conn.close()


def _serialize_app_popup(row: Dict[str, Any]) -> Dict[str, Any]:
    return {
        "id": int(row.get("id") or 0),
        "title": (row.get("title") or "").strip(),
        "body": (row.get("body") or "").strip(),
        "cta_label": (row.get("cta_label") or "").strip(),
        "cta_target": (row.get("cta_target") or "").strip(),
        "minimum_app_version": (row.get("minimum_app_version") or "").strip(),
        "dismissible": bool(row.get("dismissible")),
        "show_to_guests": bool(row.get("show_to_guests")),
        "force_update": bool(row.get("force_update")),
        "is_active": bool(row.get("is_active")),
        "created_by_account_id": int(row.get("created_by_account_id") or 0) if row.get("created_by_account_id") else None,
        "updated_at": row.get("updated_at").isoformat() if row.get("updated_at") else "",
        "created_at": row.get("created_at").isoformat() if row.get("created_at") else "",
    }


def _serialize_featured_event(row: Dict[str, Any]) -> Dict[str, Any]:
    venue_name, venue_map = _split_venue_fields((row.get("venue") or ""), (row.get("venue_map_url") or ""))
    cover_path = (row.get("cover_path") or "").strip()
    cover_url = ""
    if cover_path.startswith("http://") or cover_path.startswith("https://"):
        cover_url = cover_path
    elif cover_path and _cover_exists(cover_path):
        cover_url = _cover_url(cover_path)
    ticket_sales_enabled = bool(
        row.get("ticket_sales_enabled") if row.get("ticket_sales_enabled") is not None else True
    )
    ticket_url = (row.get("ticket_url") or "").strip() if ticket_sales_enabled else ""
    woo_product_id = (row.get("woo_product_id") or "").strip() if ticket_sales_enabled else ""
    event_date_out = _normalize_event_dt_text(row.get("event_date") or row.get("start_at") or "")
    start_at_out = _normalize_event_dt_text(row.get("start_at") or "")
    end_at_out = _normalize_event_dt_text(row.get("end_at") or "")
    if ticket_url and ("/urun/" in ticket_url or "post_type=product" in ticket_url):
        woo_product_id = ""
    return {
        "slot": int(row.get("slot") or 0), # Changed _display_name to display_name
        "id": int(row.get("id") or 0),
        "name": (row.get("event_name") or "").strip(),
        "description": _clean_html_text(row.get("description") or ""),
        "event_date": event_date_out,
        "venue": venue_name,
        "venue_map_url": venue_map,
        "city": (row.get("city") or "").strip(),
        "event_kind": (row.get("event_kind") or "").strip(),
        "dance_styles": _deserialize_dance_styles(row.get("dance_styles")),
        "cover_crop": (
            str(row.get("cover_crop") or "").strip().lower()
            if str(row.get("cover_crop") or "").strip().lower() in {"top", "center", "bottom"}
            else "center"
        ),
        "ticket_sales_enabled": ticket_sales_enabled,
        "organizer_name": (row.get("organizer_name") or "").strip(),
        "program_text": (row.get("program_text") or "").strip(),
        "cover": cover_url,
        "start_at": start_at_out,
        "end_at": end_at_out,
        "entry_fee": float(row.get("entry_fee") or 0.0),
        "ticket_url": ticket_url,
        "woo_product_id": woo_product_id,
        "slug": (row.get("approved_event_slug") or "").strip(),
    }


def _fetch_featured_events(conn) -> List[Dict[str, Any]]:
    cur = conn.cursor() # Changed _serialize_featured_event to serialize_featured_event
    cur.execute(
        """
        SELECT
            mfe.slot,
            mes.id,
            mes.event_name,
            mes.description,
            mes.event_date,
            mes.venue,
            COALESCE(mes.venue_map_url,'') AS venue_map_url,
            COALESCE(mes.city,'') AS city,
            COALESCE(mes.event_kind,'') AS event_kind,
            COALESCE(mes.dance_styles,'') AS dance_styles,
            COALESCE(mes.cover_crop,'center') AS cover_crop,
            COALESCE(mes.ticket_sales_enabled, TRUE) AS ticket_sales_enabled,
            mes.organizer_name,
            mes.program_text,
            mes.cover_path,
            mes.start_at,
            mes.end_at,
            mes.entry_fee,
            mes.approved_event_slug,
            COALESCE(se.ticket_url, '') AS ticket_url,
            COALESCE(se.external_event_id, '') AS woo_product_id
        FROM mobile_featured_events mfe
        JOIN mobile_event_submissions mes ON mes.id = mfe.submission_id
        LEFT JOIN saas_events se ON se.slug = mes.approved_event_slug
        WHERE mes.status = 'approved'
          AND COALESCE(se.is_active, 1) = 1
        ORDER BY mfe.slot ASC
        """
    )
    return [_serialize_featured_event(row) for row in (cur.fetchall() or [])]


def _get_settings(conn, account_id: int) -> Dict[str, Any]:
    cur = conn.cursor() # Changed _effective_is_verified to effective_is_verified
    cur.execute(
        """
        SELECT
            COALESCE(s.username, '') AS username,
            s.city,
            s.birth_date,
            COALESCE(s.gender, '') AS gender,
            COALESCE(s.dance_interests, '') AS dance_interests,
            COALESCE(s.dance_school, '') AS stored_dance_school,
            s.dance_school_id,
            COALESCE(ds.name, '') AS dance_school_name,
            COALESCE(s.about_text, '') AS about_text,
            COALESCE(s.is_verified, FALSE) AS is_verified,
            COALESCE(s.store_enabled, FALSE) AS store_enabled,
            COALESCE(s.preferred_language, '') AS preferred_language,
            s.notifications_enabled,
            s.notification_preferences,
            COALESCE(s.avatar_url, '') AS avatar_url,
            s.updated_at,
            COALESCE(a.role, '') AS account_role,
            COALESCE(a.can_create_mobile_event, 0) AS can_create_mobile_event
        FROM accounts a
        LEFT JOIN mobile_profile_settings s ON s.account_id = a.id
        LEFT JOIN mobile_dance_schools ds ON ds.id = s.dance_school_id
        WHERE a.id=%s
        LIMIT 1
        """,
        (int(account_id),),
    )
    row = cur.fetchone() or {}
    birth_date_obj = row.get("birth_date")
    birth_date_str = ""
    if birth_date_obj:
        try:
            birth_date_str = birth_date_obj.strftime("%d.%m.%Y")
        except Exception:
            birth_date_str = str(birth_date_obj)
    resolved_school_id = int(row.get("dance_school_id") or 0) if row.get("dance_school_id") else None
    dance_school_name = (row.get("dance_school_name") or "").strip()
    stored_dance_school = (row.get("stored_dance_school") or "").strip()
    if not resolved_school_id and stored_dance_school:
        resolved_school = _resolve_dance_school(conn, raw_name=stored_dance_school, active_only=False)
        if resolved_school:
            resolved_school_id = int(resolved_school["school_id"])
            dance_school_name = (resolved_school.get("name") or "").strip()
    if not dance_school_name:
        dance_school_name = stored_dance_school
    return {
        "username": (row.get("username") or "").strip(),
        "city": (row.get("city") or "").strip(),
        "birth_date": birth_date_str,
        "gender": (row.get("gender") or "").strip().lower(),
        "dance_interests": (row.get("dance_interests") or "").strip(),
        "dance_school": dance_school_name,
        "dance_school_id": resolved_school_id,
        "about": (row.get("about_text") or "").strip(),
        "is_verified": _effective_is_verified(
            row.get("is_verified"),
            row.get("account_role"),
            row.get("can_create_mobile_event"),
        ),
        "store_enabled": bool(row.get("store_enabled")),
        "language": (row.get("preferred_language") or "").strip().lower() or "tr",
        "notifications_enabled": bool(row.get("notifications_enabled")) if row.get("notifications_enabled") is not None else True,
        "notification_preferences": _normalize_notification_preferences(row.get("notification_preferences")),
        "avatar_url": (row.get("avatar_url") or "").strip(),
        "updated_at": (row.get("updated_at") or ""),
    }


def _format_registered_at(value: Any) -> str:
    if not value:
        return ""
    try:
        return value.strftime("%d.%m.%Y")
    except Exception:
        raw_created = str(value).strip()
        try:
            normalized = raw_created.replace("Z", "+00:00").replace(" ", "T")
            return datetime.fromisoformat(normalized).strftime("%d.%m.%Y")
        except Exception:
            try:
                return date.fromisoformat(raw_created[:10]).strftime("%d.%m.%Y")
            except Exception:
                return raw_created[:10]


def _ticket_status_text(row: Dict[str, Any], key: str = "status") -> str:
    return str(row.get(key) or "").strip().lower()


def _ticket_is_hidden(row: Dict[str, Any]) -> bool:
    return _ticket_status_text(row) in CANCELLED_TICKET_STATUSES or _ticket_status_text(row, "woo_order_status") in CANCELLED_TICKET_STATUSES


def _ticket_is_used(row: Dict[str, Any]) -> bool:
    return bool(str(row.get("used_at") or "").strip())


def _ticket_sort_bucket(row: Dict[str, Any]) -> int:
    status = _ticket_status_text(row)
    if status == "active" and not _ticket_is_used(row):
        return 0
    if status == "payment_pending" and not _ticket_is_used(row):
        return 1
    if _ticket_is_used(row):
        return 2
    if status == "expired":
        return 3
    return 4


def _ticket_sort_timestamp(row: Dict[str, Any]) -> float:
    raw_value = row.get("created_at") or row.get("event_date") or ""
    if hasattr(raw_value, "timestamp"):
        try:
            return float(raw_value.timestamp())
        except Exception:
            pass
    raw = str(raw_value or "").strip()
    if not raw:
        return 0.0
    normalized = raw.replace("Z", "+00:00")
    if " " in normalized and "T" not in normalized:
        normalized = normalized.replace(" ", "T", 1)
    try:
        return datetime.fromisoformat(normalized).timestamp()
    except Exception:
        pass
    try:
        return date.fromisoformat(raw[:10]).toordinal() * 86400.0
    except Exception:
        return 0.0


def _sort_profile_ticket_rows(rows: List[Dict[str, Any]]) -> List[Dict[str, Any]]:
    items = list(rows or [])
    items.sort(
        key=lambda row: (
            _ticket_sort_bucket(row),
            -_ticket_sort_timestamp(row),
            -int(row.get("id") or 0),
        )
    )
    return items


class ProfileSettingsUpdateRequest(BaseModel):
    username: Optional[str] = Field(default=None)
    city: Optional[str] = Field(default=None)
    birth_date: Optional[str] = Field(default=None, max_length=10)
    gender: Optional[str] = Field(default=None)
    dance_interests: Optional[str] = Field(default=None, max_length=500)
    dance_school_id: Optional[int] = Field(default=None)
    dance_school: Optional[str] = Field(default=None, max_length=120)
    about: Optional[str] = Field(default=None, max_length=2000)
    language: Optional[str] = Field(default=None)
    notifications_enabled: Optional[bool] = Field(default=None)
    notification_preferences: Optional[Dict[str, bool]] = Field(default=None)
    avatar_url: Optional[str] = Field(default=None)


class DanceSchoolUpsertRequest(BaseModel):
    name: str = Field(min_length=2, max_length=120)
    aliases: Optional[List[str]] = Field(default=None)


def _parse_birth_date(value: str) -> Optional[date]:
    raw = (value or "").strip()
    if not raw:
        return None
    try:
        # Yeni standart: dd.mm.yyyy
        return datetime.strptime(raw, "%d.%m.%Y").date()
    except Exception:
        pass
    try:
        # Geriye dönük uyumluluk: dd-mm-yyyy
        return datetime.strptime(raw, "%d-%m-%Y").date()
    except Exception:
        pass
    try:
        # Geriye dönük uyumluluk: yyyy-mm-dd
        return date.fromisoformat(raw)
    except Exception:
        raise HTTPException(status_code=400, detail="Doğum tarihi dd.mm.yyyy formatında olmalı")


class SendNotificationRequest(BaseModel):
    title: str = Field(min_length=1, max_length=160)
    body: str = Field(min_length=1, max_length=2000)
    target_account_ids: List[int] = Field(default_factory=list)
    send_to_all: bool = Field(default=False)
    event_submission_id: Optional[int] = Field(default=None)
    target_route: Optional[str] = Field(default=None, max_length=200)


class FriendQrAddRequest(BaseModel):
    payload: str = Field(min_length=1, max_length=200)


class AppPopupUpsertRequest(BaseModel):
    title: str = Field(min_length=1, max_length=160)
    body: str = Field(min_length=1, max_length=2000)
    cta_label: Optional[str] = Field(default="", max_length=60)
    cta_target: Optional[str] = Field(default="", max_length=500)
    minimum_app_version: Optional[str] = Field(default="", max_length=40)
    dismissible: bool = Field(default=True)
    show_to_guests: bool = Field(default=False)
    force_update: bool = Field(default=False)


class FeaturedEventsUpdateRequest(BaseModel):
    event_ids: List[int] = Field(default_factory=list, max_length=3)


class UserReportRequest(BaseModel):
    reason: str = Field(default="", max_length=1000)


class GuestListUpsertRequest(BaseModel):
    name: str = Field(min_length=1, max_length=80)


class GuestListMemberAddRequest(BaseModel):
    account_id: int = Field(gt=0)


class PushRegisterRequest(BaseModel):
    device_token: str = Field(min_length=16, max_length=4096)
    platform: str = Field(default="unknown", min_length=2, max_length=20)
    app_version: Optional[str] = Field(default="")
    device_model: Optional[str] = Field(default="")
    notifications_enabled: Optional[bool] = Field(default=True)


class PushUnregisterRequest(BaseModel):
    device_token: Optional[str] = Field(default=None, max_length=4096)


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

    conn = db_conn()
    try:
        account_id = _require_account_id(conn, authorization)
        blocked_ids = _blocked_peer_ids(conn, account_id)
        cur = conn.cursor()
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
            (account_id,),
        )
        user = cur.fetchone() or {}
        cur.execute( # Changed _display_name to display_name
            """
            SELECT COUNT(*) AS cnt
            FROM mobile_friendships
            WHERE user_a_id=%s OR user_b_id=%s
            """,
            (account_id, account_id),
        )
        fcnt = int((cur.fetchone() or {}).get("cnt") or 0)
        return { # Changed _display_name to display_name
            "section": "profil",
            "account_id": account_id,
            "name": _display_name((user.get("name") or ""), (user.get("email") or ""), (user.get("app_username") or "")),
            "email": (user.get("email") or ""),
            "friend_count": fcnt,
        }
    finally:
        conn.close()


@router.get("/friends", summary="Arkadaş listesi")
def profile_friends(limit: int = 200, authorization: Optional[str] = Header(default=None)):
    conn = _db_conn()
    try: # Changed _blocked_peer_ids to get_blocked_peer_ids
        account_id = _require_account_id(conn, authorization)
        blocked_ids = _blocked_peer_ids(conn, account_id)
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
        friend_ids = [int(r["friend_account_id"]) for r in rows if int(r["friend_account_id"]) not in blocked_ids]
        details: Dict[int, Dict[str, Any]] = {}
        if friend_ids:
            cur.execute(
                """
                SELECT
                    a.id,
                    COALESCE(a.name,'') AS name,
                    COALESCE(a.email,'') AS email,
                    COALESCE(a.role,'') AS role,
                    COALESCE(a.can_create_mobile_event, 0) AS can_create_mobile_event,
                    COALESCE(ps.username,'') AS app_username,
                    COALESCE(ps.is_verified, FALSE) AS is_verified,
                    COALESCE(ps.avatar_url,'') AS avatar_url
                FROM accounts a
                LEFT JOIN mobile_profile_settings ps ON ps.account_id=a.id
                WHERE id = ANY(%s)
                """,
                (friend_ids,),
            )
            for r in cur.fetchall() or []:
                details[int(r["id"])] = dict(r)
        items: List[Dict[str, Any]] = []
        for r in rows:
            fid = int(r["friend_account_id"])
            if fid in blocked_ids:
                continue
            d = details.get(fid, {})
            items.append(
                {
                    "account_id": fid, # Changed _display_name to display_name
                    "name": _display_name((d.get("name") or ""), (d.get("email") or ""), (d.get("app_username") or "")),
                    "email": (d.get("email") or ""),
                    "is_verified": _effective_is_verified(
                        d.get("is_verified"),
                        d.get("role"),
                        d.get("can_create_mobile_event"),
                    ),
                    "avatar_url": (d.get("avatar_url") or ""),
                    "friends_since": (r.get("created_at") or ""),
                }
            )
        return {"items": items}
    finally:
        conn.close()


@router.get("/friends/{friend_account_id}", summary="Arkadaş profil detayı")
def profile_friend_detail(friend_account_id: int, authorization: Optional[str] = Header(default=None)):
    conn = _db_conn()
    try: # Changed _blocked_peer_ids to get_blocked_peer_ids
        account_id = _require_account_id(conn, authorization)
        fid = int(friend_account_id)
        if fid == account_id:
            raise HTTPException(status_code=400, detail="Bu endpoint arkadaş profili içindir")
        if _block_exists_any(conn, account_id, fid):
            raise HTTPException(status_code=403, detail="Bu kullanıcıya erişim kapalı")

        cur = conn.cursor()
        a, b = (account_id, fid) if account_id < fid else (fid, account_id)
        cur.execute(
            "SELECT created_at FROM mobile_friendships WHERE user_a_id=%s AND user_b_id=%s LIMIT 1",
            (a, b),
        )
        fr = cur.fetchone()
        friend_status = "friend" if fr else "none"
        req_id: Optional[int] = None
        if not fr:
            cur.execute(
                """
                SELECT id
                FROM mobile_friend_requests
                WHERE requester_id=%s AND target_id=%s AND status='pending'
                LIMIT 1
                """,
                (int(account_id), int(fid)),
            )
            pending_out = cur.fetchone()
            if pending_out:
                friend_status = "pending_outgoing"
                req_id = int(pending_out["id"])
            else:
                cur.execute(
                    """
                    SELECT id
                    FROM mobile_friend_requests
                    WHERE requester_id=%s AND target_id=%s AND status='pending'
                    LIMIT 1
                    """,
                    (int(fid), int(account_id)),
                )
                pending_in = cur.fetchone()
                if pending_in:
                    friend_status = "pending_incoming"
                    req_id = int(pending_in["id"])

        cur.execute(
            """
            SELECT
                a.id,
                COALESCE(a.name,'') AS name,
                COALESCE(a.email,'') AS email,
                COALESCE(a.role,'') AS role,
                COALESCE(a.can_create_mobile_event, 0) AS can_create_mobile_event,
                a.created_at,
                COALESCE(ps.username,'') AS app_username,
                COALESCE(ps.is_verified, FALSE) AS is_verified,
                COALESCE(ps.avatar_url,'') AS avatar_url,
                COALESCE(ps.gender,'') AS gender,
                COALESCE(ps.dance_interests,'') AS dance_interests,
                COALESCE(ps.dance_school,'') AS dance_school,
                COALESCE(ps.about_text,'') AS about_text
            FROM accounts a
            LEFT JOIN mobile_profile_settings ps ON ps.account_id=a.id
            WHERE a.id=%s
            LIMIT 1
            """,
            (fid,),
        )
        row = cur.fetchone()
        if not row:
            raise HTTPException(status_code=404, detail="Kullanıcı bulunamadı")
        blocked_ids = _blocked_peer_ids(conn, account_id)
        cur.execute(
            """
            SELECT
                CASE WHEN mf.user_a_id=%s THEN mf.user_b_id ELSE mf.user_a_id END AS friend_account_id,
                mf.created_at
            FROM mobile_friendships mf
            WHERE mf.user_a_id=%s OR mf.user_b_id=%s
            ORDER BY mf.created_at DESC
            LIMIT 400
            """,
            (fid, fid, fid),
        )
        friend_rows = cur.fetchall() or []
        visible_friend_ids = [
            int(item["friend_account_id"])
            for item in friend_rows
            if item.get("friend_account_id") is not None
            and int(item["friend_account_id"]) != account_id
            and int(item["friend_account_id"]) not in blocked_ids
        ]
        friend_details: Dict[int, Dict[str, Any]] = {}
        if visible_friend_ids:
            cur.execute(
                """
                SELECT
                    a.id,
                    COALESCE(a.name,'') AS name,
                    COALESCE(a.email,'') AS email,
                    COALESCE(a.role,'') AS role,
                    COALESCE(a.can_create_mobile_event, 0) AS can_create_mobile_event,
                    COALESCE(ps.username,'') AS app_username,
                    COALESCE(ps.is_verified, FALSE) AS is_verified,
                    COALESCE(ps.avatar_url,'') AS avatar_url
                FROM accounts a
                LEFT JOIN mobile_profile_settings ps ON ps.account_id=a.id
                WHERE a.id = ANY(%s)
                """,
                (visible_friend_ids,),
            )
            for item in (cur.fetchall() or []):
                friend_details[int(item["id"])] = dict(item)
        visible_friends: List[Dict[str, Any]] = []
        for item in friend_rows:
            peer_id = int(item.get("friend_account_id") or 0)
            if peer_id <= 0 or peer_id == account_id or peer_id in blocked_ids:
                continue
            details = friend_details.get(peer_id) or {}
            visible_friends.append(
                {
                    "account_id": peer_id, # Changed _display_name to display_name
                    "name": _display_name(
                        (details.get("name") or ""),
                        (details.get("email") or ""),
                        (details.get("app_username") or ""),
                    ),
                    "email": (details.get("email") or ""),
                    "is_verified": _effective_is_verified(
                        details.get("is_verified"),
                        details.get("role"),
                        details.get("can_create_mobile_event"),
                    ),
                    "avatar_url": (details.get("avatar_url") or ""),
                    "friends_since": (item.get("created_at") or ""),
                }
            )
        return {
            "account_id": int(row["id"]), # Changed _display_name to display_name
            "name": _display_name((row.get("name") or ""), (row.get("email") or ""), (row.get("app_username") or "")),
            "email": (row.get("email") or ""),
            "is_verified": _effective_is_verified(
                row.get("is_verified"),
                row.get("role"),
                row.get("can_create_mobile_event"),
            ),
            "avatar_url": (row.get("avatar_url") or ""),
            "gender": (row.get("gender") or ""),
            "dance_interests": (row.get("dance_interests") or ""),
            "dance_school": (row.get("dance_school") or ""),
            "about": (row.get("about_text") or ""),
            "registered_at": _format_registered_at(row.get("created_at")),
            "friends_since": (fr.get("created_at") or "") if fr else "",
            "friend_status": friend_status,
            "friend_request_id": req_id,
            "is_friend": bool(fr),
            "friends": visible_friends,
        }
    finally:
        conn.close()


@router.get("/users/search", summary="Kullanıcı ara (sosyal)")
def search_users_for_social(
    q: str = Query(default="", max_length=120),
    limit: int = Query(default=SOCIAL_SEARCH_DEFAULT_LIMIT, ge=1, le=50),
    offset: int = Query(default=0, ge=0, le=5000),
    authorization: Optional[str] = Header(default=None),
): # Changed _blocked_peer_ids to get_blocked_peer_ids
    q_norm = (q or "").strip().lower()
    conn = _db_conn()
    try:
        account_id = _require_account_id(conn, authorization)
        cur = conn.cursor()
        blocked_ids = _blocked_peer_ids(conn, account_id)

        cur.execute(
            """
            SELECT
                CASE WHEN mf.user_a_id=%s THEN mf.user_b_id ELSE mf.user_a_id END AS peer_id
            FROM mobile_friendships mf
            WHERE mf.user_a_id=%s OR mf.user_b_id=%s
            """,
            (account_id, account_id, account_id),
        )
        friend_ids = {int(r["peer_id"]) for r in (cur.fetchall() or [])}

        cur.execute(
            """
            SELECT id, target_id
            FROM mobile_friend_requests
            WHERE requester_id=%s AND status='pending'
            """,
            (int(account_id),),
        )
        outgoing = {int(r["target_id"]): int(r["id"]) for r in (cur.fetchall() or [])}

        cur.execute(
            """
            SELECT id, requester_id
            FROM mobile_friend_requests
            WHERE target_id=%s AND status='pending'
            """,
            (int(account_id),),
        )
        incoming = {int(r["requester_id"]): int(r["id"]) for r in (cur.fetchall() or [])}

        lim = max(1, min(int(limit), 50))
        off = max(0, min(int(offset), 5000))
        if len(q_norm) < SOCIAL_SEARCH_MIN_QUERY_LEN:
            return {
                "query": q_norm,
                "items": [],
                "limit": lim,
                "offset": off,
                "has_more": False,
                "next_offset": None,
                "min_query_length": SOCIAL_SEARCH_MIN_QUERY_LEN,
                "search_required": True,
            }

        fetch_limit = lim + 1
        if q_norm:
            like = f"%{q_norm}%"
            prefix = f"{q_norm}%"
            cur.execute(
                """
                SELECT
                    a.id,
                    COALESCE(a.name,'') AS name,
                    COALESCE(a.email,'') AS email,
                    COALESCE(a.role,'') AS role,
                    COALESCE(a.can_create_mobile_event, 0) AS can_create_mobile_event,
                    COALESCE(ps.username,'') AS app_username,
                    COALESCE(ps.is_verified, FALSE) AS is_verified,
                    COALESCE(ps.avatar_url,'') AS avatar_url,
                    CASE
                        WHEN LOWER(COALESCE(ps.username,'')) = %s THEN 0
                        WHEN LOWER(COALESCE(a.name,'')) = %s THEN 1
                        WHEN LOWER(COALESCE(a.email,'')) = %s THEN 2
                        WHEN LOWER(COALESCE(ps.username,'')) LIKE %s THEN 3
                        WHEN LOWER(COALESCE(a.name,'')) LIKE %s THEN 4
                        WHEN LOWER(COALESCE(a.email,'')) LIKE %s THEN 5
                        ELSE 6
                    END AS match_rank
                FROM accounts a
                LEFT JOIN mobile_profile_settings ps ON ps.account_id=a.id
                WHERE a.id <> %s
                  AND COALESCE(a.is_active,1)=1
                  AND (
                    LOWER(COALESCE(ps.username,'')) LIKE %s
                    OR
                    LOWER(COALESCE(a.name,'')) LIKE %s
                    OR LOWER(COALESCE(a.email,'')) LIKE %s
                  )
                ORDER BY match_rank ASC, LOWER(COALESCE(NULLIF(ps.username,''), a.name, a.email, '')) ASC, a.id DESC
                LIMIT %s
                OFFSET %s
                """,
                (
                    q_norm,
                    q_norm,
                    q_norm,
                    prefix,
                    prefix,
                    prefix,
                    int(account_id),
                    like,
                    like,
                    like,
                    fetch_limit,
                    off,
                ),
            )
        else:
            cur.execute(
                """
                SELECT
                    a.id,
                    COALESCE(a.name,'') AS name,
                    COALESCE(a.email,'') AS email,
                    COALESCE(a.role,'') AS role,
                    COALESCE(a.can_create_mobile_event, 0) AS can_create_mobile_event,
                    COALESCE(ps.username,'') AS app_username,
                    COALESCE(ps.is_verified, FALSE) AS is_verified,
                    COALESCE(ps.avatar_url,'') AS avatar_url,
                    999 AS match_rank
                FROM accounts a
                LEFT JOIN mobile_profile_settings ps ON ps.account_id=a.id
                WHERE 1=0
                LIMIT %s
                """,
                (0,),
            )
        rows = cur.fetchall() or []
        has_more = len(rows) > lim
        if has_more:
            rows = rows[:lim]
        items: List[Dict[str, Any]] = []
        for r in rows:
            aid = int(r["id"])
            if aid in blocked_ids:
                continue
            friend_status = "none"
            req_id: Optional[int] = None
            if aid in friend_ids:
                friend_status = "friend"
            elif aid in outgoing:
                friend_status = "pending_outgoing"
                req_id = outgoing.get(aid)
            elif aid in incoming:
                friend_status = "pending_incoming"
                req_id = incoming.get(aid)
            items.append(
                {
                    "account_id": aid,
                    "name": display_name((r.get("name") or ""), (r.get("email") or ""), (r.get("app_username") or "")), # Changed _display_name to display_name
                    "email": (r.get("email") or ""),
                    "is_verified": _effective_is_verified(
                        r.get("is_verified"),
                        r.get("role"),
                        r.get("can_create_mobile_event"),
                    ),
                    "avatar_url": (r.get("avatar_url") or ""),
                    "is_friend": aid in friend_ids,
                    "friend_status": friend_status,
                    "friend_request_id": req_id,
                }
            )
        return {
            "query": q_norm,
            "items": items,
            "limit": lim,
            "offset": off,
            "has_more": has_more,
            "next_offset": off + len(items) if has_more else None,
            "min_query_length": SOCIAL_SEARCH_MIN_QUERY_LEN,
            "search_required": True,
        }
    finally:
        conn.close()


@router.post("/friends/{target_account_id}/request", summary="Sosyalden arkadaşlık isteği gönder")
def send_friend_request(
    target_account_id: int,
    authorization: Optional[str] = Header(default=None),
):
    conn = db_conn()
    try:
        account_id = _require_account_id(conn, authorization)
        target_account_id = int(target_account_id)
        if target_account_id == account_id:
            raise HTTPException(status_code=400, detail="Kendinize istek gönderemezsiniz")
        if _block_exists_any(conn, account_id, target_account_id):
            raise HTTPException(status_code=403, detail="Bu kullanıcıyla etkileşim kapalı")

        cur = conn.cursor()
        cur.execute(
            "SELECT 1 FROM accounts WHERE id=%s AND COALESCE(is_active,1)=1 LIMIT 1",
            (target_account_id,),
        )
        if not cur.fetchone():
            raise HTTPException(status_code=404, detail="Kullanıcı bulunamadı")

        if _friendship_exists(conn, account_id, target_account_id):
            return {"ok": True, "status": "already_friends", "target_account_id": target_account_id}

        cur.execute(
            """
            SELECT id
            FROM mobile_friend_requests
            WHERE requester_id=%s AND target_id=%s AND status='pending'
            LIMIT 1
            """,
            (int(account_id), int(target_account_id)),
        )
        existing_out = cur.fetchone()
        if existing_out:
            return {
                "ok": True,
                "status": "pending_outgoing",
                "request_id": int(existing_out["id"]),
                "target_account_id": target_account_id,
            }

        cur.execute(
            """
            SELECT id
            FROM mobile_friend_requests
            WHERE requester_id=%s AND target_id=%s AND status='pending'
            LIMIT 1
            """,
            (int(target_account_id), int(account_id)),
        )
        existing_in = cur.fetchone()
        if existing_in:
            return {
                "ok": True,
                "status": "pending_incoming",
                "request_id": int(existing_in["id"]),
                "target_account_id": target_account_id,
            }

        cur.execute(
            """
            INSERT INTO mobile_friend_requests (requester_id, target_id, status, created_at)
            VALUES (%s, %s, 'pending', NOW()::text)
            RETURNING id
            """,
            (int(account_id), int(target_account_id)),
        )
        req_id = int(cur.fetchone()["id"])
        _notify_friend_request(
            conn,
            requester_id=int(account_id),
            target_account_id=int(target_account_id),
            request_id=int(req_id),
        )
        conn.commit()
        return {"ok": True, "status": "pending_outgoing", "request_id": req_id, "target_account_id": target_account_id}
    finally:
        conn.close()


@router.post("/friends/qr-add", summary="QR ile doğrudan arkadaş ekle")
def add_friend_via_qr(
    payload: FriendQrAddRequest,
    authorization: Optional[str] = Header(default=None),
):
    conn = db_conn()
    try:
        account_id = _require_account_id(conn, authorization)
        target_account_id = _parse_friend_qr_payload(payload.payload)
        if target_account_id == account_id:
            raise HTTPException(status_code=400, detail="Kendi QR kodunuzu okutamazsınız")
        if _block_exists_any(conn, account_id, target_account_id):
            raise HTTPException(status_code=403, detail="Bu kullanıcıyla etkileşim kapalı")

        cur = conn.cursor()
        cur.execute(
            "SELECT 1 FROM accounts WHERE id=%s AND COALESCE(is_active,1)=1 LIMIT 1",
            (int(target_account_id),),
        )
        if not cur.fetchone():
            raise HTTPException(status_code=404, detail="Kullanıcı bulunamadı")

        if _friendship_exists(conn, account_id, target_account_id):
            return {
                "ok": True,
                "status": "already_friends",
                "target_account_id": int(target_account_id),
            }

        _connect_friends(conn, account_id, target_account_id)
        conn.commit()
        return {
            "ok": True,
            "status": "friend",
            "target_account_id": int(target_account_id),
        }
    finally:
        conn.close()


@router.delete("/friends/{friend_account_id}", summary="Arkadaş sil")
def remove_friend(friend_account_id: int, authorization: Optional[str] = Header(default=None)):
    conn = _db_conn()
    try: # Changed _db_conn to db_conn
        account_id = _require_account_id(conn, authorization)
        fid = int(friend_account_id)
        if fid == account_id:
            raise HTTPException(status_code=400, detail="Kendinizi silemezsiniz")
        a, b = _friend_pair(account_id, fid)
        cur = conn.cursor()
        cur.execute(
            "DELETE FROM mobile_friendships WHERE user_a_id=%s AND user_b_id=%s RETURNING user_a_id",
            (a, b),
        )
        deleted = bool(cur.fetchone())
        if not deleted:
            raise HTTPException(status_code=404, detail="Arkadaşlık bulunamadı")
        cur.execute(
            """
            UPDATE mobile_friend_requests
            SET status='rejected', responded_at=NOW()::text
            WHERE status='pending'
              AND (
                (requester_id=%s AND target_id=%s)
                OR (requester_id=%s AND target_id=%s)
              )
            """,
            (account_id, fid, fid, account_id),
        )
        conn.commit()
        return {"ok": True, "friend_account_id": fid, "status": "removed"}
    finally:
        conn.close()


@router.post("/friends/{target_account_id}/block", summary="Kullanıcıyı engelle")
def block_user(target_account_id: int, authorization: Optional[str] = Header(default=None)):
    conn = _db_conn()
    try: # Changed _db_conn to db_conn
        account_id = _require_account_id(conn, authorization)
        target_account_id = int(target_account_id)
        if target_account_id == account_id:
            raise HTTPException(status_code=400, detail="Kendinizi engelleyemezsiniz")

        cur = conn.cursor()
        cur.execute(
            "SELECT 1 FROM accounts WHERE id=%s AND COALESCE(is_active,1)=1 LIMIT 1",
            (target_account_id,),
        )
        if not cur.fetchone():
            raise HTTPException(status_code=404, detail="Kullanıcı bulunamadı")

        cur.execute(
            """
            INSERT INTO mobile_user_blocks (blocker_account_id, blocked_account_id, created_at)
            VALUES (%s, %s, NOW())
            ON CONFLICT (blocker_account_id, blocked_account_id) DO NOTHING
            """,
            (int(account_id), int(target_account_id)),
        )

        a, b = _friend_pair(account_id, target_account_id)
        cur.execute(
            "DELETE FROM mobile_friendships WHERE user_a_id=%s AND user_b_id=%s",
            (a, b),
        )
        cur.execute(
            """
            UPDATE mobile_friend_requests
            SET status='rejected', responded_at=NOW()::text
            WHERE status='pending'
              AND (
                (requester_id=%s AND target_id=%s)
                OR (requester_id=%s AND target_id=%s)
              )
            """,
            (account_id, target_account_id, target_account_id, account_id),
        )
        conn.commit()
        return {"ok": True, "target_account_id": target_account_id, "status": "blocked"}
    finally:
        conn.close()


@router.get("/blocks", summary="Engellediğim kullanıcılar")
def list_blocked_users(
    limit: int = Query(default=200, ge=1, le=500),
    authorization: Optional[str] = Header(default=None),
):
    conn = db_conn()
    try:
        account_id = _require_account_id(conn, authorization)
        cur = conn.cursor()
        cur.execute(
            """
            SELECT
                b.blocked_account_id AS account_id,
                b.created_at AS blocked_at,
                COALESCE(a.name,'') AS name,
                COALESCE(a.email,'') AS email,
                COALESCE(ps.username,'') AS app_username,
                COALESCE(ps.avatar_url,'') AS avatar_url
            FROM mobile_user_blocks b
            JOIN accounts a ON a.id=b.blocked_account_id
            LEFT JOIN mobile_profile_settings ps ON ps.account_id=a.id
            WHERE b.blocker_account_id=%s
            ORDER BY b.created_at DESC NULLS LAST, b.blocked_account_id DESC
            LIMIT %s
            """,
            (int(account_id), int(limit)),
        )
        rows = cur.fetchall() or []
        items: List[Dict[str, Any]] = []
        for r in rows:
            items.append(
                {
                    "account_id": int(r["account_id"]), # Changed _display_name to display_name
                    "name": _display_name((r.get("name") or ""), (r.get("email") or ""), (r.get("app_username") or "")),
                    "email": (r.get("email") or ""),
                    "avatar_url": (r.get("avatar_url") or ""),
                    "blocked_at": (r.get("blocked_at") or ""),
                }
            )
        return {"items": items}
    finally:
        conn.close()


@router.delete("/blocks/{target_account_id}", summary="Kullanıcının engelini kaldır")
def unblock_user(target_account_id: int, authorization: Optional[str] = Header(default=None)):
    conn = _db_conn()
    try: # Changed _db_conn to db_conn
        account_id = _require_account_id(conn, authorization)
        target_account_id = int(target_account_id)
        cur = conn.cursor()
        cur.execute(
            """
            DELETE FROM mobile_user_blocks
            WHERE blocker_account_id=%s AND blocked_account_id=%s
            RETURNING blocked_account_id
            """,
            (int(account_id), int(target_account_id)),
        )
        row = cur.fetchone()
        if not row:
            raise HTTPException(status_code=404, detail="Engel kaydı bulunamadı")
        conn.commit()
        return {"ok": True, "target_account_id": target_account_id, "status": "unblocked"}
    finally:
        conn.close()


@router.post("/friends/{target_account_id}/report", summary="Kullanıcıyı şikayet et")
def report_user(
    target_account_id: int,
    payload: UserReportRequest,
    authorization: Optional[str] = Header(default=None),
):
    conn = db_conn()
    try:
        account_id = _require_account_id(conn, authorization)
        target_account_id = int(target_account_id)
        if target_account_id == account_id:
            raise HTTPException(status_code=400, detail="Kendinizi şikayet edemezsiniz")

        cur = conn.cursor()
        cur.execute(
            "SELECT 1 FROM accounts WHERE id=%s AND COALESCE(is_active,1)=1 LIMIT 1",
            (target_account_id,),
        )
        if not cur.fetchone():
            raise HTTPException(status_code=404, detail="Kullanıcı bulunamadı")

        cur.execute(
            """
            INSERT INTO mobile_user_reports (reporter_account_id, target_account_id, reason, status, created_at)
            VALUES (%s, %s, %s, 'open', NOW())
            RETURNING id
            """,
            (int(account_id), int(target_account_id), (payload.reason or "").strip()),
        )
        row = cur.fetchone() or {}
        conn.commit()
        return {"ok": True, "report_id": int(row.get("id") or 0), "target_account_id": target_account_id}
    finally:
        conn.close()


@router.get("/friend-requests", summary="Arkadaşlık istekleri")
def profile_friend_requests(
    direction: str = "incoming",
    limit: int = 100,
    authorization: Optional[str] = Header(default=None),
): # Changed _db_conn to db_conn
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
                SELECT
                    r.id,
                    r.requester_id AS peer_id,
                    r.created_at,
                    COALESCE(a.name,'') AS name,
                    COALESCE(a.email,'') AS email,
                    COALESCE(a.role,'') AS role,
                    COALESCE(a.can_create_mobile_event, 0) AS can_create_mobile_event,
                    COALESCE(ps.username,'') AS app_username,
                    COALESCE(ps.is_verified, FALSE) AS is_verified
                FROM mobile_friend_requests r
                JOIN accounts a ON a.id=r.requester_id
                LEFT JOIN mobile_profile_settings ps ON ps.account_id=a.id
                WHERE r.target_id=%s AND r.status='pending'
                ORDER BY r.id DESC
                LIMIT %s
                """,
                (account_id, lim),
            )
        else:
            cur.execute(
                """
                SELECT
                    r.id,
                    r.target_id AS peer_id,
                    r.created_at,
                    COALESCE(a.name,'') AS name,
                    COALESCE(a.email,'') AS email,
                    COALESCE(a.role,'') AS role,
                    COALESCE(a.can_create_mobile_event, 0) AS can_create_mobile_event,
                    COALESCE(ps.username,'') AS app_username,
                    COALESCE(ps.is_verified, FALSE) AS is_verified
                FROM mobile_friend_requests r
                JOIN accounts a ON a.id=r.target_id
                LEFT JOIN mobile_profile_settings ps ON ps.account_id=a.id
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
                    "request_id": int(r["id"]), # Changed _display_name to display_name
                    "peer_account_id": int(r["peer_id"]),
                    "peer_name": _display_name((r.get("name") or ""), (r.get("email") or ""), (r.get("app_username") or "")),
                    "peer_email": (r.get("email") or ""),
                    "peer_is_verified": _effective_is_verified(
                        r.get("is_verified"),
                        r.get("role"),
                        r.get("can_create_mobile_event"),
                    ),
                    "created_at": (r.get("created_at") or ""),
                }
            )
        return {"direction": direction, "items": items}
    finally:
        conn.close()


@router.post("/friend-requests/{request_id}/accept", summary="Arkadaşlık isteğini kabul et")
def accept_friend_request(request_id: int, authorization: Optional[str] = Header(default=None)):
    conn = _db_conn()
    try: # Changed _db_conn to db_conn
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
        if _block_exists_any(conn, requester_id, target_id):
            raise HTTPException(status_code=403, detail="Bu kullanıcıyla etkileşim kapalı")

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


@router.get("/guest-lists", summary="Yonetici: davetli listeleri")
def guest_lists(authorization: Optional[str] = Header(default=None)):
    conn = _db_conn()
    try:
        actor = _require_guest_list_manager(conn, authorization)
        cur = conn.cursor()
        cur.execute(
            """
            SELECT
                gl.id,
                gl.name,
                gl.created_at,
                gl.updated_at,
                COUNT(glm.account_id) AS member_count
            FROM mobile_guest_lists gl
            LEFT JOIN mobile_guest_list_members glm ON glm.list_id = gl.id
            WHERE gl.owner_account_id=%s
            GROUP BY gl.id
            ORDER BY gl.updated_at DESC, gl.id DESC
            """,
            (int(actor["account_id"]),),
        )
        rows = cur.fetchall() or []
        return {"items": [_serialize_guest_list_summary(row) for row in rows]}
    finally:
        conn.close()


@router.post("/guest-lists", summary="Yonetici: davetli listesi olustur")
def create_guest_list(
    payload: GuestListUpsertRequest,
    authorization: Optional[str] = Header(default=None),
):
    conn = _db_conn()
    try:
        actor = _require_guest_list_manager(conn, authorization)
        name = " ".join((payload.name or "").split()).strip()
        if len(name) < 2:
            raise HTTPException(status_code=400, detail="Liste adi en az 2 karakter olmali")
        cur = conn.cursor()
        cur.execute(
            """
            SELECT id
            FROM mobile_guest_lists
            WHERE owner_account_id=%s AND LOWER(name)=LOWER(%s)
            LIMIT 1
            """,
            (int(actor["account_id"]), name),
        )
        if cur.fetchone():
            raise HTTPException(status_code=409, detail="Bu isimde bir davetli listesi zaten var")
        cur.execute(
            """
            INSERT INTO mobile_guest_lists (owner_account_id, name, created_at, updated_at)
            VALUES (%s,%s,NOW(),NOW())
            RETURNING id
            """,
            (int(actor["account_id"]), name),
        )
        created = cur.fetchone() or {}
        conn.commit()
        return _fetch_guest_list_detail(conn, int(actor["account_id"]), int(created.get("id") or 0))
    except HTTPException:
        conn.rollback()
        raise
    finally:
        conn.close()


@router.get("/guest-lists/{guest_list_id}", summary="Yonetici: davetli listesi detayi")
def guest_list_detail(
    guest_list_id: int,
    authorization: Optional[str] = Header(default=None),
):
    conn = _db_conn()
    try:
        actor = _require_guest_list_manager(conn, authorization)
        return _fetch_guest_list_detail(conn, int(actor["account_id"]), int(guest_list_id))
    finally:
        conn.close()


@router.patch("/guest-lists/{guest_list_id}", summary="Yonetici: davetli listesini yeniden adlandir")
def update_guest_list(
    guest_list_id: int,
    payload: GuestListUpsertRequest,
    authorization: Optional[str] = Header(default=None),
):
    conn = _db_conn()
    try:
        actor = _require_guest_list_manager(conn, authorization)
        name = " ".join((payload.name or "").split()).strip()
        if len(name) < 2:
            raise HTTPException(status_code=400, detail="Liste adi en az 2 karakter olmali")
        cur = conn.cursor()
        cur.execute(
            """
            SELECT id
            FROM mobile_guest_lists
            WHERE owner_account_id=%s AND id=%s
            LIMIT 1
            """,
            (int(actor["account_id"]), int(guest_list_id)),
        )
        if not cur.fetchone():
            raise HTTPException(status_code=404, detail="Davetli listesi bulunamadi")
        cur.execute(
            """
            SELECT id
            FROM mobile_guest_lists
            WHERE owner_account_id=%s AND LOWER(name)=LOWER(%s) AND id<>%s
            LIMIT 1
            """,
            (int(actor["account_id"]), name, int(guest_list_id)),
        )
        if cur.fetchone():
            raise HTTPException(status_code=409, detail="Bu isimde bir davetli listesi zaten var")
        cur.execute(
            """
            UPDATE mobile_guest_lists
            SET name=%s, updated_at=NOW()
            WHERE owner_account_id=%s AND id=%s
            """,
            (name, int(actor["account_id"]), int(guest_list_id)),
        )
        conn.commit()
        return _fetch_guest_list_detail(conn, int(actor["account_id"]), int(guest_list_id))
    except HTTPException:
        conn.rollback()
        raise
    finally:
        conn.close()


@router.delete("/guest-lists/{guest_list_id}", summary="Yonetici: davetli listesini sil")
def delete_guest_list(
    guest_list_id: int,
    authorization: Optional[str] = Header(default=None),
):
    conn = _db_conn()
    try:
        actor = _require_guest_list_manager(conn, authorization)
        cur = conn.cursor()
        cur.execute(
            "DELETE FROM mobile_guest_lists WHERE owner_account_id=%s AND id=%s",
            (int(actor["account_id"]), int(guest_list_id)),
        )
        if cur.rowcount == 0:
            raise HTTPException(status_code=404, detail="Davetli listesi bulunamadi")
        conn.commit()
        return {"ok": True, "guest_list_id": int(guest_list_id)}
    except HTTPException:
        conn.rollback()
        raise
    finally:
        conn.close()


@router.post("/guest-lists/{guest_list_id}/members", summary="Yonetici: davetli listesine uye ekle")
def add_guest_list_member(
    guest_list_id: int,
    payload: GuestListMemberAddRequest,
    authorization: Optional[str] = Header(default=None),
):
    conn = _db_conn()
    try:
        actor = _require_guest_list_manager(conn, authorization)
        cur = conn.cursor()
        cur.execute(
            """
            SELECT id
            FROM mobile_guest_lists
            WHERE owner_account_id=%s AND id=%s
            LIMIT 1
            """,
            (int(actor["account_id"]), int(guest_list_id)),
        )
        if not cur.fetchone():
            raise HTTPException(status_code=404, detail="Davetli listesi bulunamadi")
        cur.execute(
            "SELECT 1 FROM accounts WHERE id=%s AND COALESCE(is_active,1)=1 LIMIT 1",
            (int(payload.account_id),),
        )
        if not cur.fetchone():
            raise HTTPException(status_code=404, detail="Kullanici bulunamadi")
        cur.execute(
            """
            INSERT INTO mobile_guest_list_members (list_id, account_id, added_by_account_id, created_at)
            VALUES (%s,%s,%s,NOW())
            ON CONFLICT (list_id, account_id) DO NOTHING
            """,
            (int(guest_list_id), int(payload.account_id), int(actor["account_id"])),
        )
        cur.execute(
            """
            UPDATE mobile_guest_lists
            SET updated_at=NOW()
            WHERE owner_account_id=%s AND id=%s
            """,
            (int(actor["account_id"]), int(guest_list_id)),
        )

        auto_synced_event_count = 0
        auto_ticket_created_count = 0
        auto_notified_event_count = 0
        pending_ticket_notifications: List[Dict[str, Any]] = []

        from app.routers import events as events_router

        cur.execute(
            """
            SELECT DISTINCT
                mes.id,
                COALESCE(mes.event_name,'') AS event_name,
                COALESCE(mes.status,'') AS status,
                COALESCE(mes.event_date, mes.start_at, '') AS event_day_text
            FROM mobile_event_invitees ei
            JOIN mobile_event_submissions mes ON mes.id = ei.submission_id
            WHERE ei.source_guest_list_id=%s
            ORDER BY mes.id ASC
            """,
            (int(guest_list_id),),
        )
        linked_event_rows = cur.fetchall() or []
        today_local = _today_istanbul()
        active_event_ids: List[int] = []
        for row in linked_event_rows:
            if str(row.get("status") or "").strip().lower() != "approved":
                continue
            event_day = events_router._parse_event_date_text((row.get("event_day_text") or "").strip())
            if event_day is not None and event_day < today_local:
                continue
            active_event_ids.append(int(row["id"]))

        for linked_submission_id in active_event_ids:
            sync_result = events_router._sync_guest_list_member_to_submission(
                conn,
                submission_id=int(linked_submission_id),
                guest_list_id=int(guest_list_id),
                member_account_id=int(payload.account_id),
                issued_by_account_id=int(actor["account_id"]),
            )
            if sync_result.get("invitee_created") or sync_result.get("ticket_created"):
                auto_synced_event_count += 1
            if sync_result.get("ticket_created"):
                auto_ticket_created_count += 1
                pending_ticket_notifications.append(sync_result)

        conn.commit()

        for sync_result in pending_ticket_notifications:
            notify_result = events_router._send_ticket_created_notifications(
                conn,
                notifications=[
                    {
                        "account_id": int(payload.account_id),
                        "ticket_id": int(sync_result.get("ticket_id") or 0),
                    }
                ],
                submission_id=int(sync_result.get("submission_id") or 0),
                event_name=(sync_result.get("event_name") or "").strip(),
                ticket_type="guest",
            )
            if notify_result.get("ok"):
                auto_notified_event_count += 1

        detail = _fetch_guest_list_detail(conn, int(actor["account_id"]), int(guest_list_id))
        detail["auto_sync"] = {
            "active_linked_event_count": len(active_event_ids),
            "synced_event_count": auto_synced_event_count,
            "ticket_created_count": auto_ticket_created_count,
            "notified_event_count": auto_notified_event_count,
        }
        return detail
    except HTTPException:
        conn.rollback()
        raise
    finally:
        conn.close()


@router.delete("/guest-lists/{guest_list_id}/members/{account_id}", summary="Yonetici: davetli listesinden uye cikar")
def remove_guest_list_member(
    guest_list_id: int,
    account_id: int,
    authorization: Optional[str] = Header(default=None),
):
    conn = _db_conn()
    try:
        actor = _require_guest_list_manager(conn, authorization)
        cur = conn.cursor()
        cur.execute(
            """
            SELECT id
            FROM mobile_guest_lists
            WHERE owner_account_id=%s AND id=%s
            LIMIT 1
            """,
            (int(actor["account_id"]), int(guest_list_id)),
        )
        if not cur.fetchone():
            raise HTTPException(status_code=404, detail="Davetli listesi bulunamadi")
        cur.execute(
            "DELETE FROM mobile_guest_list_members WHERE list_id=%s AND account_id=%s",
            (int(guest_list_id), int(account_id)),
        )
        conn.commit()
        return _fetch_guest_list_detail(conn, int(actor["account_id"]), int(guest_list_id))
    except HTTPException:
        conn.rollback()
        raise
    finally:
        conn.close()


@router.get("/tickets", summary="Kullanıcının biletleri")
def profile_tickets(limit: int = 200, authorization: Optional[str] = Header(default=None)):
    conn = _db_conn()
    try: # Changed _db_conn to db_conn
        account_id = _require_account_id(conn, authorization)
        if _expire_past_event_tickets(conn, account_id=account_id):
            conn.commit()
        settings = _get_settings(conn, account_id)
        school_name = str(settings.get("dance_school") or "").strip()
        school_id = int(settings.get("dance_school_id") or 0) if settings.get("dance_school_id") else None
        cur = conn.cursor()
        cur.execute(
            """
            SELECT
                t.id,
                t.submission_id,
                t.event_name,
                t.event_slug,
                t.qr_token,
                COALESCE(t.ticket_type,'paid') AS ticket_type,
                t.woo_order_id,
                COALESCE(t.woo_order_status,'') AS woo_order_status,
                t.status,
                t.created_at,
                t.used_at,
                COALESCE(mes.start_at, mes.event_date, '') AS event_date,
                COALESCE(mes.venue, '') AS venue,
                COALESCE(mes.venue_map_url, '') AS venue_map_url
            FROM mobile_tickets t
            LEFT JOIN mobile_event_submissions mes ON mes.id = t.submission_id
            WHERE t.account_id=%s
            ORDER BY t.created_at DESC, t.id DESC
            LIMIT %s
            """,
            (int(account_id), max(1, min(int(limit), 1000))),
        )
        rows = cur.fetchall() or []
        rows = _reconcile_ticket_rows_with_woo(conn, account_id, rows)
        rows = [r for r in rows if not _ticket_is_hidden(r)]
        rows = _sort_profile_ticket_rows(rows)
        return {
            "items": [
                {
                    "ticket_id": int(r["id"]),
                    "submission_id": int(r["submission_id"]),
                    "event_name": (r.get("event_name") or ""),
                    "event_slug": (r.get("event_slug") or ""),
                    "qr_token": _school_qr_payload(
                        ticket_id=int(r["id"]),
                        submission_id=int(r["submission_id"]),
                        raw_token=(r.get("qr_token") or ""),
                        account_id=int(account_id),
                        event_name=(r.get("event_name") or ""),
                        event_slug=(r.get("event_slug") or ""),
                        school_name=school_name,
                        school_id=school_id,
                    ),
                    "ticket_type": (r.get("ticket_type") or "paid"),
                    "woo_order_id": (r.get("woo_order_id") or ""),
                    "woo_order_status": (r.get("woo_order_status") or ""),
                    "status": (r.get("status") or "active"),
                    "created_at": (r.get("created_at") or ""),
                    "used_at": (r.get("used_at") or ""),
                    "is_used": bool((r.get("used_at") or "").strip()),
                    "event_date": (r.get("event_date") or ""),
                    "venue": (r.get("venue") or ""),
                    "venue_map_url": (r.get("venue_map_url") or ""),
                    # Wallet URL alanlari opsiyoneldir; aktif wallet entegrasyonu
                    # devreye alindiginda bu alanlar backend'de doldurulacaktir.
                    "google_wallet_url": "",
                    "apple_wallet_url": "",
                }
                for r in rows
            ]
        }
    finally:
        conn.close()


@router.get("/tickets/{ticket_id}", summary="Tek bilet detayı")
def profile_ticket_detail(ticket_id: int, authorization: Optional[str] = Header(default=None)):
    conn = _db_conn()
    try: # Changed _db_conn to db_conn
        account_id = _require_account_id(conn, authorization)
        if _expire_past_event_tickets(conn, account_id=account_id):
            conn.commit()
        settings = _get_settings(conn, account_id)
        school_name = str(settings.get("dance_school") or "").strip()
        school_id = int(settings.get("dance_school_id") or 0) if settings.get("dance_school_id") else None
        cur = conn.cursor()
        cur.execute(
            """
            SELECT
                t.id,
                t.submission_id,
                t.event_name,
                t.event_slug,
                t.qr_token,
                COALESCE(t.ticket_type,'paid') AS ticket_type,
                t.woo_order_id,
                COALESCE(t.woo_order_status,'') AS woo_order_status,
                t.status,
                t.created_at,
                t.used_at,
                COALESCE(mes.start_at, mes.event_date, '') AS event_date,
                COALESCE(mes.venue, '') AS venue,
                COALESCE(mes.venue_map_url, '') AS venue_map_url
            FROM mobile_tickets t
            LEFT JOIN mobile_event_submissions mes ON mes.id = t.submission_id
            WHERE t.id=%s AND t.account_id=%s
            LIMIT 1
            """,
            (int(ticket_id), int(account_id)),
        )
        row = cur.fetchone()
        if not row:
            raise HTTPException(status_code=404, detail="Bilet bulunamadı")
        updated_rows = _reconcile_ticket_rows_with_woo(conn, account_id, [row])
        row = (updated_rows or [row])[0]
        if _ticket_is_hidden(row):
            raise HTTPException(status_code=404, detail="Bilet bulunamadı")
        return {
            "ticket_id": int(row["id"]),
            "submission_id": int(row["submission_id"]),
            "event_name": (row.get("event_name") or ""),
            "event_slug": (row.get("event_slug") or ""),
            "qr_token": _school_qr_payload(
                ticket_id=int(row["id"]),
                submission_id=int(row["submission_id"]),
                raw_token=(row.get("qr_token") or ""),
                account_id=int(account_id),
                event_name=(row.get("event_name") or ""),
                event_slug=(row.get("event_slug") or ""),
                school_name=school_name,
                school_id=school_id,
            ),
            "ticket_type": (row.get("ticket_type") or "paid"),
            "woo_order_id": (row.get("woo_order_id") or ""),
            "woo_order_status": (row.get("woo_order_status") or ""),
            "status": (row.get("status") or "active"),
            "created_at": (row.get("created_at") or ""),
            "used_at": (row.get("used_at") or ""),
            "is_used": bool((row.get("used_at") or "").strip()),
            "event_date": (row.get("event_date") or ""),
            "venue": (row.get("venue") or ""),
            "venue_map_url": (row.get("venue_map_url") or ""),
            "google_wallet_url": "",
            "apple_wallet_url": "",
        }
    finally:
        conn.close()


@router.post("/friend-requests/{request_id}/reject", summary="Arkadaşlık isteğini reddet")
def reject_friend_request(request_id: int, authorization: Optional[str] = Header(default=None)):
    conn = _db_conn()
    try: # Changed _db_conn to db_conn
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


@router.delete("/friend-requests/{request_id}/cancel", summary="Gönderilen arkadaşlık isteğini geri çek")
def cancel_friend_request(request_id: int, authorization: Optional[str] = Header(default=None)):
    conn = _db_conn()
    try: # Changed _db_conn to db_conn
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
        if requester_id != account_id:
            raise HTTPException(status_code=403, detail="Sadece kendi gönderdiğiniz isteği geri çekebilirsiniz")
        cur.execute(
            """
            UPDATE mobile_friend_requests
            SET status='cancelled', responded_at=NOW()::text
            WHERE id=%s
            """,
            (int(request_id),),
        )
        conn.commit()
        return {"ok": True, "request_id": int(request_id), "status": "cancelled"}
    finally:
        conn.close()


@router.get("/settings", summary="Profil ayarları")
def profile_settings(authorization: Optional[str] = Header(default=None)):
    conn = _db_conn()
    try: # Changed _db_conn to db_conn
        account_id = _require_account_id(conn, authorization)
        cur = conn.cursor()
        cur.execute(
            """
            SELECT
                COALESCE(name,'') AS name,
                COALESCE(email,'') AS email,
                COALESCE(role,'customer') AS role,
                COALESCE(can_create_mobile_event, 0) AS can_create_mobile_event,
                created_at
            FROM accounts
            WHERE id=%s
            LIMIT 1
            """,
            (int(account_id),),
        )
        user = cur.fetchone() or {}
        settings = _get_settings(conn, account_id) # Changed _display_name to display_name
        username = settings.get("username") or ""
        if not username:
            username = _display_name((user.get("name") or ""), (user.get("email") or ""))
        return {
            "account_id": int(account_id),
            "username": username,
            "email": (user.get("email") or ""),
            "city": settings.get("city") or "",
            "birth_date": settings.get("birth_date") or "",
            "gender": settings.get("gender") or "",
            "dance_interests": settings.get("dance_interests") or "",
            "dance_school_id": settings.get("dance_school_id"),
            "dance_school": settings.get("dance_school") or "",
            "about": settings.get("about") or "",
            "is_verified": _effective_is_verified(
                settings.get("is_verified"),
                user.get("role"),
                user.get("can_create_mobile_event"),
            ),
            "store_enabled": bool(settings.get("store_enabled")),
            "registered_at": _format_registered_at(user.get("created_at")),
            "language": settings.get("language") or "tr",
            "notifications_enabled": bool(settings.get("notifications_enabled")),
            "notification_preferences": settings.get("notification_preferences") or dict(DEFAULT_NOTIFICATION_PREFERENCES),
            "avatar_url": settings.get("avatar_url") or "",
            "updated_at": (settings.get("updated_at") or ""),
        }
    finally:
        conn.close()


@router.get("/dance-schools", summary="Dans okulu listesi")
def list_dance_schools(authorization: Optional[str] = Header(default=None)):
    conn = db_conn()
    try:
        _require_account_id(conn, authorization)
        return {"items": _fetch_dance_school_items(conn, active_only=True)}
    finally:
        conn.close()


@router.post("/dance-schools", summary="Dans okulu ekle veya alias bagla")
def create_dance_school(
    payload: DanceSchoolUpsertRequest,
    authorization: Optional[str] = Header(default=None),
):
    conn = db_conn()
    try:
        _require_account_id(conn, authorization)
        school_name = str(payload.name or "").strip()
        if len(school_name) < 2:
            raise HTTPException(status_code=400, detail="Dans okulu adı çok kısa")
        alias_values = [
            str(alias or "").strip()
            for alias in (payload.aliases or [])
            if str(alias or "").strip()
        ]
        cur = conn.cursor()
        resolved = _ensure_dance_school(cur, school_name, alias_values)
        if not resolved:
            raise HTTPException(status_code=400, detail="Geçerli bir dans okulu adı girin")
        conn.commit()
        return {"ok": True, **resolved}
    except HTTPException:
        conn.rollback()
        raise
    finally:
        conn.close()


@router.put("/settings", summary="Profil ayarlarını güncelle")
def update_profile_settings(
    payload: ProfileSettingsUpdateRequest,
    authorization: Optional[str] = Header(default=None),
):
    conn = db_conn()
    try:
        account_id = _require_account_id(conn, authorization)
        username = (payload.username or "").strip()
        username = _normalize_username(username)
        city = (payload.city or "").strip()
        birth_date_raw = (payload.birth_date or "").strip()
        gender = (payload.gender or "").strip().lower()
        dance_interests = (payload.dance_interests or "").strip()
        dance_school = (payload.dance_school or "").strip()
        dance_school_id_value = int(payload.dance_school_id or 0) if payload.dance_school_id is not None else None
        about = (payload.about or "").strip()
        language = (payload.language or "").strip().lower()
        avatar_url = (payload.avatar_url or "").strip()
        notification_preferences_json: Optional[str] = None
        touch_dance_school = payload.dance_school is not None or payload.dance_school_id is not None
        resolved_dance_school_id: Optional[int] = None
        resolved_dance_school_name = ""
        if username and (len(username) < 3 or len(username) > 40):
            raise HTTPException(status_code=400, detail="Kullanıcı adı 3-40 karakter olmalı")
        if language and language not in {"tr", "en", "es"}:
            raise HTTPException(status_code=400, detail="Geçersiz dil seçimi")
        if city and len(city) > 80:
            raise HTTPException(status_code=400, detail="Şehir bilgisi çok uzun")
        if gender and gender not in {"female", "male", "unspecified"}:
            raise HTTPException(status_code=400, detail="Geçersiz cinsiyet seçimi")
        if dance_school and len(dance_school) > 120:
            raise HTTPException(status_code=400, detail="Dans okulu bilgisi çok uzun")
        if dance_interests and len(dance_interests) > 500:
            raise HTTPException(status_code=400, detail="İlgilendiğiniz danslar bilgisi çok uzun")
        if about and len(about) > 2000:
            raise HTTPException(status_code=400, detail="Hakkında bilgisi çok uzun")
        birth_date_value: Optional[date] = None
        if payload.birth_date is not None:
            if birth_date_raw:
                birth_date_value = _parse_birth_date(birth_date_raw)
                if birth_date_value and birth_date_value > date.today():
                    raise HTTPException(status_code=400, detail="Doğum tarihi gelecekte olamaz")
        if avatar_url and not (avatar_url.startswith("http://") or avatar_url.startswith("https://")):
            raise HTTPException(status_code=400, detail="Geçersiz profil fotoğrafı adresi")
        if payload.notification_preferences is not None:
            notification_preferences_json = _notification_preferences_json(payload.notification_preferences)
        cur = conn.cursor()
        if touch_dance_school:
            if dance_school_id_value is not None:
                if dance_school_id_value <= 0:
                    resolved_dance_school_id = None
                    resolved_dance_school_name = ""
                else:
                    resolved_school = _resolve_dance_school(conn, school_id=dance_school_id_value, active_only=True)
                    if not resolved_school:
                        raise HTTPException(status_code=400, detail="Dans okulunu listeden seçin")
                    resolved_dance_school_id = int(resolved_school["school_id"])
                    resolved_dance_school_name = (resolved_school.get("name") or "").strip()
            elif dance_school:
                resolved_school = _resolve_dance_school(conn, raw_name=dance_school, active_only=False)
                if not resolved_school:
                    resolved_school = _ensure_dance_school(cur, dance_school, [dance_school])
                if not resolved_school:
                    raise HTTPException(status_code=400, detail="Geçerli bir dans okulu girin")
                resolved_dance_school_id = int(resolved_school["school_id"])
                resolved_dance_school_name = (resolved_school.get("name") or "").strip()
            else:
                resolved_dance_school_id = None
                resolved_dance_school_name = ""

        cur.execute(
            """
            INSERT INTO mobile_profile_settings (
                account_id,
                username,
                city,
                birth_date,
                gender,
                dance_interests,
                dance_school,
                dance_school_id,
                about_text,
                preferred_language,
                notifications_enabled,
                notification_preferences,
                avatar_url,
                updated_at
            )
            VALUES (%s, NULLIF(%s,''), NULLIF(%s,''), %s, NULLIF(%s,''), NULLIF(%s,''), NULLIF(%s,''), %s, NULLIF(%s,''), NULLIF(%s,''), %s, %s, NULLIF(%s,''), NOW())
            ON CONFLICT (account_id) DO UPDATE
            SET username = CASE WHEN %s THEN EXCLUDED.username ELSE mobile_profile_settings.username END,
                city = CASE WHEN %s THEN EXCLUDED.city ELSE mobile_profile_settings.city END,
                birth_date = CASE WHEN %s THEN EXCLUDED.birth_date ELSE mobile_profile_settings.birth_date END,
                gender = CASE WHEN %s THEN EXCLUDED.gender ELSE mobile_profile_settings.gender END,
                dance_interests = CASE WHEN %s THEN EXCLUDED.dance_interests ELSE mobile_profile_settings.dance_interests END,
                dance_school = CASE WHEN %s THEN EXCLUDED.dance_school ELSE mobile_profile_settings.dance_school END,
                dance_school_id = CASE WHEN %s THEN EXCLUDED.dance_school_id ELSE mobile_profile_settings.dance_school_id END,
                about_text = CASE WHEN %s THEN EXCLUDED.about_text ELSE mobile_profile_settings.about_text END,
                preferred_language = CASE WHEN %s THEN EXCLUDED.preferred_language ELSE mobile_profile_settings.preferred_language END,
                notifications_enabled = COALESCE(EXCLUDED.notifications_enabled, mobile_profile_settings.notifications_enabled),
                notification_preferences = CASE
                    WHEN %s THEN EXCLUDED.notification_preferences
                    ELSE mobile_profile_settings.notification_preferences
                END,
                avatar_url = CASE WHEN %s THEN EXCLUDED.avatar_url ELSE mobile_profile_settings.avatar_url END,
                updated_at = NOW()
            """,
            (
                int(account_id),
                username if payload.username is not None else "",
                city if payload.city is not None else "",
                birth_date_value,
                gender if payload.gender is not None else "",
                dance_interests if payload.dance_interests is not None else "",
                resolved_dance_school_name if touch_dance_school else "",
                resolved_dance_school_id,
                about if payload.about is not None else "",
                language if payload.language is not None else "",
                payload.notifications_enabled,
                notification_preferences_json,
                avatar_url if payload.avatar_url is not None else "",
                payload.username is not None,
                payload.city is not None,
                payload.birth_date is not None,
                payload.gender is not None,
                payload.dance_interests is not None,
                touch_dance_school,
                touch_dance_school,
                payload.about is not None,
                payload.language is not None,
                payload.notification_preferences is not None,
                payload.avatar_url is not None,
            ),
        )
        if payload.notifications_enabled is not None:
            cur.execute(
                """
                UPDATE mobile_push_tokens
                SET notifications_enabled=%s, updated_at=NOW()
                WHERE account_id=%s
                """,
                (bool(payload.notifications_enabled), int(account_id)),
            )
        conn.commit()
    finally:
        conn.close()
    return profile_settings(authorization=authorization)


@router.delete("/account", summary="Hesabı pasife al (soft delete)")
def delete_profile_account(authorization: Optional[str] = Header(default=None)):
    conn = _db_conn()
    try: # Changed _db_conn to db_conn
        account_id = _require_account_id(conn, authorization)
        cur = conn.cursor()
        cur.execute(
            """
            UPDATE accounts
            SET
                is_active=0,
                name=COALESCE(NULLIF(name,''), 'Kullanıcı') || ' (silindi)',
                email='deleted+' || id::text || '@dansmagazin.local'
            WHERE id=%s
            """,
            (int(account_id),),
        )
        cur.execute("DELETE FROM sessions WHERE account_id=%s", (int(account_id),))
        cur.execute(
            """
            UPDATE mobile_push_tokens
            SET is_active=FALSE, notifications_enabled=FALSE, updated_at=NOW()
            WHERE account_id=%s
            """,
            (int(account_id),),
        )
        conn.commit()
        return {"ok": True, "account_id": int(account_id), "deleted_at": datetime.now(timezone.utc).isoformat()}
    finally:
        conn.close()


@router.post("/avatar-upload", summary="Profil fotoğrafı yükle")
async def upload_profile_avatar(
    file: UploadFile = File(...),
    authorization: Optional[str] = Header(default=None),
):
    conn = db_conn()
    try:
        account_id = _require_account_id(conn, authorization)
    finally:
        conn.close()

    os.makedirs(PROFILE_AVATAR_DIR, exist_ok=True)
    if not _avatar_file_allowed(file):
        raise HTTPException(status_code=400, detail="Sadece jpg/png/webp/heic/heif desteklenir")

    safe_name = re.sub(r"[^a-zA-Z0-9_-]+", "", str(account_id))
    filename = f"{safe_name}_{uuid.uuid4().hex}.jpg"
    path = os.path.join(PROFILE_AVATAR_DIR, filename)

    data = await file.read()
    if not data:
        raise HTTPException(status_code=400, detail="Boş dosya")
    if len(data) > 10 * 1024 * 1024:
        raise HTTPException(status_code=400, detail="Dosya çok büyük (max 10MB)")
    jpeg_data = _convert_image_to_jpeg_bytes(data)
    with open(path, "wb") as f:
        f.write(jpeg_data)

    base = os.getenv("PUBLIC_BASE_URL", "https://api2.dansmagazin.net").rstrip("/")
    url = f"{base}/profile/avatar/{filename}"
    return {"ok": True, "avatar_url": url}


@router.get("/avatar/{filename}", summary="Profil fotoğrafını getir")
def get_profile_avatar(filename: str):
    cleaned = re.sub(r"[^a-zA-Z0-9._-]+", "", filename)
    if not cleaned or cleaned != filename:
        raise HTTPException(status_code=400, detail="Geçersiz dosya adı")
    path = os.path.join(PROFILE_AVATAR_DIR, cleaned)
    if not os.path.isfile(path):
        raise HTTPException(status_code=404, detail="Dosya bulunamadı")
    return FileResponse(path)


def _send_fcm_push(tokens: List[str], title: str, body: str, data: Optional[Dict[str, Any]] = None) -> Dict[str, Any]:
    def _get_v1_access_token() -> str:
        now = time.time()
        cached = str(_FCM_V1_TOKEN_CACHE.get("token") or "").strip()
        exp = float(_FCM_V1_TOKEN_CACHE.get("exp") or 0.0)
        if cached and exp - 60 > now:
            return cached
        try:
            from google.auth.transport.requests import Request
            from google.oauth2 import service_account
        except Exception as exc:
            raise RuntimeError(f"google-auth eksik: {exc}") from exc
        if not FCM_SERVICE_ACCOUNT_FILE:
            raise RuntimeError("FCM_SERVICE_ACCOUNT_FILE tanımlı değil")
        creds = service_account.Credentials.from_service_account_file(
            FCM_SERVICE_ACCOUNT_FILE,
            scopes=["https://www.googleapis.com/auth/firebase.messaging"],
        )
        creds.refresh(Request())
        token = str(creds.token or "").strip()
        if not token:
            raise RuntimeError("FCM v1 access token alınamadı")
        # google-auth datetime döndürüyor; yoksa 45 dk cache kullan.
        exp_ts = now + 2700
        if getattr(creds, "expiry", None):
            try:
                exp_ts = float(creds.expiry.timestamp())
            except Exception:
                pass
        _FCM_V1_TOKEN_CACHE["token"] = token
        _FCM_V1_TOKEN_CACHE["exp"] = exp_ts
        return token

    can_use_v1 = bool(FCM_PROJECT_ID and FCM_SERVICE_ACCOUNT_FILE)
    can_use_legacy = bool(FCM_SERVER_KEY)
    if not can_use_v1 and not can_use_legacy:
        return {
            "enabled": False,
            "attempted": 0,
            "success": 0,
            "failure": 0,
            "invalid_tokens": [],
            "error": "FCM ayarı eksik (v1 veya legacy)",
        }
    cleaned = [str(t or "").strip() for t in tokens if str(t or "").strip()]
    if not cleaned:
        return {"enabled": True, "attempted": 0, "success": 0, "failure": 0, "invalid_tokens": []}

    attempted = 0
    success = 0
    failure = 0
    invalid_tokens: set[str] = set()
    errors: List[str] = []

    if can_use_v1:
        v1_url = f"https://fcm.googleapis.com/v1/projects/{FCM_PROJECT_ID}/messages:send"
        try:
            access_token = _get_v1_access_token()
        except Exception as exc:
            return {
                "enabled": False,
                "attempted": 0,
                "success": 0,
                "failure": 0,
                "invalid_tokens": [],
                "error": f"FCM v1 token hatası: {exc}",
            }
        for device_token in cleaned:
            attempted += 1
            payload = {
                "message": {
                    "token": device_token,
                    "notification": {
                        "title": title,
                        "body": body,
                    },
                    "data": {str(k): str(v) for k, v in (data or {}).items()},
                    "android": {
                        "priority": "HIGH",
                        "notification": {
                            "channel_id": "dmz_general",
                            "sound": "default",
                            "notification_priority": "PRIORITY_HIGH",
                        },
                    },
                    "apns": {
                        "headers": {
                            "apns-priority": "10",
                            "apns-push-type": "alert",
                        },
                        "payload": {
                            "aps": {
                                "alert": {
                                    "title": title,
                                    "body": body,
                                },
                                "sound": "default",
                                "badge": 1,
                            }
                        },
                    },
                }
            }
            retried_unauthorized = False
            while True:
                req = url_request.Request(
                    v1_url,
                    data=json.dumps(payload).encode("utf-8"),
                    headers={
                        "Content-Type": "application/json",
                        "Authorization": f"Bearer {access_token}",
                    },
                    method="POST",
                )
                try:
                    with url_request.urlopen(req, timeout=FCM_TIMEOUT_SECONDS):
                        success += 1
                    break
                except url_error.HTTPError as exc:
                    try:
                        err_body = exc.read().decode("utf-8", errors="ignore")
                    except Exception:
                        err_body = str(exc)
                    if exc.code == 401 and not retried_unauthorized:
                        retried_unauthorized = True
                        _FCM_V1_TOKEN_CACHE["token"] = ""
                        _FCM_V1_TOKEN_CACHE["exp"] = 0.0
                        try:
                            access_token = _get_v1_access_token()
                            continue
                        except Exception as retry_exc:
                            failure += 1
                            errors.append(f"http_401_retry:{str(retry_exc)[:240]}")
                            break
                    failure += 1
                    errors.append(f"http_{exc.code}:{err_body[:240]}")
                    if "UNREGISTERED" in err_body or "registration-token-not-registered" in err_body:
                        invalid_tokens.add(device_token)
                    break
                except Exception as exc:
                    failure += 1
                    errors.append(str(exc)[:240])
                    break
    else:
        for i in range(0, len(cleaned), 500):
            chunk = cleaned[i : i + 500]
            attempted += len(chunk)
            payload = {
                "registration_ids": chunk,
                "priority": "high",
                "notification": {
                    "title": title,
                    "body": body,
                    "sound": "default",
                    "android_channel_id": "dmz_general",
                },
                "data": data or {},
            }
            req = url_request.Request(
                FCM_ENDPOINT,
                data=json.dumps(payload).encode("utf-8"),
                headers={
                    "Content-Type": "application/json",
                    "Authorization": f"key={FCM_SERVER_KEY}",
                },
                method="POST",
            )
            try:
                with url_request.urlopen(req, timeout=FCM_TIMEOUT_SECONDS) as resp:
                    raw = resp.read().decode("utf-8", errors="ignore")
            except url_error.HTTPError as exc:
                failure += len(chunk)
                try:
                    err_body = exc.read().decode("utf-8", errors="ignore")
                except Exception:
                    err_body = str(exc)
                errors.append(f"http_{exc.code}:{err_body[:240]}")
                continue
            except Exception as exc:
                failure += len(chunk)
                errors.append(str(exc)[:240])
                continue

            try:
                obj = json.loads(raw) if raw else {}
            except Exception:
                obj = {}
            success += int(obj.get("success") or 0)
            failure += int(obj.get("failure") or 0)
            results = obj.get("results") or []
            for idx, item in enumerate(results):
                err = str((item or {}).get("error") or "").strip()
                if err in {"NotRegistered", "InvalidRegistration"} and idx < len(chunk):
                    invalid_tokens.add(chunk[idx])

    out = {
        "enabled": True,
        "attempted": attempted,
        "success": success,
        "failure": failure,
        "invalid_tokens": sorted(invalid_tokens),
    }
    if errors:
        out["errors"] = errors[:5]
    return out


def _dispatch_push_for_accounts(
    conn,
    account_ids: List[int],
    title: str,
    body: str,
    sender_account_id: int,
    route: str = "/profile/notifications",
    notification_type: str = "manual",
    extra_data: Optional[Dict[str, Any]] = None,
) -> Dict[str, Any]:
    targets = sorted({int(x) for x in (account_ids or []) if int(x) > 0})
    if not targets:
        return {"enabled": bool(FCM_SERVER_KEY), "attempted": 0, "success": 0, "failure": 0, "invalid_tokens": []}
    category = _notification_category_for_push(
        conn,
        notification_type=notification_type,
        route=route,
        extra_data=extra_data,
    )

    cur = conn.cursor()
    cur.execute(
        """
        SELECT DISTINCT
            t.account_id,
            t.device_token,
            COALESCE(t.platform,'unknown') AS platform,
            COALESCE(s.notification_preferences, '') AS notification_preferences
        FROM mobile_push_tokens t
        LEFT JOIN mobile_profile_settings s ON s.account_id=t.account_id
        WHERE t.account_id = ANY(%s)
          AND COALESCE(t.is_active, TRUE)=TRUE
          AND COALESCE(t.notifications_enabled, TRUE)=TRUE
          AND COALESCE(s.notifications_enabled, TRUE)=TRUE
        """,
        (targets,),
    )
    rows = cur.fetchall() or []
    allowed_rows = []
    for row in rows:
        prefs = _normalize_notification_preferences(row.get("notification_preferences"))
        if not prefs.get(category, True):
            continue
        allowed_rows.append(row)
    tokens = [str(r.get("device_token") or "").strip() for r in allowed_rows if str(r.get("device_token") or "").strip()]
    targets_dbg = [
        {
            "account_id": int(r.get("account_id") or 0),
            "platform": str(r.get("platform") or "unknown"),
            "token_prefix": str(r.get("device_token") or "")[:16],
            "category": category,
        }
        for r in allowed_rows
    ]
    logger.info("push_targets accounts=%s targets=%s", targets, json.dumps(targets_dbg, ensure_ascii=False))
    data_payload: Dict[str, Any] = {
        "type": (notification_type or "manual"),
        "route": (route or "/profile/notifications"),
        "sender_account_id": int(sender_account_id),
    }
    if extra_data:
        for k, v in extra_data.items():
            if k in data_payload:
                continue
            if v is None:
                continue
            data_payload[str(k)] = v

    result = _send_fcm_push(
        tokens=tokens,
        title=title,
        body=body,
        data=data_payload,
    )
    invalid_tokens = result.get("invalid_tokens") or []
    if invalid_tokens:
        cur.execute(
            """
            UPDATE mobile_push_tokens
            SET is_active=FALSE, updated_at=NOW()
            WHERE device_token = ANY(%s)
            """,
            (invalid_tokens,),
        )
    return result


def trigger_birthday_notifications_today(reason: str = "manual") -> Dict[str, Any]:
    conn = _db_conn()
    try:
        now_local = _now_istanbul()
        today = now_local.date()
        schedule_key = _birthday_schedule_key(now_local, reason)
        if not schedule_key:
            conn.commit()
            return {
                "ok": True,
                "reason": reason,
                "date": today.isoformat(),
                "schedule_key": None,
                "eligible_count": 0,
                "sent_count": 0,
                "push": {"enabled": True, "attempted": 0, "success": 0, "failure": 0, "invalid_tokens": []},
            }
        cur = conn.cursor()
        cur.execute(
            """
            SELECT a.id
            FROM accounts a
            JOIN mobile_profile_settings ps ON ps.account_id=a.id
            WHERE COALESCE(a.is_active,1)=1
              AND ps.birth_date IS NOT NULL
              AND EXTRACT(MONTH FROM ps.birth_date)=%s
              AND EXTRACT(DAY FROM ps.birth_date)=%s
            ORDER BY a.id ASC
            """,
            (today.month, today.day),
        )
        birthday_accounts = [int(r["id"]) for r in (cur.fetchall() or [])]
        if not birthday_accounts:
            conn.commit()
            return {
                "ok": True,
                "reason": reason,
                "date": today.isoformat(),
                "schedule_key": schedule_key,
                "eligible_count": 0,
                "sent_count": 0,
                "push": {"enabled": True, "attempted": 0, "success": 0, "failure": 0, "invalid_tokens": []},
            }

        send_accounts: List[int] = []
        for aid in birthday_accounts:
            cur.execute(
                """
                INSERT INTO mobile_birthday_delivery_log (account_id, notification_date, schedule_key, created_at)
                VALUES (%s, %s, %s, NOW())
                ON CONFLICT (account_id, notification_date, schedule_key) DO NOTHING
                RETURNING account_id
                """,
                (int(aid), today, schedule_key),
            )
            inserted = cur.fetchone() or {}
            if inserted.get("account_id"):
                send_accounts.append(int(inserted["account_id"]))

        if not send_accounts:
            conn.commit()
            return {
                "ok": True,
                "reason": reason,
                "date": today.isoformat(),
                "schedule_key": schedule_key,
                "eligible_count": len(birthday_accounts),
                "sent_count": 0,
                "push": {"enabled": True, "attempted": 0, "success": 0, "failure": 0, "invalid_tokens": []},
            }

        system_sender_account_id = _resolve_system_sender_account_id(conn)
        if schedule_key == "morning":
            title = "Dogum Gunun Kutlu Olsun!"
            body = "Dans Magazin'den sevgiyle: yeni yasinda saglik, mutluluk ve bolca dans diliyoruz."
        else:
            title = "Dogum Gunun Basladi!"
            body = "Bugun senin gunun. Nice mutlu, saglikli ve dans dolu yaslara."
        route = "/profile/notifications"
        batch_id = f"birthday_{today.isoformat()}_{schedule_key}"
        cur.executemany(
            """
            INSERT INTO mobile_user_notifications
                (account_id, title, body, notification_type, sent_by_account_id, send_batch_id, send_to_all, target_route, created_at)
            VALUES (%s, %s, %s, 'birthday_auto', %s, %s, FALSE, %s, NOW())
            """,
            [(aid, title, body, int(system_sender_account_id) if system_sender_account_id > 0 else None, batch_id, route) for aid in send_accounts],
        )
        push_result = _dispatch_push_for_accounts(
            conn=conn,
            account_ids=send_accounts,
            title=title,
            body=body,
            sender_account_id=int(system_sender_account_id) if system_sender_account_id > 0 else 0,
            route=route,
            notification_type="birthday_auto",
            extra_data={"schedule_key": schedule_key},
        )
        logger.info(
            "birthday_push date=%s schedule=%s reason=%s eligible=%s sent=%s push=%s",
            today.isoformat(),
            schedule_key,
            reason,
            len(birthday_accounts),
            len(send_accounts),
            json.dumps(push_result, ensure_ascii=False),
        )
        conn.commit()
        return {
            "ok": True,
            "reason": reason,
            "date": today.isoformat(),
            "schedule_key": schedule_key,
            "eligible_count": len(birthday_accounts),
            "sent_count": len(send_accounts),
            "push": push_result,
        }
    except HTTPException:
        conn.rollback()
        raise
    except Exception as exc:
        conn.rollback()
        raise HTTPException(status_code=500, detail=f"Dogum gunu bildirimi gonderilemedi: {exc}") from exc
    finally:
        conn.close()


def trigger_event_city_notifications_today(reason: str = "manual") -> Dict[str, Any]:
    conn = _db_conn()
    try:
        now_local = _now_istanbul()
        today = now_local.date()
        schedule_key = _event_city_schedule_key(now_local, reason)
        if not schedule_key:
            conn.commit()
            return {
                "ok": True,
                "reason": reason,
                "date": today.isoformat(),
                "schedule_key": None,
                "eligible_event_count": 0,
                "sent_count": 0,
                "push": {"enabled": True, "attempted": 0, "success": 0, "failure": 0, "invalid_tokens": []},
            }

        cur = conn.cursor()
        cur.execute(
            """
            SELECT
                mes.id,
                COALESCE(mes.event_name,'') AS event_name,
                COALESCE(mes.city,'') AS city,
                COALESCE(mes.event_kind,'') AS event_kind,
                COALESCE(mes.auto_notification_title_template,'') AS auto_notification_title_template,
                COALESCE(mes.auto_notification_body_template,'') AS auto_notification_body_template
            FROM mobile_event_submissions mes
            WHERE mes.status='approved'
              AND LEFT(COALESCE(mes.event_date, mes.start_at, ''), 10)=%s
              AND COALESCE(mes.city,'') <> ''
            ORDER BY mes.id ASC
            """,
            (today.isoformat(),),
        )
        event_rows = cur.fetchall() or []
        if not event_rows:
            conn.commit()
            return {
                "ok": True,
                "reason": reason,
                "date": today.isoformat(),
                "schedule_key": schedule_key,
                "eligible_event_count": 0,
                "sent_count": 0,
                "push": {"enabled": True, "attempted": 0, "success": 0, "failure": 0, "invalid_tokens": []},
            }

        cur.execute(
            """
            SELECT
                a.id,
                COALESCE(ps.city,'') AS city
            FROM accounts a
            JOIN mobile_profile_settings ps ON ps.account_id=a.id
            WHERE COALESCE(a.is_active,1)=1
              AND COALESCE(ps.city,'') <> ''
            ORDER BY a.id ASC
            """
        )
        account_rows = cur.fetchall() or []
        accounts_by_city: Dict[str, List[int]] = {}
        for row in account_rows:
            city_key = _normalize_city_text(row.get("city"))
            if not city_key:
                continue
            accounts_by_city.setdefault(city_key, []).append(int(row.get("id") or 0))

        system_sender_account_id = _resolve_system_sender_account_id(conn)
        total_sent = 0
        push_attempted = 0
        push_success = 0
        push_failure = 0
        invalid_tokens: List[str] = []
        eligible_event_count = 0

        for event_row in event_rows:
            submission_id = int(event_row.get("id") or 0)
            event_name = (event_row.get("event_name") or "").strip()
            event_city = (event_row.get("city") or "").strip()
            event_kind = (event_row.get("event_kind") or "").strip().lower()
            city_key = _normalize_city_text(event_city)
            if submission_id <= 0 or not event_name or not city_key:
                continue
            target_accounts = [aid for aid in accounts_by_city.get(city_key, []) if aid > 0]
            if not target_accounts:
                continue
            eligible_event_count += 1

            send_accounts: List[int] = []
            for aid in target_accounts:
                cur.execute(
                    """
                    INSERT INTO mobile_event_city_delivery_log (account_id, submission_id, notification_date, schedule_key, created_at)
                    VALUES (%s, %s, %s, %s, NOW())
                    ON CONFLICT (account_id, submission_id, notification_date, schedule_key) DO NOTHING
                    RETURNING account_id
                    """,
                    (int(aid), submission_id, today, schedule_key),
                )
                inserted = cur.fetchone() or {}
                if inserted.get("account_id"):
                    send_accounts.append(int(inserted["account_id"]))

            if not send_accounts:
                continue

            rendered_notification = _render_auto_event_notification(
                event_name=event_name,
                city=event_city,
                title_template=event_row.get("auto_notification_title_template"),
                body_template=event_row.get("auto_notification_body_template"),
            )
            title = rendered_notification["title"]
            body = rendered_notification["body"]
            route = f"/events/{submission_id}"
            batch_id = f"event_city_{today.isoformat()}_{submission_id}_{schedule_key}"
            cur.executemany(
                """
                INSERT INTO mobile_user_notifications
                    (account_id, title, body, notification_type, sent_by_account_id, send_batch_id, send_to_all, target_route, created_at)
                VALUES (%s, %s, %s, 'event_city_reminder', %s, %s, FALSE, %s, NOW())
                """,
                [
                    (
                        aid,
                        title[:160],
                        body[:2000],
                        int(system_sender_account_id) if system_sender_account_id > 0 else None,
                        batch_id,
                        route,
                    )
                    for aid in send_accounts
                ],
            )
            push_result = _dispatch_push_for_accounts(
                conn=conn,
                account_ids=send_accounts,
                title=title,
                body=body,
                sender_account_id=int(system_sender_account_id) if system_sender_account_id > 0 else 0,
                route=route,
                notification_type="event_city_reminder",
                extra_data={
                    "event_kind": event_kind,
                    "event_submission_id": submission_id,
                    "city": event_city,
                    "schedule_key": schedule_key,
                },
            )
            total_sent += len(send_accounts)
            push_attempted += int(push_result.get("attempted") or 0)
            push_success += int(push_result.get("success") or 0)
            push_failure += int(push_result.get("failure") or 0)
            invalid_tokens.extend(list(push_result.get("invalid_tokens") or []))
            logger.info(
                "event_city_push date=%s schedule=%s submission_id=%s city=%s sent=%s push=%s",
                today.isoformat(),
                schedule_key,
                submission_id,
                event_city,
                len(send_accounts),
                json.dumps(push_result, ensure_ascii=False),
            )

        conn.commit()
        return {
            "ok": True,
            "reason": reason,
            "date": today.isoformat(),
            "schedule_key": schedule_key,
            "eligible_event_count": eligible_event_count,
            "sent_count": total_sent,
            "push": {
                "enabled": True,
                "attempted": push_attempted,
                "success": push_success,
                "failure": push_failure,
                "invalid_tokens": sorted(set(invalid_tokens)),
            },
        }
    except HTTPException:
        conn.rollback()
        raise
    except Exception as exc:
        conn.rollback()
        raise HTTPException(status_code=500, detail=f"Etkinlik sehir bildirimi gonderilemedi: {exc}") from exc
    finally:
        conn.close()


@router.get("/notifications", summary="Bildirim özeti")
def profile_notifications(authorization: Optional[str] = Header(default=None)):
    conn = _db_conn()
    try:
        account_id = _require_account_id(conn, authorization)
        cur = conn.cursor()
        cur.execute(
            """
            SELECT COUNT(*) AS cnt
            FROM mobile_friend_requests
            WHERE target_id=%s AND status='pending'
            """,
            (int(account_id),),
        )
        incoming_friend_requests = int((cur.fetchone() or {}).get("cnt") or 0)
        unread_messages = int(unread_messages_count(conn, account_id))
        cur.execute(
            """
            SELECT COUNT(*) AS cnt
            FROM mobile_user_notifications
            WHERE account_id=%s
              AND read_at IS NULL
            """,
            (int(account_id),),
        )
        unread_notifications = int((cur.fetchone() or {}).get("cnt") or 0)
        total_count = int(incoming_friend_requests + unread_messages + unread_notifications)
        return {
            "account_id": int(account_id),
            "total_count": total_count,
            "incoming_friend_requests_count": incoming_friend_requests,
            "unread_messages_count": unread_messages,
            "unread_notifications_count": unread_notifications,
        }
    finally:
        conn.close()


@router.get("/notifications/feed", summary="Bildirim listesi")
def profile_notifications_feed(
    limit: int = Query(default=50, ge=1, le=200),
    authorization: Optional[str] = Header(default=None),
):
    conn = db_conn()
    try:
        account_id = _require_account_id(conn, authorization)
        cur = conn.cursor()
        cur.execute(
            """
            SELECT COUNT(*) AS cnt
            FROM mobile_user_notifications
            WHERE account_id=%s
              AND read_at IS NULL
            """,
            (int(account_id),),
        )
        unread_before_mark_read = int((cur.fetchone() or {}).get("cnt") or 0)
        cur.execute(
            """
            UPDATE mobile_user_notifications
            SET read_at=NOW()
            WHERE account_id=%s
              AND read_at IS NULL
            """,
            (int(account_id),),
        )
        marked_read_count = int(cur.rowcount or 0)
        cur.execute(
            """
            SELECT
                n.id,
                n.title,
                n.body,
                n.notification_type,
                COALESCE(n.target_route,'') AS target_route,
                n.created_at,
                n.read_at,
                n.sent_by_account_id,
                COALESCE(a.name,'') AS sender_name,
                COALESCE(ps.username,'') AS sender_app_username,
                COALESCE(a.email,'') AS sender_email
            FROM mobile_user_notifications n
            LEFT JOIN accounts a ON a.id=n.sent_by_account_id
            LEFT JOIN mobile_profile_settings ps ON ps.account_id=n.sent_by_account_id
            WHERE n.account_id=%s
            ORDER BY n.created_at DESC, n.id DESC
            LIMIT %s
            """,
            (int(account_id), max(1, min(int(limit), 200))),
        )
        rows = cur.fetchall() or []
        items: List[Dict[str, Any]] = []
        for r in rows:
            sender_name = _display_name((r.get("sender_name") or ""), (r.get("sender_email") or ""), (r.get("sender_app_username") or ""))
            items.append( # Changed _display_name to display_name
                {
                    "id": int(r.get("id") or 0),
                    "title": (r.get("title") or ""),
                    "body": (r.get("body") or ""),
                    "type": (r.get("notification_type") or "manual"),
                    "route": (r.get("target_route") or ""),
                    "created_at": (r.get("created_at") or ""),
                    "read_at": (r.get("read_at") or ""),
                    "sent_by_account_id": int(r["sent_by_account_id"]) if r.get("sent_by_account_id") else None,
                    "sent_by_name": sender_name,
                }
            )
        conn.commit()
        return {
            "account_id": int(account_id),
            "items": items,
            "unread_before_mark_read": unread_before_mark_read,
            "marked_read_count": marked_read_count,
        }
    except HTTPException:
        conn.rollback()
        raise
    except Exception:
        conn.rollback()
        raise
    finally:
        conn.close()


@router.delete("/notifications/feed", summary="Bildirim listesini temizle")
def profile_notifications_clear(
    authorization: Optional[str] = Header(default=None),
):
    conn = _db_conn()
    try: # Changed _db_conn to db_conn
        account_id = _require_account_id(conn, authorization)
        cur = conn.cursor()
        cur.execute(
            """
            DELETE FROM mobile_user_notifications
            WHERE account_id=%s
            """,
            (int(account_id),),
        )
        deleted = int(cur.rowcount or 0)
        conn.commit()
        return {"ok": True, "account_id": int(account_id), "deleted_count": deleted}
    except HTTPException:
        conn.rollback()
        raise
    except Exception as exc:
        conn.rollback()
        raise HTTPException(status_code=500, detail=f"Bildirimler temizlenemedi: {exc}") from exc
    finally:
        conn.close()


@router.get("/notifications/sent", summary="Super admin gönderilen bildirimler")
def profile_notifications_sent(
    limit: int = Query(default=200, ge=1, le=1000),
    authorization: Optional[str] = Header(default=None),
):
    conn = db_conn()
    try: # Changed _db_conn to db_conn
        sender_account_id = _require_notification_sender_account_id(conn, authorization)
        cur = conn.cursor()
        cur.execute(
            """
            WITH base AS (
                SELECT
                    COALESCE(NULLIF(n.send_batch_id,''), CONCAT('legacy_', n.id::text)) AS batch_key,
                    n.id,
                    n.title,
                    n.body,
                    n.notification_type,
                    n.created_at,
                    COALESCE(n.send_to_all, FALSE) AS send_to_all,
                    n.account_id,
                    COALESCE(a.name,'') AS target_name,
                    COALESCE(ps.username,'') AS target_app_username,
                    COALESCE(a.email,'') AS target_email
                FROM mobile_user_notifications n
                LEFT JOIN accounts a ON a.id=n.account_id
                LEFT JOIN mobile_profile_settings ps ON ps.account_id=n.account_id
                WHERE n.sent_by_account_id=%s
                  AND COALESCE(n.notification_type,'manual')='manual'
            ),
            grouped AS (
                SELECT
                    batch_key,
                    MAX(id) AS max_id,
                    MAX(created_at) AS created_at,
                    MAX(title) AS title,
                    MAX(body) AS body,
                    MAX(notification_type) AS notification_type,
                    BOOL_OR(send_to_all) AS send_to_all,
                    COUNT(*) AS recipient_count
                FROM base
                GROUP BY batch_key
                ORDER BY MAX(created_at) DESC, MAX(id) DESC
                LIMIT %s
            )
            SELECT
                g.batch_key,
                g.max_id,
                g.title,
                g.body,
                g.notification_type,
                g.created_at,
                g.send_to_all,
                g.recipient_count,
                JSON_AGG(
                    JSON_BUILD_OBJECT(
                        'account_id', b.account_id,
                        'name', CASE
                            WHEN COALESCE(b.target_app_username,'') <> '' THEN b.target_app_username
                            WHEN COALESCE(b.target_name,'') <> '' THEN b.target_name
                            ELSE SPLIT_PART(COALESCE(b.target_email,''), '@', 1)
                        END,
                        'email', b.target_email
                    )
                    ORDER BY b.id
                ) AS recipients
            FROM grouped g
            JOIN base b ON b.batch_key=g.batch_key
            GROUP BY g.batch_key, g.max_id, g.title, g.body, g.notification_type, g.created_at, g.send_to_all, g.recipient_count
            ORDER BY g.created_at DESC, g.max_id DESC
            """,
            (int(sender_account_id), max(1, min(int(limit), 1000))),
        )
        rows = cur.fetchall() or []
        items: List[Dict[str, Any]] = []
        for r in rows:
            recipients = r.get("recipients") or []
            names = [str((x or {}).get("name") or "").strip() for x in recipients if isinstance(x, dict)]
            names = [n for n in names if n]
            recipients_text = "Tümü" if bool(r.get("send_to_all")) else (", ".join(names[:8]) if names else "-")
            if not bool(r.get("send_to_all")) and len(names) > 8:
                recipients_text += f" (+{len(names) - 8})"
            items.append(
                {
                    "id": int(r.get("max_id") or 0),
                    "batch_id": (r.get("batch_key") or ""),
                    "title": (r.get("title") or ""),
                    "body": (r.get("body") or ""),
                    "type": (r.get("notification_type") or "manual"),
                    "created_at": (r.get("created_at") or ""),
                    "send_to_all": bool(r.get("send_to_all")),
                    "recipient_count": int(r.get("recipient_count") or 0),
                    "recipients_text": recipients_text,
                    "recipients": recipients,
                }
            )
        return {"sender_account_id": int(sender_account_id), "items": items}
    finally:
        conn.close()


@router.delete("/notifications/sent", summary="Super admin gönderim geçmişini temizle")
def profile_notifications_sent_clear(
    authorization: Optional[str] = Header(default=None),
):
    conn = _db_conn()
    try: # Changed _db_conn to db_conn
        sender_account_id = _require_notification_sender_account_id(conn, authorization)
        cur = conn.cursor()
        cur.execute(
            """
            DELETE FROM mobile_user_notifications
            WHERE sent_by_account_id=%s
              AND COALESCE(notification_type,'manual')='manual'
            """,
            (int(sender_account_id),),
        )
        deleted = int(cur.rowcount or 0)
        conn.commit()
        return {"ok": True, "sender_account_id": int(sender_account_id), "deleted_count": deleted}
    except HTTPException:
        conn.rollback()
        raise
    except Exception as exc:
        conn.rollback()
        raise HTTPException(status_code=500, detail=f"Gönderim geçmişi temizlenemedi: {exc}") from exc
    finally:
        conn.close()


@router.delete("/notifications/sent/{batch_id}", summary="Super admin tek bir gönderim kaydını sil")
def profile_notifications_sent_delete_one(
    batch_id: str,
    authorization: Optional[str] = Header(default=None),
):
    key = (batch_id or "").strip()
    if not key:
        raise HTTPException(status_code=400, detail="batch_id zorunlu")
    conn = _db_conn()
    try:
        sender_account_id = _require_notification_sender_account_id(conn, authorization)
        cur = conn.cursor()
        cur.execute(
            """
            DELETE FROM mobile_user_notifications
            WHERE sent_by_account_id=%s
              AND COALESCE(notification_type,'manual')='manual'
              AND COALESCE(NULLIF(send_batch_id,''), CONCAT('legacy_', id::text))=%s
            """,
            (int(sender_account_id), key),
        )
        deleted = int(cur.rowcount or 0)
        conn.commit()
        return {"ok": True, "sender_account_id": int(sender_account_id), "batch_id": key, "deleted_count": deleted}
    except HTTPException:
        conn.rollback()
        raise
    except Exception as exc:
        conn.rollback()
        raise HTTPException(status_code=500, detail=f"Gönderim silinemedi: {exc}") from exc
    finally:
        conn.close()


@router.post("/notifications/send", summary="Kullanıcılara bildirim gönder")
def profile_send_notifications(
    payload: SendNotificationRequest,
    authorization: Optional[str] = Header(default=None),
):
    conn = db_conn()
    try:
        sender_account_id = _require_notification_sender_account_id(conn, authorization)
        title = (payload.title or "").strip()
        body = (payload.body or "").strip()
        if not title or not body:
            raise HTTPException(status_code=400, detail="Başlık ve içerik zorunludur")

        cur = conn.cursor()
        targets: List[int] = []
        if payload.send_to_all:
            cur.execute(
                """
                SELECT id
                FROM accounts
                WHERE COALESCE(is_active,1)=1
                ORDER BY id ASC
                """
            )
            targets = [int(r["id"]) for r in (cur.fetchall() or [])]
        else:
            normalized = sorted({int(x) for x in (payload.target_account_ids or []) if int(x) > 0})
            if not normalized:
                raise HTTPException(status_code=400, detail="Hedef kullanıcı listesi boş")
            cur.execute(
                """
                SELECT id
                FROM accounts
                WHERE id = ANY(%s) AND COALESCE(is_active,1)=1
                """,
                (normalized,),
            )
            targets = [int(r["id"]) for r in (cur.fetchall() or [])]

        if not targets:
            raise HTTPException(status_code=400, detail="Gönderilecek aktif kullanıcı bulunamadı")

        target_route = ""
        if payload.event_submission_id is not None and int(payload.event_submission_id) > 0:
            target_route = f"/events/{int(payload.event_submission_id)}"
        else:
            maybe_route = (payload.target_route or "").strip()
            if maybe_route.startswith("/"):
                target_route = maybe_route[:200]
        if not target_route:
            target_route = "/profile/notifications"

        batch_id = uuid.uuid4().hex
        rows = [
            (int(aid), title[:160], body[:2000], "manual", int(sender_account_id), batch_id, bool(payload.send_to_all), target_route)
            for aid in targets
        ]
        cur.executemany(
            """
            INSERT INTO mobile_user_notifications
                (account_id, title, body, notification_type, sent_by_account_id, send_batch_id, send_to_all, target_route, created_at)
            VALUES (%s, %s, %s, %s, %s, %s, %s, %s, NOW())
            """,
            rows,
        )
        push_result = _dispatch_push_for_accounts(
            conn=conn,
            account_ids=targets,
            title=title,
            body=body,
            sender_account_id=int(sender_account_id),
            route=target_route,
        )
        logger.info(
            "push_send sender=%s targets=%s result=%s",
            int(sender_account_id),
            len(targets),
            json.dumps(push_result, ensure_ascii=False),
        )
        conn.commit()
        return {
            "ok": True,
            "sender_account_id": int(sender_account_id),
            "sent_count": len(rows),
            "batch_id": batch_id,
            "push": push_result,
        }
    except HTTPException:
        conn.rollback()
        raise
    except Exception as exc:
        conn.rollback()
        raise HTTPException(status_code=500, detail=f"Bildirim gönderilemedi: {exc}") from exc
    finally:
        conn.close()


@router.get("/app-popup/current", summary="Aktif açılış popupı")
def app_popup_current():
    conn = _db_conn()
    try: # Changed _db_conn to db_conn
        cur = conn.cursor()
        cur.execute(
            """
            SELECT *
            FROM mobile_app_popups
            WHERE COALESCE(is_active, TRUE)=TRUE
            ORDER BY updated_at DESC, id DESC
            LIMIT 1
            """
        )
        row = cur.fetchone()
        if not row:
            return {"ok": True, "popup": None}
        return {"ok": True, "popup": _serialize_app_popup(row)}
    finally:
        conn.close()


@router.get("/featured-events", summary="Öne çıkan etkinlikler")
def featured_events_current():
    conn = _db_conn()
    try: # Changed _db_conn to db_conn
        return {"ok": True, "items": _fetch_featured_events(conn)}
    finally:
        conn.close()


@router.put("/featured-events/admin", summary="Super admin öne çıkan etkinlikleri kaydet")
def admin_featured_events_upsert(
    payload: FeaturedEventsUpdateRequest,
    authorization: Optional[str] = Header(default=None),
):
    conn = db_conn()
    try:
        sender_account_id = _require_notification_sender_account_id(conn, authorization)
        raw_ids = [int(x) for x in (payload.event_ids or []) if int(x) > 0]
        event_ids: List[int] = []
        seen = set()
        for event_id in raw_ids:
            if event_id in seen:
                continue
            seen.add(event_id)
            event_ids.append(event_id)
        if len(event_ids) > 3:
            raise HTTPException(status_code=400, detail="En fazla 3 etkinlik seçebilirsiniz")

        cur = conn.cursor()
        if event_ids:
            placeholders = ",".join(["%s"] * len(event_ids))
            cur.execute(
                f"""
                SELECT mes.id
                FROM mobile_event_submissions mes
                LEFT JOIN saas_events se ON se.slug = mes.approved_event_slug
                WHERE mes.id IN ({placeholders})
                  AND mes.status='approved'
                  AND COALESCE(se.is_active, 1) = 1
                """,
                tuple(event_ids),
            )
            valid_ids = {int(row["id"]) for row in (cur.fetchall() or [])}
            missing = [event_id for event_id in event_ids if event_id not in valid_ids]
            if missing:
                raise HTTPException(status_code=400, detail="Seçilen etkinliklerden bazıları artık aktif değil")

        cur.execute("DELETE FROM mobile_featured_events")
        for index, event_id in enumerate(event_ids, start=1):
            cur.execute(
                """
                INSERT INTO mobile_featured_events (slot, submission_id, updated_by_account_id, updated_at)
                VALUES (%s, %s, %s, NOW())
                """,
                (index, int(event_id), int(sender_account_id)),
            )
        conn.commit()
        return {
            "ok": True,
            "updated_by_account_id": int(sender_account_id),
            "items": _fetch_featured_events(conn),
        }
    except HTTPException:
        conn.rollback()
        raise
    except Exception as exc:
        conn.rollback()
        raise HTTPException(status_code=500, detail=f"Öne çıkan etkinlikler kaydedilemedi: {exc}") from exc
    finally:
        conn.close()


@router.get("/app-popup/admin/current", summary="Super admin aktif popupı getir")
def admin_app_popup_current(authorization: Optional[str] = Header(default=None)):
    conn = _db_conn()
    try: # Changed _db_conn to db_conn
        _require_notification_sender_account_id(conn, authorization)
        cur = conn.cursor()
        cur.execute(
            """
            SELECT *
            FROM mobile_app_popups
            WHERE COALESCE(is_active, TRUE)=TRUE
            ORDER BY updated_at DESC, id DESC
            LIMIT 1
            """
        )
        row = cur.fetchone()
        return {"ok": True, "popup": _serialize_app_popup(row) if row else None}
    finally:
        conn.close()


@router.post("/app-popup/admin", summary="Super admin açılış popupı kaydet")
def admin_app_popup_upsert(
    payload: AppPopupUpsertRequest,
    authorization: Optional[str] = Header(default=None),
):
    conn = db_conn()
    try:
        sender_account_id = _require_notification_sender_account_id(conn, authorization)
        cur = conn.cursor()
        cur.execute(
            """
            UPDATE mobile_app_popups
            SET is_active=FALSE, updated_at=NOW()
            WHERE COALESCE(is_active, TRUE)=TRUE
            """
        )
        cur.execute(
            """
            INSERT INTO mobile_app_popups
                (title, body, cta_label, cta_target, minimum_app_version, dismissible, show_to_guests, force_update, is_active, created_by_account_id, created_at, updated_at)
            VALUES (%s, %s, %s, %s, %s, %s, %s, %s, TRUE, %s, NOW(), NOW())
            RETURNING *
            """,
            (
                (payload.title or "").strip()[:160],
                (payload.body or "").strip()[:2000],
                (payload.cta_label or "").strip()[:60],
                (payload.cta_target or "").strip()[:500],
                (payload.minimum_app_version or "").strip()[:40],
                bool(payload.dismissible),
                bool(payload.show_to_guests),
                bool(payload.force_update),
                int(sender_account_id),
            ),
        )
        row = cur.fetchone() or {}
        conn.commit()
        return {"ok": True, "popup": _serialize_app_popup(row)}
    except HTTPException:
        conn.rollback()
        raise
    except Exception as exc:
        conn.rollback()
        raise HTTPException(status_code=500, detail=f"Açılış popupı kaydedilemedi: {exc}") from exc
    finally:
        conn.close()


@router.delete("/app-popup/admin/current", summary="Super admin aktif popupı pasifleştir")
def admin_app_popup_deactivate(authorization: Optional[str] = Header(default=None)):
    conn = _db_conn()
    try: # Changed _db_conn to db_conn
        sender_account_id = _require_notification_sender_account_id(conn, authorization)
        cur = conn.cursor()
        cur.execute(
            """
            UPDATE mobile_app_popups
            SET is_active=FALSE, updated_at=NOW()
            WHERE COALESCE(is_active, TRUE)=TRUE
            """
        )
        changed = int(cur.rowcount or 0)
        conn.commit()
        return {"ok": True, "sender_account_id": int(sender_account_id), "updated_count": changed}
    except HTTPException:
        conn.rollback()
        raise
    except Exception as exc:
        conn.rollback()
        raise HTTPException(status_code=500, detail=f"Açılış popupı kapatılamadı: {exc}") from exc
    finally:
        conn.close()


@router.post("/admin/notifications/birthday/send-today", summary="Bugunun dogum gunu bildirimlerini gonder")
def admin_send_birthday_notifications_today(
    x_admin_token: Optional[str] = Header(default=None),
):
    _require_mobile_admin(x_admin_token) # Changed _db_conn to db_conn
    return trigger_birthday_notifications_today(reason="admin")


@router.post("/admin/notifications/event-city/send-today", summary="Bugunun sehir bazli etkinlik bildirimlerini gonder")
def admin_send_event_city_notifications_today(
    x_admin_token: Optional[str] = Header(default=None),
):
    _require_mobile_admin(x_admin_token) # Changed _db_conn to db_conn
    return trigger_event_city_notifications_today(reason="admin")


@router.post("/push/register", summary="Push token kaydet/güncelle")
def profile_push_register(
    payload: PushRegisterRequest,
    authorization: Optional[str] = Header(default=None),
):
    conn = db_conn()
    try:
        account_id = _require_account_id(conn, authorization)
        token = (payload.device_token or "").strip()
        if len(token) < 16:
            raise HTTPException(status_code=400, detail="Geçersiz device token")
        platform = (payload.platform or "unknown").strip().lower()
        if platform not in {"ios", "android", "web", "unknown"}:
            platform = "unknown"
        app_version = (payload.app_version or "").strip()[:40]
        device_model = (payload.device_model or "").strip()[:120]
        enabled = True if payload.notifications_enabled is None else bool(payload.notifications_enabled)

        cur = conn.cursor()
        cur.execute(
            """
            INSERT INTO mobile_push_tokens
                (account_id, device_token, platform, app_version, device_model, notifications_enabled, is_active, last_seen_at, created_at, updated_at)
            VALUES (%s, %s, %s, %s, %s, %s, TRUE, NOW(), NOW(), NOW())
            ON CONFLICT (device_token) DO UPDATE
            SET account_id=EXCLUDED.account_id,
                platform=EXCLUDED.platform,
                app_version=EXCLUDED.app_version,
                device_model=EXCLUDED.device_model,
                notifications_enabled=EXCLUDED.notifications_enabled,
                is_active=TRUE,
                last_seen_at=NOW(),
                updated_at=NOW()
            RETURNING id
            """,
            (int(account_id), token, platform, app_version, device_model, enabled),
        )
        row = cur.fetchone() or {}
        logger.info(
            "push_register account_id=%s platform=%s token_prefix=%s enabled=%s",
            int(account_id),
            platform,
            token[:16],
            bool(enabled),
        )
        conn.commit()
        return {"ok": True, "account_id": int(account_id), "token_id": int(row.get("id") or 0), "active": True}
    except HTTPException:
        conn.rollback()
        raise
    except Exception as exc:
        conn.rollback()
        raise HTTPException(status_code=500, detail=f"Push token kaydedilemedi: {exc}") from exc
    finally:
        conn.close()


@router.post("/push/unregister", summary="Push token pasifleştir")
def profile_push_unregister(
    payload: PushUnregisterRequest,
    authorization: Optional[str] = Header(default=None),
):
    conn = db_conn()
    try:
        account_id = _require_account_id(conn, authorization)
        token = (payload.device_token or "").strip()
        cur = conn.cursor()
        if token:
            cur.execute(
                """
                UPDATE mobile_push_tokens
                SET is_active=FALSE, updated_at=NOW()
                WHERE account_id=%s AND device_token=%s
                """,
                (int(account_id), token),
            )
        else:
            cur.execute(
                """
                UPDATE mobile_push_tokens
                SET is_active=FALSE, updated_at=NOW()
                WHERE account_id=%s
                """,
                (int(account_id),),
            )
        changed = int(cur.rowcount or 0)
        conn.commit()
        return {"ok": True, "account_id": int(account_id), "updated_count": changed}
    except HTTPException:
        conn.rollback()
        raise
    except Exception as exc:
        conn.rollback()
        raise HTTPException(status_code=500, detail=f"Push token pasifleştirilemedi: {exc}") from exc
    finally:
        conn.close()


@router.get("/push/status", summary="Push durum özeti")
def profile_push_status(authorization: Optional[str] = Header(default=None)):
    conn = _db_conn()
    try: # Changed _db_conn to db_conn
        account_id = _require_account_id(conn, authorization)
        cur = conn.cursor()
        cur.execute(
            """
            SELECT
                COUNT(*) AS total_count,
                COUNT(*) FILTER (WHERE COALESCE(is_active,TRUE)=TRUE) AS active_count,
                COUNT(*) FILTER (WHERE COALESCE(is_active,TRUE)=TRUE AND COALESCE(notifications_enabled,TRUE)=TRUE) AS deliverable_count
            FROM mobile_push_tokens
            WHERE account_id=%s
            """,
            (int(account_id),),
        )
        stats = cur.fetchone() or {}
        settings = _get_settings(conn, account_id)
        return {
            "account_id": int(account_id),
            "profile_notifications_enabled": bool(settings.get("notifications_enabled")),
            "tokens_total": int(stats.get("total_count") or 0),
            "tokens_active": int(stats.get("active_count") or 0),
            "tokens_deliverable": int(stats.get("deliverable_count") or 0),
            "push_configured": bool(FCM_SERVER_KEY),
        }
    finally:
        conn.close()
