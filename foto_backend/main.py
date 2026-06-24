import os
import uuid
import sqlite3
import base64
import secrets
import time
import shutil
import hmac
import hashlib
import threading
import json
import mimetypes
import re
import urllib.request
import urllib.error
import urllib.parse
import html as html_lib
from datetime import datetime, timedelta, timezone
from typing import List, Optional, Dict, Any

from io import BytesIO
from PIL import Image, ImageOps, UnidentifiedImageError
from zoneinfo import ZoneInfo

DATABASE_URL = os.getenv("DATABASE_URL", "").strip()
if not DATABASE_URL:
    raise RuntimeError("DATABASE_URL gerekli (PostgreSQL zorunlu).")
USE_POSTGRES = True
if USE_POSTGRES:
    import psycopg2
    import psycopg2.extras
HAS_PGVECTOR = False

try:
    from pillow_heif import register_heif_opener  # type: ignore
    register_heif_opener()
    HEIF_ENABLED = True
except Exception:
    HEIF_ENABLED = False

import qrcode

import ssl
import smtplib
from email.message import EmailMessage
from email.utils import parseaddr

from fastapi import FastAPI, Form, UploadFile, File, Request, HTTPException
from fastapi.responses import HTMLResponse, RedirectResponse, FileResponse
from fastapi.staticfiles import StaticFiles
from fastapi.templating import Jinja2Templates


# =========================
# AYARLAR
# =========================

ROOT_DIR = os.path.dirname(os.path.abspath(__file__))
DB_PATH = os.path.join(ROOT_DIR, "database.db")

PUBLIC_BASE_URL = os.getenv("PUBLIC_BASE_URL", "https://foto.dansmagazin.net").rstrip("/")
BASE_GALLERY_URL = f"{PUBLIC_BASE_URL}/gallery/"
EXTERNAL_CAMERA_URL = os.getenv("EXTERNAL_CAMERA_URL", "https://pixcloud.ai/event/MRD692/camera").strip()

MEDIA_DIR = os.path.join(ROOT_DIR, "media")
SELFIE_DIR = os.path.join(MEDIA_DIR, "selfies")
EVENT_PHOTO_DIR = os.path.join(MEDIA_DIR, "event_photos")
QR_DIR = os.path.join(MEDIA_DIR, "qr")
LOG_DIR = os.path.join(MEDIA_DIR, "logs")
AVATAR_DIR = os.path.join(MEDIA_DIR, "avatars")
FRAME_DIR = os.path.join(MEDIA_DIR, "frames")
THUMB_DIR = os.path.join(MEDIA_DIR, "_thumbs")

os.makedirs(SELFIE_DIR, exist_ok=True)
os.makedirs(EVENT_PHOTO_DIR, exist_ok=True)
os.makedirs(QR_DIR, exist_ok=True)
os.makedirs(LOG_DIR, exist_ok=True)
os.makedirs(AVATAR_DIR, exist_ok=True)
os.makedirs(FRAME_DIR, exist_ok=True)
os.makedirs(THUMB_DIR, exist_ok=True)

FRAME_KIND_META = {
    "ratio_1_1": {"label": "1:1 Kare", "filename": "ratio_1_1.png", "ratio": 1.0},
    "ratio_3_2": {"label": "3:2 Yatay", "filename": "ratio_3_2.png", "ratio": 3.0 / 2.0},
    "ratio_2_3": {"label": "2:3 Dikey", "filename": "ratio_2_3.png", "ratio": 2.0 / 3.0},
    "ratio_3_4": {"label": "3:4 Dikey", "filename": "ratio_3_4.png", "ratio": 3.0 / 4.0},
    "ratio_4_3": {"label": "4:3 Yatay", "filename": "ratio_4_3.png", "ratio": 4.0 / 3.0},
}

EMAIL_ENABLED = os.getenv("EMAIL_ENABLED", "1") not in ("0", "false", "False")
FACE_MATCHING_ENABLED = False

MATCH_ACTIONS = {
    "upload_only",
    "console_upload_only",
}
JOB_RUNNER_INTERVAL = float(os.getenv("JOB_RUNNER_INTERVAL", "2.0"))
MAX_CONCURRENT_MATCH = int(os.getenv("MAX_CONCURRENT_MATCH", "1"))
JOB_STALE_SECONDS = int(os.getenv("JOB_STALE_SECONDS", "180"))
AUTO_DDL_ON_STARTUP = os.getenv("AUTO_DDL_ON_STARTUP", "0").strip().lower() in ("1", "true", "yes")

SMTP_SERVER = os.getenv("SMTP_SERVER", "mail.kurumsaleposta.com")
SMTP_PORT = int(os.getenv("SMTP_PORT", "587"))
EMAIL_USERNAME = os.getenv("EMAIL_USERNAME", "")
EMAIL_PASSWORD = os.getenv("EMAIL_PASSWORD", "")
EMAIL_FROM = os.getenv("EMAIL_FROM", "Dans Magazin <foto@dansmagazin.net>")
SMTP_LOGIN_USERNAME = EMAIL_USERNAME or parseaddr(EMAIL_FROM)[1]

SESSION_COOKIE = "session_token"
MOBILE_BACKEND_BASE = (os.getenv("MOBILE_BACKEND_BASE", "https://api2.dansmagazin.net") or "").strip().rstrip("/")
MOBILE_BACKEND_ADMIN_TOKEN = (os.getenv("MOBILE_ADMIN_TOKEN", "") or "").strip()
AUTO_EVENT_NOTIFICATION_DEFAULT_TITLE = "Bu akşam: {event_name}"
AUTO_EVENT_NOTIFICATION_DEFAULT_BODY = "{event_name} bu akşam başlıyor. Programı incele, geç kalmadan yerini al."
WP_SYNC_MIN_INTERVAL_SEC = int(os.getenv("WP_SYNC_MIN_INTERVAL_SEC", "120"))
WP_SYNC_ADMIN_USERNAME = (os.getenv("WP_SYNC_ADMIN_USERNAME", "") or os.getenv("SUPERADMIN_EMAIL", "") or "").strip()
WP_SYNC_ADMIN_PASSWORD = (os.getenv("WP_SYNC_ADMIN_PASSWORD", "") or os.getenv("SUPERADMIN_PASSWORD", "") or "").strip()
_WP_SYNC_SUPERADMIN_EMAILS_RAW = (
    os.getenv("WP_SYNC_SUPERADMIN_EMAILS", "")
    or os.getenv("SUPERADMIN_EMAIL", "")
    or ""
).strip()
WP_SYNC_SUPERADMIN_EMAILS = {
    x.strip().lower()
    for x in _WP_SYNC_SUPERADMIN_EMAILS_RAW.split(",")
    if x and x.strip()
}

# Upload limits
ALLOWED_IMAGE_MIME = {
    "image/jpeg",
    "image/png",
    "image/webp",
    "image/heic",
    "image/heif",
    "image/heic-sequence",
    "image/heif-sequence",
}
ALLOWED_IMAGE_FORMATS = {"JPEG", "PNG", "WEBP", "HEIC", "HEIF"}
IMAGE_MAX_BYTES = int(os.getenv("IMAGE_MAX_BYTES", str(20 * 1024 * 1024)))
SELFIE_MAX_BYTES = int(os.getenv("SELFIE_MAX_BYTES", str(5 * 1024 * 1024)))
SELFIE_FACE_RATIO_MIN = float(os.getenv("SELFIE_FACE_RATIO_MIN", "0.05"))
SELFIE_FACE_RATIO_MAX = float(os.getenv("SELFIE_FACE_RATIO_MAX", "0.80"))
SELFIE_REQUIRE_SINGLE_FACE = os.getenv("SELFIE_REQUIRE_SINGLE_FACE", "0").strip().lower() not in ("0", "false", "no")
SELFIE_STRICT_GEOMETRY = os.getenv("SELFIE_STRICT_GEOMETRY", "0").strip().lower() not in ("0", "false", "no")
FRAME_MAX_BYTES = int(os.getenv("FRAME_MAX_BYTES", str(5 * 1024 * 1024)))
EVENT_TARGET_KB = int(os.getenv("EVENT_TARGET_KB", "500"))
EVENT_MAX_SIDE = int(os.getenv("EVENT_MAX_SIDE", "2400"))
UPLOAD_BATCH_MAX_FILES = int(os.getenv("UPLOAD_BATCH_MAX_FILES", "100"))
CSRF_COOKIE = "csrf_token"
CSRF_PARAM = "csrf_token"
CSRF_MAX_AGE = 60 * 60 * 24 * 7
CSRF_COOKIE_SECURE = os.getenv("CSRF_COOKIE_SECURE", "1") not in ("0", "false", "False")


# =========================
# APP + TEMPLATES + STATIC
# =========================

app = FastAPI()
templates = Jinja2Templates(directory=os.path.join(ROOT_DIR, "templates"))

_WP_SYNC_LOCK = threading.Lock()
_WP_SYNC_LAST_TS = 0.0
_WP_SYNC_LAST_STATS: Dict[str, Any] = {}
_WP_SYNC_LAST_ERR = ""


def fmt_dt(value: Any) -> str:
    if value is None:
        return "-"
    s = str(value).strip()
    if not s:
        return "-"
    try:
        local_tz = ZoneInfo(APP_TIMEZONE)
    except Exception:
        local_tz = timezone.utc

    try:
        norm = s
        if norm.endswith("Z"):
            norm = norm[:-1] + "+00:00"
        dt = datetime.fromisoformat(norm)
        if dt.tzinfo is None:
            dt = dt.replace(tzinfo=local_tz)
        else:
            dt = dt.astimezone(local_tz)
        return dt.strftime("%d.%m.%y  %H.%M")
    except Exception:
        try:
            rough = s.replace("T", " ").split("+")[0].split(".")[0]
            dt = datetime.strptime(rough, "%Y-%m-%d %H:%M:%S")
            return dt.strftime("%d.%m.%y  %H.%M")
        except Exception:
            return s


templates.env.filters["fmt_dt"] = fmt_dt


def _parse_submission_event_dt(value: Any) -> Optional[datetime]:
    s = str(value or "").strip()
    if not s:
        return None
    normalized = s.replace("T", " ")
    if normalized.endswith("Z"):
        normalized = normalized[:-1]
    try:
        dt = datetime.fromisoformat(normalized)
        return dt.replace(tzinfo=None)
    except Exception:
        pass
    for fmt in ("%Y-%m-%d %H:%M:%S", "%Y-%m-%d", "%d.%m.%Y", "%d-%m-%Y"):
        try:
            return datetime.strptime(normalized, fmt)
        except Exception:
            pass
    return None


def _boolish(value: Any, default: bool = False) -> bool:
    if value is None:
        return default
    if isinstance(value, bool):
        return value
    text = str(value).strip().lower()
    if not text:
        return default
    return text in ("1", "true", "yes", "on")


def _submission_is_past(row: Dict[str, Any]) -> bool:
    candidate = (
        (row.get("end_at") or "").strip()
        or (row.get("start_at") or "").strip()
        or (row.get("event_date") or "").strip()
    )
    dt = _parse_submission_event_dt(candidate)
    if dt is None:
        return False
    if len(candidate) <= 10:
        dt = dt.replace(hour=23, minute=59, second=59, microsecond=0)
    return dt < datetime.now()


def create_woo_draft_event_product(
    event_name: str,
    description: str = "",
    start_at: str = "",
    end_at: str = "",
    entry_fee: Any = 0,
    cover_path: str = "",
) -> Dict[str, Any]:
    """
    WooCommerce'da satışa açık ürün (bilet) oluşturur.
    Env:
      - WOO_BASE_URL (örn: https://www.dansmagazin.net)
      - WOO_CONSUMER_KEY
      - WOO_CONSUMER_SECRET
      - WOO_EVENT_CATEGORY_ID (opsiyonel)
    """
    base = (os.getenv("WOO_BASE_URL", "") or "").strip().rstrip("/")
    ck = (os.getenv("WOO_CONSUMER_KEY", "") or "").strip()
    cs = (os.getenv("WOO_CONSUMER_SECRET", "") or "").strip()
    cat_id_raw = (os.getenv("WOO_EVENT_CATEGORY_ID", "") or "").strip()
    mobile_public_base = (os.getenv("MOBILE_PUBLIC_BASE", "https://api2.dansmagazin.net") or "").strip().rstrip("/")

    if not base or not ck or not cs:
        return {"ok": False, "error": "Woo ayarları eksik (WOO_BASE_URL/CK/CS)"}

    try:
        fee = float(entry_fee or 0)
    except Exception:
        fee = 0.0
    if fee < 0:
        fee = 0.0

    full_desc = (description or "").strip()
    start_fmt = fmt_dt(start_at) if (start_at or "").strip() else "-"
    end_fmt = fmt_dt(end_at) if (end_at or "").strip() else "-"
    if start_at or end_at:
        full_desc = (
            (full_desc + "\n\n" if full_desc else "")
            + f"Etkinlik Zamanı:\nBaşlangıç: {start_fmt}\nBitiş: {end_fmt}"
        )

    image_url = ""
    cp = (cover_path or "").strip()
    if cp:
        if cp.startswith("http://") or cp.startswith("https://"):
            image_url = cp
        else:
            image_url = f"{mobile_public_base}/events/submission-cover/{os.path.basename(cp)}"

    payload: Dict[str, Any] = {
        "name": (event_name or "").strip() or "Yeni Etkinlik",
        "status": "publish",
        "type": "simple",
        "virtual": True,
        "regular_price": f"{fee:.2f}",
        "description": full_desc,
        "short_description": (description or "").strip(),
        "manage_stock": False,
    }
    if image_url:
        payload["images"] = [{"src": image_url}]
    if cat_id_raw.isdigit():
        payload["categories"] = [{"id": int(cat_id_raw)}]

    endpoint = f"{base}/wp-json/wc/v3/products"
    req = urllib.request.Request(
        endpoint,
        data=json.dumps(payload).encode("utf-8"),
        headers={
            "Content-Type": "application/json",
            "Authorization": "Basic "
            + base64.b64encode(f"{ck}:{cs}".encode("utf-8")).decode("utf-8"),
        },
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=25) as resp:
            body = resp.read().decode("utf-8", errors="replace")
            data = json.loads(body) if body else {}
        return {
            "ok": True,
            "woo_id": str(data.get("id") or ""),
            "ticket_url": str(data.get("permalink") or ""),
            "raw": data,
        }
    except urllib.error.HTTPError as e:
        msg = e.read().decode("utf-8", errors="replace")
        return {"ok": False, "error": f"Woo HTTP {e.code}: {msg[:600]}"}
    except Exception as e:
        return {"ok": False, "error": f"Woo bağlantı hatası: {e}"}


def delete_woo_event_product(woo_product_id: str) -> Dict[str, Any]:
    """
    WooCommerce ürününü siler (force delete).
    """
    base = (os.getenv("WOO_BASE_URL", "") or "").strip().rstrip("/")
    ck = (os.getenv("WOO_CONSUMER_KEY", "") or "").strip()
    cs = (os.getenv("WOO_CONSUMER_SECRET", "") or "").strip()
    pid = (woo_product_id or "").strip()
    if not pid:
        return {"ok": False, "error": "Woo ürün id boş"}
    if not base or not ck or not cs:
        return {"ok": False, "error": "Woo ayarları eksik (WOO_BASE_URL/CK/CS)"}

    endpoint = f"{base}/wp-json/wc/v3/products/{pid}?force=true"
    req = urllib.request.Request(
        endpoint,
        headers={
            "Authorization": "Basic "
            + base64.b64encode(f"{ck}:{cs}".encode("utf-8")).decode("utf-8"),
        },
        method="DELETE",
    )
    try:
        with urllib.request.urlopen(req, timeout=25) as resp:
            body = resp.read().decode("utf-8", errors="replace")
            data = json.loads(body) if body else {}
        return {"ok": True, "raw": data}
    except urllib.error.HTTPError as e:
        msg = e.read().decode("utf-8", errors="replace")
        return {"ok": False, "error": f"Woo HTTP {e.code}: {msg[:600]}"}
    except Exception as e:
        return {"ok": False, "error": f"Woo bağlantı hatası: {e}"}


def fetch_woo_event_product(woo_product_id: str) -> Dict[str, Any]:
    base = (os.getenv("WOO_BASE_URL", "") or "").strip().rstrip("/")
    ck = (os.getenv("WOO_CONSUMER_KEY", "") or "").strip()
    cs = (os.getenv("WOO_CONSUMER_SECRET", "") or "").strip()
    pid = (woo_product_id or "").strip()
    if not pid:
        return {"ok": False, "error": "Woo ürün id boş"}
    if not base or not ck or not cs:
        return {"ok": False, "error": "Woo ayarları eksik (WOO_BASE_URL/CK/CS)"}

    endpoint = f"{base}/wp-json/wc/v3/products/{pid}"
    req = urllib.request.Request(
        endpoint,
        headers={
            "Authorization": "Basic "
            + base64.b64encode(f"{ck}:{cs}".encode("utf-8")).decode("utf-8"),
        },
        method="GET",
    )
    try:
        with urllib.request.urlopen(req, timeout=25) as resp:
            body = resp.read().decode("utf-8", errors="replace")
            data = json.loads(body) if body else {}
        return {
            "ok": True,
            "woo_id": str(data.get("id") or ""),
            "name": str(data.get("name") or ""),
            "status": str(data.get("status") or ""),
            "ticket_url": str(data.get("permalink") or ""),
            "raw": data,
        }
    except urllib.error.HTTPError as e:
        msg = e.read().decode("utf-8", errors="replace")
        return {"ok": False, "error": f"Woo HTTP {e.code}: {msg[:600]}"}
    except Exception as e:
        return {"ok": False, "error": f"Woo bağlantı hatası: {e}"}


def set_woo_event_product_publish_state(woo_product_id: str, publish: bool) -> Dict[str, Any]:
    base = (os.getenv("WOO_BASE_URL", "") or "").strip().rstrip("/")
    ck = (os.getenv("WOO_CONSUMER_KEY", "") or "").strip()
    cs = (os.getenv("WOO_CONSUMER_SECRET", "") or "").strip()
    pid = (woo_product_id or "").strip()
    if not pid:
        return {"ok": False, "error": "Woo ürün id boş"}
    if not base or not ck or not cs:
        return {"ok": False, "error": "Woo ayarları eksik (WOO_BASE_URL/CK/CS)"}

    payload = {"status": "publish" if publish else "draft"}
    endpoint = f"{base}/wp-json/wc/v3/products/{pid}"
    req = urllib.request.Request(
        endpoint,
        data=json.dumps(payload).encode("utf-8"),
        headers={
            "Content-Type": "application/json",
            "Authorization": "Basic "
            + base64.b64encode(f"{ck}:{cs}".encode("utf-8")).decode("utf-8"),
        },
        method="PUT",
    )
    try:
        with urllib.request.urlopen(req, timeout=25) as resp:
            body = resp.read().decode("utf-8", errors="replace")
            data = json.loads(body) if body else {}
        return {
            "ok": True,
            "woo_id": str(data.get("id") or pid),
            "status": str(data.get("status") or payload["status"]),
            "ticket_url": str(data.get("permalink") or ""),
            "raw": data,
        }
    except urllib.error.HTTPError as e:
        msg = e.read().decode("utf-8", errors="replace")
        return {"ok": False, "error": f"Woo HTTP {e.code}: {msg[:600]}"}
    except Exception as e:
        return {"ok": False, "error": f"Woo bağlantı hatası: {e}"}


def _mobile_submission_event_day(row: Dict[str, Any]):
    candidate = (
        (row.get("event_date") or "").strip()
        or (row.get("start_at") or "").strip()
        or (row.get("end_at") or "").strip()
    )
    dt = _parse_submission_event_dt(candidate)
    return dt.date() if dt is not None else None


def _load_mobile_submission_for_approval(c, submission_id: int) -> Optional[Dict[str, Any]]:
    c.execute(
        """
        SELECT
            ms.*,
            COALESCE(se.id, 0) AS saas_event_id,
            COALESCE(se.is_active, 0) AS event_is_active,
            COALESCE(se.external_event_id, '') AS woo_product_id,
            COALESCE(se.ticket_url, '') AS ticket_url
        FROM mobile_event_submissions ms
        LEFT JOIN saas_events se ON se.slug = ms.approved_event_slug
        WHERE ms.id=?
        LIMIT 1
        """,
        (int(submission_id),),
    )
    return c.fetchone()


def _load_mobile_series_rows_for_approval(c, seed_row: Dict[str, Any]) -> List[Dict[str, Any]]:
    if _boolish(seed_row.get("repeat_weekly"), default=False):
        return [seed_row]
    origin_id = int(seed_row.get("repeat_origin_submission_id") or seed_row.get("id") or 0)
    if int(seed_row.get("repeat_origin_submission_id") or 0) <= 0:
        c.execute(
            """
            SELECT
                ms.*,
                COALESCE(se.id, 0) AS saas_event_id,
                COALESCE(se.is_active, 0) AS event_is_active,
                COALESCE(se.external_event_id, '') AS woo_product_id,
                COALESCE(se.ticket_url, '') AS ticket_url
            FROM mobile_event_submissions ms
            LEFT JOIN saas_events se ON se.slug = ms.approved_event_slug
            WHERE COALESCE(ms.repeat_weekly, FALSE)=FALSE
              AND COALESCE(ms.repeat_origin_submission_id, 0)=0
              AND COALESCE(ms.submitter_email, '')=?
              AND COALESCE(ms.event_name, '')=?
              AND COALESCE(ms.venue, '')=?
              AND COALESCE(ms.city, '')=?
              AND COALESCE(ms.created_at, '')=?
            ORDER BY COALESCE(ms.event_date, ms.start_at, ms.created_at) ASC, ms.id ASC
            """,
            (
                (seed_row.get("submitter_email") or "").strip(),
                (seed_row.get("event_name") or "").strip(),
                (seed_row.get("venue") or "").strip(),
                (seed_row.get("city") or "").strip(),
                (seed_row.get("created_at") or "").strip(),
            ),
        )
        legacy_rows = c.fetchall() or []
        if len(legacy_rows) > 1:
            origin_id = int(legacy_rows[0]["id"])
            for item in legacy_rows:
                c.execute(
                    "UPDATE mobile_event_submissions SET repeat_origin_submission_id=? WHERE id=?",
                    (origin_id, int(item["id"])),
                )
    if origin_id <= 0:
        return [seed_row]
    c.execute(
        """
        SELECT
            ms.*,
            COALESCE(se.id, 0) AS saas_event_id,
            COALESCE(se.is_active, 0) AS event_is_active,
            COALESCE(se.external_event_id, '') AS woo_product_id,
            COALESCE(se.ticket_url, '') AS ticket_url
        FROM mobile_event_submissions ms
        LEFT JOIN saas_events se ON se.slug = ms.approved_event_slug
        WHERE COALESCE(ms.repeat_origin_submission_id, ms.id)=?
          AND COALESCE(ms.repeat_weekly, FALSE)=FALSE
        ORDER BY COALESCE(ms.event_date, ms.start_at, ms.created_at) ASC, ms.id ASC
        """,
        (origin_id,),
    )
    rows = c.fetchall() or []
    return rows or [seed_row]


def _deactivate_mobile_submission_live_event(c, row: Dict[str, Any]) -> None:
    slug = (row.get("approved_event_slug") or "").strip()
    if slug:
        c.execute("UPDATE saas_events SET is_active=0 WHERE slug=?", (slug,))
    woo_product_id = (row.get("woo_product_id") or "").strip()
    if woo_product_id:
        set_woo_event_product_publish_state(woo_product_id, publish=False)


def _sync_mobile_submission_live_event(
    c,
    row: Dict[str, Any],
    *,
    owner_id: int,
    note_prefix: str,
    activate_now: bool,
    approved_at: str,
) -> Dict[str, Any]:
    event_name = (row.get("event_name") or "").strip() or f"Etkinlik {int(row.get('id') or 0)}"
    create_photo_album = _boolish(row.get("create_photo_album"), default=True)
    existing_slug = (row.get("approved_event_slug") or "").strip()
    slug = existing_slug

    saas_event_id = int(row.get("saas_event_id") or 0)
    if not saas_event_id and slug:
        c.execute("SELECT id FROM saas_events WHERE slug=? LIMIT 1", (slug,))
        existing_event = c.fetchone()
        saas_event_id = int(existing_event["id"]) if existing_event else 0

    if saas_event_id:
        c.execute(
            """
            UPDATE saas_events
            SET account_id=?,
                name=?,
                is_active=?,
                album_enabled=?
            WHERE id=?
            """,
            (owner_id, event_name, 1 if activate_now else 0, True if create_photo_album else False, saas_event_id),
        )
    else:
        base_slug = _slug_clean(event_name) or f"event-{int(row.get('id') or 0)}"
        slug = _slug_clean(existing_slug) or base_slug
        n = 2
        while True:
            c.execute("SELECT 1 FROM saas_events WHERE slug=? LIMIT 1", (slug,))
            if not c.fetchone():
                break
            slug = f"{base_slug}-{n}"
            n += 1
        c.execute(
            """
            INSERT INTO saas_events (account_id, name, slug, is_active, created_at, album_enabled)
            VALUES (?, ?, ?, ?, ?, ?)
            """,
            (owner_id, event_name, slug, 1 if activate_now else 0, iso_now(), True if create_photo_album else False),
        )

    extra_desc_parts = []
    if (row.get("venue") or "").strip():
        extra_desc_parts.append(f"Mekan: {(row.get('venue') or '').strip()}")
    if (row.get("organizer_name") or "").strip():
        extra_desc_parts.append(f"Organizatör: {(row.get('organizer_name') or '').strip()}")
    if (row.get("program_text") or "").strip():
        extra_desc_parts.append(f"Program: {(row.get('program_text') or '').strip()}")
    base_desc = (row.get("description") or "").strip()
    full_desc = base_desc
    if extra_desc_parts:
        full_desc = (base_desc + "\n\n" if base_desc else "") + "\n".join(extra_desc_parts)

    ticket_sales_enabled = _boolish(row.get("ticket_sales_enabled"), default=True)
    woo_product_id = (row.get("woo_product_id") or "").strip()
    ticket_url = (row.get("ticket_url") or "").strip()
    woo_res: Dict[str, Any] = {"ok": False, "error": "Bilet satışı kapalı"}
    if ticket_sales_enabled:
        if woo_product_id:
            woo_res = set_woo_event_product_publish_state(woo_product_id, publish=activate_now)
        elif activate_now:
            woo_res = create_woo_draft_event_product(
                event_name=event_name,
                description=full_desc,
                start_at=(row.get("start_at") or "").strip(),
                end_at=(row.get("end_at") or "").strip(),
                entry_fee=(row.get("entry_fee") or 0),
                cover_path=(row.get("cover_path") or "").strip(),
            )
        else:
            woo_res = {"ok": True, "queued": True, "error": ""}

        if woo_res.get("ok") and (woo_product_id or woo_res.get("woo_id")):
            woo_product_id = str(woo_res.get("woo_id") or woo_product_id).strip()
            synced_ticket_url = str(woo_res.get("ticket_url") or ticket_url).strip()
            if synced_ticket_url:
                ticket_url = synced_ticket_url
            c.execute(
                """
                UPDATE saas_events
                SET external_source=?,
                    external_event_id=?,
                    ticket_url=?
                WHERE slug=?
                """,
                ("woo", woo_product_id or None, ticket_url or None, slug),
            )
    elif woo_product_id:
        woo_res = set_woo_event_product_publish_state(woo_product_id, publish=False)
        if woo_res.get("ok"):
            synced_ticket_url = str(woo_res.get("ticket_url") or ticket_url).strip()
            if synced_ticket_url:
                ticket_url = synced_ticket_url
            c.execute(
                """
                UPDATE saas_events
                SET external_source=?,
                    external_event_id=?,
                    ticket_url=?
                WHERE slug=?
                """,
                ("woo", woo_product_id or None, ticket_url or None, slug),
            )

    if not ticket_sales_enabled:
        extra = "Bilet satışı kapalı: Woo ürünü oluşturulmadı"
    elif activate_now and woo_res.get("ok") and woo_res.get("woo_id"):
        extra = f"Woo ürün hazır (id={woo_res.get('woo_id')})"
    elif activate_now and woo_res.get("ok"):
        extra = "Woo ürün yayına alındı"
    elif activate_now:
        extra = f"Woo ürün oluşturulamadı: {woo_res.get('error')}"
    elif woo_product_id and woo_res.get("ok"):
        extra = "Woo ürünü taslakta bekliyor"
    else:
        extra = "Woo ürünü aktivasyon sırasında oluşturulacak"
    album_note = "Fotoğraf albümü açık" if create_photo_album else "Fotoğraf albümü kapalı"
    merged_note = (note_prefix + " | " + extra + " | " + album_note).strip(" |")

    c.execute(
        """
        UPDATE mobile_event_submissions
        SET status='approved',
            admin_note=?,
            approved_event_slug=?,
            approved_at=?
        WHERE id=?
        """,
        (merged_note, slug, approved_at, int(row["id"])),
    )
    return {
        "slug": slug,
        "admin_note": merged_note,
        "woo_ok": bool(woo_res.get("ok")),
        "woo_id": str(woo_res.get("woo_id") or woo_product_id).strip(),
        "ticket_sales_enabled": ticket_sales_enabled,
        "active": activate_now,
    }


def _approve_mobile_submission_group(conn, submission_id: int, note_prefix: str, fallback_owner_id: int) -> Dict[str, Any]:
    c = conn.cursor()
    seed_row = _load_mobile_submission_for_approval(c, submission_id)
    if not seed_row:
        raise ValueError("Talep bulunamadı")

    c.execute("SELECT id FROM accounts WHERE LOWER(email)=LOWER(?) LIMIT 1", ((seed_row.get("submitter_email") or "").strip(),))
    owner = c.fetchone()
    owner_id = int(owner["id"]) if owner else int(fallback_owner_id or 0)
    if owner_id <= 0:
        raise ValueError("Etkinlik sahibi bulunamadı")

    rows = _load_mobile_series_rows_for_approval(c, seed_row)
    today = _local_now().date()
    approved_at = iso_now()
    active_target_id: Optional[int] = None

    for item in rows:
        status = (item.get("status") or "").strip().lower()
        event_day = _mobile_submission_event_day(item)
        if status == "approved" and _boolish(item.get("event_is_active"), default=False) and (event_day is None or event_day >= today):
            active_target_id = int(item["id"])
            break
    if active_target_id is None:
        for item in rows:
            status = (item.get("status") or "").strip().lower()
            event_day = _mobile_submission_event_day(item)
            if status == "rejected":
                continue
            if event_day is not None and event_day < today:
                continue
            active_target_id = int(item["id"])
            break

    active_slug = ""
    approved_count = 0
    archived_count = 0
    last_woo_id = ""
    last_ticket_sales_enabled = True
    active_woo_ok = False

    for item in rows:
        row_id = int(item["id"])
        status = (item.get("status") or "").strip().lower()
        event_day = _mobile_submission_event_day(item)
        if status == "rejected":
            continue
        if event_day is not None and event_day < today:
            _deactivate_mobile_submission_live_event(c, item)
            archived_note = (note_prefix + " | Geçmiş tarih olduğu için otomatik arşivlendi").strip(" |")
            c.execute(
                """
                UPDATE mobile_event_submissions
                SET status='expired',
                    admin_note=?,
                    approved_at=COALESCE(approved_at, ?)
                WHERE id=?
                """,
                (archived_note, approved_at, row_id),
            )
            archived_count += 1
            continue

        result = _sync_mobile_submission_live_event(
            c,
            item,
            owner_id=owner_id,
            note_prefix=note_prefix,
            activate_now=row_id == active_target_id,
            approved_at=approved_at,
        )
        approved_count += 1
        last_woo_id = result.get("woo_id") or last_woo_id
        last_ticket_sales_enabled = bool(result.get("ticket_sales_enabled"))
        if result.get("active"):
            active_slug = result.get("slug") or active_slug
            active_woo_ok = bool(result.get("woo_ok"))

    return {
        "is_series": len(rows) > 1,
        "approved_count": approved_count,
        "archived_count": archived_count,
        "active_slug": active_slug,
        "woo_id": last_woo_id,
        "woo_ok": active_woo_ok,
        "ticket_sales_enabled": last_ticket_sales_enabled,
    }


def list_woo_event_products(limit: int = 100) -> Dict[str, Any]:
    base = (os.getenv("WOO_BASE_URL", "") or "").strip().rstrip("/")
    ck = (os.getenv("WOO_CONSUMER_KEY", "") or "").strip()
    cs = (os.getenv("WOO_CONSUMER_SECRET", "") or "").strip()
    if not base or not ck or not cs:
        return {"ok": False, "error": "Woo ayarları eksik (WOO_BASE_URL/CK/CS)"}

    total_limit = max(1, min(int(limit or 100), 300))
    per_page = min(total_limit, 100)
    auth_header = {
        "Authorization": "Basic "
        + base64.b64encode(f"{ck}:{cs}".encode("utf-8")).decode("utf-8"),
    }
    try:
        items = []
        seen_ids = set()
        pages = max(1, (total_limit + per_page - 1) // per_page)
        for page in range(1, pages + 1):
            endpoint = (
                f"{base}/wp-json/wc/v3/products"
                f"?per_page={per_page}&page={page}&orderby=date&order=desc&status=any"
            )
            req = urllib.request.Request(endpoint, headers=auth_header, method="GET")
            with urllib.request.urlopen(req, timeout=25) as resp:
                body = resp.read().decode("utf-8", errors="replace")
                rows = json.loads(body) if body else []
            if not isinstance(rows, list) or not rows:
                break
            for row in rows:
                if not isinstance(row, dict):
                    continue
                item_id = str(row.get("id") or "").strip()
                if not item_id or item_id in seen_ids:
                    continue
                seen_ids.add(item_id)
                items.append(
                    {
                        "id": item_id,
                        "name": str(row.get("name") or "").strip(),
                        "status": str(row.get("status") or "").strip(),
                        "ticket_url": str(row.get("permalink") or "").strip(),
                    }
                )
                if len(items) >= total_limit:
                    break
            if len(items) >= total_limit or len(rows) < per_page:
                break
        return {"ok": True, "items": items}
    except urllib.error.HTTPError as e:
        msg = e.read().decode("utf-8", errors="replace")
        return {"ok": False, "error": f"Woo HTTP {e.code}: {msg[:600]}"}
    except Exception as e:
        return {"ok": False, "error": f"Woo bağlantı hatası: {e}"}


def mobile_backend_admin_call(path: str, method: str = "GET", data: Optional[Dict[str, Any]] = None) -> Dict[str, Any]:
    base = (MOBILE_BACKEND_BASE or "").strip().rstrip("/")
    token = (MOBILE_BACKEND_ADMIN_TOKEN or "").strip()
    if not base:
        return {"ok": False, "error": "MOBILE_BACKEND_BASE eksik"}
    if not token:
        return {"ok": False, "error": "MOBILE_ADMIN_TOKEN eksik"}

    url = f"{base}{path if path.startswith('/') else '/' + path}"
    headers = {"x-admin-token": token}
    body_bytes = None

    if method.upper() == "POST":
        payload = urllib.parse.urlencode({k: "" if v is None else str(v) for k, v in (data or {}).items()})
        body_bytes = payload.encode("utf-8")
        headers["Content-Type"] = "application/x-www-form-urlencoded"

    req = urllib.request.Request(url, data=body_bytes, headers=headers, method=method.upper())
    try:
        with urllib.request.urlopen(req, timeout=20) as resp:
            raw = resp.read().decode("utf-8", errors="replace")
            parsed = json.loads(raw) if raw else {}
        return {"ok": True, "data": parsed}
    except urllib.error.HTTPError as e:
        msg = e.read().decode("utf-8", errors="replace")
        return {"ok": False, "error": f"HTTP {e.code}: {msg[:500]}"}
    except Exception as e:
        return {"ok": False, "error": str(e)}


def mobile_backend_bearer_call(
    path: str,
    bearer_token: str,
    method: str = "GET",
    json_data: Optional[Dict[str, Any]] = None,
) -> Dict[str, Any]:
    base = (MOBILE_BACKEND_BASE or "").strip().rstrip("/")
    token = (bearer_token or "").strip()
    if not base:
        return {"ok": False, "error": "MOBILE_BACKEND_BASE eksik"}
    if not token:
        return {"ok": False, "error": "Session token bulunamadı"}

    url = f"{base}{path if path.startswith('/') else '/' + path}"
    headers = {"Authorization": f"Bearer {token}"}
    body_bytes = None
    if method.upper() in ("POST", "PUT", "PATCH"):
        payload = json.dumps(json_data or {}).encode("utf-8")
        body_bytes = payload
        headers["Content-Type"] = "application/json"

    req = urllib.request.Request(url, data=body_bytes, headers=headers, method=method.upper())
    try:
        with urllib.request.urlopen(req, timeout=25) as resp:
            raw = resp.read().decode("utf-8", errors="replace")
            parsed = json.loads(raw) if raw else {}
        return {"ok": True, "data": parsed}
    except urllib.error.HTTPError as e:
        msg = e.read().decode("utf-8", errors="replace")
        return {"ok": False, "error": f"HTTP {e.code}: {msg[:600]}"}
    except Exception as e:
        return {"ok": False, "error": str(e)}


def mobile_backend_bearer_form_call(
    path: str,
    bearer_token: str,
    method: str = "POST",
    data: Optional[Dict[str, Any]] = None,
) -> Dict[str, Any]:
    base = (MOBILE_BACKEND_BASE or "").strip().rstrip("/")
    token = (bearer_token or "").strip()
    if not base:
        return {"ok": False, "error": "MOBILE_BACKEND_BASE eksik"}
    if not token:
        return {"ok": False, "error": "Session token bulunamadı"}

    url = f"{base}{path if path.startswith('/') else '/' + path}"
    headers = {"Authorization": f"Bearer {token}"}
    payload = urllib.parse.urlencode({k: "" if v is None else str(v) for k, v in (data or {}).items()})
    body_bytes = payload.encode("utf-8")
    headers["Content-Type"] = "application/x-www-form-urlencoded"

    req = urllib.request.Request(url, data=body_bytes, headers=headers, method=method.upper())
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            raw = resp.read().decode("utf-8", errors="replace")
            parsed = json.loads(raw) if raw else {}
        return {"ok": True, "data": parsed}
    except urllib.error.HTTPError as e:
        msg = e.read().decode("utf-8", errors="replace")
        return {"ok": False, "error": f"HTTP {e.code}: {msg[:700]}"}
    except Exception as e:
        return {"ok": False, "error": str(e)}


def _encode_multipart_formdata(fields: Dict[str, Any], files: List[Dict[str, Any]]) -> tuple[bytes, str]:
    boundary = f"----DMZ{uuid.uuid4().hex}"
    lines: List[bytes] = []
    for key, value in (fields or {}).items():
        lines.append(f"--{boundary}".encode("utf-8"))
        lines.append(f'Content-Disposition: form-data; name="{key}"'.encode("utf-8"))
        lines.append(b"")
        lines.append(str("" if value is None else value).encode("utf-8"))
    for f in (files or []):
        field = str(f.get("field") or "").strip()
        if not field:
            continue
        filename = str(f.get("filename") or "upload.bin")
        content = f.get("content") or b""
        content_type = str(f.get("content_type") or "application/octet-stream")
        lines.append(f"--{boundary}".encode("utf-8"))
        lines.append(
            f'Content-Disposition: form-data; name="{field}"; filename="{filename}"'.encode("utf-8")
        )
        lines.append(f"Content-Type: {content_type}".encode("utf-8"))
        lines.append(b"")
        lines.append(content if isinstance(content, (bytes, bytearray)) else bytes(content))
    lines.append(f"--{boundary}--".encode("utf-8"))
    lines.append(b"")
    body = b"\r\n".join(lines)
    return body, boundary


def mobile_backend_bearer_multipart_call(
    path: str,
    bearer_token: str,
    fields: Dict[str, Any],
    files: List[Dict[str, Any]],
) -> Dict[str, Any]:
    base = (MOBILE_BACKEND_BASE or "").strip().rstrip("/")
    token = (bearer_token or "").strip()
    if not base:
        return {"ok": False, "error": "MOBILE_BACKEND_BASE eksik"}
    if not token:
        return {"ok": False, "error": "Session token bulunamadı"}

    url = f"{base}{path if path.startswith('/') else '/' + path}"
    body, boundary = _encode_multipart_formdata(fields or {}, files or [])
    headers = {
        "Authorization": f"Bearer {token}",
        "Content-Type": f"multipart/form-data; boundary={boundary}",
    }
    req = urllib.request.Request(url, data=body, headers=headers, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=40) as resp:
            raw = resp.read().decode("utf-8", errors="replace")
            parsed = json.loads(raw) if raw else {}
        return {"ok": True, "data": parsed}
    except urllib.error.HTTPError as e:
        msg = e.read().decode("utf-8", errors="replace")
        return {"ok": False, "error": f"HTTP {e.code}: {msg[:700]}"}
    except Exception as e:
        return {"ok": False, "error": str(e)}


def mobile_backend_admin_multipart_call(
    path: str,
    fields: Dict[str, Any],
    files: List[Dict[str, Any]],
) -> Dict[str, Any]:
    base = (MOBILE_BACKEND_BASE or "").strip().rstrip("/")
    token = (MOBILE_BACKEND_ADMIN_TOKEN or "").strip()
    if not base:
        return {"ok": False, "error": "MOBILE_BACKEND_BASE eksik"}
    if not token:
        return {"ok": False, "error": "MOBILE_ADMIN_TOKEN eksik"}

    url = f"{base}{path if path.startswith('/') else '/' + path}"
    body, boundary = _encode_multipart_formdata(fields or {}, files or [])
    headers = {
        "x-admin-token": token,
        "Content-Type": f"multipart/form-data; boundary={boundary}",
    }
    req = urllib.request.Request(url, data=body, headers=headers, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=40) as resp:
            raw = resp.read().decode("utf-8", errors="replace")
            parsed = json.loads(raw) if raw else {}
        return {"ok": True, "data": parsed}
    except urllib.error.HTTPError as e:
        msg = e.read().decode("utf-8", errors="replace")
        return {"ok": False, "error": f"HTTP {e.code}: {msg[:700]}"}
    except Exception as e:
        return {"ok": False, "error": str(e)}


_ADMIN_VIEW_CACHE: Dict[str, Dict[str, Any]] = {}


def _cache_get(key: str, ttl_seconds: int) -> Optional[Any]:
    entry = _ADMIN_VIEW_CACHE.get(key) or {}
    ts = float(entry.get("ts") or 0)
    if ts <= 0 or (time.time() - ts) > float(ttl_seconds):
        return None
    return entry.get("value")


def _cache_set(key: str, value: Any) -> Any:
    _ADMIN_VIEW_CACHE[key] = {"ts": time.time(), "value": value}
    return value


def _cache_delete(key: str):
    _ADMIN_VIEW_CACHE.pop(key, None)


def _invalidate_admin_news_cache():
    _cache_delete("admin_news_submissions")


def _invalidate_admin_event_cache():
    _cache_delete("admin_event_items")


def _fetch_notification_users(cur) -> List[Dict[str, Any]]:
    cur.execute(
        """
        SELECT
            id,
            COALESCE(name,'') AS name,
            COALESCE(email,'') AS email,
            COALESCE(role,'customer') AS role
        FROM accounts
        WHERE COALESCE(is_active,1)=1
        ORDER BY id DESC
        LIMIT 1000
        """
    )
    return [
        {
            "id": int(r["id"]),
            "name": (r.get("name") or "").strip()
            or ((r.get("email") or "").split("@")[0] if "@" in (r.get("email") or "") else "user"),
            "email": (r.get("email") or "").strip(),
            "role": (r.get("role") or "customer").strip(),
        }
        for r in (cur.fetchall() or [])
    ]


def _fetch_editor_candidates(cur) -> List[Dict[str, Any]]:
    cur.execute(
        """
        SELECT id, COALESCE(name,'') AS name, COALESCE(email,'') AS email, COALESCE(role,'customer') AS role,
               COALESCE(can_create_mobile_event,0) AS can_create_mobile_event
        FROM accounts
        WHERE COALESCE(is_active,1)=1
          AND (COALESCE(role,'') IN ('editor','super_admin') OR COALESCE(can_create_mobile_event,0)=1)
        ORDER BY id DESC
        LIMIT 300
        """
    )
    rows = cur.fetchall() or []
    return [
        {
            "id": int(r["id"]),
            "name": (r.get("name") or "").strip()
            or ((r.get("email") or "").split("@")[0] if "@" in (r.get("email") or "") else "user"),
            "email": (r.get("email") or "").strip(),
            "role": (r.get("role") or "customer").strip(),
        }
        for r in rows
    ]


def _fetch_admin_event_items() -> tuple[List[Dict[str, Any]], str]:
    events_res = mobile_backend_admin_call("/admin/events/items?limit=300", method="GET")
    if not events_res.get("ok"):
        return [], str(events_res.get("error") or "Canlı etkinlik listesi alınamadı")
    data = events_res.get("data") or {}
    rows = data.get("items") if isinstance(data, dict) else []
    items: List[Dict[str, Any]] = []
    for row in (rows or []):
        if not isinstance(row, dict):
            continue
        try:
            sid = int(row.get("submission_id") or 0)
        except Exception:
            sid = 0
        item = {
            "id": sid,
            "source_table": "mobile_event_submissions",
            "submitter_name": "",
            "submitter_email": "",
            "event_name": (row.get("name") or "").strip(),
            "description": (row.get("description") or "").strip(),
            "cover_path": (row.get("cover_url") or "").strip(),
            "event_date": (row.get("event_date") or "").strip(),
            "venue": (row.get("venue") or "").strip(),
            "venue_map_url": (row.get("venue_map_url") or "").strip(),
            "city": (row.get("city") or "").strip(),
            "event_kind": (row.get("event_kind") or "").strip(),
            "organizer_name": (row.get("organizer_name") or "").strip(),
            "program_text": (row.get("program_text") or "").strip(),
            "start_at": (row.get("start_at") or "").strip(),
            "end_at": (row.get("end_at") or "").strip(),
            "entry_fee": row.get("entry_fee") or 0,
            "status": (row.get("status") or "").strip(),
            "event_is_active": bool(row.get("event_is_active") if row.get("event_is_active") is not None else True),
            "ticket_sales_enabled": bool(row.get("ticket_sales_enabled") if row.get("ticket_sales_enabled") is not None else True),
            "admin_note": "",
            "approved_event_slug": (row.get("slug") or "").strip(),
            "create_photo_album": bool(row.get("create_photo_album")),
            "photo_album_enabled": bool(
                row.get("photo_album_enabled") if row.get("photo_album_enabled") is not None else True
            ),
            "reviewed_at": (row.get("approved_at") or row.get("created_at") or "").strip(),
            "reviewed_by_email": "",
            "external_source": "woo" if (row.get("woo_product_id") or row.get("ticket_url")) else "",
            "external_event_id": (row.get("woo_product_id") or "").strip(),
            "ticket_url": (row.get("ticket_url") or "").strip(),
            "auto_notification_title_template": (row.get("auto_notification_title_template") or "").strip(),
            "auto_notification_body_template": (row.get("auto_notification_body_template") or "").strip(),
        }
        if item["id"] > 0:
            items.append(item)
    return items, ""


def _fetch_admin_news_submissions() -> tuple[List[Dict[str, Any]], str]:
    news_res = mobile_backend_admin_call("/admin/news/submissions?status=all", method="GET")
    if not news_res.get("ok"):
        return [], str(news_res.get("error") or "Haber talepleri alınamadı")
    data = news_res.get("data") or {}
    rows = data.get("items") if isinstance(data, dict) else []
    parsed: List[Dict[str, Any]] = []
    for row in (rows or []):
        if not isinstance(row, dict):
            continue
        item = dict(row)
        status_val = (item.get("status") or "").strip().lower()
        if status_val == "pending":
            order = 0
        elif status_val == "approved":
            order = 1
        elif status_val == "rejected":
            order = 2
        else:
            order = 3
        try:
            sid = int(item.get("id") or item.get("submission_id") or 0)
        except Exception:
            sid = 0
        cover = (item.get("cover_url") or item.get("cover_path") or "").strip()
        if cover.startswith("/"):
            cover = f"{PUBLIC_BASE_URL}{cover}"
        item["cover_url"] = cover
        item["_status_order"] = order
        item["_sort_id"] = sid
        parsed.append(item)
    return (
        sorted(parsed, key=lambda r: (int(r.get("_status_order") or 9), -int(r.get("_sort_id") or 0)))[:300],
        "",
    )


def _cached_admin_event_items(ttl_seconds: int = 60) -> tuple[List[Dict[str, Any]], str]:
    cache_key = "admin_event_items"
    cached = _cache_get(cache_key, ttl_seconds)
    if cached is not None:
        return cached
    result = _fetch_admin_event_items()
    return _cache_set(cache_key, result)


def _cached_admin_news_submissions(ttl_seconds: int = 180) -> tuple[List[Dict[str, Any]], str]:
    cache_key = "admin_news_submissions"
    cached = _cache_get(cache_key, ttl_seconds)
    if cached is not None:
        return cached
    result = _fetch_admin_news_submissions()
    return _cache_set(cache_key, result)


def _fetch_scan_permissions_bulk(event_items: List[Dict[str, Any]]) -> tuple[Dict[int, List[Dict[str, Any]]], str]:
    submission_ids = [
        int(item.get("id") or item.get("submission_id") or 0)
        for item in (event_items or [])
        if (item.get("status") or "").strip().lower() in {"approved", "expired"}
        and int(item.get("id") or item.get("submission_id") or 0) > 0
    ]
    if not submission_ids:
        return {}, ""
    res = mobile_backend_admin_call(
        "/admin/events/scan-permissions/bulk",
        method="POST",
        data={"submission_ids_csv": ",".join(str(sid) for sid in submission_ids)},
    )
    if not res.get("ok"):
        return {}, str(res.get("error") or "Etkinlik editör yetkileri alınamadı")
    data = res.get("data") or {}
    rows = data.get("items_by_submission") if isinstance(data, dict) else {}
    if not isinstance(rows, dict):
        return {}, ""
    mapped: Dict[int, List[Dict[str, Any]]] = {}
    for key, value in rows.items():
        try:
            sid = int(key)
        except Exception:
            continue
        mapped[sid] = value if isinstance(value, list) else []
    return mapped, ""


def _fetch_admin_event_loyalty_reports(event_items: List[Dict[str, Any]]) -> tuple[Dict[int, Dict[str, Any]], str]:
    submission_ids = [
        int(item.get("id") or item.get("submission_id") or 0)
        for item in (event_items or [])
        if (item.get("status") or "").strip().lower() in {"approved", "expired"}
        and int(item.get("id") or item.get("submission_id") or 0) > 0
    ]
    if not submission_ids:
        return {}, ""
    res = mobile_backend_admin_call(
        "/admin/events/loyalty-reports/bulk",
        method="POST",
        data={"submission_ids_csv": ",".join(str(sid) for sid in submission_ids)},
    )
    if not res.get("ok"):
        return {}, str(res.get("error") or "Okul / ücretsiz bilet raporu alınamadı")
    data = res.get("data") or {}
    rows = data.get("items_by_submission") if isinstance(data, dict) else {}
    if not isinstance(rows, dict):
        return {}, ""
    mapped: Dict[int, Dict[str, Any]] = {}
    for key, value in rows.items():
        try:
            sid = int(key)
        except Exception:
            continue
        mapped[sid] = value if isinstance(value, dict) else {}
    return mapped, ""


def _fetch_admin_guest_lists(session_token: str) -> tuple[List[Dict[str, Any]], str]:
    res = mobile_backend_bearer_call("/profile/guest-lists", session_token, method="GET")
    if not res.get("ok"):
        return [], str(res.get("error") or "Davetli listeleri alınamadı")
    data = res.get("data") or {}
    rows = data.get("items") if isinstance(data, dict) else []
    if not isinstance(rows, list):
        return [], ""
    return [row for row in rows if isinstance(row, dict)], ""


def _fetch_admin_guest_list_detail(session_token: str, guest_list_id: int) -> tuple[Optional[Dict[str, Any]], str]:
    if int(guest_list_id or 0) <= 0:
        return None, ""
    res = mobile_backend_bearer_call(f"/profile/guest-lists/{int(guest_list_id)}", session_token, method="GET")
    if not res.get("ok"):
        return None, str(res.get("error") or "Davetli listesi alınamadı")
    data = res.get("data") or {}
    return data if isinstance(data, dict) else None, ""


def _search_admin_guest_list_users(
    session_token: str,
    query: str,
    *,
    existing_account_ids: Optional[set[int]] = None,
    limit: int = 20,
) -> tuple[List[Dict[str, Any]], Dict[str, Any], str]:
    q = (query or "").strip()
    if not q:
        return [], {"query": "", "min_query_length": 2, "search_required": True}, ""
    path = f"/profile/users/search?q={urllib.parse.quote(q)}&limit={max(1, min(int(limit), 50))}"
    res = mobile_backend_bearer_call(path, session_token, method="GET")
    if not res.get("ok"):
        return [], {}, str(res.get("error") or "Kullanıcı araması yapılamadı")
    data = res.get("data") or {}
    items = data.get("items") if isinstance(data, dict) else []
    if not isinstance(items, list):
        items = []
    blocked = existing_account_ids or set()
    filtered: List[Dict[str, Any]] = []
    for item in items:
        if not isinstance(item, dict):
            continue
        try:
            account_id = int(item.get("account_id") or 0)
        except Exception:
            account_id = 0
        if account_id > 0 and account_id in blocked:
            continue
        filtered.append(item)
    meta = {
        "query": (data.get("query") or q) if isinstance(data, dict) else q,
        "min_query_length": int(data.get("min_query_length") or 2) if isinstance(data, dict) else 2,
        "search_required": bool(data.get("search_required")) if isinstance(data, dict) else True,
        "has_more": bool(data.get("has_more")) if isinstance(data, dict) else False,
    }
    return filtered, meta, ""


def _fetch_event_invitees_bulk(conn, event_items: List[Dict[str, Any]]) -> Dict[int, List[Dict[str, Any]]]:
    submission_ids = sorted(
        {
            int(item.get("id") or item.get("submission_id") or 0)
            for item in (event_items or [])
            if int(item.get("id") or item.get("submission_id") or 0) > 0
        }
    )
    if not submission_ids:
        return {}
    cur = conn.cursor()
    cur.execute(
        """
        SELECT
            ei.submission_id,
            ei.account_id,
            ei.source_guest_list_id,
            ei.ticket_id,
            ei.created_at,
            COALESCE(gl.name,'') AS source_guest_list_name,
            COALESCE(NULLIF(TRIM(a.name),''), NULLIF(TRIM(ps.username),''), SPLIT_PART(COALESCE(a.email,''), '@', 1), 'user') AS display_name,
            COALESCE(a.email,'') AS email,
            COALESCE(ps.avatar_url,'') AS avatar_url,
            COALESCE(ps.is_verified, FALSE) AS is_verified,
            COALESCE(a.role,'') AS role,
            COALESCE(a.can_create_mobile_event, 0) AS can_create_mobile_event
        FROM mobile_event_invitees ei
        JOIN accounts a ON a.id = ei.account_id
        LEFT JOIN mobile_profile_settings ps ON ps.account_id = a.id
        LEFT JOIN mobile_guest_lists gl ON gl.id = ei.source_guest_list_id
        WHERE ei.submission_id = ANY(?)
        ORDER BY ei.submission_id ASC, ei.created_at ASC, ei.account_id ASC
        """,
        (submission_ids,),
    )
    rows = cur.fetchall() or []
    mapped: Dict[int, List[Dict[str, Any]]] = {sid: [] for sid in submission_ids}
    for row in rows:
        sid = int(row["submission_id"])
        mapped.setdefault(sid, []).append(
            {
                "account_id": int(row["account_id"]),
                "name": (row.get("display_name") or "").strip() or "user",
                "email": (row.get("email") or "").strip(),
                "avatar_url": (row.get("avatar_url") or "").strip(),
                "is_verified": bool(row.get("is_verified")) or _boolish(row.get("can_create_mobile_event"), default=False) or (row.get("role") or "").strip().lower() in {"super_admin", "editor"},
                "source_guest_list_id": int(row["source_guest_list_id"]) if row.get("source_guest_list_id") is not None else None,
                "source_guest_list_name": (row.get("source_guest_list_name") or "").strip(),
                "ticket_id": int(row["ticket_id"]) if row.get("ticket_id") is not None else None,
                "invited_at": (row.get("created_at") or "").strip(),
            }
        )
    return mapped


def _ticket_type_label_text(ticket_type: Any) -> str:
    normalized = str(ticket_type or "").strip().lower() or "paid"
    if normalized == "guest":
        return "Davetli"
    if normalized == "paid":
        return "Satın alınmış"
    if normalized == "loyalty_reward":
        return "Ücretsiz"
    return normalized or "Bilet"


def _ticket_control_summary_text(summary: Dict[str, Any], include_zero: bool = False) -> str:
    active_total = int(summary.get("active_ticket_count") or 0)
    if active_total <= 0 and not include_zero:
        return ""
    detail_parts: List[str] = []
    paid_count = int(summary.get("paid_ticket_count") or 0)
    guest_count = int(summary.get("guest_ticket_count") or 0)
    reward_count = int(summary.get("reward_ticket_count") or 0)
    if paid_count > 0:
        detail_parts.append(f"{paid_count} satın alınmış")
    if guest_count > 0:
        detail_parts.append(f"{guest_count} davetli")
    if reward_count > 0:
        detail_parts.append(f"{reward_count} ücretsiz")
    if not detail_parts:
        return f"{active_total} aktif bilet"
    return f"{active_total} aktif bilet ({', '.join(detail_parts)})"


def _fetch_event_ticket_controls_bulk(conn, event_items: List[Dict[str, Any]]) -> Dict[int, Dict[str, Any]]:
    submission_ids = sorted(
        {
            int(item.get("id") or item.get("submission_id") or 0)
            for item in (event_items or [])
            if int(item.get("id") or item.get("submission_id") or 0) > 0
        }
    )
    if not submission_ids:
        return {}

    cur = conn.cursor()
    mapped: Dict[int, Dict[str, Any]] = {
        sid: {
            "summary": {
                "submission_id": sid,
                "active_ticket_count": 0,
                "active_holder_count": 0,
                "paid_ticket_count": 0,
                "guest_ticket_count": 0,
                "reward_ticket_count": 0,
                "summary_text": _ticket_control_summary_text({"active_ticket_count": 0}, include_zero=True),
            },
            "holders": [],
        }
        for sid in submission_ids
    }

    cur.execute(
        """
        SELECT
            t.submission_id,
            COUNT(*)::INT AS active_ticket_count,
            COUNT(DISTINCT t.account_id)::INT AS active_holder_count,
            SUM(CASE WHEN COALESCE(t.ticket_type,'paid')='paid' THEN 1 ELSE 0 END)::INT AS paid_ticket_count,
            SUM(CASE WHEN COALESCE(t.ticket_type,'paid')='guest' THEN 1 ELSE 0 END)::INT AS guest_ticket_count,
            SUM(CASE WHEN COALESCE(t.ticket_type,'paid')='loyalty_reward' THEN 1 ELSE 0 END)::INT AS reward_ticket_count
        FROM mobile_tickets t
        WHERE t.submission_id = ANY(?)
          AND COALESCE(t.status,'active')='active'
          AND t.used_at IS NULL
        GROUP BY t.submission_id
        """,
        (submission_ids,),
    )
    for row in (cur.fetchall() or []):
        sid = int(row["submission_id"])
        summary = {
            "submission_id": sid,
            "active_ticket_count": int(row.get("active_ticket_count") or 0),
            "active_holder_count": int(row.get("active_holder_count") or 0),
            "paid_ticket_count": int(row.get("paid_ticket_count") or 0),
            "guest_ticket_count": int(row.get("guest_ticket_count") or 0),
            "reward_ticket_count": int(row.get("reward_ticket_count") or 0),
        }
        summary["summary_text"] = _ticket_control_summary_text(summary, include_zero=True)
        mapped.setdefault(sid, {"summary": {}, "holders": []})["summary"] = summary

    cur.execute(
        """
        SELECT
            t.submission_id,
            t.account_id,
            COALESCE(t.ticket_type,'paid') AS ticket_type,
            COUNT(*)::INT AS ticket_count,
            MIN(t.created_at) AS first_created_at,
            MAX(t.created_at) AS last_created_at,
            COALESCE(gl.name,'') AS source_guest_list_name,
            COALESCE(NULLIF(TRIM(a.name),''), NULLIF(TRIM(ps.username),''), SPLIT_PART(COALESCE(a.email,''), '@', 1), 'user') AS display_name,
            COALESCE(a.email,'') AS email,
            COALESCE(ps.avatar_url,'') AS avatar_url,
            COALESCE(ps.is_verified, FALSE) AS is_verified,
            COALESCE(a.role,'') AS role,
            COALESCE(a.can_create_mobile_event, 0) AS can_create_mobile_event
        FROM mobile_tickets t
        JOIN accounts a ON a.id = t.account_id
        LEFT JOIN mobile_profile_settings ps ON ps.account_id = t.account_id
        LEFT JOIN mobile_guest_lists gl ON gl.id = t.source_guest_list_id
        WHERE t.submission_id = ANY(?)
          AND COALESCE(t.status,'active')='active'
          AND t.used_at IS NULL
        GROUP BY
            t.submission_id,
            t.account_id,
            COALESCE(t.ticket_type,'paid'),
            gl.name,
            a.name,
            a.email,
            ps.username,
            ps.avatar_url,
            ps.is_verified,
            a.role,
            a.can_create_mobile_event
        ORDER BY
            t.submission_id ASC,
            CASE COALESCE(t.ticket_type,'paid')
                WHEN 'paid' THEN 0
                WHEN 'guest' THEN 1
                WHEN 'loyalty_reward' THEN 2
                ELSE 9
            END ASC,
            MAX(t.created_at) DESC,
            t.account_id ASC
        """,
        (submission_ids,),
    )
    for row in (cur.fetchall() or []):
        sid = int(row["submission_id"])
        raw_ticket_type = (row.get("ticket_type") or "paid").strip().lower()
        mapped.setdefault(sid, {"summary": {}, "holders": []})["holders"].append(
            {
                "account_id": int(row["account_id"]),
                "name": (row.get("display_name") or "").strip() or "user",
                "email": (row.get("email") or "").strip(),
                "avatar_url": (row.get("avatar_url") or "").strip(),
                "is_verified": bool(row.get("is_verified"))
                or _boolish(row.get("can_create_mobile_event"), default=False)
                or (row.get("role") or "").strip().lower() in {"super_admin", "editor"},
                "ticket_type": raw_ticket_type,
                "ticket_type_label": _ticket_type_label_text(raw_ticket_type),
                "ticket_count": int(row.get("ticket_count") or 0),
                "source_guest_list_name": (row.get("source_guest_list_name") or "").strip(),
                "first_created_at": (row.get("first_created_at") or "").strip(),
                "last_created_at": (row.get("last_created_at") or "").strip(),
            }
        )

    return mapped


def _cached_woo_event_products(limit: int = 150, ttl_seconds: int = 180) -> Dict[str, Any]:
    cache_key = f"woo_event_products:{int(limit)}"
    cached = _cache_get(cache_key, ttl_seconds)
    if cached is not None:
        return cached
    result = list_woo_event_products(limit=limit)
    return _cache_set(cache_key, result)


def _normalize_admin_mobile_events_view(value: Optional[str]) -> str:
    allowed = {"overview", "requests", "active", "hidden", "history", "create", "guest-lists"}
    view = (value or "overview").strip().lower()
    if view not in allowed:
        return "overview"
    return view


def _cached_admin_event_loyalty_reports(
    event_items: List[Dict[str, Any]],
    ttl_seconds: int = 45,
) -> tuple[Dict[int, Dict[str, Any]], str]:
    submission_ids = sorted(
        {
            int(item.get("id") or item.get("submission_id") or 0)
            for item in (event_items or [])
            if (item.get("status") or "").strip().lower() in {"approved", "expired"}
            and int(item.get("id") or item.get("submission_id") or 0) > 0
        }
    )
    if not submission_ids:
        return {}, ""
    cache_key = f"admin_event_loyalty_reports:{','.join(str(sid) for sid in submission_ids)}"
    cached = _cache_get(cache_key, ttl_seconds)
    if cached is not None:
        return cached
    result = _fetch_admin_event_loyalty_reports(event_items)
    return _cache_set(cache_key, result)


def sync_wp_customer_role_for_account(account_id: int, is_editor: bool) -> Dict[str, Any]:
    """
    App tarafındaki editör yetkisini WP/Woo kullanıcı rolüne yansıtır.
    Editor => editor, değilse => customer
    """
    base = (os.getenv("WOO_BASE_URL", "") or "").strip().rstrip("/")
    ck = (os.getenv("WOO_CONSUMER_KEY", "") or "").strip()
    cs = (os.getenv("WOO_CONSUMER_SECRET", "") or "").strip()
    if not base or not ck or not cs:
        return {"ok": False, "error": "Woo ayarları eksik (WOO_BASE_URL/CK/CS)"}

    conn = db_conn()
    c = conn.cursor()
    try:
        c.execute("SELECT email FROM accounts WHERE id=? LIMIT 1", (int(account_id),))
        row = c.fetchone()
        if not row:
            return {"ok": False, "error": "Hesap bulunamadı"}
        email = (row["email"] or "").strip().lower()
        if not email:
            return {"ok": False, "error": "Hesap e-postası boş"}

        wp_user_id = None
        try:
            c.execute(
                """
                SELECT wp_user_id
                FROM identity_map
                WHERE app_account_id=? AND COALESCE(is_active,1)=1
                ORDER BY linked_at DESC
                LIMIT 1
                """,
                (int(account_id),),
            )
            m = c.fetchone()
            if m and m["wp_user_id"] is not None:
                wp_user_id = int(m["wp_user_id"])
        except Exception:
            wp_user_id = None
    finally:
        conn.close()

    def _auth_header() -> Dict[str, str]:
        return {
            "Authorization": "Basic "
            + base64.b64encode(f"{ck}:{cs}".encode("utf-8")).decode("utf-8"),
        }

    if not wp_user_id:
        email_q = urllib.parse.quote(email)
        find_endpoint = f"{base}/wp-json/wc/v3/customers?email={email_q}&per_page=1"
        find_req = urllib.request.Request(find_endpoint, headers=_auth_header(), method="GET")
        try:
            with urllib.request.urlopen(find_req, timeout=20) as resp:
                body = resp.read().decode("utf-8", errors="replace")
                arr = json.loads(body) if body else []
            if isinstance(arr, list) and arr:
                wp_user_id = int(arr[0].get("id") or 0) or None
        except Exception as e:
            return {"ok": False, "error": f"Woo kullanıcı sorgusu başarısız: {e}"}

    # Panelde var ama WP'de yoksa otomatik oluşturup eşleştir.
    if not wp_user_id:
        temp_password = secrets.token_urlsafe(24)
        username = email.split("@", 1)[0][:50]
        create_endpoint = f"{base}/wp-json/wc/v3/customers"
        create_payload = {
            "email": email,
            "username": username or f"user{account_id}",
            "password": temp_password,
            "first_name": "",
            "last_name": "",
            "role": "customer",
        }
        create_req = urllib.request.Request(
            create_endpoint,
            data=json.dumps(create_payload).encode("utf-8"),
            headers={"Content-Type": "application/json", **_auth_header()},
            method="POST",
        )
        try:
            with urllib.request.urlopen(create_req, timeout=20) as resp:
                body = resp.read().decode("utf-8", errors="replace")
                created = json.loads(body) if body else {}
            wp_user_id = int(created.get("id") or 0) or None
        except urllib.error.HTTPError as e:
            msg = e.read().decode("utf-8", errors="replace")
            return {"ok": False, "error": f"Woo kullanıcı oluşturma hatası: HTTP {e.code}: {msg[:300]}"}
        except Exception as e:
            return {"ok": False, "error": f"Woo kullanıcı oluşturma hatası: {e}"}

    if not wp_user_id:
        return {"ok": False, "error": "WP/Woo kullanıcı eşleşmesi bulunamadı"}

    # identity_map'i garanti et
    try:
        conn2 = db_conn()
        c2 = conn2.cursor()
        c2.execute(
            """
            INSERT INTO identity_map (wp_user_id, app_account_id, match_strategy, confidence, note, is_active)
            VALUES (?, ?, 'role_sync', 95, 'ensure_wp_mapping', TRUE)
            ON CONFLICT (wp_user_id) DO UPDATE
            SET app_account_id=EXCLUDED.app_account_id,
                match_strategy=EXCLUDED.match_strategy,
                confidence=EXCLUDED.confidence,
                note=EXCLUDED.note,
                linked_at=NOW(),
                is_active=TRUE
            """,
            (int(wp_user_id), int(account_id)),
        )
        conn2.commit()
        conn2.close()
    except Exception:
        try:
            conn2.close()
        except Exception:
            pass

    target_role = "editor" if bool(is_editor) else "customer"
    endpoint = f"{base}/wp-json/wc/v3/customers/{int(wp_user_id)}"
    payload = {"role": target_role}
    req = urllib.request.Request(
        endpoint,
        data=json.dumps(payload).encode("utf-8"),
        headers={
            "Content-Type": "application/json",
            "Authorization": "Basic "
            + base64.b64encode(f"{ck}:{cs}".encode("utf-8")).decode("utf-8"),
        },
        method="PUT",
    )
    try:
        with urllib.request.urlopen(req, timeout=20) as resp:
            body = resp.read().decode("utf-8", errors="replace")
            data = json.loads(body) if body else {}
        return {"ok": True, "wp_user_id": int(data.get("id") or wp_user_id), "role": str(data.get("role") or target_role)}
    except urllib.error.HTTPError as e:
        msg = e.read().decode("utf-8", errors="replace")
        return {"ok": False, "error": f"Woo HTTP {e.code}: {msg[:400]}"}
    except Exception as e:
        return {"ok": False, "error": f"Woo rol güncelleme hatası: {e}"}


def ensure_identity_tables():
    conn = db_conn()
    c = conn.cursor()
    c.execute(
        """
        CREATE TABLE IF NOT EXISTS identity_map (
            wp_user_id BIGINT PRIMARY KEY,
            app_account_id BIGINT UNIQUE,
            match_strategy TEXT,
            confidence INTEGER,
            note TEXT,
            linked_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            is_active BOOLEAN NOT NULL DEFAULT TRUE
        )
        """
    )
    c.execute(
        """
        CREATE TABLE IF NOT EXISTS identity_merge_audit (
            id BIGSERIAL PRIMARY KEY,
            run_id BIGINT,
            wp_user_id BIGINT,
            app_account_id BIGINT,
            action TEXT NOT NULL,
            details TEXT,
            created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
        )
        """
    )
    conn.commit()
    conn.close()


def fetch_all_wp_customers() -> List[Dict[str, Any]]:
    base = (os.getenv("WOO_BASE_URL", "") or "").strip().rstrip("/")
    ck = (os.getenv("WOO_CONSUMER_KEY", "") or "").strip()
    cs = (os.getenv("WOO_CONSUMER_SECRET", "") or "").strip()
    if not base or not ck or not cs:
        raise RuntimeError("Woo ayarları eksik (WOO_BASE_URL/CK/CS)")

    page = 1
    per_page = 100
    out: List[Dict[str, Any]] = []
    def _get_json_with_retry(url: str, headers: Dict[str, str], timeout_sec: int = 60, retries: int = 3):
        last_err = None
        for i in range(max(1, retries)):
            try:
                req = urllib.request.Request(url, headers=headers, method="GET")
                with urllib.request.urlopen(req, timeout=timeout_sec) as resp:
                    body = resp.read().decode("utf-8", errors="replace")
                    return json.loads(body) if body else []
            except Exception as e:
                last_err = e
                if i < retries - 1:
                    time.sleep(0.8 * (2 ** i))
        raise last_err if last_err else RuntimeError("WP yanıtı alınamadı")

    headers = {
        "Authorization": "Basic "
        + base64.b64encode(f"{ck}:{cs}".encode("utf-8")).decode("utf-8"),
    }

    while True:
        endpoint = f"{base}/wp-json/wc/v3/customers?per_page={per_page}&page={page}"
        rows = _get_json_with_retry(endpoint, headers=headers, timeout_sec=15, retries=2)
        if not isinstance(rows, list) or not rows:
            break
        for r in rows:
            first = (r.get("first_name") or "").strip()
            last = (r.get("last_name") or "").strip()
            full = (first + " " + last).strip()
            out.append(
                {
                    "wp_user_id": int(r.get("id") or 0),
                    "email": (r.get("email") or "").strip().lower(),
                    "username": (r.get("username") or "").strip(),
                    "display_name": full or (r.get("username") or "").strip() or (r.get("email") or "").strip(),
                    "role": (r.get("role") or "customer").strip().lower(),
                }
            )
        if len(rows) < per_page:
            break
        page += 1
    return out


def fetch_all_wp_users() -> List[Dict[str, Any]]:
    base = (os.getenv("WOO_BASE_URL", "") or "").strip().rstrip("/")
    if not base:
        raise RuntimeError("WOO_BASE_URL eksik")
    if not WP_SYNC_ADMIN_USERNAME or not WP_SYNC_ADMIN_PASSWORD:
        raise RuntimeError("WP_SYNC_ADMIN_USERNAME / WP_SYNC_ADMIN_PASSWORD eksik")

    login_payload = urllib.parse.urlencode(
        {"username": WP_SYNC_ADMIN_USERNAME, "password": WP_SYNC_ADMIN_PASSWORD}
    ).encode("utf-8")
    login_req = urllib.request.Request(
        f"{base}/wp-json/jwt-auth/v1/token",
        data=login_payload,
        headers={"Content-Type": "application/x-www-form-urlencoded"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(login_req, timeout=10) as resp:
            body = resp.read().decode("utf-8", errors="replace")
            payload = json.loads(body) if body else {}
    except Exception as e:
        raise RuntimeError(f"WP JWT login hatası: {e}")
    token = (payload.get("token") or "").strip()
    if not token:
        raise RuntimeError("WP JWT token alınamadı")

    out: List[Dict[str, Any]] = []
    page = 1
    per_page = 100
    while True:
        endpoint = f"{base}/wp-json/wp/v2/users?context=edit&per_page={per_page}&page={page}"
        req = urllib.request.Request(
            endpoint,
            headers={"Authorization": f"Bearer {token}"},
            method="GET",
        )
        try:
            with urllib.request.urlopen(req, timeout=15) as resp:
                body = resp.read().decode("utf-8", errors="replace")
                rows = json.loads(body) if body else []
        except urllib.error.HTTPError as e:
            if e.code == 400:
                break
            msg = e.read().decode("utf-8", errors="replace")
            raise RuntimeError(f"WP users HTTP {e.code}: {msg[:300]}")
        except Exception as e:
            raise RuntimeError(f"WP users okuma hatası: {e}")

        if not isinstance(rows, list) or not rows:
            break
        for r in rows:
            roles = [str(x).strip().lower() for x in (r.get("roles") or []) if str(x).strip()]
            role = roles[0] if roles else "customer"
            out.append(
                {
                    "wp_user_id": int(r.get("id") or 0),
                    "email": (r.get("email") or "").strip().lower(),
                    "username": (r.get("slug") or r.get("name") or "").strip(),
                    "display_name": (r.get("name") or "").strip() or (r.get("slug") or "").strip(),
                    "role": role,
                }
            )
        if len(rows) < per_page:
            break
        page += 1
    return out


def fetch_wp_directory_users() -> List[Dict[str, Any]]:
    def _role_priority(role: str) -> int:
        r = (role or "").strip().lower()
        if r == "administrator":
            return 3
        if r in {"editor", "shop_manager"}:
            return 2
        return 1

    merged: Dict[str, Dict[str, Any]] = {}
    for u in fetch_all_wp_customers():
        email = (u.get("email") or "").strip().lower()
        if not email:
            continue
        merged[email] = dict(u)

    wp_err = None
    try:
        wp_users = fetch_all_wp_users()
    except Exception as e:
        wp_users = []
        wp_err = str(e)

    for u in wp_users:
        email = (u.get("email") or "").strip().lower()
        if not email:
            continue
        prev = merged.get(email)
        if not prev:
            merged[email] = dict(u)
            continue
        if _role_priority(u.get("role") or "") >= _role_priority(prev.get("role") or ""):
            prev["role"] = (u.get("role") or prev.get("role") or "customer").strip().lower()
        if not prev.get("wp_user_id") and u.get("wp_user_id"):
            prev["wp_user_id"] = int(u.get("wp_user_id") or 0)
        if not prev.get("display_name") and u.get("display_name"):
            prev["display_name"] = u.get("display_name")
        merged[email] = prev

    out = list(merged.values())
    if wp_err:
        log(f"[WP_SYNC] fetch_all_wp_users warning: {wp_err}")
    return out


def _wp_role_to_editor(role: str, email: str = "") -> int:
    rl = (role or "").strip().lower()
    if rl in {"editor", "shop_manager"}:
        return 1
    if rl == "administrator" and _wp_email_can_be_super_admin(email):
        return 1
    return 0


def _wp_email_can_be_super_admin(email: str) -> bool:
    e = (email or "").strip().lower()
    if not e:
        return False
    allow = set(WP_SYNC_SUPERADMIN_EMAILS)
    allow.update(
        {
            (WP_SYNC_ADMIN_USERNAME or "").strip().lower(),
            (os.getenv("SUPERADMIN_EMAIL", "") or "").strip().lower(),
            "ism.ustundag@gmail.com",
            "info@dansmagazin.net",
        }
    )
    allow.discard("")
    return e in allow


def _wp_role_to_local_role(role: str, email: str = "") -> str:
    rl = (role or "").strip().lower()
    if rl == "administrator":
        return "super_admin" if _wp_email_can_be_super_admin(email) else "customer"
    if rl in {"editor", "shop_manager"}:
        return "editor"
    return "customer"


def sync_wp_users_to_panel(push_panel_to_wp: bool = False) -> Dict[str, Any]:
    ensure_identity_tables()
    wp_users = fetch_wp_directory_users()

    created = 0
    updated = 0
    mapped = 0
    conflicts = 0
    skipped = 0
    panel_to_wp_created = 0
    panel_to_wp_mapped = 0

    conn = db_conn()
    c = conn.cursor()
    try:
        for w in wp_users:
            wp_user_id = int(w.get("wp_user_id") or 0)
            email = (w.get("email") or "").strip().lower()
            if not wp_user_id or not email:
                skipped += 1
                continue

            c.execute("SELECT id, role, COALESCE(can_create_mobile_event,0) AS can_create_mobile_event FROM accounts WHERE LOWER(email)=LOWER(?) LIMIT 1", (email,))
            acc = c.fetchone()
            wp_role = (w.get("role") or "").strip().lower()
            editor_flag = _wp_role_to_editor(wp_role, email)
            local_role = _wp_role_to_local_role(wp_role, email)

            if not acc:
                random_pw = secrets.token_urlsafe(24)
                c.execute(
                    """
                    INSERT INTO accounts (email, password_hash, role, is_active, photo_credit, name, created_at, can_create_mobile_event)
                    VALUES (?, ?, ?, 1, 0, ?, ?, ?)
                    RETURNING id
                    """,
                    (email, hash_password(random_pw), local_role, (w.get("display_name") or None), iso_now(), editor_flag),
                )
                acc_id = int(c.fetchone()[0])
                created += 1
            else:
                acc_id = int(acc["id"])
                current_role = (acc.get("role") or "customer").strip().lower()
                current_can_create = int(acc.get("can_create_mobile_event") or 0)

                # Panelden müşteriye verilen "mobil etkinlik oluşturma" yetkisi
                # (can_create_mobile_event=1) WP rolü customer olsa da korunmalı.
                target_role = local_role
                target_can_create = editor_flag
                if local_role == "customer" and current_can_create == 1:
                    target_can_create = 1
                    # customer hesabı panelde editor role'a zorlanmamalı; flag yeterli.
                    if current_role in {"customer", "editor"}:
                        target_role = current_role if current_role == "editor" else "customer"

                if current_can_create != int(target_can_create) or current_role != target_role:
                    c.execute(
                        "UPDATE accounts SET can_create_mobile_event=?, role=? WHERE id=?",
                        (int(target_can_create), target_role, acc_id),
                    )
                    updated += 1

            c.execute("SELECT wp_user_id FROM identity_map WHERE app_account_id=? AND COALESCE(is_active,TRUE)=TRUE LIMIT 1", (acc_id,))
            row = c.fetchone()
            if row and row["wp_user_id"] is not None and int(row["wp_user_id"]) != wp_user_id:
                conflicts += 1
                continue

            c.execute(
                """
                INSERT INTO identity_map (wp_user_id, app_account_id, match_strategy, confidence, note, is_active)
                VALUES (?, ?, 'wp_sync_email', 100, 'admin_sync', TRUE)
                ON CONFLICT (wp_user_id) DO UPDATE
                SET app_account_id=EXCLUDED.app_account_id,
                    match_strategy=EXCLUDED.match_strategy,
                    confidence=EXCLUDED.confidence,
                    note=EXCLUDED.note,
                    linked_at=NOW(),
                    is_active=TRUE
                """,
                (wp_user_id, acc_id),
            )
            mapped += 1

        # İsteğe bağlı: iki yönlü mod (legacy). Varsayılan tek yönlüdür (WP -> panel).
        if push_panel_to_wp:
            c.execute(
                """
                SELECT a.id, a.email, COALESCE(a.can_create_mobile_event,0) AS can_create_mobile_event
                FROM accounts a
                WHERE a.role='customer' AND COALESCE(a.is_active,1)=1
                ORDER BY a.id DESC
                """
            )
            panel_users = c.fetchall() or []
            for p in panel_users:
                acc_id = int(p["id"])
                email = (p["email"] or "").strip().lower()
                if not email or email.startswith("merged+"):
                    skipped += 1
                    continue
                c.execute("SELECT wp_user_id FROM identity_map WHERE app_account_id=? AND COALESCE(is_active,TRUE)=TRUE LIMIT 1", (acc_id,))
                existing = c.fetchone()
                had_mapping = bool(existing and existing["wp_user_id"])

                sync_res = sync_wp_customer_role_for_account(acc_id, bool(int(p["can_create_mobile_event"] or 0)))
                if sync_res.get("ok"):
                    panel_to_wp_mapped += 1
                    if not had_mapping:
                        panel_to_wp_created += 1

        conn.commit()
    finally:
        conn.close()

    return {
        "created": created,
        "updated": updated,
        "mapped": mapped,
        "conflicts": conflicts,
        "skipped": skipped,
        "wp_total": len(wp_users),
        "panel_to_wp_created": panel_to_wp_created,
        "panel_to_wp_mapped": panel_to_wp_mapped,
    }


def maybe_sync_wp_users(force: bool = False) -> Dict[str, Any]:
    global _WP_SYNC_LAST_TS, _WP_SYNC_LAST_STATS, _WP_SYNC_LAST_ERR
    now_ts = time.time()
    if not force and _WP_SYNC_LAST_TS > 0 and (now_ts - _WP_SYNC_LAST_TS) < max(10, WP_SYNC_MIN_INTERVAL_SEC):
        stats = dict(_WP_SYNC_LAST_STATS or {})
        stats["cached"] = True
        stats["seconds_since_last"] = int(now_ts - _WP_SYNC_LAST_TS)
        if _WP_SYNC_LAST_ERR:
            stats["last_error"] = _WP_SYNC_LAST_ERR
        return stats

    with _WP_SYNC_LOCK:
        now_ts = time.time()
        if not force and _WP_SYNC_LAST_TS > 0 and (now_ts - _WP_SYNC_LAST_TS) < max(10, WP_SYNC_MIN_INTERVAL_SEC):
            stats = dict(_WP_SYNC_LAST_STATS or {})
            stats["cached"] = True
            stats["seconds_since_last"] = int(now_ts - _WP_SYNC_LAST_TS)
            if _WP_SYNC_LAST_ERR:
                stats["last_error"] = _WP_SYNC_LAST_ERR
            return stats
        try:
            stats = sync_wp_users_to_panel(push_panel_to_wp=False)
            _WP_SYNC_LAST_TS = time.time()
            _WP_SYNC_LAST_STATS = dict(stats)
            _WP_SYNC_LAST_ERR = ""
            stats["cached"] = False
            stats["seconds_since_last"] = 0
            return stats
        except Exception as e:
            _WP_SYNC_LAST_ERR = str(e)
            stats = dict(_WP_SYNC_LAST_STATS or {})
            stats["cached"] = True
            stats["last_error"] = _WP_SYNC_LAST_ERR
            stats["seconds_since_last"] = int(time.time() - _WP_SYNC_LAST_TS) if _WP_SYNC_LAST_TS > 0 else -1
            return stats


def get_wp_sync_snapshot() -> Dict[str, Any]:
    with _WP_SYNC_LOCK:
        now_ts = time.time()
        stats = dict(_WP_SYNC_LAST_STATS or {})
        stats["cached"] = True
        stats["seconds_since_last"] = int(now_ts - _WP_SYNC_LAST_TS) if _WP_SYNC_LAST_TS > 0 else -1
        if not WP_SYNC_ADMIN_USERNAME or not WP_SYNC_ADMIN_PASSWORD:
            stats["last_error"] = "WP_SYNC_ADMIN_USERNAME / WP_SYNC_ADMIN_PASSWORD eksik. Woo müşteri listesi gelir, editor/admin kullanıcıları eksik kalabilir."
        if _WP_SYNC_LAST_ERR:
            stats["last_error"] = _WP_SYNC_LAST_ERR
        return stats

app.mount("/media", StaticFiles(directory=MEDIA_DIR), name="media")
app.mount("/static", StaticFiles(directory=os.path.join(ROOT_DIR, "static")), name="static")


# =========================
# LOG
# =========================

APP_TIMEZONE = os.getenv("APP_TIMEZONE", "Europe/Istanbul")


def _local_now() -> datetime:
    try:
        return datetime.now(ZoneInfo(APP_TIMEZONE))
    except Exception:
        return datetime.now(timezone.utc)


def log(msg: str):
    print(f"[{_local_now().isoformat(timespec='seconds')}] {msg}", flush=True)


def _now_s():
    return datetime.utcnow().timestamp()


def iso_now() -> str:
    return _local_now().isoformat(timespec="seconds")


# =========================
# DB HELPERS
# =========================

def _adapt_sql(sql: str) -> str:
    if USE_POSTGRES:
        return sql.replace("?", "%s")
    return sql


if USE_POSTGRES:
    DBOperationalError = psycopg2.OperationalError
else:
    DBOperationalError = sqlite3.OperationalError


class _PgCursor:
    def __init__(self, cur):
        self._cur = cur

    def execute(self, sql, params=None):
        return self._cur.execute(_adapt_sql(sql), params or ())

    def executemany(self, sql, seq):
        return self._cur.executemany(_adapt_sql(sql), seq)

    def fetchone(self):
        return self._cur.fetchone()

    def fetchall(self):
        return self._cur.fetchall()

    @property
    def rowcount(self):
        return self._cur.rowcount

    @property
    def lastrowid(self):
        return None

    def __getattr__(self, name):
        return getattr(self._cur, name)


class _PgConn:
    def __init__(self, conn):
        self._conn = conn

    def cursor(self):
        return _PgCursor(self._conn.cursor())

    def execute(self, sql, params=None):
        cur = self.cursor()
        cur.execute(sql, params)
        return cur

    def commit(self):
        return self._conn.commit()

    def rollback(self):
        return self._conn.rollback()

    def close(self):
        return self._conn.close()


def db_conn():
    if USE_POSTGRES:
        conn = psycopg2.connect(DATABASE_URL, cursor_factory=psycopg2.extras.DictCursor)
        return _PgConn(conn)
    conn = sqlite3.connect(DB_PATH, check_same_thread=False, timeout=10)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA busy_timeout = 5000;")
    conn.execute("PRAGMA journal_mode = WAL;")
    conn.execute("PRAGMA synchronous = NORMAL;")
    return conn


def _human_size(size_bytes: int) -> str:
    value = float(max(0, int(size_bytes or 0)))
    units = ["B", "KB", "MB", "GB", "TB"]
    idx = 0
    while value >= 1024 and idx < len(units) - 1:
        value /= 1024.0
        idx += 1
    if idx == 0:
        return f"{int(value)} {units[idx]}"
    if value >= 100:
        return f"{value:.0f} {units[idx]}"
    if value >= 10:
        return f"{value:.1f} {units[idx]}"
    return f"{value:.2f} {units[idx]}"


def _safe_tree_size(path: str) -> int:
    total = 0
    if not path or not os.path.exists(path):
        return 0
    for root, _, files in os.walk(path):
        for filename in files:
            try:
                total += os.path.getsize(os.path.join(root, filename))
            except OSError:
                pass
    return total


def _fetch_scalar(cur, sql: str, params: Optional[tuple] = None, default: int = 0) -> int:
    cur.execute(_adapt_sql(sql), params or ())
    row = cur.fetchone()
    if not row:
        return int(default)
    try:
        if isinstance(row, dict):
            value = next(iter(row.values()))
        else:
            value = row[0]
        return int(value or 0)
    except Exception:
        return int(default)


def _build_admin_reports(
    conn,
    *,
    active_events_count: int = 0,
    past_events_count: int = 0,
    message_q: str = "",
    message_limit: int = 100,
    conversation_a: int = 0,
    conversation_b: int = 0,
) -> Dict[str, Any]:
    today = _local_now().date()
    today_str = today.isoformat()
    last_7_str = (today - timedelta(days=6)).isoformat()
    last_30_str = (today - timedelta(days=29)).isoformat()
    disk_total, disk_used, disk_free = shutil.disk_usage(ROOT_DIR)
    panel_media_size = _safe_tree_size(MEDIA_DIR)
    backend_media_dir = "/home/ubuntu/mobil_backend/media"
    backend_media_size = _safe_tree_size(backend_media_dir)
    panel_media_children = [
        ("Etkinlik fotoğrafları", os.path.join(MEDIA_DIR, "event_photos")),
        ("Thumb klasörü", os.path.join(MEDIA_DIR, "_thumbs")),
        ("Kapak görselleri", os.path.join(MEDIA_DIR, "submission_covers")),
        ("Haber kapakları", os.path.join(MEDIA_DIR, "news_submission_covers")),
        ("QR kodları", os.path.join(MEDIA_DIR, "qr")),
    ]
    disk_items = []
    for label, path in panel_media_children:
        size_val = _safe_tree_size(path)
        if size_val <= 0:
            continue
        disk_items.append(
            {
                "label": label,
                "path": path,
                "size_bytes": int(size_val),
                "size_text": _human_size(size_val),
            }
        )
    disk_items.sort(key=lambda item: int(item.get("size_bytes") or 0), reverse=True)

    report: Dict[str, Any] = {
        "disk": {
            "server_total_text": _human_size(disk_total),
            "server_used_text": _human_size(disk_used),
            "server_free_text": _human_size(disk_free),
            "server_used_pct": int(round((disk_used / disk_total) * 100)) if disk_total else 0,
            "panel_media_text": _human_size(panel_media_size),
            "backend_media_text": _human_size(backend_media_size),
            "items": disk_items,
        },
        "registrations": {
            "total_users": 0,
            "today_users": 0,
            "last_7_days": 0,
            "last_30_days": 0,
            "daily_rows": [],
            "max_daily_count": 0,
        },
        "messages": {
            "total_messages": 0,
            "today_messages": 0,
            "last_7_days": 0,
            "conversation_count": 0,
            "top_users": [],
            "recent_pairs": [],
            "conversations": [],
            "selected_thread": {
                "a_id": 0,
                "b_id": 0,
                "title": "",
                "messages": [],
            },
            "filters": {
                "q": (message_q or "").strip(),
                "limit": max(20, min(int(message_limit or 100), 200)),
                "conversation_a": int(conversation_a or 0),
                "conversation_b": int(conversation_b or 0),
            },
        },
        "devices": {
            "total_tokens": 0,
            "active_tokens": 0,
            "deliverable_tokens": 0,
            "ios_tokens": 0,
            "android_tokens": 0,
            "web_tokens": 0,
        },
        "content": {
            "active_events": int(active_events_count or 0),
            "past_events": int(past_events_count or 0),
            "approved_news": 0,
            "open_albums": 0,
            "store_products": 0,
            "pending_friend_requests": 0,
            "open_user_reports": 0,
            "notifications_today": 0,
        },
        "errors": [],
    }

    cur = conn.cursor()

    try:
        report["registrations"]["total_users"] = _fetch_scalar(
            cur,
            "SELECT COUNT(*) FROM accounts WHERE COALESCE(role,'customer')='customer'",
        )
        report["registrations"]["today_users"] = _fetch_scalar(
            cur,
            "SELECT COUNT(*) FROM accounts WHERE COALESCE(role,'customer')='customer' AND LEFT(COALESCE(created_at,''),10)=?",
            (today_str,),
        )
        report["registrations"]["last_7_days"] = _fetch_scalar(
            cur,
            "SELECT COUNT(*) FROM accounts WHERE COALESCE(role,'customer')='customer' AND LEFT(COALESCE(created_at,''),10)>=?",
            (last_7_str,),
        )
        report["registrations"]["last_30_days"] = _fetch_scalar(
            cur,
            "SELECT COUNT(*) FROM accounts WHERE COALESCE(role,'customer')='customer' AND LEFT(COALESCE(created_at,''),10)>=?",
            (last_30_str,),
        )
        cur.execute(
            """
            SELECT LEFT(COALESCE(created_at,''),10) AS day_key, COUNT(*) AS user_count
            FROM accounts
            WHERE COALESCE(role,'customer')='customer'
              AND LEFT(COALESCE(created_at,''),10) <> ''
            GROUP BY LEFT(COALESCE(created_at,''),10)
            ORDER BY day_key DESC
            LIMIT 14
            """
        )
        daily_rows = []
        max_daily = 0
        for row in (cur.fetchall() or []):
            count_val = int(row["user_count"] or 0)
            max_daily = max(max_daily, count_val)
            daily_rows.append(
                {
                    "day": (row.get("day_key") or "").strip(),
                    "count": count_val,
                }
            )
        report["registrations"]["daily_rows"] = daily_rows
        report["registrations"]["max_daily_count"] = max_daily
    except Exception as exc:
        report["errors"].append(f"Kayıt raporu alınamadı: {exc}")

    try:
        report["messages"]["total_messages"] = _fetch_scalar(cur, "SELECT COUNT(*) FROM mobile_direct_messages")
        report["messages"]["today_messages"] = _fetch_scalar(
            cur,
            "SELECT COUNT(*) FROM mobile_direct_messages WHERE LEFT(COALESCE(created_at,''),10)=?",
            (today_str,),
        )
        report["messages"]["last_7_days"] = _fetch_scalar(
            cur,
            "SELECT COUNT(*) FROM mobile_direct_messages WHERE LEFT(COALESCE(created_at,''),10)>=?",
            (last_7_str,),
        )
        report["messages"]["conversation_count"] = _fetch_scalar(
            cur,
            """
            SELECT COUNT(*) FROM (
                SELECT LEAST(sender_account_id, receiver_account_id) AS a,
                       GREATEST(sender_account_id, receiver_account_id) AS b
                FROM mobile_direct_messages
                GROUP BY 1,2
            ) t
            """,
        )
        cur.execute(
            """
            WITH sent AS (
                SELECT sender_account_id AS account_id,
                       COUNT(*) AS sent_count,
                       MAX(created_at) AS last_sent_at
                FROM mobile_direct_messages
                GROUP BY sender_account_id
            ),
            received AS (
                SELECT receiver_account_id AS account_id,
                       COUNT(*) AS received_count,
                       MAX(created_at) AS last_received_at
                FROM mobile_direct_messages
                GROUP BY receiver_account_id
            )
            SELECT
                a.id,
                COALESCE(NULLIF(TRIM(a.name),''), SPLIT_PART(COALESCE(a.email,''), '@', 1), 'user') AS display_name,
                COALESCE(a.email,'') AS email,
                COALESCE(sent.sent_count, 0) AS sent_count,
                COALESCE(received.received_count, 0) AS received_count,
                GREATEST(COALESCE(sent.last_sent_at, ''), COALESCE(received.last_received_at, '')) AS last_message_at
            FROM accounts a
            LEFT JOIN sent ON sent.account_id=a.id
            LEFT JOIN received ON received.account_id=a.id
            WHERE COALESCE(sent.sent_count,0) + COALESCE(received.received_count,0) > 0
            ORDER BY (COALESCE(sent.sent_count,0) + COALESCE(received.received_count,0)) DESC,
                     last_message_at DESC
            LIMIT 20
            """
        )
        report["messages"]["top_users"] = [
            {
                "account_id": int(row["id"] or 0),
                "display_name": (row.get("display_name") or "user").strip(),
                "email": (row.get("email") or "").strip(),
                "sent_count": int(row.get("sent_count") or 0),
                "received_count": int(row.get("received_count") or 0),
                "last_message_at": (row.get("last_message_at") or "").strip(),
            }
            for row in (cur.fetchall() or [])
        ]
        cur.execute(
            """
            SELECT
                sa.id AS sender_id,
                COALESCE(NULLIF(TRIM(sa.name),''), SPLIT_PART(COALESCE(sa.email,''), '@', 1), 'user') AS sender_name,
                ra.id AS receiver_id,
                COALESCE(NULLIF(TRIM(ra.name),''), SPLIT_PART(COALESCE(ra.email,''), '@', 1), 'user') AS receiver_name,
                COUNT(*) AS message_count,
                MAX(m.created_at) AS last_message_at
            FROM mobile_direct_messages m
            JOIN accounts sa ON sa.id=m.sender_account_id
            JOIN accounts ra ON ra.id=m.receiver_account_id
            WHERE LEFT(COALESCE(m.created_at,''),10)>=?
            GROUP BY sa.id, sender_name, ra.id, receiver_name
            ORDER BY MAX(m.created_at) DESC
            LIMIT 20
            """,
            (last_7_str,),
        )
        report["messages"]["recent_pairs"] = [
            {
                "sender_name": (row.get("sender_name") or "user").strip(),
                "receiver_name": (row.get("receiver_name") or "user").strip(),
                "message_count": int(row.get("message_count") or 0),
                "last_message_at": (row.get("last_message_at") or "").strip(),
            }
            for row in (cur.fetchall() or [])
        ]
    except Exception as exc:
        report["errors"].append(f"Mesaj raporu alınamadı: {exc}")

    try:
        raw_limit = max(20, min(int(message_limit or 100), 200))
    except Exception:
        raw_limit = 100
    selected_a = min(int(conversation_a or 0), int(conversation_b or 0)) if conversation_a and conversation_b else int(conversation_a or 0)
    selected_b = max(int(conversation_a or 0), int(conversation_b or 0)) if conversation_a and conversation_b else int(conversation_b or 0)
    raw_q = (message_q or "").strip().lower()
    filter_parts: List[str] = []
    filter_params: List[Any] = []
    if raw_q:
        like = f"%{raw_q}%"
        id_match = raw_q if raw_q.isdigit() else ""
        filter_parts.append(
            """
            (
                LOWER(COALESCE(sa.name,'')) LIKE ?
                OR LOWER(COALESCE(sa.email,'')) LIKE ?
                OR LOWER(COALESCE(sps.username,'')) LIKE ?
                OR LOWER(COALESCE(ra.name,'')) LIKE ?
                OR LOWER(COALESCE(ra.email,'')) LIKE ?
                OR LOWER(COALESCE(rps.username,'')) LIKE ?
                OR LOWER(COALESCE(m.body,'')) LIKE ?
                OR CAST(sa.id AS TEXT)=?
                OR CAST(ra.id AS TEXT)=?
            )
            """
        )
        filter_params.extend([like, like, like, like, like, like, like, id_match, id_match])
    where_sql = ""
    if filter_parts:
        where_sql = "WHERE " + " AND ".join(filter_parts)

    cur.execute(
        _adapt_sql(
            f"""
            WITH convo AS (
                SELECT
                    LEAST(m.sender_account_id, m.receiver_account_id) AS a_id,
                    GREATEST(m.sender_account_id, m.receiver_account_id) AS b_id,
                    COUNT(*) AS message_count,
                    MAX(m.created_at) AS last_message_at,
                    MAX(m.id) AS last_message_id
                FROM mobile_direct_messages m
                JOIN accounts sa ON sa.id=m.sender_account_id
                LEFT JOIN mobile_profile_settings sps ON sps.account_id=sa.id
                JOIN accounts ra ON ra.id=m.receiver_account_id
                LEFT JOIN mobile_profile_settings rps ON rps.account_id=ra.id
                {where_sql}
                GROUP BY 1,2
                ORDER BY MAX(m.created_at) DESC NULLS LAST, MAX(m.id) DESC
                LIMIT ?
            )
            SELECT
                convo.a_id,
                convo.b_id,
                convo.message_count,
                COALESCE(convo.last_message_at::text,'') AS last_message_at,
                COALESCE(NULLIF(TRIM(aa.name),''), NULLIF(TRIM(aps.username),''), SPLIT_PART(COALESCE(aa.email,''), '@', 1), 'user') AS a_name,
                COALESCE(aa.email,'') AS a_email,
                COALESCE(NULLIF(TRIM(bb.name),''), NULLIF(TRIM(bps.username),''), SPLIT_PART(COALESCE(bb.email,''), '@', 1), 'user') AS b_name,
                COALESCE(bb.email,'') AS b_email
            FROM convo
            JOIN accounts aa ON aa.id=convo.a_id
            LEFT JOIN mobile_profile_settings aps ON aps.account_id=aa.id
            JOIN accounts bb ON bb.id=convo.b_id
            LEFT JOIN mobile_profile_settings bps ON bps.account_id=bb.id
            ORDER BY convo.last_message_at DESC NULLS LAST, convo.message_count DESC
            """
        ),
        tuple(filter_params + [raw_limit]),
    )
    conversations = [
        {
            "a_id": int(row.get("a_id") or 0),
            "b_id": int(row.get("b_id") or 0),
            "a_name": (row.get("a_name") or "user").strip(),
            "a_email": (row.get("a_email") or "").strip(),
            "b_name": (row.get("b_name") or "user").strip(),
            "b_email": (row.get("b_email") or "").strip(),
            "message_count": int(row.get("message_count") or 0),
            "last_message_at": (row.get("last_message_at") or "").strip(),
        }
        for row in (cur.fetchall() or [])
    ]
    report["messages"]["conversations"] = conversations
    if (selected_a <= 0 or selected_b <= 0) and conversations:
        selected_a = int(conversations[0]["a_id"])
        selected_b = int(conversations[0]["b_id"])

    if selected_a > 0 and selected_b > 0:
        cur.execute(
            _adapt_sql(
                """
                SELECT
                    m.id,
                    COALESCE(m.created_at::text,'') AS created_at,
                    COALESCE(m.body,'') AS body,
                    m.sender_account_id,
                    m.receiver_account_id,
                    COALESCE(NULLIF(TRIM(sa.name),''), NULLIF(TRIM(sps.username),''), SPLIT_PART(COALESCE(sa.email,''), '@', 1), 'user') AS sender_name,
                    COALESCE(sa.email,'') AS sender_email,
                    COALESCE(NULLIF(TRIM(ra.name),''), NULLIF(TRIM(rps.username),''), SPLIT_PART(COALESCE(ra.email,''), '@', 1), 'user') AS receiver_name,
                    COALESCE(ra.email,'') AS receiver_email
                FROM mobile_direct_messages m
                JOIN accounts sa ON sa.id=m.sender_account_id
                LEFT JOIN mobile_profile_settings sps ON sps.account_id=sa.id
                JOIN accounts ra ON ra.id=m.receiver_account_id
                LEFT JOIN mobile_profile_settings rps ON rps.account_id=ra.id
                WHERE LEAST(m.sender_account_id, m.receiver_account_id)=?
                  AND GREATEST(m.sender_account_id, m.receiver_account_id)=?
                ORDER BY m.created_at ASC NULLS LAST, m.id ASC
                """
            ),
            (selected_a, selected_b),
        )
        selected_meta = next(
            (
                item
                for item in conversations
                if int(item.get("a_id") or 0) == selected_a and int(item.get("b_id") or 0) == selected_b
            ),
            None,
        )
        report["messages"]["selected_thread"] = {
            "a_id": selected_a,
            "b_id": selected_b,
            "title": (
                f"{selected_meta.get('a_name')} - {selected_meta.get('b_name')}"
                if selected_meta
                else f"#{selected_a} - #{selected_b}"
            ),
            "messages": [
                {
                    "id": int(row.get("id") or 0),
                    "created_at": (row.get("created_at") or "").strip(),
                    "body": (row.get("body") or "").strip(),
                    "sender_id": int(row.get("sender_account_id") or 0),
                    "receiver_id": int(row.get("receiver_account_id") or 0),
                    "sender_name": (row.get("sender_name") or "user").strip(),
                    "sender_email": (row.get("sender_email") or "").strip(),
                    "receiver_name": (row.get("receiver_name") or "user").strip(),
                    "receiver_email": (row.get("receiver_email") or "").strip(),
                    "is_left": int(row.get("sender_account_id") or 0) == selected_a,
                }
                for row in (cur.fetchall() or [])
            ],
        }

    try:
        cur.execute(
            """
            SELECT
                COUNT(*) AS total_tokens,
                COUNT(*) FILTER (WHERE COALESCE(is_active,TRUE)=TRUE) AS active_tokens,
                COUNT(*) FILTER (WHERE COALESCE(is_active,TRUE)=TRUE AND COALESCE(notifications_enabled,TRUE)=TRUE) AS deliverable_tokens,
                COUNT(*) FILTER (WHERE COALESCE(is_active,TRUE)=TRUE AND COALESCE(notifications_enabled,TRUE)=TRUE AND COALESCE(platform,'unknown')='ios') AS ios_tokens,
                COUNT(*) FILTER (WHERE COALESCE(is_active,TRUE)=TRUE AND COALESCE(notifications_enabled,TRUE)=TRUE AND COALESCE(platform,'unknown')='android') AS android_tokens,
                COUNT(*) FILTER (WHERE COALESCE(is_active,TRUE)=TRUE AND COALESCE(notifications_enabled,TRUE)=TRUE AND COALESCE(platform,'unknown')='web') AS web_tokens
            FROM mobile_push_tokens
            """
        )
        row = cur.fetchone() or {}
        for key in report["devices"].keys():
            report["devices"][key] = int(row.get(key) or 0)
    except Exception as exc:
        report["errors"].append(f"Cihaz / push raporu alınamadı: {exc}")

    try:
        report["content"]["approved_news"] = _fetch_scalar(
            cur,
            "SELECT COUNT(*) FROM mobile_news_submissions WHERE COALESCE(status,'pending')='approved'",
        )
        report["content"]["open_albums"] = _fetch_scalar(
            cur,
            "SELECT COUNT(*) FROM saas_events WHERE COALESCE(album_enabled, TRUE)=TRUE",
        )
        report["content"]["store_products"] = _fetch_scalar(
            cur,
            "SELECT COUNT(*) FROM mobile_store_products WHERE COALESCE(is_active,TRUE)=TRUE AND COALESCE(is_sold,FALSE)=FALSE",
        )
        report["content"]["pending_friend_requests"] = _fetch_scalar(
            cur,
            "SELECT COUNT(*) FROM mobile_friend_requests WHERE COALESCE(status,'pending')='pending'",
        )
        report["content"]["open_user_reports"] = _fetch_scalar(
            cur,
            "SELECT COUNT(*) FROM mobile_user_reports WHERE COALESCE(status,'open')='open'",
        )
        report["content"]["notifications_today"] = _fetch_scalar(
            cur,
            "SELECT COUNT(*) FROM mobile_user_notifications WHERE LEFT(COALESCE(created_at::text,''),10)=?",
            (today_str,),
        )
    except Exception as exc:
        report["errors"].append(f"İçerik özeti alınamadı: {exc}")

    return report


def log_mail_event(event_slug: str, user_id: Optional[int], email: str, status: str, error: str = ""):
    try:
        conn = db_conn()
        c = conn.cursor()
        c.execute(
            "INSERT INTO mail_logs (event_slug, user_id, email, status, error, sent_at) VALUES (?,?,?,?,?,?)",
            (event_slug or "", user_id, email or "", status, (error or "")[:500], iso_now()),
        )
        conn.commit()
        conn.close()
    except Exception:
        pass


def list_mail_logs(event_slug: str, limit: int = 200, status: Optional[str] = None, offset: int = 0, with_total: bool = False):
    conn = db_conn()
    c = conn.cursor()
    where_sql = "WHERE ml.event_slug=?"
    params_base = [event_slug]
    if status in ("sent", "error"):
        where_sql += " AND ml.status=?"
        params_base.append(status)

    total = None
    if with_total:
        c.execute(
            f"""
            SELECT COUNT(*) AS cnt
            FROM mail_logs ml
            {where_sql}
            """,
            tuple(params_base),
        )
        tr = c.fetchone()
        total = int(tr["cnt"] if tr and "cnt" in tr.keys() else (tr[0] if tr else 0))

    params = list(params_base) + [int(limit), int(offset)]
    c.execute(
        f"""
        SELECT ml.email, ml.status, ml.error, ml.sent_at, u.name AS user_name
        FROM mail_logs ml
        LEFT JOIN users u ON u.id = ml.user_id
        {where_sql}
        ORDER BY ml.id DESC
        LIMIT ? OFFSET ?
        """,
        tuple(params),
    )
    rows = c.fetchall()
    conn.close()
    if with_total:
        return rows, int(total or 0)
    return rows


def log_qr_scan(event_slug: str, request: Request):
    try:
        ip = request.client.host if request.client else ""
        ua = request.headers.get("user-agent", "")
        conn = db_conn()
        c = conn.cursor()
        c.execute(
            "INSERT INTO qr_scans (event_slug, ip, user_agent, created_at) VALUES (?,?,?,?)",
            (event_slug or "", ip, ua[:200], iso_now()),
        )
        conn.commit()
        conn.close()
    except Exception:
        pass


def count_qr_scans(event_slug: str) -> int:
    conn = db_conn()
    c = conn.cursor()
    c.execute("SELECT COUNT(*) AS cnt FROM qr_scans WHERE event_slug=?", (event_slug,))
    n = int(c.fetchone()["cnt"])
    conn.close()
    return n


def log_photo_download(event_slug: str, user_id: int, photo_id: int):
    try:
        conn = db_conn()
        c = conn.cursor()
        c.execute(
            "INSERT INTO photo_downloads (event_slug, user_id, photo_id, created_at) VALUES (?,?,?,?)",
            (event_slug or "", int(user_id), int(photo_id), iso_now()),
        )
        conn.commit()
        conn.close()
    except Exception:
        pass


def count_photo_downloads(event_slug: str) -> int:
    conn = db_conn()
    c = conn.cursor()
    c.execute("SELECT COUNT(*) AS cnt FROM photo_downloads WHERE event_slug=?", (event_slug,))
    n = int(c.fetchone()["cnt"])
    conn.close()
    return n


def human_size(num_bytes: int) -> str:
    try:
        n = float(num_bytes)
    except Exception:
        return "-"
    for unit in ["B", "KB", "MB", "GB", "TB"]:
        if n < 1024.0:
            return f"{n:.1f} {unit}"
        n /= 1024.0
    return f"{n:.1f} PB"


# =========================
# IMAGE OPTIMIZE
# =========================

def _encode_jpeg_under_kb(img: Image.Image, target_kb: int) -> bytes:
    target_bytes = int(target_kb) * 1024
    q = 88
    min_q = 45

    buf = BytesIO()
    img.save(buf, format="JPEG", quality=q, optimize=True, progressive=True)
    data = buf.getvalue()
    if len(data) <= target_bytes:
        return data

    while q > min_q:
        q -= 8
        buf = BytesIO()
        img.save(buf, format="JPEG", quality=q, optimize=True, progressive=True)
        data = buf.getvalue()
        if len(data) <= target_bytes:
            return data

    return data


def save_image_optimized_from_bytes(
    raw: bytes,
    save_path: str,
    target_kb: int = 800,
    max_side: int = 2400,
    allowed_formats: Optional[set] = None,
) -> int:
    if not raw:
        raise ValueError("Boş dosya")

    try:
        img = Image.open(BytesIO(raw))
    except UnidentifiedImageError:
        if HEIF_ENABLED:
            raise ValueError("Desteklenmeyen görüntü formatı")
        raise ValueError("Desteklenmeyen görüntü formatı (HEIC/HEIF için HEIF desteği gerekir)")
    if allowed_formats is None:
        allowed_formats = ALLOWED_IMAGE_FORMATS
    if img.format and img.format.upper() not in allowed_formats:
        raise ValueError("Desteklenmeyen görüntü formatı")
    img = ImageOps.exif_transpose(img)

    if img.mode != "RGB":
        img = img.convert("RGB")

    w, h = img.size
    longest = max(w, h)
    if longest > int(max_side):
        scale = float(max_side) / float(longest)
        nw = max(1, int(w * scale))
        nh = max(1, int(h * scale))
        img = img.resize((nw, nh), Image.LANCZOS)

    jpeg_bytes = _encode_jpeg_under_kb(img, target_kb=target_kb)

    os.makedirs(os.path.dirname(save_path), exist_ok=True)
    with open(save_path, "wb") as f:
        f.write(jpeg_bytes)

    return len(jpeg_bytes)


async def save_image_optimized_from_upload(
    upload: UploadFile,
    save_path: str,
    target_kb: int = 800,
    max_side: int = 2400,
    max_bytes: int = IMAGE_MAX_BYTES,
) -> int:
    raw = await upload.read()
    if upload.content_type and upload.content_type.lower() not in ALLOWED_IMAGE_MIME:
        raise ValueError("Sadece jpg/png/webp yükleyebilirsiniz")
    if len(raw) > int(max_bytes):
        raise ValueError("Dosya çok büyük")
    return save_image_optimized_from_bytes(
        raw,
        save_path,
        target_kb=target_kb,
        max_side=max_side,
        allowed_formats=ALLOWED_IMAGE_FORMATS,
    )


# =========================
# LEGACY DB (PUBLIC FLOW)
# =========================

def init_legacy_db():
    conn = db_conn()
    c = conn.cursor()

    if USE_POSTGRES:
        c.execute("""
            CREATE TABLE IF NOT EXISTS users (
                id SERIAL PRIMARY KEY,
                event_id TEXT,
                name TEXT,
                email TEXT,
                selfie_path TEXT,
                kvkk_consent INTEGER,
                created_at TEXT,
                gallery_token TEXT
            )
        """)
        c.execute("""
            CREATE TABLE IF NOT EXISTS event_photos (
                id SERIAL PRIMARY KEY,
                event_id TEXT,
                file_path TEXT,
                created_at TEXT,
                uploaded_by_account_id INTEGER,
                file_size_bytes INTEGER
            )
        """)
        c.execute("""
            CREATE TABLE IF NOT EXISTS photo_matches (
                id SERIAL PRIMARY KEY,
                event_id TEXT,
                user_id INTEGER,
                photo_id INTEGER,
                score REAL
            )
        """)
        c.execute("""
            CREATE TABLE IF NOT EXISTS events (
                id SERIAL PRIMARY KEY,
                slug TEXT UNIQUE,
                name TEXT,
                created_at TEXT
            )
        """)
    else:
        c.execute("""
            CREATE TABLE IF NOT EXISTS users (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                event_id TEXT,
                name TEXT,
                email TEXT,
                selfie_path TEXT,
                kvkk_consent INTEGER,
                created_at TEXT,
                gallery_token TEXT
            )
        """)
        c.execute("""
            CREATE TABLE IF NOT EXISTS event_photos (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                event_id TEXT,
                file_path TEXT,
                created_at TEXT,
                uploaded_by_account_id INTEGER,
                file_size_bytes INTEGER
            )
        """)
        c.execute("""
            CREATE TABLE IF NOT EXISTS photo_matches (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                event_id TEXT,
                user_id INTEGER,
                photo_id INTEGER,
                score REAL
            )
        """)
        c.execute("""
            CREATE TABLE IF NOT EXISTS events (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                slug TEXT UNIQUE,
                name TEXT,
                created_at TEXT
            )
        """)

    conn.commit()
    conn.close()


def insert_user(event_id: str, name: str, email: str, selfie_path: str, kvkk_consent: bool) -> int:
    last_err = None
    for _ in range(6):
        try:
            conn = db_conn()
            c = conn.cursor()
            if USE_POSTGRES:
                c.execute(
                    """
                    INSERT INTO users (event_id, name, email, selfie_path, kvkk_consent, created_at, gallery_token)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    RETURNING id
                    """,
                    (event_id, name, email, selfie_path, 1 if kvkk_consent else 0, iso_now(), None)
                )
                user_id = int(c.fetchone()[0])
            else:
                c.execute(
                    """
                    INSERT INTO users (event_id, name, email, selfie_path, kvkk_consent, created_at, gallery_token)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    """,
                    (event_id, name, email, selfie_path, 1 if kvkk_consent else 0, iso_now(), None)
                )
                user_id = int(c.lastrowid)
            conn.commit()
            conn.close()
            return user_id
        except DBOperationalError as e:
            last_err = e
            try:
                conn.close()
            except Exception:
                pass
            if "locked" in str(e).lower():
                time.sleep(0.2)
                continue
            raise
    raise DBOperationalError(str(last_err) if last_err else "database is locked")


def insert_event_photo(
    event_id: str,
    file_path: str,
    uploaded_by_account_id: Optional[int] = None,
    file_size_bytes: Optional[int] = None,
):
    conn = db_conn()
    c = conn.cursor()
    c.execute(
        "INSERT INTO event_photos (event_id, file_path, created_at, uploaded_by_account_id, file_size_bytes) VALUES (?, ?, ?, ?, ?)",
        (
            event_id,
            file_path,
            iso_now(),
            int(uploaded_by_account_id) if uploaded_by_account_id is not None else None,
            int(file_size_bytes) if file_size_bytes is not None else None,
        )
    )
    conn.commit()
    conn.close()


# =========================
# AUTH DB (SaaS)
# =========================

def init_auth_tables():
    conn = db_conn()
    c = conn.cursor()

    if USE_POSTGRES:
        c.execute("""
        CREATE TABLE IF NOT EXISTS accounts (
            id SERIAL PRIMARY KEY,
            email TEXT UNIQUE NOT NULL,
            password_hash TEXT NOT NULL,
            role TEXT NOT NULL,
            is_active INTEGER NOT NULL DEFAULT 1,
            photo_credit INTEGER NOT NULL DEFAULT 0,
            name TEXT,
            phone TEXT,
            avatar_path TEXT,
            created_at TEXT NOT NULL
        )
        """)
        c.execute("""
        CREATE TABLE IF NOT EXISTS sessions (
            id SERIAL PRIMARY KEY,
            account_id INTEGER NOT NULL,
            session_token TEXT UNIQUE NOT NULL,
            expires_at TEXT NOT NULL,
            created_at TEXT NOT NULL
        )
        """)
        c.execute("""
        CREATE TABLE IF NOT EXISTS saas_events (
            id SERIAL PRIMARY KEY,
            account_id INTEGER NOT NULL,
            name TEXT NOT NULL,
            slug TEXT UNIQUE NOT NULL,
            is_active INTEGER NOT NULL DEFAULT 1,
            frame_landscape TEXT,
            frame_portrait TEXT,
            frame_square TEXT,
            frame_ratio_1_1 TEXT,
            frame_ratio_3_2 TEXT,
            frame_ratio_2_3 TEXT,
            frame_ratio_3_4 TEXT,
            frame_ratio_4_3 TEXT,
            created_at TEXT NOT NULL
        )
        """)
        c.execute("""
        CREATE TABLE IF NOT EXISTS jobs (
            id SERIAL PRIMARY KEY,
            account_id INTEGER NOT NULL,
            event_slug TEXT NOT NULL,
            subalbum_id INTEGER,
            action TEXT NOT NULL,
            uploaded_count INTEGER NOT NULL DEFAULT 0,
            status TEXT NOT NULL,
            message TEXT,
            created_at TEXT NOT NULL,
            finished_at TEXT,
            target_user_id INTEGER,
            processed_count INTEGER,
            match_count INTEGER,
            match_cursor INTEGER,
            match_start INTEGER,
            match_end INTEGER,
            pid TEXT,
            heartbeat_at TEXT
        )
        """)
    else:
        c.execute("""
        CREATE TABLE IF NOT EXISTS accounts (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            email TEXT UNIQUE NOT NULL,
            password_hash TEXT NOT NULL,
            role TEXT NOT NULL,               -- 'super_admin' | 'customer'
            is_active INTEGER NOT NULL DEFAULT 1,
            photo_credit INTEGER NOT NULL DEFAULT 0,
            name TEXT,                        -- profil adı (opsiyonel)
            phone TEXT,                       -- telefon (opsiyonel)
            avatar_path TEXT,                 -- profil foto (opsiyonel)
            created_at TEXT NOT NULL
        )
        """)
        c.execute("""
        CREATE TABLE IF NOT EXISTS sessions (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            account_id INTEGER NOT NULL,
            session_token TEXT UNIQUE NOT NULL,
            expires_at TEXT NOT NULL,
            created_at TEXT NOT NULL,
            FOREIGN KEY(account_id) REFERENCES accounts(id)
        )
        """)
        c.execute("""
        CREATE TABLE IF NOT EXISTS saas_events (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            account_id INTEGER NOT NULL,
            name TEXT NOT NULL,
            slug TEXT UNIQUE NOT NULL,
            is_active INTEGER NOT NULL DEFAULT 1,
            frame_landscape TEXT,
            frame_portrait TEXT,
            frame_square TEXT,
            frame_ratio_1_1 TEXT,
            frame_ratio_3_2 TEXT,
            frame_ratio_2_3 TEXT,
            frame_ratio_3_4 TEXT,
            frame_ratio_4_3 TEXT,
            created_at TEXT NOT NULL,
            FOREIGN KEY(account_id) REFERENCES accounts(id)
        )
        """)
        c.execute("""
        CREATE TABLE IF NOT EXISTS jobs (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            account_id INTEGER NOT NULL,
            event_slug TEXT NOT NULL,
            subalbum_id INTEGER,
            action TEXT NOT NULL,
            uploaded_count INTEGER NOT NULL DEFAULT 0,
            status TEXT NOT NULL,
            message TEXT,
            created_at TEXT NOT NULL,
            finished_at TEXT,
            target_user_id INTEGER
        )
        """)

    conn.commit()
    conn.close()


def ensure_accounts_columns():
    """
    Backfill missing columns for older DBs.
    """
    conn = db_conn()
    c = conn.cursor()
    if USE_POSTGRES:
        c.execute(
            "SELECT column_name FROM information_schema.columns WHERE table_name=%s",
            ("accounts",),
        )
        cols = {r[0] for r in c.fetchall()}
    else:
        c.execute("PRAGMA table_info(accounts)")
        cols = {r[1] for r in c.fetchall()}
    if "name" not in cols:
        c.execute("ALTER TABLE accounts ADD COLUMN name TEXT")
    if "phone" not in cols:
        c.execute("ALTER TABLE accounts ADD COLUMN phone TEXT")
    if "avatar_path" not in cols:
        c.execute("ALTER TABLE accounts ADD COLUMN avatar_path TEXT")
    if "can_create_mobile_event" not in cols:
        c.execute("ALTER TABLE accounts ADD COLUMN can_create_mobile_event INTEGER DEFAULT 0")
    if "is_mobile_event_reviewer" not in cols:
        c.execute("ALTER TABLE accounts ADD COLUMN is_mobile_event_reviewer INTEGER DEFAULT 0")
    conn.commit()
    conn.close()


def ensure_saas_event_columns():
    conn = db_conn()
    c = conn.cursor()
    if USE_POSTGRES:
        c.execute(
            "SELECT column_name FROM information_schema.columns WHERE table_name=%s",
            ("saas_events",),
        )
        cols = {r[0] for r in c.fetchall()}
    else:
        c.execute("PRAGMA table_info(saas_events)")
        cols = {r[1] for r in c.fetchall()}
    if "frame_landscape" not in cols:
        c.execute("ALTER TABLE saas_events ADD COLUMN frame_landscape TEXT")
    if "frame_portrait" not in cols:
        c.execute("ALTER TABLE saas_events ADD COLUMN frame_portrait TEXT")
    if "frame_square" not in cols:
        c.execute("ALTER TABLE saas_events ADD COLUMN frame_square TEXT")
    if "frame_ratio_1_1" not in cols:
        c.execute("ALTER TABLE saas_events ADD COLUMN frame_ratio_1_1 TEXT")
    if "frame_ratio_3_2" not in cols:
        c.execute("ALTER TABLE saas_events ADD COLUMN frame_ratio_3_2 TEXT")
    if "frame_ratio_2_3" not in cols:
        c.execute("ALTER TABLE saas_events ADD COLUMN frame_ratio_2_3 TEXT")
    if "frame_ratio_3_4" not in cols:
        c.execute("ALTER TABLE saas_events ADD COLUMN frame_ratio_3_4 TEXT")
    if "frame_ratio_4_3" not in cols:
        c.execute("ALTER TABLE saas_events ADD COLUMN frame_ratio_4_3 TEXT")
    if "external_source" not in cols:
        c.execute("ALTER TABLE saas_events ADD COLUMN external_source TEXT")
    if "external_event_id" not in cols:
        c.execute("ALTER TABLE saas_events ADD COLUMN external_event_id TEXT")
    if "ticket_url" not in cols:
        c.execute("ALTER TABLE saas_events ADD COLUMN ticket_url TEXT")
    if "album_enabled" not in cols:
        if USE_POSTGRES:
            c.execute("ALTER TABLE saas_events ADD COLUMN album_enabled BOOLEAN NOT NULL DEFAULT TRUE")
        else:
            c.execute("ALTER TABLE saas_events ADD COLUMN album_enabled INTEGER NOT NULL DEFAULT 1")
    if "photo_target_kb" not in cols:
        c.execute("ALTER TABLE saas_events ADD COLUMN photo_target_kb INTEGER")
    if "photo_max_side" not in cols:
        c.execute("ALTER TABLE saas_events ADD COLUMN photo_max_side INTEGER")
    if USE_POSTGRES:
        c.execute("UPDATE saas_events SET album_enabled=TRUE WHERE album_enabled IS NULL")
    else:
        c.execute("UPDATE saas_events SET album_enabled=1 WHERE album_enabled IS NULL")
    conn.commit()
    conn.close()


def ensure_jobs_columns():
    conn = db_conn()
    c = conn.cursor()
    if USE_POSTGRES:
        c.execute(
            "SELECT column_name FROM information_schema.columns WHERE table_name=%s",
            ("jobs",),
        )
        cols = {r[0] for r in c.fetchall()}
    else:
        c.execute("PRAGMA table_info(jobs)")
        cols = {r[1] for r in c.fetchall()}
    if "processed_count" not in cols:
        c.execute("ALTER TABLE jobs ADD COLUMN processed_count INTEGER")
    if "match_count" not in cols:
        c.execute("ALTER TABLE jobs ADD COLUMN match_count INTEGER")
    if "match_cursor" not in cols:
        c.execute("ALTER TABLE jobs ADD COLUMN match_cursor INTEGER")
    if "match_end" not in cols:
        c.execute("ALTER TABLE jobs ADD COLUMN match_end INTEGER")
    if "match_start" not in cols:
        c.execute("ALTER TABLE jobs ADD COLUMN match_start INTEGER")
    if "pid" not in cols:
        c.execute("ALTER TABLE jobs ADD COLUMN pid TEXT")
    if "heartbeat_at" not in cols:
        c.execute("ALTER TABLE jobs ADD COLUMN heartbeat_at TEXT")
    if "subalbum_id" not in cols:
        c.execute("ALTER TABLE jobs ADD COLUMN subalbum_id INTEGER")
    conn.commit()
    conn.close()


def ensure_event_subalbums_table():
    conn = db_conn()
    c = conn.cursor()
    if USE_POSTGRES:
        c.execute("""
        CREATE TABLE IF NOT EXISTS event_subalbums (
            id SERIAL PRIMARY KEY,
            event_slug TEXT NOT NULL,
            name TEXT NOT NULL,
            created_by_account_id INTEGER,
            is_active INTEGER NOT NULL DEFAULT 1,
            sort_order INTEGER NOT NULL DEFAULT 0,
            created_at TEXT NOT NULL
        )
        """)
        c.execute("""
        CREATE UNIQUE INDEX IF NOT EXISTS idx_event_subalbums_unique_name
        ON event_subalbums(event_slug, LOWER(name))
        WHERE is_active = 1
        """)
    else:
        c.execute("""
        CREATE TABLE IF NOT EXISTS event_subalbums (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            event_slug TEXT NOT NULL,
            name TEXT NOT NULL,
            created_by_account_id INTEGER,
            is_active INTEGER NOT NULL DEFAULT 1,
            sort_order INTEGER NOT NULL DEFAULT 0,
            created_at TEXT NOT NULL
        )
        """)
        c.execute("""
        CREATE UNIQUE INDEX IF NOT EXISTS idx_event_subalbums_unique_name
        ON event_subalbums(event_slug, name)
        """)
    conn.commit()
    conn.close()


def ensure_event_photos_columns():
    conn = db_conn()
    c = conn.cursor()
    if USE_POSTGRES:
        c.execute(
            "SELECT column_name FROM information_schema.columns WHERE table_name=%s",
            ("event_photos",),
        )
        cols = {r[0] for r in c.fetchall()}
    else:
        c.execute("PRAGMA table_info(event_photos)")
        cols = {r[1] for r in c.fetchall()}
    if "uploaded_by_account_id" not in cols:
        c.execute("ALTER TABLE event_photos ADD COLUMN uploaded_by_account_id INTEGER")
    if "file_size_bytes" not in cols:
        c.execute("ALTER TABLE event_photos ADD COLUMN file_size_bytes INTEGER")
    conn.commit()
    conn.close()


def ensure_mobile_profile_settings_table():
    """
    Mobil app'e özel profil ayarları (username/dil/bildirim) tablosunu garanti eder.
    """
    conn = db_conn()
    c = conn.cursor()
    if USE_POSTGRES:
        c.execute(
            """
            CREATE TABLE IF NOT EXISTS mobile_profile_settings (
                account_id INTEGER PRIMARY KEY,
                username VARCHAR(40),
                preferred_language VARCHAR(8),
                is_verified BOOLEAN NOT NULL DEFAULT FALSE,
                notifications_enabled BOOLEAN,
                updated_at TIMESTAMP WITHOUT TIME ZONE DEFAULT NOW()
            )
            """
        )
    else:
        c.execute(
            """
            CREATE TABLE IF NOT EXISTS mobile_profile_settings (
                account_id INTEGER PRIMARY KEY,
                username TEXT,
                preferred_language TEXT,
                is_verified INTEGER NOT NULL DEFAULT 0,
                notifications_enabled INTEGER,
                updated_at TEXT
            )
            """
        )
    conn.commit()
    conn.close()


def init_event_account_frames_table():
    conn = db_conn()
    c = conn.cursor()
    if USE_POSTGRES:
        c.execute("""
            CREATE TABLE IF NOT EXISTS event_account_frames (
                id SERIAL PRIMARY KEY,
                event_slug TEXT NOT NULL,
                account_id INTEGER NOT NULL,
                frame_landscape TEXT,
                frame_portrait TEXT,
                frame_square TEXT,
                frame_ratio_1_1 TEXT,
                frame_ratio_3_2 TEXT,
                frame_ratio_2_3 TEXT,
                frame_ratio_3_4 TEXT,
                frame_ratio_4_3 TEXT,
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL,
                UNIQUE(event_slug, account_id)
            )
        """)
    else:
        c.execute("""
            CREATE TABLE IF NOT EXISTS event_account_frames (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                event_slug TEXT NOT NULL,
                account_id INTEGER NOT NULL,
                frame_landscape TEXT,
                frame_portrait TEXT,
                frame_square TEXT,
                frame_ratio_1_1 TEXT,
                frame_ratio_3_2 TEXT,
                frame_ratio_2_3 TEXT,
                frame_ratio_3_4 TEXT,
                frame_ratio_4_3 TEXT,
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL,
                UNIQUE(event_slug, account_id)
            )
        """)
    if USE_POSTGRES:
        c.execute(
            "SELECT column_name FROM information_schema.columns WHERE table_name=%s",
            ("event_account_frames",),
        )
        cols = {r[0] for r in c.fetchall()}
    else:
        c.execute("PRAGMA table_info(event_account_frames)")
        cols = {r[1] for r in c.fetchall()}
    if "frame_ratio_1_1" not in cols:
        c.execute("ALTER TABLE event_account_frames ADD COLUMN frame_ratio_1_1 TEXT")
    if "frame_ratio_3_2" not in cols:
        c.execute("ALTER TABLE event_account_frames ADD COLUMN frame_ratio_3_2 TEXT")
    if "frame_ratio_2_3" not in cols:
        c.execute("ALTER TABLE event_account_frames ADD COLUMN frame_ratio_2_3 TEXT")
    if "frame_ratio_3_4" not in cols:
        c.execute("ALTER TABLE event_account_frames ADD COLUMN frame_ratio_3_4 TEXT")
    if "frame_ratio_4_3" not in cols:
        c.execute("ALTER TABLE event_account_frames ADD COLUMN frame_ratio_4_3 TEXT")
    conn.commit()
    conn.close()


def get_event_account_frames(event_slug: str, account_id: int) -> Dict[str, str]:
    conn = db_conn()
    c = conn.cursor()
    c.execute(
        """
        SELECT
            frame_landscape, frame_portrait, frame_square,
            frame_ratio_1_1, frame_ratio_3_2, frame_ratio_2_3, frame_ratio_3_4, frame_ratio_4_3
        FROM event_account_frames
        WHERE event_slug=? AND account_id=?
        LIMIT 1
        """,
        (event_slug, int(account_id)),
    )
    row = c.fetchone()
    conn.close()
    if not row:
        return {
            "ratio_1_1": "",
            "ratio_3_2": "",
            "ratio_2_3": "",
            "ratio_3_4": "",
            "ratio_4_3": "",
            "landscape": "",
            "portrait": "",
            "square": "",
        }
    ratio_1_1 = (row["frame_ratio_1_1"] if "frame_ratio_1_1" in row.keys() else "") or (row["frame_square"] if "frame_square" in row.keys() else "") or ""
    ratio_3_2 = (row["frame_ratio_3_2"] if "frame_ratio_3_2" in row.keys() else "") or (row["frame_landscape"] if "frame_landscape" in row.keys() else "") or ""
    ratio_2_3 = (row["frame_ratio_2_3"] if "frame_ratio_2_3" in row.keys() else "") or (row["frame_portrait"] if "frame_portrait" in row.keys() else "") or ""
    ratio_3_4 = (row["frame_ratio_3_4"] if "frame_ratio_3_4" in row.keys() else "") or ""
    ratio_4_3 = (row["frame_ratio_4_3"] if "frame_ratio_4_3" in row.keys() else "") or ""
    return {
        "ratio_1_1": ratio_1_1,
        "ratio_3_2": ratio_3_2,
        "ratio_2_3": ratio_2_3,
        "ratio_3_4": ratio_3_4,
        "ratio_4_3": ratio_4_3,
        "landscape": ratio_3_2 or ratio_4_3,
        "portrait": ratio_2_3,
        "square": ratio_1_1,
    }


def get_event_processing_settings(event_slug: str) -> Dict[str, int]:
    conn = db_conn()
    c = conn.cursor()
    c.execute(
        "SELECT photo_target_kb, photo_max_side FROM saas_events WHERE slug=? LIMIT 1",
        (event_slug,),
    )
    row = c.fetchone()
    conn.close()
    target_kb = int(row["photo_target_kb"] or 0) if row else 0
    max_side = int(row["photo_max_side"] or 0) if row else 0
    if target_kb <= 0:
        target_kb = int(EVENT_TARGET_KB)
    if max_side <= 0:
        max_side = int(EVENT_MAX_SIDE)
    return {"target_kb": target_kb, "max_side": max_side}


def set_event_processing_settings(event_slug: str, target_kb: int, max_side: int):
    conn = db_conn()
    c = conn.cursor()
    c.execute(
        "UPDATE saas_events SET photo_target_kb=?, photo_max_side=? WHERE slug=?",
        (int(target_kb), int(max_side), event_slug),
    )
    conn.commit()
    conn.close()


def upsert_event_account_frames(event_slug: str, account_id: int, updates: Dict[str, str]):
    if not updates:
        return
    conn = db_conn()
    c = conn.cursor()
    c.execute(
        "SELECT id FROM event_account_frames WHERE event_slug=? AND account_id=? LIMIT 1",
        (event_slug, int(account_id)),
    )
    row = c.fetchone()
    now = iso_now()
    if row:
        sets = ", ".join([f"{k}=?" for k in updates.keys()])
        vals = list(updates.values()) + [now, event_slug, int(account_id)]
        c.execute(
            f"UPDATE event_account_frames SET {sets}, updated_at=? WHERE event_slug=? AND account_id=?",
            vals,
        )
    else:
        landscape = updates.get("frame_landscape", updates.get("frame_ratio_3_2", ""))
        portrait = updates.get("frame_portrait", updates.get("frame_ratio_2_3", ""))
        square = updates.get("frame_square", updates.get("frame_ratio_1_1", ""))
        ratio_1_1 = updates.get("frame_ratio_1_1", square)
        ratio_3_2 = updates.get("frame_ratio_3_2", landscape)
        ratio_2_3 = updates.get("frame_ratio_2_3", portrait)
        ratio_3_4 = updates.get("frame_ratio_3_4", "")
        ratio_4_3 = updates.get("frame_ratio_4_3", "")
        c.execute(
            """
            INSERT INTO event_account_frames (
                event_slug, account_id,
                frame_landscape, frame_portrait, frame_square,
                frame_ratio_1_1, frame_ratio_3_2, frame_ratio_2_3, frame_ratio_3_4, frame_ratio_4_3,
                created_at, updated_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            (
                event_slug, int(account_id),
                landscape, portrait, square,
                ratio_1_1, ratio_3_2, ratio_2_3, ratio_3_4, ratio_4_3,
                now, now,
            ),
        )
    conn.commit()
    conn.close()


def clear_event_account_frame(event_slug: str, account_id: int, kind: str):
    col_map = {
        "landscape": ["frame_landscape", "frame_ratio_3_2"],
        "portrait": ["frame_portrait", "frame_ratio_2_3"],
        "square": ["frame_square", "frame_ratio_1_1"],
        "ratio_1_1": ["frame_ratio_1_1", "frame_square"],
        "ratio_3_2": ["frame_ratio_3_2", "frame_landscape"],
        "ratio_2_3": ["frame_ratio_2_3", "frame_portrait"],
        "ratio_3_4": ["frame_ratio_3_4"],
        "ratio_4_3": ["frame_ratio_4_3"],
    }
    cols = col_map.get((kind or "").strip().lower())
    if not cols:
        raise ValueError("Geçersiz çerçeve türü")

    conn = db_conn()
    c = conn.cursor()
    set_sql = ", ".join([f"{col}=NULL" for col in cols])
    c.execute(
        f"UPDATE event_account_frames SET {set_sql}, updated_at=? WHERE event_slug=? AND account_id=?",
        (iso_now(), event_slug, int(account_id)),
    )
    conn.commit()
    conn.close()


def _parse_iso_ts(raw: Optional[str]) -> Optional[datetime]:
    if not raw:
        return None
    try:
        return datetime.fromisoformat(str(raw).replace(" ", "T"))
    except Exception:
        return None


def _recover_stale_running_jobs(c):
    """
    Worker öldüyse ve job 'running' kaldıysa otomatik olarak tekrar kuyruğa al.
    """
    if JOB_STALE_SECONDS <= 0:
        return 0
    c.execute(
        "SELECT id, heartbeat_at, created_at FROM jobs WHERE status='running' AND action IN ({})".format(
            ",".join(["?"] * len(MATCH_ACTIONS))
        ),
        tuple(MATCH_ACTIONS),
    )
    rows = c.fetchall()
    now = _local_now()
    recovered = 0
    for r in rows:
        hb = _parse_iso_ts(r["heartbeat_at"] if "heartbeat_at" in r.keys() else None)
        created = _parse_iso_ts(r["created_at"])
        ref = hb or created
        if not ref:
            continue
        age = (now - ref).total_seconds()
        if age < JOB_STALE_SECONDS:
            continue
        c.execute(
            """
            UPDATE jobs
            SET status='queued',
                message=?,
                finished_at=NULL
            WHERE id=? AND status='running'
            """,
            (f"Otomatik kurtarma: stale running ({int(age)}s)", int(r["id"])),
        )
        recovered += int(c.rowcount or 0)
    return recovered


def ensure_mail_log_table():
    conn = db_conn()
    c = conn.cursor()
    if USE_POSTGRES:
        c.execute("""
        CREATE TABLE IF NOT EXISTS mail_logs (
            id SERIAL PRIMARY KEY,
            event_slug TEXT NOT NULL,
            user_id INTEGER,
            email TEXT NOT NULL,
            status TEXT NOT NULL,
            error TEXT,
            sent_at TEXT NOT NULL
        )
        """)
    else:
        c.execute("""
        CREATE TABLE IF NOT EXISTS mail_logs (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            event_slug TEXT NOT NULL,
            user_id INTEGER,
            email TEXT NOT NULL,
            status TEXT NOT NULL,
            error TEXT,
            sent_at TEXT NOT NULL
        )
        """)
    conn.commit()
    conn.close()


def ensure_qr_scan_table():
    conn = db_conn()
    c = conn.cursor()
    if USE_POSTGRES:
        c.execute("""
        CREATE TABLE IF NOT EXISTS qr_scans (
            id SERIAL PRIMARY KEY,
            event_slug TEXT NOT NULL,
            ip TEXT,
            user_agent TEXT,
            created_at TEXT NOT NULL
        )
        """)
    else:
        c.execute("""
        CREATE TABLE IF NOT EXISTS qr_scans (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            event_slug TEXT NOT NULL,
            ip TEXT,
            user_agent TEXT,
            created_at TEXT NOT NULL
        )
        """)
    conn.commit()
    conn.close()


def ensure_download_table():
    conn = db_conn()
    c = conn.cursor()
    if USE_POSTGRES:
        c.execute("""
        CREATE TABLE IF NOT EXISTS photo_downloads (
            id SERIAL PRIMARY KEY,
            event_slug TEXT NOT NULL,
            user_id INTEGER,
            photo_id INTEGER,
            created_at TEXT NOT NULL
        )
        """)
    else:
        c.execute("""
        CREATE TABLE IF NOT EXISTS photo_downloads (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            event_slug TEXT NOT NULL,
            user_id INTEGER,
            photo_id INTEGER,
            created_at TEXT NOT NULL
        )
        """)
    conn.commit()
    conn.close()


def ensure_photo_attempts_table():
    conn = db_conn()
    c = conn.cursor()
    if USE_POSTGRES:
        c.execute("""
        CREATE TABLE IF NOT EXISTS photo_attempts (
            id SERIAL PRIMARY KEY,
            event_slug TEXT NOT NULL,
            user_id INTEGER NOT NULL,
            photo_id INTEGER NOT NULL,
            attempted_at TEXT NOT NULL
        )
        """)
        c.execute("""
        CREATE UNIQUE INDEX IF NOT EXISTS idx_photo_attempts_unique
        ON photo_attempts(event_slug, user_id, photo_id)
        """)
    else:
        c.execute("""
        CREATE TABLE IF NOT EXISTS photo_attempts (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            event_slug TEXT NOT NULL,
            user_id INTEGER NOT NULL,
            photo_id INTEGER NOT NULL,
            attempted_at TEXT NOT NULL
        )
        """)
        c.execute("""
        CREATE UNIQUE INDEX IF NOT EXISTS idx_photo_attempts_unique
        ON photo_attempts(event_slug, user_id, photo_id)
        """)
    conn.commit()
    conn.close()


def ensure_event_submissions_table():
    conn = db_conn()
    c = conn.cursor()
    if USE_POSTGRES:
        c.execute(
            """
            CREATE TABLE IF NOT EXISTS event_submissions (
                id SERIAL PRIMARY KEY,
                submitter_name TEXT NOT NULL,
                submitter_email TEXT NOT NULL,
                event_name TEXT NOT NULL,
                description TEXT,
                cover_image TEXT,
                start_at TEXT,
                end_at TEXT,
                entry_fee DOUBLE PRECISION NOT NULL DEFAULT 0,
                status TEXT NOT NULL DEFAULT 'pending',
                admin_note TEXT,
                approved_event_slug TEXT,
                reviewed_by_account_id INTEGER,
                reviewed_at TEXT,
                created_at TEXT NOT NULL
            )
            """
        )
    else:
        c.execute(
            """
            CREATE TABLE IF NOT EXISTS event_submissions (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                submitter_name TEXT NOT NULL,
                submitter_email TEXT NOT NULL,
                event_name TEXT NOT NULL,
                description TEXT,
                cover_image TEXT,
                start_at TEXT,
                end_at TEXT,
                entry_fee REAL NOT NULL DEFAULT 0,
                status TEXT NOT NULL DEFAULT 'pending',
                admin_note TEXT,
                approved_event_slug TEXT,
                reviewed_by_account_id INTEGER,
                reviewed_at TEXT,
                created_at TEXT NOT NULL
            )
            """
        )
    conn.commit()
    conn.close()


def ensure_event_submissions_columns():
    conn = db_conn()
    c = conn.cursor()
    if USE_POSTGRES:
        c.execute(
            "SELECT column_name FROM information_schema.columns WHERE table_name=%s",
            ("event_submissions",),
        )
        cols = {r[0] for r in c.fetchall()}
    else:
        c.execute("PRAGMA table_info(event_submissions)")
        cols = {r[1] for r in c.fetchall()}

    if "admin_note" not in cols:
        c.execute("ALTER TABLE event_submissions ADD COLUMN admin_note TEXT")
    if "approved_event_slug" not in cols:
        c.execute("ALTER TABLE event_submissions ADD COLUMN approved_event_slug TEXT")
    if "reviewed_by_account_id" not in cols:
        c.execute("ALTER TABLE event_submissions ADD COLUMN reviewed_by_account_id INTEGER")
    if "reviewed_at" not in cols:
        c.execute("ALTER TABLE event_submissions ADD COLUMN reviewed_at TEXT")

    # mobil_backend tarafindan olusturulan tablo icin uyumluluk kolonu
    try:
        if USE_POSTGRES:
            c.execute(
                "SELECT column_name FROM information_schema.columns WHERE table_name=%s",
                ("mobile_event_submissions",),
            )
            mcols = {r[0] for r in c.fetchall()}
        else:
            c.execute("PRAGMA table_info(mobile_event_submissions)")
            mcols = {r[1] for r in c.fetchall()}
        if "approved_event_slug" not in mcols:
            c.execute("ALTER TABLE mobile_event_submissions ADD COLUMN approved_event_slug TEXT")
        if "city" not in mcols:
            c.execute("ALTER TABLE mobile_event_submissions ADD COLUMN city TEXT")
        if "event_kind" not in mcols:
            c.execute("ALTER TABLE mobile_event_submissions ADD COLUMN event_kind TEXT")
        if "ticket_sales_enabled" not in mcols:
            if USE_POSTGRES:
                c.execute("ALTER TABLE mobile_event_submissions ADD COLUMN ticket_sales_enabled BOOLEAN NOT NULL DEFAULT TRUE")
            else:
                c.execute("ALTER TABLE mobile_event_submissions ADD COLUMN ticket_sales_enabled INTEGER NOT NULL DEFAULT 1")
        if "create_photo_album" not in mcols:
            if USE_POSTGRES:
                c.execute("ALTER TABLE mobile_event_submissions ADD COLUMN create_photo_album BOOLEAN NOT NULL DEFAULT FALSE")
            else:
                c.execute("ALTER TABLE mobile_event_submissions ADD COLUMN create_photo_album INTEGER NOT NULL DEFAULT 0")
        if "repeat_weekly" not in mcols:
            if USE_POSTGRES:
                c.execute("ALTER TABLE mobile_event_submissions ADD COLUMN repeat_weekly BOOLEAN NOT NULL DEFAULT FALSE")
            else:
                c.execute("ALTER TABLE mobile_event_submissions ADD COLUMN repeat_weekly INTEGER NOT NULL DEFAULT 0")
        if "repeat_weekday" not in mcols:
            c.execute("ALTER TABLE mobile_event_submissions ADD COLUMN repeat_weekday INTEGER")
        if "repeat_origin_submission_id" not in mcols:
            c.execute("ALTER TABLE mobile_event_submissions ADD COLUMN repeat_origin_submission_id INTEGER")
    except Exception:
        # tablo bu app'te yoksa sessiz gec
        pass

    conn.commit()
    conn.close()


def ensure_embedding_cache_tables():
    global HAS_PGVECTOR
    HAS_PGVECTOR = False


def _pbkdf2_hash(password: str, salt: bytes) -> bytes:
    return hashlib.pbkdf2_hmac("sha256", password.encode("utf-8"), salt, 120_000)


def hash_password(password: str) -> str:
    salt = secrets.token_bytes(16)
    dk = _pbkdf2_hash(password, salt)
    return base64.b64encode(salt + dk).decode("utf-8")


def verify_password(password: str, stored: str) -> bool:
    raw = base64.b64decode(stored.encode("utf-8"))
    salt, dk = raw[:16], raw[16:]
    test = _pbkdf2_hash(password, salt)
    return hmac.compare_digest(dk, test)


def ensure_super_admin_from_env():
    email = os.getenv("SUPERADMIN_EMAIL")
    password = os.getenv("SUPERADMIN_PASSWORD")
    if not email or not password:
        return

    email = email.strip().lower()

    conn = db_conn()
    c = conn.cursor()
    c.execute("SELECT id FROM accounts WHERE role='super_admin' LIMIT 1")
    row = c.fetchone()
    if row:
        conn.close()
        return

    c.execute(
        "INSERT INTO accounts (email, password_hash, role, is_active, photo_credit, name, created_at) VALUES (?, ?, 'super_admin', 1, 0, NULL, ?)",
        (email, hash_password(password), iso_now()),
    )
    conn.commit()
    conn.close()


def create_session(account_id: int, days: int = 7) -> str:
    token = secrets.token_urlsafe(32)
    expires_at = (datetime.utcnow() + timedelta(days=days)).isoformat(timespec="seconds")

    conn = db_conn()
    c = conn.cursor()
    c.execute(
        "INSERT INTO sessions (account_id, session_token, expires_at, created_at) VALUES (?, ?, ?, ?)",
        (account_id, token, expires_at, iso_now()),
    )
    conn.commit()
    conn.close()
    return token


def destroy_session(token: str):
    conn = db_conn()
    c = conn.cursor()
    c.execute("DELETE FROM sessions WHERE session_token=?", (token,))
    conn.commit()
    conn.close()


def get_current_account(request: Request) -> Optional[sqlite3.Row]:
    token = request.cookies.get(SESSION_COOKIE)
    if not token:
        return None

    # Rol değişiklikleri panelde beklemeden görünmeli.
    # maybe_sync_wp_users cache'lidir; her istekte çağrı güvenlidir.
    try:
        maybe_sync_wp_users(force=False)
    except Exception:
        pass

    conn = db_conn()
    c = conn.cursor()
    c.execute("""
        SELECT a.* , s.expires_at as session_expires_at
        FROM sessions s
        JOIN accounts a ON a.id = s.account_id
        WHERE s.session_token = ?
        LIMIT 1
    """, (token,))
    row = c.fetchone()
    conn.close()

    if not row:
        return None

    try:
        exp = datetime.fromisoformat(row["session_expires_at"])
        if exp < datetime.utcnow():
            destroy_session(token)
            return None
    except Exception:
        destroy_session(token)
        return None

    if int(row["is_active"]) != 1:
        return None

    return row


def require_super_admin(request: Request) -> sqlite3.Row:
    acc = get_current_account(request)
    if not acc:
        raise HTTPException(status_code=401, detail="Giriş gerekli")
    if acc["role"] != "super_admin":
        raise HTTPException(status_code=403, detail="Yetki yok")
    return acc


def require_console_access(request: Request):
    acc = get_current_account(request)
    if not acc:
        return RedirectResponse("/login?err=Console için giriş gerekli", status_code=303)
    if acc["role"] != "super_admin":
        raise HTTPException(status_code=403, detail="Console yetkiniz yok")
    return acc


def _wp_base_url() -> str:
    return (os.getenv("WOO_BASE_URL", "") or "").strip().rstrip("/")


def _loads_wp_json_response(body: str) -> Dict[str, Any]:
    """
    Some hosting/security layers prepend an nginx 404 HTML fragment before the
    real WordPress JWT JSON response. Accept clean JSON and recover from that
    mixed response shape so users do not see raw HTML on login.
    """
    text = (body or "").strip()
    if not text:
        return {}
    try:
        parsed = json.loads(text)
        return parsed if isinstance(parsed, dict) else {}
    except Exception:
        pass

    for match in re.finditer(r"\{", text):
        candidate = text[match.start():].strip()
        try:
            parsed = json.loads(candidate)
        except Exception:
            continue
        return parsed if isinstance(parsed, dict) else {}
    return {}


def _clean_wp_html_message(message: str) -> str:
    msg = html_lib.unescape(message or "")
    msg = re.sub(r"<[^>]+>", " ", msg)
    msg = re.sub(r"\s+", " ", msg).strip()
    return msg


def _friendly_wp_login_error(status_code: int, body: str) -> str:
    parsed = _loads_wp_json_response(body)
    code = str(parsed.get("code") or "").strip()
    message = _clean_wp_html_message(str(parsed.get("message") or ""))
    low = f"{code} {message}".lower()

    if "incorrect_password" in low or "invalid_username" in low or "kullanıcı adı veya parola yanlış" in low:
        return "WordPress kullanıcı adı veya şifre hatalı. Şifreni yeni değiştirdiysen yeni şifreyle tekrar dene."
    if "jwt_auth" in low and message:
        return f"WordPress giriş doğrulaması reddedildi: {message}"
    if message:
        return f"WordPress login hatası (HTTP {status_code}): {message}"
    return f"WordPress login servisi beklenen yanıtı vermedi (HTTP {status_code}). Lütfen biraz sonra tekrar deneyin."


def _wp_admin_login(email: str, password: str) -> Dict[str, Any]:
    base = _wp_base_url()
    if not base:
        raise RuntimeError("WOO_BASE_URL eksik")

    payload = urllib.parse.urlencode(
        {
            "username": email.strip(),
            "password": password,
        }
    ).encode("utf-8")
    token_req = urllib.request.Request(
        f"{base}/wp-json/jwt-auth/v1/token",
        data=payload,
        headers={"Content-Type": "application/x-www-form-urlencoded"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(token_req, timeout=20) as resp:
            token_body = resp.read().decode("utf-8", errors="replace")
        token_json = _loads_wp_json_response(token_body)
    except urllib.error.HTTPError as e:
        msg = e.read().decode("utf-8", errors="replace")
        raise RuntimeError(_friendly_wp_login_error(e.code, msg))
    except Exception as e:
        raise RuntimeError(f"WP login hatası: {e}")

    jwt_token = (token_json.get("token") or "").strip()
    if not jwt_token:
        raise RuntimeError("WP token alınamadı")

    me_req = urllib.request.Request(
        f"{base}/wp-json/wp/v2/users/me?context=edit",
        headers={"Authorization": f"Bearer {jwt_token}"},
        method="GET",
    )
    try:
        with urllib.request.urlopen(me_req, timeout=20) as resp:
            me_body = resp.read().decode("utf-8", errors="replace")
        me = _loads_wp_json_response(me_body)
    except urllib.error.HTTPError as e:
        msg = e.read().decode("utf-8", errors="replace")
        clean_msg = _friendly_wp_login_error(e.code, msg)
        raise RuntimeError(f"WP kullanıcı doğrulama hatası: {clean_msg}")
    except Exception as e:
        raise RuntimeError(f"WP kullanıcı doğrulama hatası: {e}")

    roles = [str(r).strip().lower() for r in (me.get("roles") or []) if str(r).strip()]
    if "administrator" not in roles:
        raise PermissionError("Panel erişimi için WordPress yönetici rolü gerekir.")

    wp_user_id = int(me.get("id") or 0) if str(me.get("id") or "").isdigit() else 0
    wp_email = (me.get("email") or token_json.get("user_email") or email).strip().lower()
    wp_name = (me.get("name") or token_json.get("user_display_name") or "").strip()
    return {
        "wp_user_id": wp_user_id,
        "email": wp_email,
        "name": wp_name,
        "roles": roles,
    }


def _mobile_auth_base() -> str:
    return (os.getenv("MOBILE_AUTH_BASE", "https://api2.dansmagazin.net") or "").strip().rstrip("/")


def _mobile_session_me(session_token: str) -> Dict[str, Any]:
    token = (session_token or "").strip()
    if not token:
        raise PermissionError("Mobil oturum eksik")
    base = _mobile_auth_base()
    if not base:
        raise RuntimeError("MOBILE_AUTH_BASE eksik")

    req = urllib.request.Request(
        f"{base}/auth/me",
        headers={"Authorization": f"Bearer {token}"},
        method="GET",
    )
    try:
        with urllib.request.urlopen(req, timeout=15) as resp:
            body = resp.read().decode("utf-8", errors="replace")
        me = json.loads(body) if body else {}
    except urllib.error.HTTPError as e:
        msg = e.read().decode("utf-8", errors="replace")
        if e.code == 401:
            raise PermissionError("Mobil oturum geçersiz")
        raise RuntimeError(f"Mobil doğrulama hatası (HTTP {e.code}): {msg[:300]}")
    except Exception as e:
        raise RuntimeError(f"Mobil doğrulama hatası: {e}")

    if not isinstance(me, dict):
        raise RuntimeError("Mobil kullanıcı cevabı geçersiz")
    return me


def _normalize_panel_next_path(next_value: str) -> str:
    raw = (next_value or "").strip()
    if not raw:
        return "/panel/overview"

    try:
        p = urllib.parse.urlparse(raw)
    except Exception:
        return "/panel/overview"

    if p.scheme or p.netloc:
        return "/panel/overview"

    path = (p.path or "").strip()
    if not path:
        path = "/panel/overview"
    if not path.startswith("/"):
        path = f"/{path}"

    allowed_prefixes = ("/panel", "/admin/users", "/admin/mobile", "/console")
    if not any(path.startswith(prefix) for prefix in allowed_prefixes):
        path = "/panel/overview"

    query = urllib.parse.urlencode(
        urllib.parse.parse_qsl(p.query, keep_blank_values=True),
        doseq=True,
    )
    return f"{path}?{query}" if query else path


def _upsert_panel_admin_from_wp(wp_user: Dict[str, Any]) -> int:
    email = (wp_user.get("email") or "").strip().lower()
    if not email:
        raise RuntimeError("WP kullanıcı email boş")

    name = (wp_user.get("name") or "").strip()
    wp_user_id = int(wp_user.get("wp_user_id") or 0)

    conn = db_conn()
    c = conn.cursor()
    try:
        c.execute("SELECT id FROM accounts WHERE LOWER(email)=LOWER(?) LIMIT 1", (email,))
        row = c.fetchone()
        if row:
            account_id = int(row["id"])
            c.execute(
                """
                UPDATE accounts
                SET role='super_admin',
                    is_active=1,
                    can_create_mobile_event=1,
                    name=COALESCE(NULLIF(?,''), name)
                WHERE id=?
                """,
                (name, account_id),
            )
        else:
            account_id = 0
            random_pw = secrets.token_urlsafe(24)
            c.execute(
                """
                INSERT INTO accounts (email, password_hash, role, is_active, photo_credit, name, created_at, can_create_mobile_event)
                VALUES (?, ?, 'super_admin', 1, 0, ?, ?, 1)
                """,
                (email, hash_password(random_pw), name or None, iso_now()),
            )
            c.execute("SELECT id FROM accounts WHERE LOWER(email)=LOWER(?) LIMIT 1", (email,))
            created = c.fetchone()
            if not created:
                raise RuntimeError("Panel admin hesabı oluşturulamadı")
            account_id = int(created["id"])

        if wp_user_id > 0:
            c.execute(
                """
                INSERT INTO identity_map (wp_user_id, app_account_id, match_strategy, confidence, note, is_active)
                VALUES (?, ?, 'wp_panel_login', 100, 'panel_wp_admin_login', TRUE)
                ON CONFLICT (wp_user_id) DO UPDATE
                SET app_account_id=excluded.app_account_id,
                    match_strategy=excluded.match_strategy,
                    confidence=excluded.confidence,
                    note=excluded.note,
                    linked_at=?,
                    is_active=TRUE
                """,
                (wp_user_id, account_id, iso_now()),
            )

        conn.commit()
        return account_id
    finally:
        conn.close()


# =========================
# CSRF
# =========================

def _csrf_token_from_cookie(request: Request) -> str:
    return request.cookies.get(CSRF_COOKIE) or ""


def verify_csrf_token(request: Request, token: str):
    cookie = _csrf_token_from_cookie(request)
    if not cookie or not token or not hmac.compare_digest(cookie, token):
        raise HTTPException(status_code=403, detail="CSRF doğrulaması başarısız")


def _csrf_refresh_redirect(url: str):
    token = secrets.token_urlsafe(32)
    resp = RedirectResponse(url, status_code=303)
    resp.set_cookie(
        CSRF_COOKIE,
        token,
        httponly=True,
        secure=CSRF_COOKIE_SECURE,
        samesite="lax",
        max_age=CSRF_MAX_AGE,
        path="/",
    )
    return resp


def render_template(request: Request, name: str, context: Dict[str, Any], csrf: bool = False):
    if not csrf:
        return templates.TemplateResponse(name, context)

    token = _csrf_token_from_cookie(request)
    if not token:
        token = secrets.token_urlsafe(32)
    ctx = dict(context)
    ctx["csrf_token"] = token
    resp = templates.TemplateResponse(name, ctx)
    if not _csrf_token_from_cookie(request):
        resp.set_cookie(
            CSRF_COOKIE,
            token,
            httponly=True,
            secure=CSRF_COOKIE_SECURE,
            samesite="lax",
            max_age=CSRF_MAX_AGE,
            path="/",
        )
    return resp


# =========================
# STARTUP
# =========================

@app.on_event("startup")
def on_startup():
    init_legacy_db()
    init_auth_tables()
    init_event_account_frames_table()
    ensure_accounts_columns()
    ensure_saas_event_columns()
    ensure_jobs_columns()
    ensure_event_subalbums_table()
    ensure_event_photos_columns()
    ensure_mobile_profile_settings_table()
    ensure_mail_log_table()
    ensure_qr_scan_table()
    ensure_download_table()
    ensure_photo_attempts_table()
    ensure_event_submissions_table()
    ensure_event_submissions_columns()
    ensure_identity_tables()
    # Embedding DDL/index islemlerini runtime'da her startup'ta calistirma.
    # Bunlar restart.sh -> ensure_postgres_schema.py ile kontrollu sekilde uygulanir.
    if AUTO_DDL_ON_STARTUP:
        ensure_embedding_cache_tables()
    ensure_super_admin_from_env()
    start_job_runner()


# =========================
# BASIC NAV
# =========================

@app.get("/", include_in_schema=False)
def root():
    return RedirectResponse("/login", status_code=303)


# =========================
# AUTH ROUTES
# =========================

@app.get("/login", response_class=HTMLResponse, include_in_schema=False)
def login_page(request: Request, msg: Optional[str] = None, err: Optional[str] = None):
    return render_template(
        request,
        "login.html",
        {"request": request, "message": msg, "error": err},
        csrf=True,
    )


@app.get("/mobile-sso-login", include_in_schema=False)
def mobile_sso_login(request: Request, next: Optional[str] = None, st: Optional[str] = None):
    auth = (request.headers.get("authorization") or "").strip()
    session_token = ""
    if auth.lower().startswith("bearer "):
        session_token = auth.split(" ", 1)[1].strip()
    if not session_token:
        session_token = (st or "").strip()
    if not session_token:
        return RedirectResponse("/login?err=Mobil oturum bulunamadı", status_code=303)

    next_path = _normalize_panel_next_path(next or "")
    try:
        me = _mobile_session_me(session_token)
        app_role = (me.get("app_role") or "customer").strip().lower()
        if app_role != "super_admin":
            return RedirectResponse("/login?err=Bu panel sadece super admin için", status_code=303)

        email = (me.get("email") or "").strip().lower()
        if not email:
            raise RuntimeError("Mobil kullanıcı email boş")
        name = (me.get("name") or "").strip()
        wp_user_id_raw = me.get("wp_user_id")
        wp_user_id = int(wp_user_id_raw) if str(wp_user_id_raw or "").isdigit() else 0

        account_id = _upsert_panel_admin_from_wp(
            {
                "email": email,
                "name": name,
                "wp_user_id": wp_user_id,
                "roles": ["administrator"],
            }
        )
    except PermissionError as e:
        return RedirectResponse(f"/login?err={urllib.parse.quote(str(e))}", status_code=303)
    except Exception as e:
        return RedirectResponse(f"/login?err={urllib.parse.quote(str(e))}", status_code=303)

    token = create_session(account_id, days=7)
    resp = RedirectResponse(next_path, status_code=303)
    resp.set_cookie(
        key=SESSION_COOKIE,
        value=token,
        httponly=True,
        secure=True,
        samesite="lax",
        max_age=60 * 60 * 24 * 7,
        path="/",
    )
    return resp


@app.post("/login", include_in_schema=False)
async def login_post(request: Request):
    form = await request.form()
    try:
        verify_csrf_token(request, form.get(CSRF_PARAM))
    except HTTPException:
        return _csrf_refresh_redirect("/login?err=Oturum yenilendi, tekrar deneyin")
    email = (form.get("email") or "").strip().lower()
    password = (form.get("password") or "").strip()

    if not email or not password:
        return RedirectResponse("/login?err=E-posta ve şifre zorunlu", status_code=303)

    try:
        wp_user = _wp_admin_login(email, password)
        account_id = _upsert_panel_admin_from_wp(wp_user)
    except PermissionError as e:
        return RedirectResponse(f"/login?err={urllib.parse.quote(str(e))}", status_code=303)
    except Exception as e:
        return RedirectResponse(f"/login?err={urllib.parse.quote(str(e))}", status_code=303)

    token = create_session(account_id, days=7)
    resp = RedirectResponse("/panel", status_code=303)
    resp.set_cookie(
        key=SESSION_COOKIE,
        value=token,
        httponly=True,
        secure=True,
        samesite="lax",
        max_age=60 * 60 * 24 * 7,
        path="/",
    )
    return resp


@app.get("/signup", response_class=HTMLResponse, include_in_schema=False)
def signup_page(request: Request, msg: Optional[str] = None, err: Optional[str] = None):
    return RedirectResponse("/login?err=Panel kaydı kapalı. Sadece yetkili hesaplarla giriş yapılabilir.", status_code=303)


@app.post("/signup", include_in_schema=False)
async def signup_post(request: Request):
    return RedirectResponse("/login?err=Panel kaydı kapalı. Sadece yetkili hesaplarla giriş yapılabilir.", status_code=303)


@app.api_route("/logout", methods=["GET", "POST", "HEAD"], include_in_schema=False)
def logout_any(request: Request):
    token = request.cookies.get(SESSION_COOKIE)
    if token:
        destroy_session(token)

    resp = RedirectResponse("/login?msg=Çıkış yapıldı", status_code=303)
    resp.delete_cookie(SESSION_COOKIE, path="/")
    return resp


@app.api_route("/console/logout", methods=["GET", "POST", "HEAD"], include_in_schema=False)
def console_logout_alias_any():
    return RedirectResponse("/logout", status_code=303)


@app.api_route("/console/logout/", methods=["GET", "POST", "HEAD"], include_in_schema=False)
def console_logout_alias_slash_any():
    return RedirectResponse("/logout", status_code=303)


# =========================
# PANEL HOME (ROLE ROUTER)
# =========================

@app.get("/panel", response_class=HTMLResponse, include_in_schema=False)
def panel_home(request: Request):
    acc = get_current_account(request)
    if not acc:
        return RedirectResponse("/login?err=Önce giriş yapın", status_code=303)

    if acc["role"] == "super_admin":
        return RedirectResponse("/admin/users", status_code=303)

    return RedirectResponse("/panel/events", status_code=303)


# =========================
# SUPER ADMIN: USER MANAGEMENT
# =========================

@app.get("/admin/users", response_class=HTMLResponse, include_in_schema=False)
def admin_users(request: Request, msg: Optional[str] = None, err: Optional[str] = None):
    _ = require_super_admin(request)

    wp_users: List[Dict[str, Any]] = []
    wp_error = ""
    wp_only: List[Dict[str, Any]] = []
    sync_stats: Dict[str, Any] = get_wp_sync_snapshot()
    if sync_stats.get("last_error"):
        wp_error = f"WP/Woo kullanıcıları okunamadı: {sync_stats.get('last_error')}"

    qp = request.query_params
    role_filter = (qp.get("role") or "all").strip().lower()
    if role_filter not in {"all", "super_admin", "editor", "customer"}:
        role_filter = "all"
    q = (qp.get("q") or "").strip()
    sort = (qp.get("sort") or "id").strip().lower()
    order = (qp.get("order") or "desc").strip().lower()
    if order not in {"asc", "desc"}:
        order = "desc"
    sort_sql_map = {
        "id": "a.id",
        "username": "LOWER(COALESCE(mps.username,''))",
        "email": "LOWER(a.email)",
        "role": "LOWER(a.role)",
        "status": "a.is_active",
    }
    sort_sql = sort_sql_map.get(sort, "a.id")

    conn = db_conn()
    c = conn.cursor()
    where_parts: List[str] = []
    params: List[Any] = []
    if role_filter != "all":
        where_parts.append("a.role=?")
        params.append(role_filter)
    if q:
        where_parts.append(
            "(LOWER(a.email) LIKE ? OR LOWER(COALESCE(a.name,'')) LIKE ? OR LOWER(COALESCE(mps.username,'')) LIKE ? OR CAST(a.id AS TEXT) LIKE ?)"
        )
        q_like = f"%{q.lower()}%"
        params.extend([q_like, q_like, q_like, q_like])

    sql = """
        SELECT
            a.id, a.email, a.role, a.is_active, a.photo_credit, a.created_at,
            a.name,
            COALESCE(mps.username,'') AS app_username,
            CASE
                WHEN LOWER(COALESCE(a.role,'')) IN ('super_admin', 'editor') THEN TRUE
                ELSE COALESCE(mps.is_verified, FALSE)
            END AS is_verified,
            CASE
                WHEN LOWER(COALESCE(a.role,'')) IN ('super_admin', 'editor') THEN TRUE
                ELSE FALSE
            END AS is_auto_verified,
            COALESCE(can_create_mobile_event, 0) AS can_create_mobile_event
            , im.wp_user_id AS mapped_wp_user_id
        FROM accounts a
        LEFT JOIN identity_map im ON im.app_account_id=a.id AND COALESCE(im.is_active,TRUE)=TRUE
        LEFT JOIN mobile_profile_settings mps ON mps.account_id=a.id
        """
    if where_parts:
        sql += " WHERE " + " AND ".join(where_parts)
    sql += f" ORDER BY {sort_sql} {order.upper()}, a.id DESC"
    c.execute(sql, tuple(params))
    users = c.fetchall()
    conn.close()

    return render_template(request, "admin_users.html", {
        "request": request,
        "users": users,
        "wp_users": wp_users,
        "wp_only": wp_only,
        "wp_error": wp_error,
        "sync_stats": sync_stats,
        "message": msg,
        "error": err,
        "role_filter": role_filter,
        "q": q,
        "sort": sort if sort in sort_sql_map else "id",
        "order": order,
    }, csrf=True)


@app.get("/admin/users/{user_id}", response_class=HTMLResponse, include_in_schema=False)
def admin_user_detail(request: Request, user_id: int, msg: Optional[str] = None, err: Optional[str] = None):
    _ = require_super_admin(request)
    conn = db_conn()
    c = conn.cursor()
    c.execute(
        """
        SELECT
            a.id, a.email, a.role, a.is_active, a.photo_credit, a.created_at, a.name,
            COALESCE(mps.username,'') AS app_username,
            CASE
                WHEN LOWER(COALESCE(a.role,'')) IN ('super_admin', 'editor') THEN TRUE
                ELSE COALESCE(mps.is_verified, FALSE)
            END AS is_verified,
            CASE
                WHEN LOWER(COALESCE(a.role,'')) IN ('super_admin', 'editor') THEN TRUE
                ELSE FALSE
            END AS is_auto_verified,
            COALESCE(a.can_create_mobile_event,0) AS can_create_mobile_event,
            im.wp_user_id AS mapped_wp_user_id
        FROM accounts a
        LEFT JOIN identity_map im ON im.app_account_id=a.id AND COALESCE(im.is_active,TRUE)=TRUE
        LEFT JOIN mobile_profile_settings mps ON mps.account_id=a.id
        WHERE a.id=?
        LIMIT 1
        """,
        (int(user_id),),
    )
    user = c.fetchone()
    c.execute(
        """
        SELECT a.id, a.email, COALESCE(mps.username,'') AS app_username
        FROM accounts a
        LEFT JOIN mobile_profile_settings mps ON mps.account_id=a.id
        WHERE a.role='customer' AND a.id<>?
        ORDER BY a.id DESC
        """,
        (int(user_id),),
    )
    merge_candidates = c.fetchall() or []
    conn.close()
    if not user:
        return RedirectResponse("/admin/users?err=Kullanıcı bulunamadı", status_code=303)
    return render_template(
        request,
        "admin_user_detail.html",
        {
            "request": request,
            "user": user,
            "merge_candidates": merge_candidates,
            "message": msg,
            "error": err,
        },
        csrf=True,
    )


@app.post("/admin/users/{user_id}/set_username", include_in_schema=False)
async def admin_set_user_username(
    request: Request,
    user_id: int,
    username: str = Form(...),
    redirect_to: Optional[str] = Form(None),
):
    _ = require_super_admin(request)
    form = await request.form()
    verify_csrf_token(request, form.get(CSRF_PARAM))

    back = (redirect_to or "").strip() or f"/admin/users/{int(user_id)}"
    normalized = " ".join((username or "").split())
    if len(normalized) < 3 or len(normalized) > 40:
        return RedirectResponse(f"{back}?err=Kullanıcı adı 3-40 karakter olmalı", status_code=303)

    conn = db_conn()
    c = conn.cursor()
    c.execute("SELECT id, role FROM accounts WHERE id=? LIMIT 1", (int(user_id),))
    row = c.fetchone()
    if not row:
        conn.close()
        return RedirectResponse(f"{back}?err=Kullanıcı bulunamadı", status_code=303)
    if (row.get("role") or "").strip().lower() == "super_admin":
        conn.close()
        return RedirectResponse(f"{back}?err=Super admin kullanıcı adı panelden değiştirilemez", status_code=303)

    c.execute(
        """
        INSERT INTO mobile_profile_settings (account_id, username, updated_at)
        VALUES (?, ?, NOW())
        ON CONFLICT (account_id) DO UPDATE
        SET username=EXCLUDED.username, updated_at=NOW()
        """,
        (int(user_id), normalized),
    )
    conn.commit()
    conn.close()
    return RedirectResponse(f"{back}?msg=Kullanıcı adı güncellendi", status_code=303)


@app.post("/admin/users/create", include_in_schema=False)
def admin_create_user(
    request: Request,
    email: str = Form(...),
    password: str = Form(...),
    photo_credit: int = Form(0),
    can_create_mobile_event: Optional[str] = Form(None),
    csrf_token: str = Form(...),
):
    _ = require_super_admin(request)
    verify_csrf_token(request, csrf_token)
    return RedirectResponse("/admin/users?err=Panelden kullanıcı oluşturma kapalı. Kullanıcılar yalnızca WP/Woo'dan gelir.", status_code=303)


@app.post("/admin/users/sync_wp", include_in_schema=False)
async def admin_sync_wp_users(request: Request):
    _ = require_super_admin(request)
    form = await request.form()
    verify_csrf_token(request, form.get(CSRF_PARAM))
    try:
        stat = maybe_sync_wp_users(force=True)
        msg = (
            f"WP senkron tamamlandı: wp_total={stat['wp_total']}, "
            f"created={stat['created']}, updated={stat['updated']}, "
            f"mapped={stat['mapped']}, panel_to_wp_created={stat['panel_to_wp_created']}, "
            f"panel_to_wp_mapped={stat['panel_to_wp_mapped']}, conflicts={stat['conflicts']}, skipped={stat['skipped']}"
        )
        return RedirectResponse(f"/admin/users?msg={urllib.parse.quote(msg)}", status_code=303)
    except Exception as e:
        return RedirectResponse(f"/admin/users?err={urllib.parse.quote(f'WP senkron hatası: {e}')}", status_code=303)


@app.post("/admin/users/{user_id}/set_password", include_in_schema=False)
async def admin_set_user_password(
    request: Request,
    user_id: int,
    password: str = Form(...),
    redirect_to: Optional[str] = Form(None),
):
    _ = require_super_admin(request)
    form = await request.form()
    verify_csrf_token(request, form.get(CSRF_PARAM))

    pw = (password or "").strip()
    back = (redirect_to or "").strip() or f"/admin/users/{int(user_id)}"
    if len(pw) < 6:
        return RedirectResponse(f"{back}?err=Parola en az 6 karakter olmalı", status_code=303)

    conn = db_conn()
    c = conn.cursor()
    c.execute("SELECT id, role FROM accounts WHERE id=? LIMIT 1", (int(user_id),))
    row = c.fetchone()
    if not row:
        conn.close()
        return RedirectResponse(f"{back}?err=Kullanıcı bulunamadı", status_code=303)
    if (row.get("role") or "").strip().lower() == "super_admin":
        conn.close()
        return RedirectResponse(f"{back}?err=Super admin parolası panelden değiştirilemez", status_code=303)
    c.execute("UPDATE accounts SET password_hash=? WHERE id=?", (hash_password(pw), int(user_id)))
    conn.commit()
    conn.close()
    return RedirectResponse(f"{back}?msg=Parola güncellendi", status_code=303)


@app.post("/admin/users/merge", include_in_schema=False)
async def admin_merge_users(
    request: Request,
    source_user_id: int = Form(...),
    target_user_id: int = Form(...),
    target_new_password: str = Form(""),
    redirect_to: Optional[str] = Form(None),
):
    _ = require_super_admin(request)
    form = await request.form()
    verify_csrf_token(request, form.get(CSRF_PARAM))

    src = int(source_user_id)
    dst = int(target_user_id)
    back = (redirect_to or "").strip() or "/admin/users"
    if src == dst:
        return RedirectResponse(f"{back}?err=Kaynak ve hedef kullanıcı aynı olamaz", status_code=303)

    conn = db_conn()
    c = conn.cursor()
    try:
        c.execute("SELECT id, email FROM accounts WHERE id=? AND role='customer' LIMIT 1", (src,))
        srow = c.fetchone()
        c.execute("SELECT id, email FROM accounts WHERE id=? AND role='customer' LIMIT 1", (dst,))
        drow = c.fetchone()
        if not srow or not drow:
            conn.close()
            return RedirectResponse(f"{back}?err=Kaynak veya hedef kullanıcı bulunamadı", status_code=303)

        c.execute("UPDATE saas_events SET account_id=? WHERE account_id=?", (dst, src))
        c.execute("UPDATE jobs SET account_id=? WHERE account_id=?", (dst, src))
        c.execute("UPDATE event_photos SET uploaded_by_account_id=? WHERE uploaded_by_account_id=?", (dst, src))
        c.execute("UPDATE sessions SET account_id=? WHERE account_id=?", (dst, src))

        c.execute("SELECT wp_user_id FROM identity_map WHERE app_account_id=? AND COALESCE(is_active,TRUE)=TRUE", (src,))
        src_wp_rows = c.fetchall() or []
        for r in src_wp_rows:
            wp_uid = int(r["wp_user_id"])
            try:
                c.execute(
                    """
                    INSERT INTO identity_map (wp_user_id, app_account_id, match_strategy, confidence, note, is_active)
                    VALUES (?, ?, 'manual_merge', 95, 'admin_merge', TRUE)
                    ON CONFLICT (wp_user_id) DO UPDATE
                    SET app_account_id=EXCLUDED.app_account_id,
                        match_strategy=EXCLUDED.match_strategy,
                        confidence=EXCLUDED.confidence,
                        note=EXCLUDED.note,
                        linked_at=NOW(),
                        is_active=TRUE
                    """,
                    (wp_uid, dst),
                )
            except Exception:
                c.execute("UPDATE identity_map SET is_active=FALSE WHERE wp_user_id=?", (wp_uid,))

        src_email = (srow["email"] or "").strip().lower()
        merged_email = f"merged+{src}+{src_email}"[:240]
        c.execute(
            "UPDATE accounts SET is_active=0, can_create_mobile_event=0, email=?, name=COALESCE(name,'') || ' [merged]' WHERE id=?",
            (merged_email, src),
        )

        new_pw = (target_new_password or "").strip()
        if new_pw:
            if len(new_pw) < 6:
                conn.rollback()
                conn.close()
                return RedirectResponse(f"{back}?err=Yeni parola en az 6 karakter olmalı", status_code=303)
            c.execute("UPDATE accounts SET password_hash=? WHERE id=?", (hash_password(new_pw), dst))

        conn.commit()
        conn.close()
        return RedirectResponse(f"{back}?msg=Kullanıcılar birleştirildi", status_code=303)
    except Exception as e:
        conn.rollback()
        conn.close()
        return RedirectResponse(f"{back}?err={urllib.parse.quote(f'Birleştirme hatası: {e}')}", status_code=303)


@app.post("/admin/users/{user_id}/toggle", include_in_schema=False)
async def admin_toggle_user(request: Request, user_id: int, redirect_to: Optional[str] = Form(None)):
    _ = require_super_admin(request)
    form = await request.form()
    verify_csrf_token(request, form.get(CSRF_PARAM))

    back = (redirect_to or "").strip() or f"/admin/users/{int(user_id)}"
    conn = db_conn()
    c = conn.cursor()
    c.execute("SELECT is_active, role FROM accounts WHERE id=?", (user_id,))
    row = c.fetchone()
    if not row:
        conn.close()
        return RedirectResponse(f"{back}?err=Kullanıcı bulunamadı", status_code=303)
    if (row.get("role") or "").strip().lower() == "super_admin":
        conn.close()
        return RedirectResponse(f"{back}?err=Super admin hesabı pasife alınamaz", status_code=303)

    new_val = 0 if int(row["is_active"]) == 1 else 1
    c.execute("UPDATE accounts SET is_active=? WHERE id=?", (new_val, user_id))
    conn.commit()
    conn.close()

    return RedirectResponse(f"{back}?msg=Hesap durumu güncellendi", status_code=303)


@app.post("/admin/users/{user_id}/set_credit", include_in_schema=False)
async def admin_set_credit(
    request: Request,
    user_id: int,
    photo_credit: int = Form(...),
    redirect_to: Optional[str] = Form(None),
):
    _ = require_super_admin(request)
    form = await request.form()
    verify_csrf_token(request, form.get(CSRF_PARAM))

    back = (redirect_to or "").strip() or f"/admin/users/{int(user_id)}"
    conn = db_conn()
    c = conn.cursor()
    c.execute("SELECT id, role FROM accounts WHERE id=? LIMIT 1", (int(user_id),))
    row = c.fetchone()
    if not row:
        conn.close()
        return RedirectResponse(f"{back}?err=Kullanıcı bulunamadı", status_code=303)
    if (row.get("role") or "").strip().lower() == "super_admin":
        conn.close()
        return RedirectResponse(f"{back}?err=Super admin kredisi değiştirilemez", status_code=303)
    c.execute("UPDATE accounts SET photo_credit=? WHERE id=?", (int(photo_credit), user_id))
    conn.commit()
    conn.close()

    return RedirectResponse(f"{back}?msg=Kredi güncellendi", status_code=303)


@app.post("/admin/users/{user_id}/toggle_verified", include_in_schema=False)
async def admin_toggle_verified_user(
    request: Request,
    user_id: int,
    redirect_to: Optional[str] = Form(None),
):
    _ = require_super_admin(request)
    form = await request.form()
    verify_csrf_token(request, form.get(CSRF_PARAM))

    back = (redirect_to or "").strip() or f"/admin/users/{int(user_id)}"
    conn = db_conn()
    c = conn.cursor()
    c.execute("SELECT id, role FROM accounts WHERE id=? LIMIT 1", (int(user_id),))
    row = c.fetchone()
    if not row:
        conn.close()
        return RedirectResponse(f"{back}?err=Kullanıcı bulunamadı", status_code=303)
    role = ((row or {}).get("role") or "").strip().lower()
    if role in {"super_admin", "editor"}:
        conn.close()
        msg = "Bu kullanıcı rolü gereği otomatik olarak onaylıdır"
        return RedirectResponse(f"{back}?msg={urllib.parse.quote(msg)}", status_code=303)

    c.execute("SELECT COALESCE(is_verified, FALSE) AS is_verified FROM mobile_profile_settings WHERE account_id=? LIMIT 1", (int(user_id),))
    current = c.fetchone()
    current_verified = bool((current or {}).get("is_verified"))
    new_verified = not current_verified
    c.execute(
        """
        INSERT INTO mobile_profile_settings (account_id, is_verified, updated_at)
        VALUES (?, ?, NOW())
        ON CONFLICT (account_id) DO UPDATE
        SET is_verified=EXCLUDED.is_verified, updated_at=NOW()
        """,
        (int(user_id), bool(new_verified)),
    )
    conn.commit()
    conn.close()
    msg = "Onaylı kullanıcı işareti güncellendi"
    return RedirectResponse(f"{back}?msg={urllib.parse.quote(msg)}", status_code=303)


@app.post("/admin/users/{user_id}/toggle_mobile_event", include_in_schema=False)
async def admin_toggle_mobile_event_permission(
    request: Request,
    user_id: int,
    redirect_to: Optional[str] = Form(None),
):
    _ = require_super_admin(request)
    form = await request.form()
    verify_csrf_token(request, form.get(CSRF_PARAM))

    back = (redirect_to or "").strip() or f"/admin/users/{int(user_id)}"
    conn = db_conn()
    c = conn.cursor()
    c.execute("SELECT can_create_mobile_event, role FROM accounts WHERE id=?", (user_id,))
    row = c.fetchone()
    if not row:
        conn.close()
        return RedirectResponse(f"{back}?err=Kullanıcı bulunamadı", status_code=303)
    if (row.get("role") or "").strip().lower() == "super_admin":
        conn.close()
        return RedirectResponse(f"{back}?err=Super admin yetkisi panelden düşürülemez", status_code=303)

    new_val = 0 if int(row["can_create_mobile_event"] or 0) == 1 else 1
    c.execute("UPDATE accounts SET can_create_mobile_event=? WHERE id=?", (new_val, user_id))
    conn.commit()
    conn.close()

    wp_sync = sync_wp_customer_role_for_account(user_id, bool(new_val))
    if wp_sync.get("ok"):
        return RedirectResponse(
            f"{back}?msg=Editör yetkisi güncellendi (WP rol: {wp_sync.get('role')})",
            status_code=303,
        )
    return RedirectResponse(
        f"{back}?msg=Editör yetkisi güncellendi (WP senkron uyarısı: {wp_sync.get('error')})",
        status_code=303,
    )


@app.post("/admin/users/{user_id}/delete", include_in_schema=False)
async def admin_delete_user(request: Request, user_id: int, redirect_to: Optional[str] = Form(None)):
    _ = require_super_admin(request)
    form = await request.form()
    verify_csrf_token(request, form.get(CSRF_PARAM))
    back = (redirect_to or "").strip() or "/admin/users"

    conn = db_conn()
    c = conn.cursor()
    try:
        c.execute("SELECT id, role, email FROM accounts WHERE id=? LIMIT 1", (int(user_id),))
        row = c.fetchone()
        if not row:
            conn.close()
            return RedirectResponse(f"{back}?err=Kullanıcı bulunamadı", status_code=303)
        if row["role"] == "super_admin":
            conn.close()
            return RedirectResponse(f"{back}?err=Super admin hesabı silinemez", status_code=303)

        # İlişkili veri varsa kullanıcı silinmez; önce merge önerilir.
        c.execute("SELECT COUNT(*) AS c FROM saas_events WHERE account_id=?", (int(user_id),))
        ev_cnt = int(c.fetchone()["c"] or 0)
        c.execute("SELECT COUNT(*) AS c FROM jobs WHERE account_id=?", (int(user_id),))
        job_cnt = int(c.fetchone()["c"] or 0)
        if ev_cnt > 0 or job_cnt > 0:
            conn.close()
            return RedirectResponse(f"{back}?err=Kullanıcıya bağlı kayıtlar var (event/job). Önce birleştirin.", status_code=303)

        c.execute("DELETE FROM sessions WHERE account_id=?", (int(user_id),))
        c.execute("UPDATE identity_map SET is_active=FALSE WHERE app_account_id=?", (int(user_id),))
        c.execute("DELETE FROM accounts WHERE id=?", (int(user_id),))
        conn.commit()
        conn.close()
        return RedirectResponse(f"/admin/users?msg=Kullanıcı silindi", status_code=303)
    except Exception as e:
        conn.rollback()
        conn.close()
        return RedirectResponse(f"{back}?err={urllib.parse.quote(f'Kullanıcı silme hatası: {e}')}", status_code=303)


@app.get("/admin/mobile", response_class=HTMLResponse, include_in_schema=False)
def admin_mobile_management(
    request: Request,
    msg: Optional[str] = None,
    err: Optional[str] = None,
    tab: Optional[str] = None,
    view: Optional[str] = None,
    guest_list_id: int = 0,
    guest_user_q: Optional[str] = None,
    message_q: Optional[str] = None,
    message_limit: int = 100,
    conversation_a: int = 0,
    conversation_b: int = 0,
):
    _ = require_super_admin(request)
    active_tab = (tab or "events").strip().lower()
    if active_tab not in {"events", "news", "notifications", "reports"}:
        active_tab = "events"
    events_view = _normalize_admin_mobile_events_view(view) if active_tab == "events" else "overview"

    users: List[Dict[str, Any]] = []
    session_token = (request.cookies.get(SESSION_COOKIE) or "").strip()
    conn = db_conn()
    c = conn.cursor()

    notification_users: List[Dict[str, Any]] = []
    sent_notifications: List[Dict[str, Any]] = []
    notifications_err = ""
    current_popup: Optional[Dict[str, Any]] = None
    notification_event_targets: List[Dict[str, Any]] = []
    notification_news_targets: List[Dict[str, Any]] = []
    notification_store_targets: List[Dict[str, Any]] = []
    notification_product_targets: List[Dict[str, Any]] = []
    notification_album_targets: List[Dict[str, Any]] = []
    notification_poll_targets: List[Dict[str, Any]] = []

    submissions: List[Dict[str, Any]] = []
    submissions_err = ""
    request_items: List[Dict[str, Any]] = []
    old_request_items: List[Dict[str, Any]] = []
    active_event_items: List[Dict[str, Any]] = []
    inactive_event_items: List[Dict[str, Any]] = []
    old_event_items: List[Dict[str, Any]] = []
    news_submissions: List[Dict[str, Any]] = []
    news_submissions_err = ""
    scan_permissions_map: Dict[int, List[Dict[str, Any]]] = {}
    scan_permissions_err = ""
    loyalty_reports_map: Dict[int, Dict[str, Any]] = {}
    loyalty_reports_err = ""
    guest_lists: List[Dict[str, Any]] = []
    guest_lists_err = ""
    selected_guest_list_id = max(0, int(guest_list_id or 0))
    selected_guest_list_detail: Optional[Dict[str, Any]] = None
    guest_list_search_items: List[Dict[str, Any]] = []
    guest_list_search_meta: Dict[str, Any] = {}
    event_invitees_map: Dict[int, List[Dict[str, Any]]] = {}
    event_ticket_controls_map: Dict[int, Dict[str, Any]] = {}
    editor_candidates: List[Dict[str, Any]] = []
    woo_product_candidates: List[Dict[str, Any]] = []
    woo_products_err = ""
    reports_data: Dict[str, Any] = {}
    event_counts = {
        "requests": 0,
        "old_requests": 0,
        "active": 0,
        "hidden": 0,
        "history": 0,
    }

    if active_tab == "events":
        try:
            collected = []
            try:
                c.execute(
                    """
                    SELECT
                        es.id,
                        'event_submissions' AS source_table,
                        es.submitter_name,
                        es.submitter_email,
                        es.event_name,
                        es.description,
                        es.cover_image AS cover_path,
                        NULL::TEXT AS event_date,
                        NULL::TEXT AS venue,
                        NULL AS venue_map_url,
                        NULL AS city,
                        NULL AS event_kind,
                        NULL::TEXT AS organizer_name,
                        NULL::TEXT AS program_text,
                        es.start_at,
                        es.end_at,
                        es.entry_fee,
                        es.status,
                        TRUE AS create_photo_album,
                        es.admin_note,
                        es.approved_event_slug,
                        es.reviewed_at,
                        es.created_at,
                        ra.email AS reviewed_by_email
                    FROM event_submissions es
                    LEFT JOIN accounts ra ON ra.id = es.reviewed_by_account_id
                    ORDER BY es.id DESC
                    LIMIT 200
                    """
                )
                collected.extend(c.fetchall() or [])
            except Exception:
                pass

            try:
                c.execute(
                    """
                    SELECT
                        ms.id,
                        'mobile_event_submissions' AS source_table,
                        ms.submitter_name,
                        ms.submitter_email,
                        ms.event_name,
                        ms.description,
                        ms.cover_path,
                        ms.event_date,
                        ms.venue,
                        ms.venue_map_url,
                        ms.city,
                        ms.event_kind,
                        ms.organizer_name,
                        ms.program_text,
                        ms.start_at,
                        ms.end_at,
                        ms.entry_fee,
                        ms.status,
                        COALESCE(ms.create_photo_album, FALSE) AS create_photo_album,
                        ms.admin_note,
                        ms.approved_event_slug,
                        ms.approved_at AS reviewed_at,
                        ms.created_at,
                        NULL::TEXT AS reviewed_by_email
                    FROM mobile_event_submissions ms
                    ORDER BY ms.id DESC
                    LIMIT 200
                    """
                )
                collected.extend(c.fetchall() or [])
            except Exception:
                pass

            submissions = sorted(
                collected,
                key=lambda r: (
                    0 if (r["status"] or "") == "pending" else 1 if (r["status"] or "") == "approved" else 2,
                    -int(r["id"] or 0),
                ),
            )[:200]
            for item in submissions:
                cover_path = (item["cover_path"] or "").strip()
                if cover_path and (cover_path.startswith("http://") or cover_path.startswith("https://")):
                    item["cover_path"] = cover_path
                elif cover_path and cover_path.startswith("/"):
                    item["cover_path"] = f"{PUBLIC_BASE_URL}/events/submission-cover/{os.path.basename(cover_path)}"

            request_candidates = [s for s in submissions if (s.get("status") or "").strip().lower() != "approved"]
            for item in request_candidates:
                status = (item.get("status") or "").strip().lower()
                if status == "pending" and not _submission_is_past(item):
                    request_items.append(item)
                else:
                    old_request_items.append(item)
            event_counts["requests"] = len(request_items)
            event_counts["old_requests"] = len(old_request_items)
        except Exception as e:
            submissions_err = f"Etkinlik talepleri okunamadı: {e}"

        try:
            backend_items, backend_err = _cached_admin_event_items()
            if backend_err:
                submissions_err = submissions_err or backend_err
            else:
                active_event_items = [
                    item
                    for item in backend_items
                    if (item.get("status") or "").strip().lower() == "approved"
                    and bool(item.get("event_is_active", True))
                ]
                inactive_event_items = [
                    item
                    for item in backend_items
                    if (item.get("status") or "").strip().lower() == "approved"
                    and not bool(item.get("event_is_active", True))
                ]
                old_event_items = [
                    item for item in backend_items if (item.get("status") or "").strip().lower() == "expired"
                ]
                event_counts["active"] = len(active_event_items)
                event_counts["hidden"] = len(inactive_event_items)
                event_counts["history"] = len(old_event_items)
        except Exception as e:
            submissions_err = submissions_err or f"Canlı etkinlik listesi okunamadı: {e}"

        if session_token:
            try:
                guest_lists, guest_lists_err = _fetch_admin_guest_lists(session_token)
            except Exception as e:
                guest_lists_err = f"Davetli listeleri okunamadı: {e}"
            if guest_lists and selected_guest_list_id <= 0:
                try:
                    selected_guest_list_id = int((guest_lists[0].get("guest_list_id") or 0))
                except Exception:
                    selected_guest_list_id = 0
        else:
            guest_lists_err = "Oturum tokenı bulunamadı."

        if events_view in {"active", "hidden", "history"}:
            try:
                editor_candidates = _fetch_editor_candidates(c)
            except Exception:
                editor_candidates = []

            try:
                woo_res = _cached_woo_event_products(limit=150)
                if woo_res.get("ok"):
                    items = woo_res.get("items") if isinstance(woo_res.get("items"), list) else []
                    woo_product_candidates = items
                else:
                    woo_products_err = str(woo_res.get("error") or "Woo ürün listesi alınamadı")
            except Exception as e:
                woo_products_err = f"Woo ürün listesi okunamadı: {e}"

            try:
                permission_items: List[Dict[str, Any]] = []
                if events_view == "active":
                    permission_items = active_event_items
                elif events_view == "hidden":
                    permission_items = inactive_event_items
                else:
                    permission_items = active_event_items + inactive_event_items + old_event_items
                scan_permissions_map, scan_permissions_err = _fetch_scan_permissions_bulk(permission_items)
            except Exception as e:
                scan_permissions_err = f"Etkinlik editör yetkileri okunamadı: {e}"

            try:
                loyalty_items: List[Dict[str, Any]] = []
                if events_view == "active":
                    loyalty_items = active_event_items
                elif events_view == "hidden":
                    loyalty_items = inactive_event_items
                else:
                    loyalty_items = old_event_items
                loyalty_reports_map, loyalty_reports_err = _cached_admin_event_loyalty_reports(loyalty_items)
            except Exception as e:
                loyalty_reports_err = f"Okul / ücretsiz bilet raporu okunamadı: {e}"
            try:
                invitee_items: List[Dict[str, Any]] = []
                if events_view == "active":
                    invitee_items = active_event_items
                elif events_view == "hidden":
                    invitee_items = inactive_event_items
                else:
                    invitee_items = old_event_items
                event_invitees_map = _fetch_event_invitees_bulk(conn, invitee_items)
            except Exception:
                event_invitees_map = {}
            try:
                ticket_control_items: List[Dict[str, Any]] = []
                if events_view == "active":
                    ticket_control_items = active_event_items
                elif events_view == "hidden":
                    ticket_control_items = inactive_event_items
                else:
                    ticket_control_items = old_event_items
                event_ticket_controls_map = _fetch_event_ticket_controls_bulk(conn, ticket_control_items)
            except Exception:
                event_ticket_controls_map = {}
        elif events_view == "guest-lists" and session_token:
            if selected_guest_list_id > 0:
                try:
                    selected_guest_list_detail, detail_err = _fetch_admin_guest_list_detail(session_token, selected_guest_list_id)
                    if detail_err and not guest_lists_err:
                        guest_lists_err = detail_err
                except Exception as e:
                    if not guest_lists_err:
                        guest_lists_err = f"Davetli listesi detayları okunamadı: {e}"
            existing_account_ids: set[int] = set()
            for item in ((selected_guest_list_detail or {}).get("members") or []):
                if isinstance(item, dict):
                    try:
                        existing_account_ids.add(int(item.get("account_id") or 0))
                    except Exception:
                        continue
            q = (guest_user_q or "").strip()
            if q:
                try:
                    guest_list_search_items, guest_list_search_meta, search_err = _search_admin_guest_list_users(
                        session_token,
                        q,
                        existing_account_ids=existing_account_ids,
                    )
                    if search_err and not guest_lists_err:
                        guest_lists_err = search_err
                except Exception as e:
                    if not guest_lists_err:
                        guest_lists_err = f"Kullanıcı araması yapılamadı: {e}"

    elif active_tab == "news":
        try:
            news_submissions, news_submissions_err = _cached_admin_news_submissions()
        except Exception as e:
            news_submissions_err = f"Haber talepleri okunamadı: {e}"

    elif active_tab == "notifications":
        try:
            notification_users = _fetch_notification_users(c)
        except Exception:
            notification_users = []

        if session_token:
            try:
                sent_res = mobile_backend_bearer_call("/profile/notifications/sent?limit=500", session_token, method="GET")
                if sent_res.get("ok"):
                    data = sent_res.get("data") or {}
                    rows = data.get("items") if isinstance(data, dict) else []
                    sent_notifications = rows if isinstance(rows, list) else []
                else:
                    notifications_err = str(sent_res.get("error") or "Gönderilen bildirimler alınamadı")
            except Exception as e:
                notifications_err = f"Gönderilen bildirimler okunamadı: {e}"
            try:
                popup_res = mobile_backend_bearer_call("/profile/app-popup/admin/current", session_token, method="GET")
                if popup_res.get("ok"):
                    data = popup_res.get("data") or {}
                    popup = data.get("popup") if isinstance(data, dict) else None
                    current_popup = popup if isinstance(popup, dict) else None
                elif not notifications_err:
                    notifications_err = str(popup_res.get("error") or "Açılış popupı alınamadı")
            except Exception as e:
                if not notifications_err:
                    notifications_err = f"Açılış popupı okunamadı: {e}"
        else:
            notifications_err = "Oturum tokenı bulunamadı."

        try:
            backend_items, backend_err = _cached_admin_event_items()
            if backend_err and not notifications_err:
                notifications_err = backend_err
            active_event_items = [
                item
                for item in backend_items
                if (item.get("status") or "").strip().lower() == "approved"
                and bool(item.get("event_is_active", True))
            ]
        except Exception as e:
            if not notifications_err:
                notifications_err = f"Etkinlik hedefleri hazırlanamadı: {e}"

        try:
            news_submissions, news_submissions_err = _cached_admin_news_submissions()
            if news_submissions_err and not notifications_err:
                notifications_err = news_submissions_err
        except Exception as e:
            if not notifications_err:
                notifications_err = f"Haber hedefleri hazırlanamadı: {e}"

        try:
            notification_event_targets = [
                {
                    "value": f"/events/{int(item.get('id') or 0)}",
                    "submission_id": int(item.get("id") or 0),
                    "label": f"{(item.get('event_name') or '-').strip()}  ·  #{int(item.get('id') or 0)}",
                    "auto_title_template": (item.get("auto_notification_title_template") or "").strip(),
                    "auto_body_template": (item.get("auto_notification_body_template") or "").strip(),
                }
                for item in (active_event_items or [])
                if int(item.get("id") or 0) > 0
            ]
        except Exception:
            notification_event_targets = []

        try:
            notification_news_targets = [
                {
                    "value": f"/news/{int(item.get('id') or 0)}",
                    "label": f"{(item.get('title') or '-').strip()}  ·  #{int(item.get('id') or 0)}",
                }
                for item in (news_submissions or [])
                if (item.get("status") or "").strip().lower() == "approved" and int(item.get("id") or 0) > 0
            ]
        except Exception:
            notification_news_targets = []

        if session_token:
            try:
                stores_res = mobile_backend_bearer_call("/store/sellers?limit=300", session_token, method="GET")
                if stores_res.get("ok"):
                    rows = (stores_res.get("data") or {}).get("items") if isinstance(stores_res.get("data"), dict) else []
                    notification_store_targets = [
                        {
                            "value": f"/store/sellers/{int(item.get('account_id') or 0)}",
                            "label": ((item.get("store_title") or item.get("name") or "Mağaza").strip()),
                        }
                        for item in (rows or [])
                        if isinstance(item, dict) and int(item.get("account_id") or 0) > 0
                    ]
                products_res = mobile_backend_bearer_call("/store/products?limit=300", session_token, method="GET")
                if products_res.get("ok"):
                    rows = (products_res.get("data") or {}).get("items") if isinstance(products_res.get("data"), dict) else []
                    notification_product_targets = [
                        {
                            "value": f"/store/products/{int(item.get('id') or 0)}",
                            "label": f"{((item.get('seller') or {}).get('name') or 'Mağaza').strip()}  ·  {(item.get('title') or '-').strip()}",
                        }
                        for item in (rows or [])
                        if isinstance(item, dict) and int(item.get("id") or 0) > 0
                    ]
            except Exception:
                notification_store_targets = notification_store_targets or []
                notification_product_targets = notification_product_targets or []

            try:
                albums_res = mobile_backend_bearer_call("/photos/albums?limit=100", session_token, method="GET")
                if albums_res.get("ok"):
                    rows = (albums_res.get("data") or {}).get("items") if isinstance(albums_res.get("data"), dict) else []
                    notification_album_targets = [
                        {
                            "value": f"/photos/albums/{(item.get('slug') or '').strip()}",
                            "label": ((item.get("name") or item.get("event_name") or item.get("slug") or "Albüm").strip()),
                        }
                        for item in (rows or [])
                        if isinstance(item, dict) and (item.get("slug") or "").strip()
                    ]
                polls_res = mobile_backend_bearer_call("/photos/polls?limit=100", session_token, method="GET")
                if polls_res.get("ok"):
                    rows = (polls_res.get("data") or {}).get("items") if isinstance(polls_res.get("data"), dict) else []
                    notification_poll_targets = [
                        {
                            "value": f"/photos/polls/{int(item.get('id') or 0)}",
                            "label": ((item.get("title") or "Anket").strip()),
                        }
                        for item in (rows or [])
                        if isinstance(item, dict) and int(item.get("id") or 0) > 0
                    ]
            except Exception:
                notification_album_targets = notification_album_targets or []
                notification_poll_targets = notification_poll_targets or []

    elif active_tab == "reports":
        try:
            active_events_count = _fetch_scalar(
                c,
                "SELECT COUNT(*) FROM mobile_event_submissions WHERE COALESCE(status,'')='approved'",
            )
            past_events_count = _fetch_scalar(
                c,
                "SELECT COUNT(*) FROM mobile_event_submissions WHERE COALESCE(status,'')='expired'",
            )
            reports_data = _build_admin_reports(
                conn,
                active_events_count=active_events_count,
                past_events_count=past_events_count,
                message_q=(message_q or "").strip(),
                message_limit=max(20, min(int(message_limit or 100), 200)),
                conversation_a=max(0, int(conversation_a or 0)),
                conversation_b=max(0, int(conversation_b or 0)),
            )
        except Exception as e:
            reports_data = {"errors": [f"Raporlar hazırlanamadı: {e}"]}

    conn.close()
    return render_template(
        request,
        "admin_mobile.html",
        {
            "request": request,
            "users": users,
            "submissions": submissions,
            "submissions_err": submissions_err,
            "request_items": request_items,
            "old_request_items": old_request_items,
            "active_event_items": active_event_items,
            "inactive_event_items": inactive_event_items,
            "old_event_items": old_event_items,
            "news_submissions": news_submissions,
            "news_submissions_err": news_submissions_err,
            "scan_permissions_map": scan_permissions_map,
            "scan_permissions_err": scan_permissions_err,
            "loyalty_reports_map": loyalty_reports_map,
            "loyalty_reports_err": loyalty_reports_err,
            "guest_lists": guest_lists,
            "guest_lists_err": guest_lists_err,
            "selected_guest_list_id": selected_guest_list_id,
            "selected_guest_list_detail": selected_guest_list_detail,
            "guest_list_search_items": guest_list_search_items,
            "guest_list_search_meta": guest_list_search_meta,
            "event_invitees_map": event_invitees_map,
            "event_ticket_controls_map": event_ticket_controls_map,
            "editor_candidates": editor_candidates,
            "woo_product_candidates": woo_product_candidates,
            "woo_products_err": woo_products_err,
            "notification_users": notification_users,
            "notification_event_targets": notification_event_targets,
            "notification_news_targets": notification_news_targets,
            "notification_store_targets": notification_store_targets,
            "notification_product_targets": notification_product_targets,
            "notification_album_targets": notification_album_targets,
            "notification_poll_targets": notification_poll_targets,
            "auto_event_notification_defaults": {
                "title": AUTO_EVENT_NOTIFICATION_DEFAULT_TITLE,
                "body": AUTO_EVENT_NOTIFICATION_DEFAULT_BODY,
            },
            "sent_notifications": sent_notifications,
            "current_popup": current_popup,
            "notifications_err": notifications_err,
            "reports_data": reports_data,
            "active_tab": active_tab,
            "events_view": events_view,
            "event_counts": event_counts,
            "message": msg,
            "error": err,
        },
        csrf=True,
    )


@app.post("/admin/mobile/events/create", include_in_schema=False)
async def admin_mobile_create_event(
    request: Request,
    event_name: str = Form(""),
    description: str = Form(""),
    event_date: str = Form(""),
    venue: str = Form(""),
    venue_map_url: str = Form(""),
    city: str = Form(""),
    event_kind: str = Form("dance_night"),
    ticket_sales_enabled: Optional[str] = Form(None),
    create_photo_album: Optional[str] = Form(None),
    repeat_mode: str = Form("none"),
    repeat_weekly: Optional[str] = Form(None),
    repeat_weekday: str = Form(""),
    repeat_selected_dates: str = Form(""),
    organizer_name: str = Form(""),
    program_text: str = Form(""),
    start_at: str = Form(""),
    end_at: str = Form(""),
    entry_fee: str = Form("0"),
    cover_image: Optional[UploadFile] = File(None),
):
    acc = require_super_admin(request)
    form = await request.form()
    try:
        verify_csrf_token(request, form.get(CSRF_PARAM))
    except HTTPException:
        return _csrf_refresh_redirect("/admin/mobile?tab=events&err=Oturum yenilendi, etkinliği tekrar kaydedin")
    session_token = (request.cookies.get(SESSION_COOKIE) or "").strip()
    if not session_token:
        return RedirectResponse("/admin/mobile?tab=events&err=Oturum tokenı bulunamadı", status_code=303)

    acc_name = ""
    acc_email = ""
    try:
        acc_name = (acc["name"] or "").strip()
    except Exception:
        acc_name = ""
    try:
        acc_email = (acc["email"] or "").strip()
    except Exception:
        acc_email = ""
    ticket_sales_enabled_flag = _boolish(ticket_sales_enabled, default=False)
    create_photo_album_flag = _boolish(create_photo_album, default=False)
    repeat_mode_value = (repeat_mode or "none").strip().lower()
    repeat_weekly_requested = _boolish(repeat_weekly, default=False)

    payload = {
        "submitter_name": (acc_name or acc_email or "super-admin"),
        "submitter_email": acc_email,
        "event_name": (event_name or "").strip(),
        "description": (description or "").strip(),
        "event_date": (event_date or "").strip(),
        "venue": (venue or "").strip(),
        "venue_map_url": (venue_map_url or "").strip(),
        "city": (city or "").strip(),
        "event_kind": (event_kind or "dance_night").strip().lower(),
        "ticket_sales_enabled": "1" if ticket_sales_enabled_flag else "0",
        "create_photo_album": "1" if create_photo_album_flag else "0",
        "repeat_mode": repeat_mode_value,
        "repeat_weekly": "1" if repeat_mode_value == "weekly_fixed" or repeat_weekly_requested else "0",
        "repeat_weekday": (repeat_weekday or "").strip(),
        "repeat_selected_dates": (repeat_selected_dates or "").strip(),
        "organizer_name": (organizer_name or "").strip(),
        "program_text": (program_text or "").strip(),
        "start_at": (start_at or "").strip(),
        "end_at": (end_at or "").strip(),
        "entry_fee": (entry_fee or "0").strip(),
    }
    if cover_image and getattr(cover_image, "filename", ""):
        raw = await cover_image.read()
        files = [
            {
                "field": "cover_image",
                "filename": (cover_image.filename or "event-cover.jpg"),
                "content_type": (cover_image.content_type or "application/octet-stream"),
                "content": raw,
            }
        ]
        res = mobile_backend_bearer_multipart_call("/events/submissions", session_token, fields=payload, files=files)
    else:
        res = mobile_backend_bearer_form_call("/events/submissions", session_token, method="POST", data=payload)
    if not res.get("ok"):
        return RedirectResponse(
            f"/admin/mobile?tab=events&err={urllib.parse.quote('Etkinlik oluşturulamadı: ' + str(res.get('error')))}",
            status_code=303,
        )
    data = res.get("data") or {}
    sid = int((data.get("submission_id") or 0)) if isinstance(data, dict) else 0
    created_count = int((data.get("created_count") or 0)) if isinstance(data, dict) else 0
    if created_count > 1:
        msg = f"{created_count} etkinlik talebi oluşturuldu"
    else:
        msg = f"Etkinlik talebi oluşturuldu (#{sid})" if sid > 0 else "Etkinlik talebi oluşturuldu"
    return RedirectResponse(f"/admin/mobile?tab=events&msg={urllib.parse.quote(msg)}", status_code=303)


@app.post("/admin/mobile/news/create", include_in_schema=False)
async def admin_mobile_create_news(
    request: Request,
    title: str = Form(""),
    body_text: str = Form(""),
    source_link: str = Form(""),
    cover_image: Optional[UploadFile] = File(None),
):
    acc = require_super_admin(request)
    form = await request.form()
    try:
        verify_csrf_token(request, form.get(CSRF_PARAM))
    except HTTPException:
        return _csrf_refresh_redirect("/admin/mobile?tab=news&err=Oturum yenilendi, haberi tekrar kaydedin")
    session_token = (request.cookies.get(SESSION_COOKIE) or "").strip()
    if not session_token:
        return RedirectResponse("/admin/mobile?tab=news&err=Oturum tokenı bulunamadı", status_code=303)

    acc_name = ""
    acc_email = ""
    try:
        acc_name = (acc["name"] or "").strip()
    except Exception:
        acc_name = ""
    try:
        acc_email = (acc["email"] or "").strip()
    except Exception:
        acc_email = ""

    payload = {
        "title": (title or "").strip(),
        "body_text": (body_text or "").strip(),
        "source_link": (source_link or "").strip(),
        "submitter_name": (acc_name or acc_email or "super-admin"),
        "submitter_email": acc_email,
    }
    if cover_image and getattr(cover_image, "filename", ""):
        raw = await cover_image.read()
        files = [
            {
                "field": "cover_image",
                "filename": (cover_image.filename or "news-cover.jpg"),
                "content_type": (cover_image.content_type or "application/octet-stream"),
                "content": raw,
            }
        ]
        res = mobile_backend_bearer_multipart_call("/news/submissions", session_token, fields=payload, files=files)
    else:
        res = mobile_backend_bearer_form_call("/news/submissions", session_token, method="POST", data=payload)
    if not res.get("ok"):
        return RedirectResponse(
            f"/admin/mobile?tab=news&err={urllib.parse.quote('Haber oluşturulamadı: ' + str(res.get('error')))}",
            status_code=303,
        )
    _invalidate_admin_news_cache()
    data = res.get("data") or {}
    sid = int((data.get("submission_id") or 0)) if isinstance(data, dict) else 0
    msg = f"Haber talebi oluşturuldu (#{sid})" if sid > 0 else "Haber talebi oluşturuldu"
    return RedirectResponse(f"/admin/mobile?tab=news&msg={urllib.parse.quote(msg)}", status_code=303)


@app.post("/admin/mobile/notifications/send", include_in_schema=False)
async def admin_mobile_send_notification(
    request: Request,
    title: str = Form(""),
    body: str = Form(""),
    event_submission_id: str = Form(""),
    target_route: str = Form(""),
    send_to_all: Optional[str] = Form(None),
    target_account_ids_csv: str = Form(""),
):
    _ = require_super_admin(request)
    form = await request.form()
    try:
        verify_csrf_token(request, form.get(CSRF_PARAM))
    except HTTPException:
        return _csrf_refresh_redirect("/admin/mobile?tab=notifications&err=Oturum yenilendi, bildirimi tekrar gönderin")

    session_token = (request.cookies.get(SESSION_COOKIE) or "").strip()
    if not session_token:
        return RedirectResponse("/admin/mobile?tab=notifications&err=Oturum bulunamadı", status_code=303)

    title_norm = (title or "").strip()
    body_norm = (body or "").strip()
    if not title_norm or not body_norm:
        return RedirectResponse("/admin/mobile?tab=notifications&err=Başlık ve içerik zorunlu", status_code=303)

    send_all = str(send_to_all or "").strip().lower() in {"1", "true", "on", "yes"}
    event_id = 0
    try:
        event_id = int((event_submission_id or "").strip() or "0")
    except Exception:
        event_id = 0
    if event_id < 0:
        event_id = 0
    route_norm = (target_route or "").strip()
    if route_norm and not route_norm.startswith("/"):
        return RedirectResponse("/admin/mobile?tab=notifications&err=Özel yönlendirme / ile başlamalı", status_code=303)
    target_ids: List[int] = []
    if not send_all:
        raw = [x.strip() for x in (target_account_ids_csv or "").split(",")]
        for x in raw:
            if not x:
                continue
            try:
                v = int(x)
                if v > 0:
                    target_ids.append(v)
            except Exception:
                pass
        target_ids = sorted(set(target_ids))
        if not target_ids:
            return RedirectResponse("/admin/mobile?tab=notifications&err=En az bir alıcı seçin", status_code=303)

    res = mobile_backend_bearer_call(
        "/profile/notifications/send",
        session_token,
        method="POST",
        json_data={
            "title": title_norm[:160],
            "body": body_norm[:2000],
            "event_submission_id": (event_id if event_id > 0 else None),
            "target_route": (route_norm[:200] if event_id <= 0 and route_norm else None),
            "send_to_all": send_all,
            "target_account_ids": target_ids,
        },
    )
    if not res.get("ok"):
        return RedirectResponse(
            f"/admin/mobile?tab=notifications&err={urllib.parse.quote(str(res.get('error') or 'Bildirim gönderilemedi'))}",
            status_code=303,
        )

    data = res.get("data") or {}
    sent_count = int((data.get("sent_count") or 0))
    return RedirectResponse(
        f"/admin/mobile?tab=notifications&msg={urllib.parse.quote(f'Bildirim gönderildi. Alıcı: {sent_count}')}",
        status_code=303,
    )


@app.post("/admin/mobile/notifications/auto-event/save", include_in_schema=False)
async def admin_mobile_save_auto_event_notification_template(
    request: Request,
    event_submission_id: str = Form(""),
    title_template: str = Form(""),
    body_template: str = Form(""),
    apply_all: Optional[str] = Form(None),
):
    _ = require_super_admin(request)
    form = await request.form()
    try:
        verify_csrf_token(request, form.get(CSRF_PARAM))
    except HTTPException:
        return _csrf_refresh_redirect("/admin/mobile?tab=notifications&err=Oturum yenilendi, otomatik bildirim içeriğini tekrar kaydedin")

    apply_all_flag = str(apply_all or "").strip().lower() in {"1", "true", "on", "yes"}
    submission_id = 0
    try:
        submission_id = int((event_submission_id or "").strip() or "0")
    except Exception:
        submission_id = 0

    if not apply_all_flag and submission_id <= 0:
        return RedirectResponse(
            "/admin/mobile?tab=notifications&err=Önce bir etkinlik seçin",
            status_code=303,
        )

    res = mobile_backend_admin_call(
        "/admin/events/auto-notification-template/save",
        method="POST",
        data={
            "submission_id": str(submission_id or ""),
            "title_template": (title_template or "").strip(),
            "body_template": (body_template or "").strip(),
            "apply_all": "1" if apply_all_flag else "",
        },
    )
    if not res.get("ok"):
        return RedirectResponse(
            f"/admin/mobile?tab=notifications&err={urllib.parse.quote(str(res.get('error') or 'İçerik kaydedilemedi'))}",
            status_code=303,
        )

    data = res.get("data") or {}
    updated_count = int((data.get("updated_count") or 0))
    if apply_all_flag:
        msg = f"Otomatik etkinlik bildirimi tüm etkinlikler için güncellendi ({updated_count})"
    else:
        msg = "Otomatik etkinlik bildirimi içeriği güncellendi"
    return RedirectResponse(
        f"/admin/mobile?tab=notifications&msg={urllib.parse.quote(msg)}",
        status_code=303,
    )


@app.post("/admin/mobile/popup/save", include_in_schema=False)
async def admin_mobile_save_popup(
    request: Request,
    title: str = Form(""),
    body: str = Form(""),
    cta_label: str = Form(""),
    cta_target: str = Form(""),
    minimum_app_version: str = Form(""),
    dismissible: Optional[str] = Form(None),
    show_to_guests: Optional[str] = Form(None),
    force_update: Optional[str] = Form(None),
):
    _ = require_super_admin(request)
    form = await request.form()
    try:
        verify_csrf_token(request, form.get(CSRF_PARAM))
    except HTTPException:
        return _csrf_refresh_redirect("/admin/mobile?tab=notifications&err=Oturum yenilendi, popupı tekrar kaydedin")

    session_token = (request.cookies.get(SESSION_COOKIE) or "").strip()
    if not session_token:
        return RedirectResponse("/admin/mobile?tab=notifications&err=Oturum bulunamadı", status_code=303)

    title_norm = (title or "").strip()
    body_norm = (body or "").strip()
    if not title_norm or not body_norm:
        return RedirectResponse("/admin/mobile?tab=notifications&err=Popup başlığı ve içeriği zorunlu", status_code=303)

    res = mobile_backend_bearer_call(
        "/profile/app-popup/admin",
        session_token,
        method="POST",
        json_data={
            "title": title_norm[:160],
            "body": body_norm[:2000],
            "cta_label": (cta_label or "").strip()[:60],
            "cta_target": (cta_target or "").strip()[:500],
            "minimum_app_version": (minimum_app_version or "").strip()[:40],
            "dismissible": str(dismissible or "").strip().lower() in {"1", "true", "on", "yes"},
            "show_to_guests": str(show_to_guests or "").strip().lower() in {"1", "true", "on", "yes"},
            "force_update": str(force_update or "").strip().lower() in {"1", "true", "on", "yes"},
        },
    )
    if not res.get("ok"):
        return RedirectResponse(
            f"/admin/mobile?tab=notifications&err={urllib.parse.quote(str(res.get('error') or 'Popup kaydedilemedi'))}",
            status_code=303,
        )

    return RedirectResponse("/admin/mobile?tab=notifications&msg=Açılış popupı kaydedildi", status_code=303)


@app.post("/admin/mobile/popup/deactivate", include_in_schema=False)
async def admin_mobile_deactivate_popup(request: Request):
    _ = require_super_admin(request)
    form = await request.form()
    try:
        verify_csrf_token(request, form.get(CSRF_PARAM))
    except HTTPException:
        return _csrf_refresh_redirect("/admin/mobile?tab=notifications&err=Oturum yenilendi, popupı tekrar kapatın")

    session_token = (request.cookies.get(SESSION_COOKIE) or "").strip()
    if not session_token:
        return RedirectResponse("/admin/mobile?tab=notifications&err=Oturum bulunamadı", status_code=303)

    res = mobile_backend_bearer_call(
        "/profile/app-popup/admin/current",
        session_token,
        method="DELETE",
    )
    if not res.get("ok"):
        return RedirectResponse(
            f"/admin/mobile?tab=notifications&err={urllib.parse.quote(str(res.get('error') or 'Popup kapatılamadı'))}",
            status_code=303,
        )

    return RedirectResponse("/admin/mobile?tab=notifications&msg=Açılış popupı kapatıldı", status_code=303)



@app.post("/admin/mobile/notifications/delete", include_in_schema=False)
async def admin_mobile_delete_notification_batch(
    request: Request,
    batch_id: str = Form(""),
):
    _ = require_super_admin(request)
    form = await request.form()
    verify_csrf_token(request, form.get(CSRF_PARAM))

    session_token = (request.cookies.get(SESSION_COOKIE) or "").strip()
    if not session_token:
        return RedirectResponse("/admin/mobile?tab=notifications&err=Oturum bulunamadı", status_code=303)

    key = (batch_id or "").strip()
    if not key:
        return RedirectResponse("/admin/mobile?tab=notifications&err=Silinecek kayıt bulunamadı", status_code=303)

    res = mobile_backend_bearer_call(
        f"/profile/notifications/sent/{urllib.parse.quote(key)}",
        session_token,
        method="DELETE",
    )
    if not res.get("ok"):
        return RedirectResponse(
            f"/admin/mobile?tab=notifications&err={urllib.parse.quote(str(res.get('error') or 'Bildirim kaydı silinemedi'))}",
            status_code=303,
        )

    data = res.get("data") or {}
    deleted_count = int((data.get("deleted_count") or 0))
    return RedirectResponse(
        f"/admin/mobile?tab=notifications&msg={urllib.parse.quote(f'Bildirim kaydı silindi ({deleted_count})')}",
        status_code=303,
    )


@app.post("/admin/mobile/notifications/delete-all", include_in_schema=False)
async def admin_mobile_delete_all_notifications(
    request: Request,
):
    _ = require_super_admin(request)
    form = await request.form()
    verify_csrf_token(request, form.get(CSRF_PARAM))

    session_token = (request.cookies.get(SESSION_COOKIE) or "").strip()
    if not session_token:
        return RedirectResponse("/admin/mobile?tab=notifications&err=Oturum bulunamadı", status_code=303)

    res = mobile_backend_bearer_call(
        "/profile/notifications/sent",
        session_token,
        method="DELETE",
    )
    if not res.get("ok"):
        return RedirectResponse(
            f"/admin/mobile?tab=notifications&err={urllib.parse.quote(str(res.get('error') or 'Bildirim geçmişi temizlenemedi'))}",
            status_code=303,
        )

    data = res.get("data") or {}
    deleted_count = int((data.get("deleted_count") or 0))
    return RedirectResponse(
        f"/admin/mobile?tab=notifications&msg={urllib.parse.quote(f'Gönderilen bildirim geçmişi temizlendi ({deleted_count})')}",
        status_code=303,
    )


# =========================
# CUSTOMER: PROFILE + PASSWORD
# =========================

@app.post("/panel/profile/update", include_in_schema=False)
async def panel_profile_update(
    request: Request,
    name: str = Form(...),
    phone: Optional[str] = Form(None),
    avatar: Optional[UploadFile] = File(None),
):
    acc = get_current_account(request)
    if not acc:
        return RedirectResponse("/login?err=Önce giriş yapın", status_code=303)
    if acc["role"] != "customer":
        return RedirectResponse("/panel?err=Yetkisiz", status_code=303)

    form = await request.form()
    verify_csrf_token(request, form.get(CSRF_PARAM))
    name = (name or "").strip()
    phone = (phone or "").strip()
    if len(name) < 2:
        return RedirectResponse("/panel/profile?err=Ad Soyad çok kısa", status_code=303)

    avatar_path = None
    if avatar is not None and getattr(avatar, "filename", ""):
        try:
            avatar_path = await save_avatar_file(avatar)
        except Exception:
            return RedirectResponse("/panel/profile?err=Profil fotoğrafı yüklenemedi", status_code=303)

    conn = db_conn()
    c = conn.cursor()
    if avatar_path:
        c.execute("UPDATE accounts SET name=?, phone=?, avatar_path=? WHERE id=?", (name, phone, avatar_path, acc["id"]))
    else:
        c.execute("UPDATE accounts SET name=?, phone=? WHERE id=?", (name, phone, acc["id"]))
    conn.commit()
    conn.close()

    return RedirectResponse("/panel/profile?msg=Profil güncellendi", status_code=303)


@app.post("/panel/password/change", include_in_schema=False)
async def panel_password_change(
    request: Request,
    current_password: str = Form(...),
    new_password: str = Form(...),
    new_password2: str = Form(...),
):
    acc = get_current_account(request)
    if not acc:
        return RedirectResponse("/login?err=Önce giriş yapın", status_code=303)
    if acc["role"] != "customer":
        return RedirectResponse("/panel?err=Yetkisiz", status_code=303)

    form = await request.form()
    verify_csrf_token(request, form.get(CSRF_PARAM))
    current_password = (current_password or "").strip()
    new_password = (new_password or "").strip()
    new_password2 = (new_password2 or "").strip()

    if len(new_password) < 6:
        return RedirectResponse("/panel/profile?err=Yeni şifre en az 6 karakter olmalı", status_code=303)
    if new_password != new_password2:
        return RedirectResponse("/panel/profile?err=Yeni şifreler eşleşmiyor", status_code=303)

    # DB’den güncel hash çek
    conn = db_conn()
    c = conn.cursor()
    c.execute("SELECT password_hash FROM accounts WHERE id=? LIMIT 1", (acc["id"],))
    row = c.fetchone()
    if not row:
        conn.close()
        return RedirectResponse("/panel/profile?err=Hesap bulunamadı", status_code=303)

    if not verify_password(current_password, row["password_hash"]):
        conn.close()
        return RedirectResponse("/panel/profile?err=Mevcut şifre hatalı", status_code=303)

    c.execute("UPDATE accounts SET password_hash=? WHERE id=?", (hash_password(new_password), acc["id"]))
    conn.commit()
    conn.close()

    return RedirectResponse("/panel/profile?msg=Şifre güncellendi", status_code=303)


# =========================
# CUSTOMER: EVENTS (Panel)
# =========================

def _slug_clean(s: str) -> str:
    s = (s or "").strip().lower()
    s = s.replace(" ", "-")
    allowed = "abcdefghijklmnopqrstuvwxyz0123456789-_"
    s = "".join(ch for ch in s if ch in allowed)
    while "--" in s:
        s = s.replace("--", "-")
    return s


def get_customer_event_or_none(acc: sqlite3.Row, event_id: int):
    conn = db_conn()
    c = conn.cursor()
    c.execute(
        "SELECT * FROM saas_events WHERE id=? AND account_id=? AND COALESCE(album_enabled, TRUE)=TRUE LIMIT 1",
        (event_id, acc["id"]),
    )
    event = c.fetchone()
    conn.close()
    return event


def get_customer_stats(acc_id: int):
    conn = db_conn()
    c = conn.cursor()
    c.execute("SELECT COUNT(*) AS cnt FROM saas_events WHERE account_id=? AND COALESCE(album_enabled, TRUE)=TRUE", (acc_id,))
    total_events = int(c.fetchone()["cnt"])
    c.execute("""
        SELECT COUNT(*) AS cnt
        FROM event_photos ep
        JOIN saas_events se ON se.slug = ep.event_id
        WHERE se.account_id = ?
    """, (acc_id,))
    total_photos = int(c.fetchone()["cnt"])
    c.execute("SELECT photo_credit, name, phone, avatar_path FROM accounts WHERE id=? LIMIT 1", (acc_id,))
    row = c.fetchone()
    conn.close()
    return {
        "total_events": total_events,
        "total_photos": total_photos,
        "photo_credit": int(row["photo_credit"]) if row else 0,
        "profile_name": (row["name"] if row else "") or "",
        "phone": (row["phone"] if row else "") or "",
        "avatar_path": (row["avatar_path"] if row else "") or "",
    }


@app.get("/panel/overview", response_class=HTMLResponse, include_in_schema=False)
def panel_overview(request: Request):
    acc = get_current_account(request)
    if not acc:
        return RedirectResponse("/login?err=Önce giriş yapın", status_code=303)
    if acc["role"] == "super_admin":
        return RedirectResponse("/admin/users", status_code=303)

    stats = get_customer_stats(acc["id"])
    return render_template(request, "panel_overview.html", {
        "request": request,
        "user_email": acc["email"],
        "photo_credit": stats["photo_credit"],
        "total_events": stats["total_events"],
        "total_photos": stats["total_photos"],
        "avatar_path": stats["avatar_path"],
    }, csrf=True)


@app.get("/panel/credits", response_class=HTMLResponse, include_in_schema=False)
def panel_credits(request: Request):
    acc = get_current_account(request)
    if not acc:
        return RedirectResponse("/login?err=Önce giriş yapın", status_code=303)
    if acc["role"] == "super_admin":
        return RedirectResponse("/admin/users", status_code=303)

    stats = get_customer_stats(acc["id"])
    return render_template(request, "panel_credits.html", {
        "request": request,
        "user_email": acc["email"],
        "photo_credit": stats["photo_credit"],
        "avatar_path": stats["avatar_path"],
    }, csrf=True)


@app.get("/panel/history", response_class=HTMLResponse, include_in_schema=False)
def panel_history(request: Request):
    acc = get_current_account(request)
    if not acc:
        return RedirectResponse("/login?err=Önce giriş yapın", status_code=303)
    if acc["role"] == "super_admin":
        return RedirectResponse("/admin/users", status_code=303)

    conn = db_conn()
    c = conn.cursor()
    c.execute("""
        SELECT id, action, status, uploaded_count, created_at, finished_at, message
        FROM jobs
        WHERE account_id=?
        ORDER BY id DESC
        LIMIT 200
    """, (acc["id"],))
    rows = c.fetchall()
    conn.close()

    stats = get_customer_stats(acc["id"])
    return render_template(request, "panel_history.html", {
        "request": request,
        "user_email": acc["email"],
        "jobs": rows,
        "photo_credit": stats["photo_credit"],
        "avatar_path": stats["avatar_path"],
    }, csrf=True)


@app.get("/panel/profile", response_class=HTMLResponse, include_in_schema=False)
def panel_profile(request: Request, msg: Optional[str] = None, err: Optional[str] = None):
    acc = get_current_account(request)
    if not acc:
        return RedirectResponse("/login?err=Önce giriş yapın", status_code=303)
    if acc["role"] == "super_admin":
        return RedirectResponse("/admin/users", status_code=303)

    stats = get_customer_stats(acc["id"])
    return render_template(request, "panel_profile.html", {
        "request": request,
        "user_email": acc["email"],
        "profile_name": stats["profile_name"],
        "phone": stats["phone"],
        "avatar_path": stats["avatar_path"],
        "photo_credit": stats["photo_credit"],
        "message": msg,
        "error": err,
    }, csrf=True)


@app.get("/panel/events", response_class=HTMLResponse, include_in_schema=False)
def panel_events(request: Request, msg: Optional[str] = None, err: Optional[str] = None):
    acc = get_current_account(request)
    if not acc:
        return RedirectResponse("/login?err=Önce giriş yapın", status_code=303)

    if acc["role"] == "super_admin":
        return RedirectResponse("/admin/users", status_code=303)

    conn = db_conn()
    c = conn.cursor()
    c.execute(
        "SELECT * FROM saas_events WHERE account_id=? AND COALESCE(album_enabled, TRUE)=TRUE ORDER BY id DESC",
        (acc["id"],),
    )
    events = c.fetchall()

    conn.close()

    stats = get_customer_stats(acc["id"])
    active_events_count = 0
    inactive_events_count = 0
    for event in events or []:
        is_active = event.get("is_active") if isinstance(event, dict) else event["is_active"]
        if bool(is_active):
            active_events_count += 1
        else:
            inactive_events_count += 1

    return render_template(request, "panel_events.html", {
        "request": request,
        "user_email": acc["email"],
        "events": events,
        "message": msg,
        "error": err,
        "photo_credit": stats["photo_credit"],
        "profile_name": stats["profile_name"],
        "avatar_path": stats["avatar_path"],
        # bu alanlar template’te kullanırsan:
        "profile_message": msg if msg and "Profil" in msg else None,
        "profile_error": err if err and "Profil" in err else None,
        "password_message": msg if msg and "Şifre" in msg else None,
        "password_error": err if err and "şifre" in err.lower() else None,
        "total_events": stats["total_events"],
        "total_photos": stats["total_photos"],
        "active_events_count": active_events_count,
        "inactive_events_count": inactive_events_count,
    }, csrf=True)


@app.post("/panel/events/create", include_in_schema=False)
async def panel_create_event(request: Request, name: str = Form(...), slug: str = Form(...)):
    acc = get_current_account(request)
    if not acc:
        return RedirectResponse("/login?err=Önce giriş yapın", status_code=303)
    if acc["role"] != "customer":
        return RedirectResponse("/panel?err=Bu işlem sadece müşteri içindir", status_code=303)

    form = await request.form()
    verify_csrf_token(request, form.get(CSRF_PARAM))
    name = (name or "").strip()
    slug = _slug_clean(slug)

    if len(name) < 2:
        return RedirectResponse("/panel/events?err=Etkinlik adı çok kısa", status_code=303)
    if len(slug) < 3:
        return RedirectResponse("/panel/events?err=Slug çok kısa", status_code=303)

    conn = db_conn()
    c = conn.cursor()

    c.execute("SELECT id FROM saas_events WHERE slug=? LIMIT 1", (slug,))
    if c.fetchone():
        conn.close()
        return RedirectResponse("/panel/events?err=Bu slug zaten kullanılıyor", status_code=303)

    c.execute(
        "INSERT INTO saas_events (account_id,name,slug,is_active,created_at) VALUES (?,?,?,?,?)",
        (acc["id"], name, slug, 1, iso_now())
    )
    conn.commit()
    conn.close()

    return RedirectResponse("/panel/events?msg=Etkinlik oluşturuldu", status_code=303)


def list_event_photos_for_slug_with_match_counts(
    slug: str,
    limit: int = 25,
    offset: int = 0,
) -> Dict[str, Any]:
    conn = db_conn()
    c = conn.cursor()
    c.execute("SELECT COUNT(*) AS cnt FROM event_photos WHERE event_id=?", (slug,))
    total = int(c.fetchone()["cnt"])
    c.execute(
        """
        SELECT
            ep.id,
            ep.file_path,
            ep.created_at,
            0 AS match_count
        FROM event_photos ep
        WHERE ep.event_id=?
        ORDER BY ep.id DESC
        LIMIT ?
        OFFSET ?
        """,
        (slug, int(limit), int(offset)),
    )
    rows = c.fetchall()
    conn.close()

    out = []
    for r in rows:
        file_path = (r["file_path"] or "").replace("\\", "/").lstrip("/")
        abs_path = os.path.join(ROOT_DIR, file_path) if file_path and not os.path.isabs(file_path) else file_path
        size = 0
        filename = os.path.basename(file_path) if file_path else "-"
        try:
            if abs_path and os.path.exists(abs_path):
                size = os.path.getsize(abs_path)
        except Exception:
            size = 0

        clean = file_path
        if clean.startswith("media/"):
            clean = clean[len("media/"):]
        url = "/media/" + clean if clean else ""

        out.append({
            "id": r["id"],
            "file_path": file_path,
            "created_at": r["created_at"],
            "filename": filename,
            "size_bytes": size,
            "size_human": human_size(size),
            "url": url,
            "match_count": int(r["match_count"] or 0),
        })
    return {"items": out, "total": total}


def list_jobs_for_event(slug: str):
    conn = db_conn()
    c = conn.cursor()
    c.execute(
        """
        SELECT j.id, j.pid, j.action, j.uploaded_count, j.processed_count, j.match_count, j.status, j.message, j.created_at, j.finished_at,
               COALESCE(j.subalbum_id,0) AS subalbum_id,
               COALESCE(sa.name,'') AS subalbum_name
        FROM jobs j
        LEFT JOIN event_subalbums sa ON sa.id = j.subalbum_id
        WHERE j.event_slug=?
          AND j.action IN ('upload_only', 'console_upload_only')
        ORDER BY j.id DESC
        LIMIT 200
        """,
        (slug,),
    )
    rows = c.fetchall()
    conn.close()
    return rows


def list_jobs_for_slug(slug: str, limit: int = 200):
    conn = db_conn()
    c = conn.cursor()
    c.execute("""
        SELECT j.id, j.pid, j.action, j.uploaded_count, j.processed_count, j.match_count, j.status, j.message, j.created_at, j.finished_at,
               COALESCE(j.subalbum_id,0) AS subalbum_id,
               COALESCE(sa.name,'') AS subalbum_name
        FROM jobs j
        LEFT JOIN event_subalbums sa ON sa.id = j.subalbum_id
        WHERE j.event_slug=?
        ORDER BY j.id DESC
        LIMIT ?
    """, (slug, int(limit)))
    rows = c.fetchall()
    conn.close()
    return rows


def list_upload_batches_for_event(slug: str, limit: int = 200) -> List[Dict[str, Any]]:
    conn = db_conn()
    c = conn.cursor()
    c.execute(
        """
        SELECT
            j.id, j.pid, j.uploaded_count, j.status, j.created_at, j.finished_at, j.message,
            COALESCE(match_start,0) AS match_start,
            COALESCE(match_end,0) AS match_end,
            COALESCE(j.subalbum_id,0) AS subalbum_id,
            COALESCE(sa.name,'') AS subalbum_name
        FROM jobs j
        LEFT JOIN event_subalbums sa ON sa.id = j.subalbum_id
        WHERE j.event_slug=?
          AND j.action IN ('upload_only', 'console_upload_only')
        ORDER BY j.id DESC
        LIMIT ?
        """,
        (slug, int(limit)),
    )
    rows = c.fetchall() or []
    out: List[Dict[str, Any]] = []
    for r in rows:
        job_id = int(r["id"])
        match_start = int(r["match_start"] or 0)
        match_end = int(r["match_end"] or 0)
        photo_count = max(0, match_end - match_start) if (match_end > match_start) else int(r["uploaded_count"] or 0)
        total_size = 0
        if match_end > match_start:
            c.execute(
                """
                SELECT COALESCE(SUM(COALESCE(file_size_bytes,0)),0) AS total_size
                FROM event_photos
                WHERE event_id=? AND id>? AND id<=?
                """,
                (slug, match_start, match_end),
            )
            rr = c.fetchone()
            total_size = int((rr["total_size"] if rr and "total_size" in rr.keys() else 0) or 0)
        out.append(
            {
                "job_id": job_id,
                "pid": (r["pid"] or "").strip(),
                "status": (r["status"] or "").strip(),
                "created_at": r["created_at"],
                "finished_at": r["finished_at"],
                "message": (r["message"] or "").strip(),
                "photo_count": photo_count,
                "total_size_bytes": total_size,
                "total_size_human": human_size(total_size),
                "match_start": match_start,
                "match_end": match_end,
                "subalbum_id": int(r["subalbum_id"] or 0) if "subalbum_id" in r.keys() else 0,
                "subalbum_name": (r["subalbum_name"] or "").strip() if "subalbum_name" in r.keys() else "",
            }
        )
    conn.close()
    return out


def list_event_subalbums(slug: str) -> List[Dict[str, Any]]:
    conn = db_conn()
    c = conn.cursor()
    c.execute(
        """
        SELECT id, name, sort_order, created_at
        FROM event_subalbums
        WHERE event_slug=? AND COALESCE(is_active,1)=1
        ORDER BY sort_order ASC, id ASC
        """,
        (slug,),
    )
    rows = c.fetchall() or []
    conn.close()
    return [
        {
            "id": int(r["id"]),
            "name": (r["name"] or "").strip(),
            "sort_order": int(r["sort_order"] or 0),
            "created_at": r["created_at"],
        }
        for r in rows
        if (r["name"] or "").strip()
    ]


def create_event_subalbum(slug: str, name: str, created_by_account_id: Optional[int]) -> Dict[str, Any]:
    clean = " ".join((name or "").strip().split())
    if not clean:
        return {"ok": False, "error": "Alt albüm adı boş olamaz"}
    conn = db_conn()
    c = conn.cursor()
    try:
        if USE_POSTGRES:
            c.execute(
                """
                SELECT id
                FROM event_subalbums
                WHERE event_slug=? AND LOWER(name)=LOWER(?) AND COALESCE(is_active,1)=1
                LIMIT 1
                """,
                (slug, clean),
            )
        else:
            c.execute(
                """
                SELECT id
                FROM event_subalbums
                WHERE event_slug=? AND name=? AND COALESCE(is_active,1)=1
                LIMIT 1
                """,
                (slug, clean),
            )
        row = c.fetchone()
        if row:
            return {"ok": True, "id": int(row["id"]), "name": clean, "existing": True}
        c.execute(
            """
            INSERT INTO event_subalbums (event_slug, name, created_by_account_id, created_at)
            VALUES (?, ?, ?, ?)
            RETURNING id
            """,
            (slug, clean, int(created_by_account_id) if created_by_account_id else None, iso_now()),
        )
        new_id = int(c.fetchone()[0])
        conn.commit()
        return {"ok": True, "id": new_id, "name": clean, "existing": False}
    except Exception as e:
        conn.rollback()
        return {"ok": False, "error": f"Alt albüm oluşturulamadı: {e}"}
    finally:
        conn.close()


def set_job_subalbum(event_slug: str, job_id: int, subalbum_id: Optional[int]) -> Dict[str, Any]:
    conn = db_conn()
    c = conn.cursor()
    try:
        c.execute(
            """
            SELECT id
            FROM jobs
            WHERE id=? AND event_slug=? AND action IN ('upload_only', 'console_upload_only')
            LIMIT 1
            """,
            (int(job_id), event_slug),
        )
        job = c.fetchone()
        if not job:
            return {"ok": False, "error": "Yükleme paketi bulunamadı"}
        target_subalbum_id = int(subalbum_id) if subalbum_id else None
        if target_subalbum_id:
            c.execute(
                """
                SELECT id, name
                FROM event_subalbums
                WHERE id=? AND event_slug=? AND COALESCE(is_active,1)=1
                LIMIT 1
                """,
                (target_subalbum_id, event_slug),
            )
            subalbum = c.fetchone()
            if not subalbum:
                return {"ok": False, "error": "Seçilen alt albüm bulunamadı"}
            subalbum_name = (subalbum["name"] or "").strip()
        else:
            subalbum_name = ""
        c.execute(
            "UPDATE jobs SET subalbum_id=? WHERE id=? AND event_slug=?",
            (target_subalbum_id, int(job_id), event_slug),
        )
        conn.commit()
        return {"ok": True, "subalbum_name": subalbum_name}
    except Exception as e:
        conn.rollback()
        return {"ok": False, "error": f"Alt albüm güncellenemedi: {e}"}
    finally:
        conn.close()


def list_photos_for_upload_batch(
    slug: str,
    job_id: int,
    limit: int = 40,
    offset: int = 0,
) -> Dict[str, Any]:
    conn = db_conn()
    c = conn.cursor()
    c.execute(
        """
        SELECT COALESCE(match_start,0) AS match_start, COALESCE(match_end,0) AS match_end
        FROM jobs
        WHERE id=? AND event_slug=? AND action IN ('upload_only', 'console_upload_only')
        LIMIT 1
        """,
        (int(job_id), slug),
    )
    job = c.fetchone()
    if not job:
        conn.close()
        return {"items": [], "total": 0, "found": False}
    match_start = int(job["match_start"] or 0)
    match_end = int(job["match_end"] or 0)
    if match_end <= match_start:
        conn.close()
        return {"items": [], "total": 0, "found": True}

    c.execute(
        "SELECT COUNT(*) AS cnt FROM event_photos WHERE event_id=? AND id>? AND id<=?",
        (slug, match_start, match_end),
    )
    total = int(c.fetchone()["cnt"])
    c.execute(
        """
        SELECT id, file_path, created_at, COALESCE(file_size_bytes,0) AS file_size_bytes
        FROM event_photos
        WHERE event_id=? AND id>? AND id<=?
        ORDER BY id DESC
        LIMIT ?
        OFFSET ?
        """,
        (slug, match_start, match_end, int(limit), int(offset)),
    )
    rows = c.fetchall() or []
    conn.close()

    items: List[Dict[str, Any]] = []
    for r in rows:
        file_path = (r["file_path"] or "").replace("\\", "/").lstrip("/")
        clean = file_path[6:] if file_path.startswith("media/") else file_path
        url = "/media/" + clean if clean else ""
        size = int(r["file_size_bytes"] or 0)
        items.append(
            {
                "id": int(r["id"]),
                "file_path": file_path,
                "created_at": r["created_at"],
                "filename": os.path.basename(file_path) if file_path else "-",
                "size_bytes": size,
                "size_human": human_size(size),
                "url": url,
            }
        )
    return {"items": items, "total": total, "found": True, "match_start": match_start, "match_end": match_end}


def create_job(
    acc_id: int,
    slug: str,
    action: str,
    uploaded_count: int,
    subalbum_id: int = None,
    target_user_id: int = None,
    status: str = "queued",
    pid: str = None,
    match_start: int = None,
    match_cursor: int = None,
    match_end: int = None,
) -> int:
    conn = db_conn()
    c = conn.cursor()
    if USE_POSTGRES:
        c.execute("""
            INSERT INTO jobs (
                account_id, event_slug, action, uploaded_count, status, message, created_at, finished_at,
                target_user_id, pid, match_start, match_cursor, match_end, subalbum_id
            )
            VALUES (?, ?, ?, ?, ?, NULL, ?, NULL, ?, ?, ?, ?, ?, ?)
            RETURNING id
        """, (
            acc_id,
            slug,
            action,
            int(uploaded_count),
            status,
            iso_now(),
            target_user_id,
            pid,
            match_start,
            match_cursor,
            match_end,
            int(subalbum_id) if subalbum_id else None,
        ))
        job_id = int(c.fetchone()[0])
    else:
        c.execute("""
            INSERT INTO jobs (
                account_id, event_slug, action, uploaded_count, status, message, created_at, finished_at,
                target_user_id, pid, match_start, match_cursor, match_end, subalbum_id
            )
            VALUES (?, ?, ?, ?, ?, NULL, ?, NULL, ?, ?, ?, ?, ?, ?)
        """, (
            acc_id,
            slug,
            action,
            int(uploaded_count),
            status,
            iso_now(),
            target_user_id,
            pid,
            match_start,
            match_cursor,
            match_end,
            int(subalbum_id) if subalbum_id else None,
        ))
        job_id = int(c.lastrowid)
    conn.commit()
    conn.close()
    return job_id


def finish_job(job_id: int, status: str, message: str):
    conn = db_conn()
    c = conn.cursor()
    c.execute("""
        UPDATE jobs
        SET status=?, message=?, finished_at=?
        WHERE id=?
    """, (status, (message or "")[:5000], iso_now(), int(job_id)))
    conn.commit()
    conn.close()


def update_job_match_range(job_id: int, match_start: int, match_end: int, status: str = None, message: str = None):
    conn = db_conn()
    c = conn.cursor()
    c.execute("""
        UPDATE jobs
        SET match_start=?, match_cursor=?, match_end=?,
            status=COALESCE(?, status),
            message=COALESCE(?, message),
            finished_at=CASE WHEN COALESCE(?, status)='queued' THEN NULL ELSE finished_at END
        WHERE id=?
    """, (
        int(match_start or 0),
        int(match_start or 0),
        int(match_end or 0),
        status,
        message,
        status,
        int(job_id),
    ))
    conn.commit()
    conn.close()


def get_event_photos_max_id(slug: str) -> int:
    conn = db_conn()
    c = conn.cursor()
    c.execute("SELECT COALESCE(MAX(id), 0) AS mx FROM event_photos WHERE event_id=?", (slug,))
    mx = int(c.fetchone()["mx"] or 0)
    conn.close()
    return mx


def generate_pid(length: int = 8) -> str:
    alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
    return "".join(secrets.choice(alphabet) for _ in range(int(length)))


def decrement_credit(acc_id: int, count: int) -> bool:
    conn = db_conn()
    c = conn.cursor()
    c.execute("SELECT photo_credit FROM accounts WHERE id=? LIMIT 1", (acc_id,))
    row = c.fetchone()
    if not row:
        conn.close()
        return False

    credit = int(row["photo_credit"])
    if credit < int(count):
        conn.close()
        return False

    c.execute("UPDATE accounts SET photo_credit=? WHERE id=?", (credit - int(count), acc_id))
    conn.commit()
    conn.close()
    return True


def refund_credit(acc_id: int, count: int):
    try:
        conn = db_conn()
        c = conn.cursor()
        c.execute("UPDATE accounts SET photo_credit = photo_credit + ? WHERE id=?", (int(count), int(acc_id)))
        conn.commit()
        conn.close()
    except Exception:
        pass


def spawn_match_worker(job_id: int, slug: str):
    finish_job(job_id, "done", "Yuz tanima/eslestirme devre disi.")


def _normalize_panel_event_tab(value: Optional[str]) -> str:
    allowed = {"media", "uploads", "users", "mail", "reports", "sales"}
    current = (value or "media").strip().lower()
    if current not in allowed:
        return "media"
    return current


def _claim_next_job() -> Optional[Dict[str, Any]]:
    """
    Tek scheduler mantigini DB seviyesinde garanti eder.
    Birden fazla uvicorn olsa bile ayni anda tek claim islemi calisir.
    """
    if not FACE_MATCHING_ENABLED:
        return None

    lock_key = 914207
    conn = db_conn()
    c = conn.cursor()
    locked = False
    try:
        if USE_POSTGRES:
            c.execute("SELECT pg_try_advisory_lock(?) AS ok", (int(lock_key),))
            lrow = c.fetchone()
            locked = bool(lrow[0] if lrow is not None else False)
            if not locked:
                conn.close()
                return None

        recovered = _recover_stale_running_jobs(c)
        if recovered:
            conn.commit()
            log(f"[JOBRUNNER] stale running job recovered: {recovered}")

        c.execute(
            "SELECT COUNT(*) AS cnt FROM jobs WHERE status='running' AND action IN ({})".format(
                ",".join(["?"] * len(MATCH_ACTIONS))
            ),
            tuple(MATCH_ACTIONS),
        )
        running = int(c.fetchone()["cnt"])
        if running >= MAX_CONCURRENT_MATCH:
            conn.close()
            return None

        c.execute(
            "SELECT id, event_slug FROM jobs WHERE status='queued' AND action IN ({}) ORDER BY id ASC LIMIT 1".format(
                ",".join(["?"] * len(MATCH_ACTIONS))
            ),
            tuple(MATCH_ACTIONS),
        )
        row = c.fetchone()
        if not row:
            conn.close()
            return None

        c.execute(
            "UPDATE jobs SET status='running', heartbeat_at=? WHERE id=? AND status='queued'",
            (iso_now(), int(row["id"])),
        )
        changed = int(c.rowcount or 0)
        conn.commit()
        if changed == 1:
            return {"id": int(row["id"]), "event_slug": row["event_slug"]}
        return None
    finally:
        try:
            if USE_POSTGRES and locked:
                c.execute("SELECT pg_advisory_unlock(?)", (int(lock_key),))
                conn.commit()
        except Exception:
            pass
        try:
            conn.close()
        except Exception:
            pass


def start_job_runner():
    def _loop():
        while True:
            try:
                row = _claim_next_job()
                if row:
                    spawn_match_worker(int(row["id"]), row["event_slug"])
            except Exception as e:
                log(f"[JOBRUNNER] hata: {e}")
            time.sleep(JOB_RUNNER_INTERVAL)

    t = threading.Thread(target=_loop, daemon=True)
    t.start()


@app.get("/panel/events/{event_id}", response_class=HTMLResponse, include_in_schema=False)
def panel_event_detail(
    request: Request,
    event_id: int,
    msg: Optional[str] = None,
    err: Optional[str] = None,
    tab: Optional[str] = None,
    mail_filter: Optional[str] = None,
    mail_page: Optional[int] = None,
    page: Optional[int] = None,
):
    acc = get_current_account(request)
    if not acc:
        return RedirectResponse("/login?err=Önce giriş yapın", status_code=303)
    if acc["role"] != "customer":
        return RedirectResponse("/admin/users", status_code=303)

    event = get_customer_event_or_none(acc, event_id)
    if not event:
        return RedirectResponse("/panel/events?err=Etkinlik bulunamadı", status_code=303)

    current_tab = _normalize_panel_event_tab(tab)
    slug = event["slug"]
    frame_paths = {
        "ratio_1_1": "",
        "ratio_3_2": "",
        "ratio_2_3": "",
        "ratio_3_4": "",
        "ratio_4_3": "",
        "landscape": "",
        "portrait": "",
        "square": "",
    }

    page_num = int(page or 1)
    if page_num < 1:
        page_num = 1
    per_page = 25
    photos: List[Dict[str, Any]] = []
    total_photos_all = 0
    jobs = []
    mail_page_num = int(mail_page or 1)
    if mail_page_num < 1:
        mail_page_num = 1
    mail_per_page = 25
    mail_logs = []
    mail_total = 0
    mail_total_pages = 0

    conn = db_conn()
    c = conn.cursor()

    c.execute("SELECT photo_credit, avatar_path FROM accounts WHERE id=?", (acc["id"],))
    r = c.fetchone()
    photo_credit = int(r["photo_credit"]) if r else 0
    avatar_path = (r["avatar_path"] if r else "") or ""

    event_match_total = 0
    rows = []
    conn.close()

    attendees = []
    for row in rows:
        token = row["gallery_token"]
        attendees.append({
            "id": row["id"],
            "name": row["name"],
            "email": row["email"],
            "selfie_path": row["selfie_path"],
            "created_at": row["created_at"],
            "gallery_token": token,
            "gallery_url": f"{BASE_GALLERY_URL}{token}" if token else "",
            "match_count": int(row["match_count"] or 0),
        })

    if current_tab == "media":
        frame_paths = get_event_account_frames(slug, int(acc["id"]))
        photos_page = list_event_photos_for_slug_with_match_counts(slug, limit=per_page, offset=(page_num - 1) * per_page)
        photos = photos_page["items"]
        total_photos_all = photos_page["total"]
        subalbums = list_event_subalbums(slug)
    elif current_tab == "uploads":
        jobs = list_jobs_for_event(slug)
        subalbums = list_event_subalbums(slug)
    elif current_tab == "mail":
        mail_logs, mail_total = list_mail_logs(
            slug,
            limit=mail_per_page,
            offset=(mail_page_num - 1) * mail_per_page,
            status=mail_filter,
            with_total=True,
        )
        mail_total_pages = (mail_total // mail_per_page) + (1 if (mail_total % mail_per_page) > 0 else 0)
    elif current_tab == "reports":
        conn = db_conn()
        c = conn.cursor()
        c.execute("SELECT COUNT(*) AS cnt FROM event_photos WHERE event_id=?", (slug,))
        row = c.fetchone()
        total_photos_all = int((row["cnt"] if row and "cnt" in row.keys() else 0) or 0)
        conn.close()
        event_match_total = 0
    else:
        subalbums = []

    if current_tab not in {"media", "uploads"}:
        subalbums = []

    qr_target = f"{PUBLIC_BASE_URL}/e/{slug}"
    qr_img = f"/qr/{slug}.png"
    qr_scans = count_qr_scans(slug) if current_tab == "reports" else 0
    download_count = count_photo_downloads(slug) if current_tab == "reports" else 0
    total_users = 0
    total_photos = total_photos_all

    return render_template(request, "panel_event_detail.html", {
        "request": request,
        "active": "events",
        "header": "Etkinlik Düzenle",
        "user_email": acc["email"],
        "event": event,
        "tab": current_tab,
        "message": msg,
        "error": err,
        "photos": photos,
        "page": page_num,
        "per_page": per_page,
        "total_photos_all": total_photos_all,
        "jobs": jobs,
        "photo_credit": photo_credit,
        "avatar_path": avatar_path,
        "attendees": attendees,
        "subalbums": subalbums,
        "qr_target": qr_target,
        "qr_img": qr_img,
        "event_match_total": event_match_total,
        "mail_logs": mail_logs,
        "mail_filter": mail_filter or "",
        "mail_page": mail_page_num,
        "mail_total_pages": mail_total_pages,
        "mail_total": mail_total,
        "report_total_users": total_users,
        "report_total_photos": total_photos,
        "report_total_matches": event_match_total,
        "report_qr_scans": qr_scans,
        "report_downloads": download_count,
        "frame_ratio_1_1": frame_paths["ratio_1_1"],
        "frame_ratio_3_2": frame_paths["ratio_3_2"],
        "frame_ratio_2_3": frame_paths["ratio_2_3"],
        "frame_ratio_3_4": frame_paths["ratio_3_4"],
        "frame_ratio_4_3": frame_paths["ratio_4_3"],
        "frame_landscape": frame_paths["landscape"],
        "frame_portrait": frame_paths["portrait"],
        "frame_square": frame_paths["square"],
        "upload_batch_max_files": int(UPLOAD_BATCH_MAX_FILES),
    }, csrf=True)


@app.post("/panel/events/{event_id}/subalbums/create", include_in_schema=False)
async def panel_event_subalbum_create(request: Request, event_id: int):
    acc = get_current_account(request)
    if not acc:
        return RedirectResponse("/login?err=Önce giriş yapın", status_code=303)
    if acc["role"] != "customer":
        return RedirectResponse("/admin/users", status_code=303)
    event = get_customer_event_or_none(acc, event_id)
    if not event:
        return RedirectResponse("/panel/events?err=Etkinlik bulunamadı", status_code=303)
    form = await request.form()
    verify_csrf_token(request, form.get(CSRF_PARAM))
    res = create_event_subalbum(event["slug"], form.get("subalbum_name") or "", int(acc["id"]))
    if not res.get("ok"):
        return RedirectResponse(f"/panel/events/{event_id}?err={urllib.parse.quote(str(res.get('error') or 'Alt albüm oluşturulamadı'))}", status_code=303)
    msg = "Alt albüm oluşturuldu" if not res.get("existing") else "Alt albüm zaten vardı"
    return RedirectResponse(f"/panel/events/{event_id}?msg={urllib.parse.quote(msg)}", status_code=303)


@app.post("/panel/events/{event_id}/jobs/{job_id}/subalbum", include_in_schema=False)
async def panel_event_job_subalbum_update(request: Request, event_id: int, job_id: int):
    acc = get_current_account(request)
    if not acc:
        return RedirectResponse("/login?err=Önce giriş yapın", status_code=303)
    if acc["role"] != "customer":
        return RedirectResponse("/admin/users", status_code=303)
    event = get_customer_event_or_none(acc, event_id)
    if not event:
        return RedirectResponse("/panel/events?err=Etkinlik bulunamadı", status_code=303)
    form = await request.form()
    verify_csrf_token(request, form.get(CSRF_PARAM))
    subalbum_id_raw = (form.get("subalbum_id") or "").strip()
    subalbum_id = int(subalbum_id_raw) if subalbum_id_raw.isdigit() and int(subalbum_id_raw) > 0 else None
    res = set_job_subalbum(event["slug"], int(job_id), subalbum_id)
    if not res.get("ok"):
        return RedirectResponse(f"/panel/events/{event_id}?tab=uploads&err={urllib.parse.quote(str(res.get('error') or 'Alt albüm güncellenemedi'))}", status_code=303)
    msg = "Paket ana albüme taşındı" if not subalbum_id else "Paket alt albüme bağlandı"
    return RedirectResponse(f"/panel/events/{event_id}?tab=uploads&msg={urllib.parse.quote(msg)}", status_code=303)


@app.post("/panel/events/{event_id}/rename", include_in_schema=False)
async def panel_event_rename(request: Request, event_id: int):
    acc = get_current_account(request)
    if not acc:
        return RedirectResponse("/login?err=Önce giriş yapın", status_code=303)
    if acc["role"] != "customer":
        return RedirectResponse("/admin/users", status_code=303)

    form = await request.form()
    verify_csrf_token(request, form.get(CSRF_PARAM))
    name = (form.get("name") or "").strip()
    if not name:
        return RedirectResponse(f"/panel/events/{event_id}?err=Etkinlik adı boş olamaz", status_code=303)

    event = get_customer_event_or_none(acc, event_id)
    if not event:
        return RedirectResponse("/panel/events?err=Etkinlik bulunamadı", status_code=303)

    conn = db_conn()
    c = conn.cursor()
    c.execute(
        "UPDATE saas_events SET name=? WHERE id=? AND account_id=?",
        (name, event_id, acc["id"]),
    )
    conn.commit()
    conn.close()
    return RedirectResponse(f"/panel/events/{event_id}?msg=Etkinlik adı güncellendi", status_code=303)


@app.post("/panel/events/{event_id}/delete", include_in_schema=False)
async def panel_delete_event(request: Request, event_id: int):
    acc = get_current_account(request)
    if not acc:
        return RedirectResponse("/login?err=Önce giriş yapın", status_code=303)
    if acc["role"] != "customer":
        return RedirectResponse("/admin/users", status_code=303)

    form = await request.form()
    verify_csrf_token(request, form.get(CSRF_PARAM))

    event = get_customer_event_or_none(acc, event_id)
    if not event:
        return RedirectResponse("/panel/events?err=Etkinlik bulunamadı", status_code=303)
    slug = event["slug"]
    ext_source = (event["external_source"] or "").strip().lower() if "external_source" in event.keys() else ""
    ext_event_id = (event["external_event_id"] or "").strip() if "external_event_id" in event.keys() else ""

    last_err = None
    selfie_paths = []
    photo_paths = []
    for _ in range(6):
        try:
            conn = db_conn()
            c = conn.cursor()
            if not USE_POSTGRES:
                c.execute("BEGIN IMMEDIATE")

            c.execute("SELECT selfie_path FROM users WHERE event_id=?", (slug,))
            selfie_paths = [r[0] for r in c.fetchall() if r and r[0]]

            c.execute("SELECT file_path FROM event_photos WHERE event_id=?", (slug,))
            photo_paths = [r[0] for r in c.fetchall() if r and r[0]]

            c.execute("DELETE FROM photo_matches WHERE event_id=?", (slug,))
            c.execute("DELETE FROM event_photos WHERE event_id=?", (slug,))
            c.execute("DELETE FROM users WHERE event_id=?", (slug,))
            c.execute("DELETE FROM events WHERE slug=?", (slug,))
            c.execute("DELETE FROM saas_events WHERE slug=? AND account_id=?", (slug, int(acc["id"])))
            c.execute("DELETE FROM event_submissions WHERE approved_event_slug=?", (slug,))
            c.execute("DELETE FROM mobile_event_submissions WHERE approved_event_slug=?", (slug,))
            c.execute("DELETE FROM jobs WHERE event_slug=?", (slug,))
            c.execute("DELETE FROM mail_logs WHERE event_slug=?", (slug,))
            c.execute("DELETE FROM qr_scans WHERE event_slug=?", (slug,))
            c.execute("DELETE FROM photo_downloads WHERE event_slug=?", (slug,))
            c.execute("DELETE FROM photo_attempts WHERE event_slug=?", (slug,))
            c.execute("DELETE FROM event_account_frames WHERE event_slug=?", (slug,))
            conn.commit()
            conn.close()
            last_err = None
            break
        except DBOperationalError as e:
            last_err = e
            try:
                conn.close()
            except Exception:
                pass
            if "locked" in str(e).lower():
                time.sleep(0.15)
                continue
            raise

    if last_err:
        return RedirectResponse(f"/panel/events/{event_id}?err=Veritabanı kilitli. Lütfen tekrar deneyin.", status_code=303)

    event_dir = os.path.join(EVENT_PHOTO_DIR, slug)
    frame_dir = os.path.join(FRAME_DIR, slug)
    try:
        if os.path.isdir(event_dir):
            shutil.rmtree(event_dir)
    except Exception:
        pass
    try:
        if os.path.isdir(frame_dir):
            shutil.rmtree(frame_dir)
    except Exception:
        pass

    try:
        qr_path = os.path.join(QR_DIR, f"{slug}.png")
        if os.path.exists(qr_path):
            os.remove(qr_path)
    except Exception:
        pass

    for p in photo_paths:
        try:
            abs_path = os.path.join(ROOT_DIR, p) if p else ""
            if abs_path and os.path.exists(abs_path):
                os.remove(abs_path)
        except Exception:
            pass
    for sp in selfie_paths:
        try:
            abs_path = os.path.join(ROOT_DIR, sp) if sp else ""
            if abs_path and os.path.exists(abs_path):
                os.remove(abs_path)
        except Exception:
            pass

    woo_msg = ""
    if ext_source == "woo" and ext_event_id:
        wr = delete_woo_event_product(ext_event_id)
        if wr.get("ok"):
            woo_msg = " | Woo ürünü silindi"
        else:
            woo_msg = f" | Woo ürünü silinemedi: {wr.get('error')}"

    return RedirectResponse(f"/panel/events?msg=Etkinlik silindi{woo_msg}", status_code=303)


# =========================
# CUSTOMER: UPLOAD (credit check + auto match via worker)
# =========================

@app.post("/panel/events/{event_id}/upload_photos", include_in_schema=False)
async def panel_upload_photos(request: Request, event_id: int, photos: List[UploadFile] = File(...)):
    acc = get_current_account(request)
    if not acc:
        return RedirectResponse("/login?err=Önce giriş yapın", status_code=303)
    if acc["role"] != "customer":
        return RedirectResponse("/admin/users", status_code=303)

    event = get_customer_event_or_none(acc, event_id)
    if not event:
        return RedirectResponse("/panel/events?err=Etkinlik bulunamadı", status_code=303)

    form = await request.form()
    verify_csrf_token(request, form.get(CSRF_PARAM))
    subalbum_id_raw = (form.get("subalbum_id") or "").strip()
    subalbum_id = int(subalbum_id_raw) if subalbum_id_raw.isdigit() and int(subalbum_id_raw) > 0 else None
    t0 = _now_s()
    files = [p for p in (photos or []) if p and (p.filename or "").strip()]
    if len(files) == 0:
        return RedirectResponse(f"/panel/events/{event_id}?err=Fotoğraf seçmediniz", status_code=303)
    if len(files) > int(UPLOAD_BATCH_MAX_FILES):
        return RedirectResponse(
            f"/panel/events/{event_id}?err=Tek partta en fazla {int(UPLOAD_BATCH_MAX_FILES)} fotoğraf yükleyebilirsiniz",
            status_code=303,
        )

    slug = event["slug"]

    ok = decrement_credit(acc["id"], len(files))
    if not ok:
        return RedirectResponse(
            f"/panel/events/{event_id}?err=Kredi yetersiz. Seçilen: {len(files)}",
            status_code=303
        )

    pid = generate_pid()
    prev_max_id = get_event_photos_max_id(slug)
    job_id = create_job(
        acc["id"],
        slug,
        action="upload_only",
        uploaded_count=len(files),
        subalbum_id=subalbum_id,
        status="uploading",
        pid=pid,
        match_start=prev_max_id,
        match_cursor=prev_max_id,
        match_end=None,
    )

    saved = 0
    total_bytes = 0
    try:
        event_dir = os.path.join(EVENT_PHOTO_DIR, slug)
        os.makedirs(event_dir, exist_ok=True)

        frame_paths = get_event_account_frames(slug, int(acc["id"]))
        proc_settings = get_event_processing_settings(slug)

        for photo in files:
            save_path = os.path.join(event_dir, f"{uuid.uuid4().hex}.jpg")
            raw = await photo.read()
            try:
                pil_probe = Image.open(BytesIO(raw))
                pil_format = pil_probe.format or "UNKNOWN"
                pil_probe.close()
            except Exception:
                pil_format = "UNKNOWN"
            log(f"[UPLOAD] file={photo.filename} ctype={photo.content_type} bytes={len(raw)} pil={pil_format}")
            if photo.content_type and photo.content_type.lower() not in ALLOWED_IMAGE_MIME:
                raise ValueError(f"Sadece jpg/png/webp yükleyebilirsiniz (ctype={photo.content_type})")
            if len(raw) > int(IMAGE_MAX_BYTES):
                raise ValueError("Dosya çok büyük")
            size = process_event_photo_bytes(
                raw,
                save_path,
                frame_paths,
                target_kb=int(proc_settings["target_kb"]),
                max_side=int(proc_settings["max_side"]),
            )
            total_bytes += size
            try:
                pass
            except Exception:
                pass

            rel = os.path.relpath(save_path, ROOT_DIR).replace("\\", "/")
            insert_event_photo(slug, rel, uploaded_by_account_id=int(acc["id"]), file_size_bytes=int(size))
            saved += 1

        new_max_id = get_event_photos_max_id(slug)
        update_job_match_range(
            job_id,
            prev_max_id,
            new_max_id,
            status="done",
            message=f"Yukleme tamamlandi. (PID {pid})",
        )
        dt = _now_s() - t0
        log(f"[UPLOAD] panel event_id={event_id} slug={slug} files={saved} bytes={total_bytes} secs={dt:.2f}")
        msg = f"Yuklendi: {saved}. (PID {pid})"
        return RedirectResponse(f"/panel/events/{event_id}?msg={msg}", status_code=303)

    except Exception as e:
        finish_job(job_id, "error", f"Upload hatası: {e}")
        refund_credit(acc["id"], len(files))
        return RedirectResponse(
            f"/panel/events/{event_id}?err=Upload sırasında hata oluştu. Kredi geri yüklendi.",
            status_code=303
        )


@app.post("/panel/photos/{photo_id}/delete", include_in_schema=False)
async def panel_delete_photo(request: Request, photo_id: int, event_id: int = Form(...)):
    acc = get_current_account(request)
    if not acc:
        return RedirectResponse("/login?err=Önce giriş yapın", status_code=303)
    if acc["role"] != "customer":
        return RedirectResponse("/admin/users", status_code=303)

    form = await request.form()
    verify_csrf_token(request, form.get(CSRF_PARAM))
    event = get_customer_event_or_none(acc, int(event_id))
    if not event:
        return RedirectResponse("/panel/events?err=Etkinlik bulunamadı", status_code=303)

    slug = event["slug"]

    conn = db_conn()
    c = conn.cursor()
    c.execute("SELECT event_id, file_path FROM event_photos WHERE id=? LIMIT 1", (int(photo_id),))
    row = c.fetchone()
    if not row:
        conn.close()
        return RedirectResponse(f"/panel/events/{event_id}?err=Foto bulunamadı", status_code=303)

    if row["event_id"] != slug:
        conn.close()
        return RedirectResponse(f"/panel/events/{event_id}?err=Yetkisiz işlem", status_code=303)

    file_path = row["file_path"]

    c.execute("DELETE FROM photo_matches WHERE photo_id=?", (int(photo_id),))
    c.execute("DELETE FROM event_photos WHERE id=?", (int(photo_id),))
    conn.commit()
    conn.close()

    try:
        abs_path = os.path.join(ROOT_DIR, file_path) if file_path and not os.path.isabs(file_path) else file_path
        if abs_path and os.path.exists(abs_path):
            os.remove(abs_path)
    except Exception:
        pass

    return RedirectResponse(f"/panel/events/{event_id}?msg=Foto silindi", status_code=303)


@app.post("/panel/events/{event_id}/frames", include_in_schema=False)
async def panel_upload_frames(
    request: Request,
    event_id: int,
    frame_ratio_1_1: Optional[UploadFile] = File(None),
    frame_ratio_3_2: Optional[UploadFile] = File(None),
    frame_ratio_2_3: Optional[UploadFile] = File(None),
    frame_ratio_3_4: Optional[UploadFile] = File(None),
    frame_ratio_4_3: Optional[UploadFile] = File(None),
):
    acc = get_current_account(request)
    if not acc:
        return RedirectResponse("/login?err=Önce giriş yapın", status_code=303)
    if acc["role"] != "customer":
        return RedirectResponse("/admin/users", status_code=303)

    form = await request.form()
    verify_csrf_token(request, form.get(CSRF_PARAM))

    event = get_customer_event_or_none(acc, event_id)
    if not event:
        return RedirectResponse("/panel/events?err=Etkinlik bulunamadı", status_code=303)

    slug = event["slug"]
    base_dir = os.path.join(FRAME_DIR, slug, str(int(acc["id"])))
    os.makedirs(base_dir, exist_ok=True)

    updates = {}
    try:
        uploads = {
            "ratio_1_1": frame_ratio_1_1,
            "ratio_3_2": frame_ratio_3_2,
            "ratio_2_3": frame_ratio_2_3,
            "ratio_3_4": frame_ratio_3_4,
            "ratio_4_3": frame_ratio_4_3,
        }
        for kind, upload in uploads.items():
            if upload and getattr(upload, "filename", ""):
                path = os.path.join(base_dir, str(FRAME_KIND_META[kind]["filename"]))
                rel = await save_frame_file(upload, path)
                updates[f"frame_{kind}"] = rel
        if "frame_ratio_3_2" in updates:
            updates["frame_landscape"] = updates["frame_ratio_3_2"]
        if "frame_ratio_2_3" in updates:
            updates["frame_portrait"] = updates["frame_ratio_2_3"]
        if "frame_ratio_1_1" in updates:
            updates["frame_square"] = updates["frame_ratio_1_1"]
    except Exception as e:
        return RedirectResponse(f"/panel/events/{event_id}?err=Çerçeve yüklenemedi: {e}", status_code=303)

    if updates:
        upsert_event_account_frames(slug, int(acc["id"]), updates)

    return RedirectResponse(f"/panel/events/{event_id}?msg=Çerçeveler güncellendi", status_code=303)


@app.post("/panel/events/{event_id}/reprocess", include_in_schema=False)
async def panel_reprocess_event_photos(request: Request, event_id: int):
    acc = get_current_account(request)
    if not acc:
        return RedirectResponse("/login?err=Önce giriş yapın", status_code=303)
    if acc["role"] != "customer":
        return RedirectResponse("/admin/users", status_code=303)

    form = await request.form()
    verify_csrf_token(request, form.get(CSRF_PARAM))

    event = get_customer_event_or_none(acc, event_id)
    if not event:
        return RedirectResponse("/panel/events?err=Etkinlik bulunamadı", status_code=303)

    slug = event["slug"]
    frame_paths = get_event_account_frames(slug, int(acc["id"]))
    count = reprocess_event_photos(
        slug,
        frame_paths,
        target_kb=EVENT_TARGET_KB,
        max_side=EVENT_MAX_SIDE,
        uploaded_by_account_id=int(acc["id"]),
    )
    return RedirectResponse(f"/panel/events/{event_id}?msg=Çerçeve uygulandı: {count} foto", status_code=303)


@app.post("/panel/events/{event_id}/frames/delete", include_in_schema=False)
async def panel_delete_frame(request: Request, event_id: int):
    acc = get_current_account(request)
    if not acc:
        return RedirectResponse("/login?err=Önce giriş yapın", status_code=303)
    if acc["role"] != "customer":
        return RedirectResponse("/admin/users", status_code=303)

    form = await request.form()
    verify_csrf_token(request, form.get(CSRF_PARAM))
    kind = (form.get("kind") or "").strip().lower()

    event = get_customer_event_or_none(acc, event_id)
    if not event:
        return RedirectResponse("/panel/events?err=Etkinlik bulunamadı", status_code=303)

    slug = event["slug"]
    try:
        clear_event_account_frame(slug, int(acc["id"]), kind)
    except ValueError:
        return RedirectResponse(f"/panel/events/{event_id}?err=Geçersiz çerçeve türü", status_code=303)

    for filename in _frame_disk_names(kind):
        frame_file = os.path.join(FRAME_DIR, slug, str(int(acc["id"])), filename)
        try:
            if os.path.exists(frame_file):
                os.remove(frame_file)
        except Exception:
            pass
    return RedirectResponse(f"/panel/events/{event_id}?msg=Çerçeve silindi", status_code=303)


# =========================
# PUBLIC: SELFIE FLOW
# =========================

def validate_selfie_geometry(save_path: str):
    raise ValueError("Selfie kaydi kaldirildi.")


def save_selfie_file_from_dataurl(data_url: str) -> str:
    raise ValueError("Selfie kaydi kaldirildi.")


def save_selfie_file_from_upload(selfie: UploadFile) -> str:
    raise ValueError("Selfie kaydi kaldirildi.")


def save_selfie_file(selfie: Optional[UploadFile], selfie_dataurl: Optional[str]) -> str:
    raise ValueError("Selfie kaydi kaldirildi.")


async def save_avatar_file(avatar: UploadFile) -> str:
    save_path = os.path.join(AVATAR_DIR, f"{uuid.uuid4().hex}.jpg")
    await save_image_optimized_from_upload(
        avatar,
        save_path,
        target_kb=200,
        max_side=600,
        max_bytes=3 * 1024 * 1024,
    )
    return os.path.relpath(save_path, ROOT_DIR).replace("\\", "/")


async def save_frame_file(upload: UploadFile, save_path: str) -> str:
    raw = await upload.read()
    if upload.content_type and upload.content_type.lower() not in {"image/png"}:
        raise ValueError("Sadece PNG yükleyebilirsiniz")
    if len(raw) > FRAME_MAX_BYTES:
        raise ValueError("Çerçeve dosyası çok büyük")

    img = Image.open(BytesIO(raw))
    if img.mode != "RGBA":
        img = img.convert("RGBA")

    os.makedirs(os.path.dirname(save_path), exist_ok=True)
    img.save(save_path, format="PNG", optimize=True)
    return os.path.relpath(save_path, ROOT_DIR).replace("\\", "/")


def _resize_image(img: Image.Image, max_side: int) -> Image.Image:
    w, h = img.size
    longest = max(w, h)
    if longest <= int(max_side):
        return img
    scale = float(max_side) / float(longest)
    nw = max(1, int(w * scale))
    nh = max(1, int(h * scale))
    return img.resize((nw, nh), Image.LANCZOS)


def _safe_media_abs_path(file_path: str) -> str:
    clean = (file_path or "").replace("\\", "/").lstrip("/")
    if clean.startswith("media/"):
        clean = clean[len("media/") :]
    abs_path = os.path.normpath(os.path.join(MEDIA_DIR, clean))
    media_root = os.path.normpath(MEDIA_DIR)
    if not abs_path.startswith(media_root + os.sep) and abs_path != media_root:
        raise HTTPException(status_code=400, detail="Geçersiz medya yolu")
    return abs_path


def _thumb_cache_path(file_path: str, max_side: int) -> str:
    clean = (file_path or "").replace("\\", "/").lstrip("/")
    if clean.startswith("media/"):
        clean = clean[len("media/") :]
    root, _ext = os.path.splitext(clean)
    rel = f"{int(max_side)}/{root}.jpg"
    return os.path.join(THUMB_DIR, rel)


def _frame_disk_names(kind: str) -> List[str]:
    kind = (kind or "").strip().lower()
    names: List[str] = []
    meta = FRAME_KIND_META.get(kind)
    if meta:
        names.append(str(meta["filename"]))
    legacy = {
        "ratio_1_1": "square.png",
        "ratio_3_2": "landscape.png",
        "ratio_2_3": "portrait.png",
        "ratio_4_3": "ratio_4_3.png",
        "square": "square.png",
        "landscape": "landscape.png",
        "portrait": "portrait.png",
    }.get(kind)
    if legacy and legacy not in names:
        names.append(legacy)
    if kind.endswith(".png") and kind not in names:
        names.append(kind)
    return names


def _apply_frame(img: Image.Image, frame_path: str) -> Image.Image:
    if not frame_path:
        return img
    abs_path = os.path.join(ROOT_DIR, frame_path) if not os.path.isabs(frame_path) else frame_path
    if not abs_path or not os.path.exists(abs_path):
        return img
    frame = Image.open(abs_path).convert("RGBA")
    base = img.convert("RGBA")
    bw, bh = base.size
    fw, fh = frame.size
    if fw <= 0 or fh <= 0:
        return img
    if frame.size != base.size:
        scale = min(float(bw) / float(fw), float(bh) / float(fh))
        nw = max(1, int(round(fw * scale)))
        nh = max(1, int(round(fh * scale)))
        frame = frame.resize((nw, nh), Image.LANCZOS)
        canvas = Image.new("RGBA", base.size, (0, 0, 0, 0))
        offset = ((bw - nw) // 2, (bh - nh) // 2)
        canvas.alpha_composite(frame, offset)
        frame = canvas
    base.alpha_composite(frame)
    return base.convert("RGB")


def _select_frame_path(frame_paths: Dict[str, str], w: int, h: int) -> str:
    if w == 0 or h == 0:
        return ""
    ratio = w / float(h)
    candidates = []
    for kind, meta in FRAME_KIND_META.items():
        path = (frame_paths.get(kind) or "").strip()
        if not path:
            continue
        target = float(meta["ratio"])
        diff = abs(ratio - target)
        rel = diff / target if target else diff
        candidates.append((rel, diff, path))
    if not candidates:
        return ""
    candidates.sort(key=lambda item: (item[0], item[1]))
    best_rel, _best_diff, best_path = candidates[0]
    if best_rel > 0.08:
        return ""
    return best_path


def process_event_photo_bytes(raw: bytes, save_path: str, frame_paths: Dict[str, str], target_kb: int = EVENT_TARGET_KB, max_side: int = EVENT_MAX_SIDE) -> int:
    if not raw:
        raise ValueError("Boş dosya")
    try:
        img = Image.open(BytesIO(raw))
    except UnidentifiedImageError:
        if HEIF_ENABLED:
            raise ValueError("Desteklenmeyen görüntü formatı")
        raise ValueError("Desteklenmeyen görüntü formatı (HEIC/HEIF için HEIF desteği gerekir)")
    img = ImageOps.exif_transpose(img)
    if img.mode != "RGB":
        img = img.convert("RGB")
    img = _resize_image(img, max_side=max_side)
    w, h = img.size
    frame_path = _select_frame_path(frame_paths, w, h)
    img = _apply_frame(img, frame_path)
    jpeg_bytes = _encode_jpeg_under_kb(img, target_kb=target_kb)
    os.makedirs(os.path.dirname(save_path), exist_ok=True)
    with open(save_path, "wb") as f:
        f.write(jpeg_bytes)
    return len(jpeg_bytes)


def reprocess_event_photos(
    slug: str,
    frame_paths: Dict[str, str],
    target_kb: int = EVENT_TARGET_KB,
    max_side: int = EVENT_MAX_SIDE,
    uploaded_by_account_id: Optional[int] = None,
) -> int:
    conn = db_conn()
    c = conn.cursor()
    if uploaded_by_account_id is None:
        c.execute("SELECT id, file_path FROM event_photos WHERE event_id=?", (slug,))
    else:
        c.execute(
            "SELECT id, file_path FROM event_photos WHERE event_id=? AND uploaded_by_account_id=?",
            (slug, int(uploaded_by_account_id)),
        )
    rows = c.fetchall()
    conn.close()

    processed = 0
    for r in rows:
        file_path = r["file_path"]
        if not file_path:
            continue
        abs_path = os.path.join(ROOT_DIR, file_path) if not os.path.isabs(file_path) else file_path
        if not abs_path or not os.path.exists(abs_path):
            continue
        try:
            with open(abs_path, "rb") as f:
                raw = f.read()
            process_event_photo_bytes(raw, abs_path, frame_paths, target_kb=target_kb, max_side=max_side)
            processed += 1
        except Exception:
            continue

    return processed


def _get_event_name(event_id: str) -> str:
    try:
        conn = db_conn()
        c = conn.cursor()
        c.execute("SELECT name FROM saas_events WHERE slug=? LIMIT 1", (event_id,))
        row = c.fetchone()
        conn.close()
        return (row["name"] if row else "") or event_id
    except Exception:
        return event_id


def _normalize_lang(lang: Optional[str]) -> str:
    return "en" if (lang or "").strip().lower() == "en" else "tr"


@app.get("/e/{event_id}", response_class=HTMLResponse)
async def landing_page(request: Request, event_id: str, lang: Optional[str] = None):
    lang = _normalize_lang(lang)
    event_name = _get_event_name(event_id)
    log_qr_scan(event_id, request)
    return render_template(
        request,
        "landing.html",
        {"request": request, "event_id": event_id, "event_name": event_name, "lang": lang},
        csrf=False,
    )


@app.get("/e/{event_id}/all", response_class=HTMLResponse)
async def event_all_gallery(request: Request, event_id: str, page: int = 1, lang: Optional[str] = None):
    lang = _normalize_lang(lang)
    page = max(1, int(page or 1))
    per_page = 60
    offset = (page - 1) * per_page

    conn = db_conn()
    c = conn.cursor()
    c.execute("SELECT COUNT(*) AS cnt FROM event_photos WHERE event_id=?", (event_id,))
    total = int(c.fetchone()["cnt"] or 0)
    c.execute(
        """
        SELECT id, file_path, created_at
        FROM event_photos
        WHERE event_id=?
        ORDER BY id DESC
        LIMIT ? OFFSET ?
        """,
        (event_id, int(per_page), int(offset)),
    )
    rows = c.fetchall()
    conn.close()

    photos = []
    for r in rows:
        file_path = (r["file_path"] or "").replace("\\", "/").lstrip("/")
        clean = file_path[6:] if file_path.startswith("media/") else file_path
        url = "/media/" + clean if clean else ""
        photos.append(
            {
                "id": int(r["id"]),
                "url": url,
                "created_at": r["created_at"] or "",
            }
        )

    total_pages = max(1, (total + per_page - 1) // per_page)

    return render_template(
        request,
        "event_all_gallery.html",
        {
            "request": request,
            "event_id": event_id,
            "event_name": _get_event_name(event_id),
            "lang": lang,
            "photos": photos,
            "page": page,
            "total_pages": total_pages,
            "total": total,
        },
        csrf=False,
    )


@app.get("/privacy", response_class=HTMLResponse)
@app.get("/aydinlatma", response_class=HTMLResponse)
async def privacy_page(request: Request):
    return render_template(
        request,
        "privacy.html",
        {"request": request},
        csrf=False,
    )


@app.get("/e/{event_id}/register", response_class=HTMLResponse)
async def register_page(
    request: Request,
    event_id: str,
    lang: Optional[str] = None,
    name: Optional[str] = None,
    email: Optional[str] = None,
    redirect_external: Optional[str] = None,
):
    return RedirectResponse(f"/e/{event_id}/all", status_code=307)


@app.get("/e/{event_id}/lookup", response_class=HTMLResponse)
async def lookup_page(request: Request, event_id: str, lang: Optional[str] = None):
    return RedirectResponse(f"/e/{event_id}/all", status_code=307)


@app.get("/e/{event_id}/lookup/", include_in_schema=False)
async def lookup_page_slash(event_id: str, lang: Optional[str] = None):
    return RedirectResponse(f"/e/{event_id}/all", status_code=307)


@app.post("/register", response_class=HTMLResponse)
async def register_user_base64(
    request: Request,
    event_id: str = Form(...),
    name: str = Form(...),
    email: str = Form(...),
    kvkk_consent: str = Form(...),
    selfie_data: str = Form(...),
    redirect_external: Optional[str] = Form(None),
):
    return HTMLResponse("Selfie tabanli kayit kaldirildi.", status_code=410)


@app.post("/register_file", response_class=HTMLResponse)
async def register_user_file(
    request: Request,
    event_id: str = Form(...),
    name: str = Form(...),
    email: str = Form(...),
    kvkk_consent: str = Form(...),
    selfie: Optional[UploadFile] = File(None),
    selfie_dataurl: Optional[str] = Form(None),
    redirect_external: Optional[str] = Form(None),
):
    return HTMLResponse("Selfie tabanli kayit kaldirildi.", status_code=410)


@app.post("/lookup", response_class=HTMLResponse)
async def lookup_by_email(
    request: Request,
    email: str = Form(...),
    event_id: Optional[str] = Form(None),
    lang: Optional[str] = Form(None),
):
    return HTMLResponse("Selfie tabanli fotograf arama kaldirildi.", status_code=410)


# =========================
# CONSOLE (super_admin only)
# =========================

@app.get("/console", response_class=HTMLResponse)
async def console_home(request: Request):
    r = require_console_access(request)
    if isinstance(r, RedirectResponse):
        return r

    msg = request.query_params.get("msg")
    err = request.query_params.get("err")

    conn = db_conn()
    c = conn.cursor()
    c.execute("""
        SELECT
            se.slug,
            se.name,
            se.created_at,
            a.email AS owner_email
        FROM saas_events se
        JOIN accounts a ON a.id = se.account_id
        WHERE COALESCE(se.album_enabled, TRUE)=TRUE
        ORDER BY se.id DESC
    """)
    events = c.fetchall()
    conn.close()

    return render_template(
        request,
        "console_dashboard.html",
        {
            "request": request,
            "active": "events",
            "header": "Fotoğraf Albümleri",
            "title": "Fotoğraf Albümleri",
            "events": events,
            "base_url": PUBLIC_BASE_URL,
            "message": msg,
            "error": err,
        },
        csrf=True,
    )


@app.post("/console/submissions/{submission_id}/approve", include_in_schema=False)
async def console_approve_submission(
    request: Request,
    submission_id: int,
    csrf_token: str = Form(...),
    source_table: str = Form("event_submissions"),
    admin_note: str = Form(""),
):
    r = require_console_access(request)
    if isinstance(r, RedirectResponse):
        return r
    verify_csrf_token(request, csrf_token)

    conn = db_conn()
    c = conn.cursor()
    source_table = (source_table or "").strip().lower()
    if source_table not in ("event_submissions", "mobile_event_submissions"):
        source_table = "event_submissions"

    if source_table == "mobile_event_submissions":
        c.execute("SELECT * FROM mobile_event_submissions WHERE id=? LIMIT 1", (int(submission_id),))
    else:
        c.execute("SELECT * FROM event_submissions WHERE id=? LIMIT 1", (int(submission_id),))
    row = c.fetchone()
    if not row:
        conn.close()
        return RedirectResponse("/admin/mobile?err=Talep bulunamadı", status_code=303)

    c.execute("SELECT id FROM accounts WHERE LOWER(email)=LOWER(?) LIMIT 1", (row["submitter_email"],))
    owner = c.fetchone()
    owner_id = int(owner["id"]) if owner else int(r["id"])

    if source_table == "mobile_event_submissions":
        try:
            summary = _approve_mobile_submission_group(
                conn,
                int(submission_id),
                (admin_note or "").strip(),
                owner_id,
            )
            conn.commit()
            conn.close()
            active_slug = (summary.get("active_slug") or "").strip()
            approved_count = int(summary.get("approved_count") or 0)
            archived_count = int(summary.get("archived_count") or 0)
            if not active_slug and archived_count > 0:
                return RedirectResponse(
                    f"/admin/mobile?msg={urllib.parse.quote(f'Seri işlendi: {archived_count} geçmiş tarih arşivlendi')}",
                    status_code=303,
                )
            if summary.get("is_series"):
                detail = f"{approved_count} tarih hazır"
                if archived_count > 0:
                    detail += f", {archived_count} geçmiş tarih arşivlendi"
                suffix = f" | {detail}"
                if not summary.get("ticket_sales_enabled"):
                    suffix += " | Bilet satışı kapalı"
                elif summary.get("woo_id"):
                    suffix += f" | Aktif Woo ürün id={summary.get('woo_id')}"
                msg_text = f"Seri onaylandı: {active_slug or '-'}{suffix}"
                return RedirectResponse(
                    f"/admin/mobile?msg={urllib.parse.quote(msg_text)}",
                    status_code=303,
                )
            if not summary.get("ticket_sales_enabled"):
                return RedirectResponse(
                    f"/admin/mobile?msg=Talep onaylandı: {active_slug} | Bilet satışı kapalı, Woo ürünü oluşturulmadı",
                    status_code=303,
                )
            if summary.get("woo_id"):
                return RedirectResponse(
                    f"/admin/mobile?msg=Talep onaylandı: {active_slug} | Woo ürün id={summary.get('woo_id')}",
                    status_code=303,
                )
            if summary.get("woo_ok"):
                return RedirectResponse(
                    f"/admin/mobile?msg=Talep onaylandı: {active_slug} | Woo ürün yayına alındı",
                    status_code=303,
                )
            return RedirectResponse(
                f"/admin/mobile?msg=Talep onaylandı: {active_slug} | Woo ürün oluşturulamadı",
                status_code=303,
            )
        except Exception as e:
            conn.rollback()
            conn.close()
            return RedirectResponse(
                f"/admin/mobile?err={urllib.parse.quote('Seri onayı başarısız: ' + str(e)[:300])}",
                status_code=303,
            )

    event_name = (row["event_name"] or "").strip() or f"Etkinlik {submission_id}"
    create_photo_album = True
    if source_table == "mobile_event_submissions" and "create_photo_album" in row.keys():
        create_photo_album = _boolish(row["create_photo_album"], default=True)
    base_slug = _slug_clean(event_name) or f"event-{submission_id}"
    slug = base_slug
    n = 2
    while True:
        c.execute("SELECT 1 FROM saas_events WHERE slug=? LIMIT 1", (slug,))
        if not c.fetchone():
            break
        slug = f"{base_slug}-{n}"
        n += 1

    c.execute(
        """
        INSERT INTO saas_events (account_id, name, slug, is_active, created_at, album_enabled)
        VALUES (?, ?, ?, 1, ?, ?)
        """,
        (owner_id, event_name, slug, iso_now(), True if create_photo_album else False),
    )

    cover_for_woo = ""
    if "cover_path" in row.keys():
        cover_for_woo = row["cover_path"] or ""
    elif "cover_image" in row.keys():
        cover_for_woo = row["cover_image"] or ""

    extra_desc_parts = []
    if "venue" in row.keys() and (row["venue"] or "").strip():
        extra_desc_parts.append(f"Mekan: {row['venue']}")
    if "organizer_name" in row.keys() and (row["organizer_name"] or "").strip():
        extra_desc_parts.append(f"Organizatör: {row['organizer_name']}")
    if "program_text" in row.keys() and (row["program_text"] or "").strip():
        extra_desc_parts.append(f"Program: {row['program_text']}")

    base_desc = (row["description"] or "") if "description" in row.keys() else ""
    full_desc = base_desc
    if extra_desc_parts:
        full_desc = (base_desc + "\n\n" if base_desc else "") + "\n".join(extra_desc_parts)

    ticket_sales_enabled = True
    if "ticket_sales_enabled" in row.keys():
        raw_ts = row["ticket_sales_enabled"]
        if raw_ts is None:
            ticket_sales_enabled = True
        elif isinstance(raw_ts, bool):
            ticket_sales_enabled = raw_ts
        else:
            ticket_sales_enabled = str(raw_ts).strip().lower() in ("1", "true", "yes", "on")

    woo_res = {"ok": False, "error": "Bilet satışı kapalı"}
    if ticket_sales_enabled:
        woo_res = create_woo_draft_event_product(
            event_name=event_name,
            description=full_desc,
            start_at=(row["start_at"] or "") if "start_at" in row.keys() else "",
            end_at=(row["end_at"] or "") if "end_at" in row.keys() else "",
            entry_fee=(row["entry_fee"] or 0) if "entry_fee" in row.keys() else 0,
            cover_path=cover_for_woo,
        )
        if woo_res.get("ok"):
            c.execute(
                """
                UPDATE saas_events
                SET external_source='woo', external_event_id=?, ticket_url=?
                WHERE slug=?
                """,
                ((woo_res.get("woo_id") or None), (woo_res.get("ticket_url") or None), slug),
            )

    note_prefix = (admin_note or "").strip()
    if not ticket_sales_enabled:
        extra = "Bilet satışı kapalı: Woo ürünü oluşturulmadı"
    elif woo_res.get("ok"):
        extra = f"Woo ürün oluşturuldu (id={woo_res.get('woo_id')})"
    else:
        extra = f"Woo ürün oluşturulamadı: {woo_res.get('error')}"
    album_note = "Fotoğraf albümü açık" if create_photo_album else "Fotoğraf albümü kapalı"
    merged_note = (note_prefix + " | " + extra + " | " + album_note).strip(" |")

    if source_table == "mobile_event_submissions":
        c.execute(
            """
            UPDATE mobile_event_submissions
            SET status='approved',
                admin_note=?,
                approved_event_slug=?,
                approved_at=?
            WHERE id=?
            """,
            (merged_note, slug, iso_now(), int(submission_id)),
        )
    else:
        c.execute(
            """
            UPDATE event_submissions
            SET status='approved',
                admin_note=?,
                approved_event_slug=?,
                reviewed_by_account_id=?,
                reviewed_at=?
            WHERE id=?
            """,
            (merged_note, slug, int(r["id"]), iso_now(), int(submission_id)),
        )
    conn.commit()
    conn.close()
    if not ticket_sales_enabled:
        return RedirectResponse(
            f"/admin/mobile?msg=Talep onaylandı: {slug} | Bilet satışı kapalı, Woo ürünü oluşturulmadı",
            status_code=303,
        )
    if woo_res.get("ok"):
        return RedirectResponse(
            f"/admin/mobile?msg=Talep onaylandı: {slug} | Woo ürün id={woo_res.get('woo_id')}",
            status_code=303,
        )
    return RedirectResponse(
        f"/admin/mobile?msg=Talep onaylandı: {slug} | Woo ürün oluşturulamadı",
        status_code=303,
    )


@app.post("/console/submissions/{submission_id}/reject", include_in_schema=False)
async def console_reject_submission(
    request: Request,
    submission_id: int,
    csrf_token: str = Form(...),
    source_table: str = Form("event_submissions"),
    admin_note: str = Form(""),
):
    r = require_console_access(request)
    if isinstance(r, RedirectResponse):
        return r
    verify_csrf_token(request, csrf_token)

    conn = db_conn()
    c = conn.cursor()
    source_table = (source_table or "").strip().lower()
    if source_table not in ("event_submissions", "mobile_event_submissions"):
        source_table = "event_submissions"

    if source_table == "mobile_event_submissions":
        c.execute("SELECT id FROM mobile_event_submissions WHERE id=? LIMIT 1", (int(submission_id),))
    else:
        c.execute("SELECT id FROM event_submissions WHERE id=? LIMIT 1", (int(submission_id),))
    row = c.fetchone()
    if not row:
        conn.close()
        return RedirectResponse("/admin/mobile?err=Talep bulunamadı", status_code=303)
    if source_table == "mobile_event_submissions":
        c.execute(
            """
            UPDATE mobile_event_submissions
            SET status='rejected',
                admin_note=?
            WHERE id=?
            """,
            ((admin_note or "").strip(), int(submission_id)),
        )
    else:
        c.execute(
            """
            UPDATE event_submissions
            SET status='rejected',
                admin_note=?,
                reviewed_by_account_id=?,
                reviewed_at=?
            WHERE id=?
            """,
            ((admin_note or "").strip(), int(r["id"]), iso_now(), int(submission_id)),
        )
    conn.commit()
    conn.close()
    return RedirectResponse("/admin/mobile?msg=Talep reddedildi", status_code=303)


def purge_event_album_content(slug: str) -> Dict[str, Any]:
    last_err = None
    selfie_paths: List[str] = []
    photo_paths: List[str] = []
    for _ in range(6):
        try:
            conn = db_conn()
            c = conn.cursor()
            if not USE_POSTGRES:
                c.execute("BEGIN IMMEDIATE")
            c.execute("SELECT selfie_path FROM users WHERE event_id=?", (slug,))
            selfie_paths = [r[0] for r in c.fetchall() if r and r[0]]
            c.execute("SELECT file_path FROM event_photos WHERE event_id=?", (slug,))
            photo_paths = [r[0] for r in c.fetchall() if r and r[0]]
            c.execute("DELETE FROM photo_matches WHERE event_id=?", (slug,))
            c.execute("DELETE FROM event_photos WHERE event_id=?", (slug,))
            c.execute("DELETE FROM users WHERE event_id=?", (slug,))
            c.execute("DELETE FROM events WHERE slug=?", (slug,))
            c.execute("DELETE FROM jobs WHERE event_slug=?", (slug,))
            c.execute("DELETE FROM mail_logs WHERE event_slug=?", (slug,))
            c.execute("DELETE FROM qr_scans WHERE event_slug=?", (slug,))
            c.execute("DELETE FROM photo_downloads WHERE event_slug=?", (slug,))
            c.execute("DELETE FROM photo_attempts WHERE event_slug=?", (slug,))
            c.execute("DELETE FROM event_account_frames WHERE event_slug=?", (slug,))
            c.execute("DELETE FROM event_subalbums WHERE event_slug=?", (slug,))
            c.execute(
                """
                UPDATE saas_events
                SET frame_landscape=NULL,
                    frame_portrait=NULL,
                    frame_square=NULL,
                    frame_ratio_1_1=NULL,
                    frame_ratio_3_2=NULL,
                    frame_ratio_2_3=NULL,
                    frame_ratio_3_4=NULL,
                    frame_ratio_4_3=NULL,
                    photo_target_kb=NULL,
                    photo_max_side=NULL
                WHERE slug=?
                """,
                (slug,),
            )
            conn.commit()
            conn.close()
            last_err = None
            break
        except DBOperationalError as e:
            last_err = e
            try:
                conn.close()
            except Exception:
                pass
            if "locked" in str(e).lower():
                time.sleep(0.15)
                continue
            raise
    if last_err:
        return {"ok": False, "error": "Albüm temizlenemedi (DB locked)"}

    event_dir = os.path.join(EVENT_PHOTO_DIR, slug)
    frame_dir = os.path.join(FRAME_DIR, slug)
    try:
        if os.path.isdir(event_dir):
            shutil.rmtree(event_dir)
    except Exception:
        pass
    try:
        if os.path.isdir(frame_dir):
            shutil.rmtree(frame_dir)
    except Exception:
        pass
    try:
        qr_path = os.path.join(QR_DIR, f"{slug}.png")
        if os.path.exists(qr_path):
            os.remove(qr_path)
    except Exception:
        pass
    for p in photo_paths:
        try:
            abs_path = os.path.join(ROOT_DIR, p) if p else ""
            if abs_path and os.path.exists(abs_path):
                os.remove(abs_path)
        except Exception:
            pass
    for sp in selfie_paths:
        try:
            abs_path = os.path.join(ROOT_DIR, sp) if sp else ""
            if abs_path and os.path.exists(abs_path):
                os.remove(abs_path)
        except Exception:
            pass
    return {"ok": True}


def _get_submission_album_context(conn, submission_id: int, source_table: str) -> Optional[Dict[str, Any]]:
    c = conn.cursor()
    source_table = (source_table or "").strip().lower()
    if source_table == "event_submissions":
        c.execute(
            """
            SELECT id, COALESCE(event_name,'') AS event_name, COALESCE(submitter_email,'') AS submitter_email,
                   COALESCE(approved_event_slug,'') AS approved_event_slug
            FROM event_submissions
            WHERE id=?
            LIMIT 1
            """,
            (int(submission_id),),
        )
    else:
        c.execute(
            """
            SELECT id, COALESCE(event_name,'') AS event_name, COALESCE(submitter_email,'') AS submitter_email,
                   COALESCE(approved_event_slug,'') AS approved_event_slug
            FROM mobile_event_submissions
            WHERE id=?
            LIMIT 1
            """,
            (int(submission_id),),
        )
    row = c.fetchone()
    if not row:
        return None
    return row


@app.post("/admin/mobile/submissions/{submission_id}/album/create", include_in_schema=False)
async def admin_mobile_create_album(
    request: Request,
    submission_id: int,
    source_table: str = Form("mobile_event_submissions"),
    csrf_token: str = Form(...),
):
    admin = require_super_admin(request)
    verify_csrf_token(request, csrf_token)
    conn = db_conn()
    c = conn.cursor()
    try:
        row = _get_submission_album_context(conn, int(submission_id), source_table)
        if not row:
            conn.close()
            return RedirectResponse("/admin/mobile?tab=events&err=Etkinlik bulunamadı", status_code=303)
        slug = (row.get("approved_event_slug") or "").strip()
        if not slug:
            conn.close()
            return RedirectResponse("/admin/mobile?tab=events&err=Önce etkinliği onayla", status_code=303)
        c.execute("SELECT id FROM saas_events WHERE slug=? LIMIT 1", (slug,))
        existing = c.fetchone()
        if existing:
            c.execute("UPDATE saas_events SET album_enabled=TRUE WHERE slug=?", (slug,))
        else:
            owner_id = int(admin["id"])
            submitter_email = (row.get("submitter_email") or "").strip()
            if submitter_email:
                c.execute("SELECT id FROM accounts WHERE LOWER(email)=LOWER(?) LIMIT 1", (submitter_email,))
                owner = c.fetchone()
                if owner:
                    owner_id = int(owner["id"])
            c.execute(
                """
                INSERT INTO saas_events (account_id, name, slug, is_active, created_at, album_enabled)
                VALUES (?, ?, ?, 1, ?, TRUE)
                """,
                (owner_id, (row.get("event_name") or slug).strip() or slug, slug, iso_now()),
            )
        if (source_table or "").strip().lower() == "mobile_event_submissions":
            c.execute("UPDATE mobile_event_submissions SET create_photo_album=TRUE WHERE id=?", (int(submission_id),))
        conn.commit()
        conn.close()
        return RedirectResponse("/admin/mobile?tab=events&msg=Fotoğraf albümü açıldı", status_code=303)
    except Exception as e:
        conn.rollback()
        conn.close()
        return RedirectResponse(f"/admin/mobile?tab=events&err={urllib.parse.quote(str(e)[:300])}", status_code=303)


@app.post("/admin/mobile/submissions/{submission_id}/album/delete", include_in_schema=False)
async def admin_mobile_delete_album(
    request: Request,
    submission_id: int,
    source_table: str = Form("mobile_event_submissions"),
    csrf_token: str = Form(...),
):
    _ = require_super_admin(request)
    verify_csrf_token(request, csrf_token)
    conn = db_conn()
    c = conn.cursor()
    try:
        row = _get_submission_album_context(conn, int(submission_id), source_table)
        if not row:
            conn.close()
            return RedirectResponse("/admin/mobile?tab=events&err=Etkinlik bulunamadı", status_code=303)
        slug = (row.get("approved_event_slug") or "").strip()
        if not slug:
            conn.close()
            return RedirectResponse("/admin/mobile?tab=events&err=Bağlı albüm bulunamadı", status_code=303)
        purge_res = purge_event_album_content(slug)
        if not purge_res.get("ok"):
            conn.close()
            return RedirectResponse(
                f"/admin/mobile?tab=events&err={urllib.parse.quote(str(purge_res.get('error') or 'Albüm silinemedi'))}",
                status_code=303,
            )
        c.execute("UPDATE saas_events SET album_enabled=FALSE WHERE slug=?", (slug,))
        if (source_table or "").strip().lower() == "mobile_event_submissions":
            c.execute("UPDATE mobile_event_submissions SET create_photo_album=FALSE WHERE id=?", (int(submission_id),))
        conn.commit()
        conn.close()
        return RedirectResponse("/admin/mobile?tab=events&msg=Fotoğraf albümü kapatıldı", status_code=303)
    except Exception as e:
        conn.rollback()
        conn.close()
        return RedirectResponse(f"/admin/mobile?tab=events&err={urllib.parse.quote(str(e)[:300])}", status_code=303)


@app.post("/admin/mobile/submissions/{submission_id}/delete", include_in_schema=False)
async def admin_mobile_delete_submission(
    request: Request,
    submission_id: int,
    source_table: str = Form("event_submissions"),
    delete_linked_event: Optional[str] = Form(None),
    csrf_token: str = Form(...),
):
    _ = require_super_admin(request)
    verify_csrf_token(request, csrf_token)

    source_table = (source_table or "").strip().lower()
    if source_table not in ("event_submissions", "mobile_event_submissions"):
        source_table = "event_submissions"

    conn = db_conn()
    c = conn.cursor()
    linked_slug = ""
    if source_table == "mobile_event_submissions":
        c.execute("SELECT approved_event_slug FROM mobile_event_submissions WHERE id=? LIMIT 1", (int(submission_id),))
    else:
        c.execute("SELECT approved_event_slug FROM event_submissions WHERE id=? LIMIT 1", (int(submission_id),))
    row = c.fetchone()
    if not row:
        conn.close()
        return RedirectResponse("/admin/mobile?err=Talep bulunamadı", status_code=303)
    linked_slug = (row["approved_event_slug"] or "").strip() if "approved_event_slug" in row.keys() else ""

    if source_table == "mobile_event_submissions":
        c.execute("DELETE FROM mobile_event_submissions WHERE id=?", (int(submission_id),))
    else:
        c.execute("DELETE FROM event_submissions WHERE id=?", (int(submission_id),))

    conn.commit()
    conn.close()

    if delete_linked_event and linked_slug:
        # ilgili fotoğraf etkinliğini de temizle
        last_err = None
        selfie_paths = []
        photo_paths = []
        ext_source = ""
        ext_event_id = ""
        for _ in range(6):
            try:
                conn = db_conn()
                c = conn.cursor()
                if not USE_POSTGRES:
                    c.execute("BEGIN IMMEDIATE")
                c.execute("SELECT external_source, external_event_id FROM saas_events WHERE slug=? LIMIT 1", (linked_slug,))
                ev = c.fetchone()
                if ev:
                    ext_source = (ev["external_source"] or "").strip().lower() if "external_source" in ev.keys() else ""
                    ext_event_id = (ev["external_event_id"] or "").strip() if "external_event_id" in ev.keys() else ""
                c.execute("SELECT selfie_path FROM users WHERE event_id=?", (linked_slug,))
                selfie_paths = [r[0] for r in c.fetchall() if r and r[0]]
                c.execute("SELECT file_path FROM event_photos WHERE event_id=?", (linked_slug,))
                photo_paths = [r[0] for r in c.fetchall() if r and r[0]]
                c.execute("DELETE FROM photo_matches WHERE event_id=?", (linked_slug,))
                c.execute("DELETE FROM event_photos WHERE event_id=?", (linked_slug,))
                c.execute("DELETE FROM users WHERE event_id=?", (linked_slug,))
                c.execute("DELETE FROM events WHERE slug=?", (linked_slug,))
                c.execute("DELETE FROM saas_events WHERE slug=?", (linked_slug,))
                c.execute("DELETE FROM event_submissions WHERE approved_event_slug=?", (linked_slug,))
                c.execute("DELETE FROM mobile_event_submissions WHERE approved_event_slug=?", (linked_slug,))
                c.execute("DELETE FROM jobs WHERE event_slug=?", (linked_slug,))
                c.execute("DELETE FROM mail_logs WHERE event_slug=?", (linked_slug,))
                c.execute("DELETE FROM qr_scans WHERE event_slug=?", (linked_slug,))
                c.execute("DELETE FROM photo_downloads WHERE event_slug=?", (linked_slug,))
                c.execute("DELETE FROM photo_attempts WHERE event_slug=?", (linked_slug,))
                c.execute("DELETE FROM event_account_frames WHERE event_slug=?", (linked_slug,))
                conn.commit()
                conn.close()
                last_err = None
                break
            except DBOperationalError as e:
                last_err = e
                try:
                    conn.close()
                except Exception:
                    pass
                if "locked" in str(e).lower():
                    time.sleep(0.15)
                    continue
                raise
        if last_err:
            return RedirectResponse("/admin/mobile?err=Talep silindi ancak bağlı etkinlik silinemedi (DB locked)", status_code=303)
        event_dir = os.path.join(EVENT_PHOTO_DIR, linked_slug)
        frame_dir = os.path.join(FRAME_DIR, linked_slug)
        try:
            if os.path.isdir(event_dir):
                shutil.rmtree(event_dir)
        except Exception:
            pass
        try:
            if os.path.isdir(frame_dir):
                shutil.rmtree(frame_dir)
        except Exception:
            pass
        try:
            qr_path = os.path.join(QR_DIR, f"{linked_slug}.png")
            if os.path.exists(qr_path):
                os.remove(qr_path)
        except Exception:
            pass
        for p in photo_paths:
            try:
                abs_path = os.path.join(ROOT_DIR, p) if p else ""
                if abs_path and os.path.exists(abs_path):
                    os.remove(abs_path)
            except Exception:
                pass
        for sp in selfie_paths:
            try:
                abs_path = os.path.join(ROOT_DIR, sp) if sp else ""
                if abs_path and os.path.exists(abs_path):
                    os.remove(abs_path)
            except Exception:
                pass

        woo_msg = ""
        if ext_source == "woo" and ext_event_id:
            wr = delete_woo_event_product(ext_event_id)
            if wr.get("ok"):
                woo_msg = " | Woo ürünü silindi"
            else:
                woo_msg = f" | Woo ürünü silinemedi: {wr.get('error')}"

        return RedirectResponse(f"/admin/mobile?msg=Talep ve bağlı fotoğraf etkinliği silindi{woo_msg}", status_code=303)

    return RedirectResponse("/admin/mobile?msg=Talep silindi", status_code=303)


@app.post("/admin/mobile/guest-lists/create", include_in_schema=False)
async def admin_mobile_guest_list_create(
    request: Request,
    name: str = Form(""),
    csrf_token: str = Form(...),
):
    _ = require_super_admin(request)
    try:
        verify_csrf_token(request, csrf_token)
    except HTTPException:
        return _csrf_refresh_redirect("/admin/mobile?tab=events&view=guest-lists&err=Oturum yenilendi, listeyi tekrar oluşturun")
    session_token = (request.cookies.get(SESSION_COOKIE) or "").strip()
    if not session_token:
        return RedirectResponse("/admin/mobile?tab=events&view=guest-lists&err=Oturum tokenı bulunamadı", status_code=303)
    list_name = (name or "").strip()
    if len(list_name) < 2:
        return RedirectResponse("/admin/mobile?tab=events&view=guest-lists&err=Liste adı çok kısa", status_code=303)
    res = mobile_backend_bearer_call("/profile/guest-lists", session_token, method="POST", json_data={"name": list_name})
    if not res.get("ok"):
        return RedirectResponse(
            f"/admin/mobile?tab=events&view=guest-lists&err={urllib.parse.quote(str(res.get('error') or 'Davetli listesi oluşturulamadı'))}",
            status_code=303,
        )
    data = res.get("data") or {}
    new_id = int((data.get("guest_list_id") or 0)) if isinstance(data, dict) else 0
    return RedirectResponse(
        f"/admin/mobile?tab=events&view=guest-lists&guest_list_id={new_id}&msg={urllib.parse.quote('Davetli listesi oluşturuldu')}",
        status_code=303,
    )


@app.post("/admin/mobile/guest-lists/{guest_list_id}/rename", include_in_schema=False)
async def admin_mobile_guest_list_rename(
    request: Request,
    guest_list_id: int,
    name: str = Form(""),
    csrf_token: str = Form(...),
):
    _ = require_super_admin(request)
    try:
        verify_csrf_token(request, csrf_token)
    except HTTPException:
        return _csrf_refresh_redirect(f"/admin/mobile?tab=events&view=guest-lists&guest_list_id={int(guest_list_id)}&err=Oturum yenilendi, listeyi tekrar kaydedin")
    session_token = (request.cookies.get(SESSION_COOKIE) or "").strip()
    if not session_token:
        return RedirectResponse("/admin/mobile?tab=events&view=guest-lists&err=Oturum tokenı bulunamadı", status_code=303)
    list_name = (name or "").strip()
    if len(list_name) < 2:
        return RedirectResponse(
            f"/admin/mobile?tab=events&view=guest-lists&guest_list_id={int(guest_list_id)}&err=Liste adı çok kısa",
            status_code=303,
        )
    res = mobile_backend_bearer_call(
        f"/profile/guest-lists/{int(guest_list_id)}",
        session_token,
        method="PATCH",
        json_data={"name": list_name},
    )
    if not res.get("ok"):
        return RedirectResponse(
            f"/admin/mobile?tab=events&view=guest-lists&guest_list_id={int(guest_list_id)}&err={urllib.parse.quote(str(res.get('error') or 'Davetli listesi güncellenemedi'))}",
            status_code=303,
        )
    return RedirectResponse(
        f"/admin/mobile?tab=events&view=guest-lists&guest_list_id={int(guest_list_id)}&msg={urllib.parse.quote('Davetli listesi güncellendi')}",
        status_code=303,
    )


@app.post("/admin/mobile/guest-lists/{guest_list_id}/delete", include_in_schema=False)
async def admin_mobile_guest_list_delete(
    request: Request,
    guest_list_id: int,
    csrf_token: str = Form(...),
):
    _ = require_super_admin(request)
    try:
        verify_csrf_token(request, csrf_token)
    except HTTPException:
        return _csrf_refresh_redirect(f"/admin/mobile?tab=events&view=guest-lists&guest_list_id={int(guest_list_id)}&err=Oturum yenilendi, listeyi tekrar silin")
    session_token = (request.cookies.get(SESSION_COOKIE) or "").strip()
    if not session_token:
        return RedirectResponse("/admin/mobile?tab=events&view=guest-lists&err=Oturum tokenı bulunamadı", status_code=303)
    res = mobile_backend_bearer_call(f"/profile/guest-lists/{int(guest_list_id)}", session_token, method="DELETE")
    if not res.get("ok"):
        return RedirectResponse(
            f"/admin/mobile?tab=events&view=guest-lists&guest_list_id={int(guest_list_id)}&err={urllib.parse.quote(str(res.get('error') or 'Davetli listesi silinemedi'))}",
            status_code=303,
        )
    return RedirectResponse(
        f"/admin/mobile?tab=events&view=guest-lists&msg={urllib.parse.quote('Davetli listesi silindi')}",
        status_code=303,
    )


@app.post("/admin/mobile/guest-lists/{guest_list_id}/members/add", include_in_schema=False)
async def admin_mobile_guest_list_add_member(
    request: Request,
    guest_list_id: int,
    account_id: int = Form(...),
    csrf_token: str = Form(...),
):
    _ = require_super_admin(request)
    try:
        verify_csrf_token(request, csrf_token)
    except HTTPException:
        return _csrf_refresh_redirect(f"/admin/mobile?tab=events&view=guest-lists&guest_list_id={int(guest_list_id)}&err=Oturum yenilendi, kullanıcıyı tekrar ekleyin")
    session_token = (request.cookies.get(SESSION_COOKIE) or "").strip()
    if not session_token:
        return RedirectResponse("/admin/mobile?tab=events&view=guest-lists&err=Oturum tokenı bulunamadı", status_code=303)
    res = mobile_backend_bearer_call(
        f"/profile/guest-lists/{int(guest_list_id)}/members",
        session_token,
        method="POST",
        json_data={"account_id": int(account_id)},
    )
    if not res.get("ok"):
        return RedirectResponse(
            f"/admin/mobile?tab=events&view=guest-lists&guest_list_id={int(guest_list_id)}&err={urllib.parse.quote(str(res.get('error') or 'Kullanıcı listeye eklenemedi'))}",
            status_code=303,
        )
    return RedirectResponse(
        f"/admin/mobile?tab=events&view=guest-lists&guest_list_id={int(guest_list_id)}&msg={urllib.parse.quote('Kullanıcı listeye eklendi')}",
        status_code=303,
    )


@app.post("/admin/mobile/guest-lists/{guest_list_id}/members/{account_id}/remove", include_in_schema=False)
async def admin_mobile_guest_list_remove_member(
    request: Request,
    guest_list_id: int,
    account_id: int,
    csrf_token: str = Form(...),
):
    _ = require_super_admin(request)
    try:
        verify_csrf_token(request, csrf_token)
    except HTTPException:
        return _csrf_refresh_redirect(f"/admin/mobile?tab=events&view=guest-lists&guest_list_id={int(guest_list_id)}&err=Oturum yenilendi, kullanıcıyı tekrar çıkarın")
    session_token = (request.cookies.get(SESSION_COOKIE) or "").strip()
    if not session_token:
        return RedirectResponse("/admin/mobile?tab=events&view=guest-lists&err=Oturum tokenı bulunamadı", status_code=303)
    res = mobile_backend_bearer_call(
        f"/profile/guest-lists/{int(guest_list_id)}/members/{int(account_id)}",
        session_token,
        method="DELETE",
    )
    if not res.get("ok"):
        return RedirectResponse(
            f"/admin/mobile?tab=events&view=guest-lists&guest_list_id={int(guest_list_id)}&err={urllib.parse.quote(str(res.get('error') or 'Kullanıcı listeden çıkarılamadı'))}",
            status_code=303,
        )
    return RedirectResponse(
        f"/admin/mobile?tab=events&view=guest-lists&guest_list_id={int(guest_list_id)}&msg={urllib.parse.quote('Kullanıcı listeden çıkarıldı')}",
        status_code=303,
    )


@app.post("/admin/mobile/submissions/{submission_id}/guest-lists/import", include_in_schema=False)
async def admin_mobile_import_guest_list_to_event(
    request: Request,
    submission_id: int,
    guest_list_id: int = Form(...),
    view: str = Form("active"),
    csrf_token: str = Form(...),
):
    _ = require_super_admin(request)
    try:
        verify_csrf_token(request, csrf_token)
    except HTTPException:
        return _csrf_refresh_redirect(f"/admin/mobile?tab=events&view={(view or 'active').strip()}&err=Oturum yenilendi, davetli listesini tekrar aktarın")
    session_token = (request.cookies.get(SESSION_COOKIE) or "").strip()
    if not session_token:
        return RedirectResponse("/admin/mobile?tab=events&err=Oturum tokenı bulunamadı", status_code=303)
    target_view = _normalize_admin_mobile_events_view(view)
    if target_view not in {"active", "hidden", "history"}:
        target_view = "active"
    res = mobile_backend_bearer_call(
        f"/events/manage/items/{int(submission_id)}/invitees/import-guest-list",
        session_token,
        method="POST",
        json_data={"guest_list_id": int(guest_list_id)},
    )
    if not res.get("ok"):
        return RedirectResponse(
            f"/admin/mobile?tab=events&view={target_view}&err={urllib.parse.quote(str(res.get('error') or 'Davetli listesi etkinliğe aktarılamadı'))}",
            status_code=303,
        )
    data = res.get("data") or {}
    imported_count = int((data.get("imported_count") or 0)) if isinstance(data, dict) else 0
    existing_count = int((data.get("existing_count") or 0)) if isinstance(data, dict) else 0
    ticket_created_count = int((data.get("ticket_created_count") or 0)) if isinstance(data, dict) else 0
    guest_list_name = (data.get("guest_list_name") or "Davetli listesi").strip() if isinstance(data, dict) else "Davetli listesi"
    msg = f"{guest_list_name} aktarıldı. {imported_count} yeni davetli, {ticket_created_count} QR bilet hazırlandı"
    if existing_count > 0:
        msg += f", {existing_count} kişi zaten davetliydi"
    return RedirectResponse(
        f"/admin/mobile?tab=events&view={target_view}&msg={urllib.parse.quote(msg)}",
        status_code=303,
    )


@app.post("/admin/mobile/submissions/{submission_id}/invitees/{account_id}/remove", include_in_schema=False)
async def admin_mobile_remove_event_invitee(
    request: Request,
    submission_id: int,
    account_id: int,
    view: str = Form("active"),
    csrf_token: str = Form(...),
):
    _ = require_super_admin(request)
    try:
        verify_csrf_token(request, csrf_token)
    except HTTPException:
        return _csrf_refresh_redirect(f"/admin/mobile?tab=events&view={(view or 'active').strip()}&err=Oturum yenilendi, davetliyi tekrar çıkarın")
    session_token = (request.cookies.get(SESSION_COOKIE) or "").strip()
    if not session_token:
        return RedirectResponse("/admin/mobile?tab=events&err=Oturum tokenı bulunamadı", status_code=303)
    target_view = _normalize_admin_mobile_events_view(view)
    if target_view not in {"active", "hidden", "history"}:
        target_view = "active"
    res = mobile_backend_bearer_call(
        f"/events/manage/items/{int(submission_id)}/invitees/{int(account_id)}",
        session_token,
        method="DELETE",
    )
    if not res.get("ok"):
        return RedirectResponse(
            f"/admin/mobile?tab=events&view={target_view}&err={urllib.parse.quote(str(res.get('error') or 'Davetli çıkarılamadı'))}",
            status_code=303,
        )
    return RedirectResponse(
        f"/admin/mobile?tab=events&view={target_view}&msg={urllib.parse.quote('Davetli etkinlikten çıkarıldı')}",
        status_code=303,
    )


@app.post("/admin/mobile/submissions/{submission_id}/copy", include_in_schema=False)
async def admin_mobile_copy_submission(
    request: Request,
    submission_id: int,
    csrf_token: str = Form(...),
):
    _ = require_super_admin(request)
    try:
        verify_csrf_token(request, csrf_token)
    except HTTPException:
        return _csrf_refresh_redirect("/admin/mobile?tab=events&err=Oturum yenilendi, etkinliği tekrar kopyalayın")

    session_token = (request.cookies.get(SESSION_COOKIE) or "").strip()
    if not session_token:
        return RedirectResponse("/admin/mobile?tab=events&err=Oturum tokenı bulunamadı", status_code=303)

    conn = db_conn()
    c = conn.cursor()
    c.execute(
        """
        SELECT
            COALESCE(event_name,'') AS event_name,
            COALESCE(description,'') AS description,
            COALESCE(event_date,'') AS event_date,
            COALESCE(venue,'') AS venue,
            COALESCE(venue_map_url,'') AS venue_map_url,
            COALESCE(city,'') AS city,
            COALESCE(event_kind,'dance_night') AS event_kind,
            COALESCE(dance_styles,'') AS dance_styles,
            COALESCE(ticket_sales_enabled, FALSE) AS ticket_sales_enabled,
            COALESCE(create_photo_album, FALSE) AS create_photo_album,
            COALESCE(organizer_name,'') AS organizer_name,
            COALESCE(program_text,'') AS program_text,
            COALESCE(start_at,'') AS start_at,
            COALESCE(end_at,'') AS end_at,
            COALESCE(entry_fee,0) AS entry_fee,
            COALESCE(cover_path,'') AS cover_path
        FROM mobile_event_submissions
        WHERE id=?
        LIMIT 1
        """,
        (int(submission_id),),
    )
    row = c.fetchone()
    conn.close()
    if not row:
        return RedirectResponse("/admin/mobile?tab=events&err=Kopyalanacak etkinlik bulunamadı", status_code=303)

    payload = {
        "event_name": (row["event_name"] or "").strip(),
        "description": (row["description"] or "").strip(),
        "event_date": (row["event_date"] or "").strip(),
        "venue": (row["venue"] or "").strip(),
        "venue_map_url": (row["venue_map_url"] or "").strip(),
        "city": (row["city"] or "").strip(),
        "event_kind": (row["event_kind"] or "dance_night").strip().lower(),
        "dance_styles": (row["dance_styles"] or "").strip(),
        "ticket_sales_enabled": "1" if _boolish(row.get("ticket_sales_enabled"), default=False) else "0",
        "create_photo_album": "1" if _boolish(row.get("create_photo_album"), default=False) else "0",
        "repeat_mode": "none",
        "repeat_weekly": "0",
        "repeat_weekday": "",
        "repeat_selected_dates": "",
        "organizer_name": (row["organizer_name"] or "").strip(),
        "program_text": (row["program_text"] or "").strip(),
        "start_at": (row["start_at"] or "").strip(),
        "end_at": (row["end_at"] or "").strip(),
        "entry_fee": str(row["entry_fee"] or 0),
        "clone_attendees_from_submission_id": str(int(submission_id)),
    }

    cover_path = (row["cover_path"] or "").strip()
    if cover_path and os.path.exists(cover_path):
        try:
            with open(cover_path, "rb") as fh:
                raw = fh.read()
            content_type = (mimetypes.guess_type(cover_path)[0] or "application/octet-stream").strip()
            res = mobile_backend_bearer_multipart_call(
                "/events/submissions",
                session_token,
                fields=payload,
                files=[
                    {
                        "field": "cover_image",
                        "filename": os.path.basename(cover_path) or "event-cover.jpg",
                        "content_type": content_type,
                        "content": raw,
                    }
                ],
            )
        except Exception:
            res = mobile_backend_bearer_form_call("/events/submissions", session_token, method="POST", data=payload)
    else:
        res = mobile_backend_bearer_form_call("/events/submissions", session_token, method="POST", data=payload)

    if not res.get("ok"):
        return RedirectResponse(
            f"/admin/mobile?tab=events&err={urllib.parse.quote('Etkinlik kopyalanamadı: ' + str(res.get('error') or 'bilinmeyen hata'))}",
            status_code=303,
        )

    data = res.get("data") or {}
    new_submission_id = int((data.get("submission_id") or 0)) if isinstance(data, dict) else 0
    msg = f"Etkinlik kopyalandı: #{new_submission_id}. Tarihi düzenleyip onaylayabilirsiniz."
    return RedirectResponse(f"/admin/mobile?tab=events&view=requests&msg={urllib.parse.quote(msg)}", status_code=303)


@app.post("/admin/mobile/submissions/{submission_id}/update", include_in_schema=False)
async def admin_mobile_update_submission(
    request: Request,
    submission_id: int,
    source_table: str = Form("mobile_event_submissions"),
    event_name: str = Form(""),
    event_date: str = Form(""),
    description: str = Form(""),
    venue: str = Form(""),
    venue_map_url: str = Form(""),
    city: str = Form(""),
    event_kind: str = Form(""),
    organizer_name: str = Form(""),
    program_text: str = Form(""),
    start_at: str = Form(""),
    end_at: str = Form(""),
    entry_fee: str = Form("0"),
    ticket_sales_enabled: Optional[str] = Form(None),
    woo_product_id: str = Form(""),
    ticket_url: str = Form(""),
    cover_image: Optional[UploadFile] = File(None),
    csrf_token: str = Form(...),
):
    _ = require_super_admin(request)
    try:
        verify_csrf_token(request, csrf_token)
    except HTTPException:
        return _csrf_refresh_redirect("/admin/mobile?tab=events&err=Oturum yenilendi, etkinliği tekrar kaydedin")

    source_table = (source_table or "").strip().lower()
    if source_table not in ("event_submissions", "mobile_event_submissions"):
        source_table = "mobile_event_submissions"

    ev_name = (event_name or "").strip()
    if len(ev_name) < 2:
        return RedirectResponse("/admin/mobile?err=Etkinlik adı çok kısa", status_code=303)

    try:
        fee_val = float((entry_fee or "0").replace(",", "."))
    except Exception:
        return RedirectResponse("/admin/mobile?err=Geçersiz ücret", status_code=303)
    ticket_sales_enabled_val = _boolish(ticket_sales_enabled, default=False)
    woo_product_id_val = (woo_product_id or "").strip()
    ticket_url_val = (ticket_url or "").strip()
    if ticket_url_val and not (ticket_url_val.startswith("http://") or ticket_url_val.startswith("https://")):
        return RedirectResponse("/admin/mobile?err=Bilet linki http:// veya https:// ile başlamalı", status_code=303)

    conn = db_conn()
    c = conn.cursor()
    try:
        if source_table == "mobile_event_submissions":
            backend_payload = {
                "event_name": ev_name,
                "event_date": (event_date or "").strip(),
                "description": (description or "").strip(),
                "venue": (venue or "").strip(),
                "venue_map_url": (venue_map_url or "").strip(),
                "city": (city or "").strip(),
                "event_kind": (event_kind or "").strip(),
                "organizer_name": (organizer_name or "").strip(),
                "program_text": (program_text or "").strip(),
                "start_at": (start_at or event_date or "").strip(),
                "end_at": (end_at or event_date or "").strip(),
                "entry_fee": fee_val,
                "ticket_sales_enabled": "1" if ticket_sales_enabled_val else "0",
            }
            if woo_product_id_val:
                backend_payload["woo_product_id"] = woo_product_id_val
            if ticket_url_val:
                backend_payload["ticket_url"] = ticket_url_val
            if cover_image and getattr(cover_image, "filename", ""):
                raw = await cover_image.read()
                backend_update = mobile_backend_admin_multipart_call(
                    f"/admin/events/items/{int(submission_id)}/update",
                    fields=backend_payload,
                    files=[
                        {
                            "field": "cover_image",
                            "filename": (cover_image.filename or "event-cover.jpg"),
                            "content_type": (cover_image.content_type or "application/octet-stream"),
                            "content": raw,
                        }
                    ],
                )
            else:
                backend_update = mobile_backend_admin_call(
                    f"/admin/events/items/{int(submission_id)}/update",
                    method="POST",
                    data=backend_payload,
                )
            if not backend_update.get("ok"):
                conn.close()
                return RedirectResponse(
                    f"/admin/mobile?err={urllib.parse.quote('Backend güncellemesi başarısız: ' + str(backend_update.get('error'))[:300])}",
                    status_code=303,
                )
            c.execute(
                "SELECT approved_event_slug FROM mobile_event_submissions WHERE id=? LIMIT 1",
                (int(submission_id),),
            )
            row = c.fetchone()
            if not row:
                conn.close()
                return RedirectResponse("/admin/mobile?err=Talep bulunamadı", status_code=303)
            linked_slug = (row["approved_event_slug"] or "").strip() if "approved_event_slug" in row.keys() else ""

            c.execute(
                """
                UPDATE mobile_event_submissions
                SET event_name=?,
                    event_date=?,
                    description=?,
                    venue=?,
                    venue_map_url=?,
                    city=?,
                    event_kind=?,
                    organizer_name=?,
                    program_text=?,
                    start_at=?,
                    end_at=?,
                    entry_fee=?,
                    ticket_sales_enabled=?
                WHERE id=?
                """,
                (
                    ev_name,
                    (event_date or "").strip(),
                    (description or "").strip(),
                    (venue or "").strip(),
                    (venue_map_url or "").strip(),
                    (city or "").strip(),
                    (event_kind or "").strip(),
                    (organizer_name or "").strip(),
                    (program_text or "").strip(),
                    (start_at or event_date or "").strip(),
                    (end_at or event_date or "").strip(),
                    fee_val,
                    ticket_sales_enabled_val,
                    int(submission_id),
                ),
            )
        else:
            c.execute(
                "SELECT approved_event_slug FROM event_submissions WHERE id=? LIMIT 1",
                (int(submission_id),),
            )
            row = c.fetchone()
            if not row:
                conn.close()
                return RedirectResponse("/admin/mobile?err=Talep bulunamadı", status_code=303)
            linked_slug = (row["approved_event_slug"] or "").strip() if "approved_event_slug" in row.keys() else ""

            c.execute(
                """
                UPDATE event_submissions
                SET event_name=?,
                    description=?,
                    start_at=?,
                    end_at=?,
                    entry_fee=?
                WHERE id=?
                """,
                (
                    ev_name,
                    (description or "").strip(),
                    (start_at or "").strip(),
                    (end_at or "").strip(),
                    fee_val,
                    int(submission_id),
                ),
            )

        if linked_slug:
            c.execute("UPDATE saas_events SET name=? WHERE slug=?", (ev_name, linked_slug))
            if woo_product_id_val or ticket_url_val:
                if woo_product_id_val:
                    woo_sync = set_woo_event_product_publish_state(
                        woo_product_id_val,
                        publish=ticket_sales_enabled_val,
                    )
                    if not woo_sync.get("ok"):
                        conn.close()
                        action_label = "yayına alınamadı" if ticket_sales_enabled_val else "satışa kapatılamadı"
                        return RedirectResponse(
                            f"/admin/mobile?err={urllib.parse.quote('Woo ürünü ' + action_label + ': ' + str(woo_sync.get('error'))[:300])}",
                            status_code=303,
                        )
                    woo_product_id_val = str(woo_sync.get("woo_id") or woo_product_id_val).strip()
                    synced_ticket_url = str(woo_sync.get("ticket_url") or "").strip()
                    if synced_ticket_url:
                        ticket_url_val = synced_ticket_url
                c.execute(
                    """
                    UPDATE saas_events
                    SET external_source=?,
                        external_event_id=?,
                        ticket_url=?
                    WHERE slug=?
                    """,
                    ("woo", woo_product_id_val or None, ticket_url_val or None, linked_slug),
                )

        conn.commit()
        conn.close()
        _invalidate_admin_event_cache()
        return RedirectResponse("/admin/mobile?msg=Etkinlik bilgileri güncellendi", status_code=303)
    except Exception as e:
        conn.rollback()
        conn.close()
        return RedirectResponse(f"/admin/mobile?err={urllib.parse.quote(str(e)[:300])}", status_code=303)


@app.post("/admin/mobile/submissions/{submission_id}/active", include_in_schema=False)
async def admin_mobile_set_submission_active(
    request: Request,
    submission_id: int,
    source_table: str = Form("mobile_event_submissions"),
    is_active: str = Form("1"),
    csrf_token: str = Form(...),
):
    _ = require_super_admin(request)
    try:
        verify_csrf_token(request, csrf_token)
    except HTTPException:
        return _csrf_refresh_redirect("/admin/mobile?tab=events&err=Oturum yenilendi, tekrar deneyin")

    source_table = (source_table or "").strip().lower()
    if source_table != "mobile_event_submissions":
        return RedirectResponse("/admin/mobile?tab=events&err=Bu etkinlik türü pasife alma işlemini desteklemiyor", status_code=303)

    active_flag = (is_active or "").strip().lower() in {"1", "true", "yes", "on"}
    res = mobile_backend_admin_call(
        f"/admin/events/items/{int(submission_id)}/update",
        method="POST",
        data={"is_active": "1" if active_flag else "0"},
    )
    if not res.get("ok"):
        return RedirectResponse(
            f"/admin/mobile?tab=events&err={urllib.parse.quote('Etkinlik durumu güncellenemedi: ' + str(res.get('error'))[:300])}",
            status_code=303,
        )

    conn = None
    try:
        conn = db_conn()
        c = conn.cursor()
        c.execute(
            "SELECT approved_event_slug FROM mobile_event_submissions WHERE id=? LIMIT 1",
            (int(submission_id),),
        )
        row = c.fetchone()
        slug = (row["approved_event_slug"] or "").strip() if row and "approved_event_slug" in row.keys() else ""
        if slug:
            c.execute("UPDATE saas_events SET is_active=? WHERE slug=?", (1 if active_flag else 0, slug))
        conn.commit()
        conn.close()
    except Exception:
        try:
            if conn:
                conn.rollback()
                conn.close()
        except Exception:
            pass

    _invalidate_admin_event_cache()
    msg = "Etkinlik aktifleştirildi" if active_flag else "Etkinlik pasife alındı"
    return RedirectResponse(f"/admin/mobile?tab=events&msg={urllib.parse.quote(msg)}", status_code=303)


@app.post("/admin/mobile/submissions/{submission_id}/scan-permissions/grant", include_in_schema=False)
async def admin_mobile_grant_scan_permission(
    request: Request,
    submission_id: int,
    account_id: int = Form(...),
    csrf_token: str = Form(...),
):
    _ = require_super_admin(request)
    try:
        verify_csrf_token(request, csrf_token)
    except HTTPException:
        return _csrf_refresh_redirect("/admin/mobile?tab=events&err=Oturum yenilendi, tekrar editör atayın")
    res = mobile_backend_admin_call(
        f"/admin/events/{int(submission_id)}/scan-permissions/grant",
        method="POST",
        data={"account_id": int(account_id)},
    )
    if not res.get("ok"):
        return RedirectResponse(f"/admin/mobile?err={urllib.parse.quote('Yetki verilemedi: ' + str(res.get('error')))}", status_code=303)
    return RedirectResponse("/admin/mobile?msg=Etkinlik editör yetkisi verildi", status_code=303)


@app.post("/admin/mobile/submissions/{submission_id}/scan-permissions/revoke", include_in_schema=False)
async def admin_mobile_revoke_scan_permission(
    request: Request,
    submission_id: int,
    account_id: int = Form(...),
    csrf_token: str = Form(...),
):
    _ = require_super_admin(request)
    try:
        verify_csrf_token(request, csrf_token)
    except HTTPException:
        return _csrf_refresh_redirect("/admin/mobile?tab=events&err=Oturum yenilendi, tekrar deneyin")
    res = mobile_backend_admin_call(
        f"/admin/events/{int(submission_id)}/scan-permissions/revoke",
        method="POST",
        data={"account_id": int(account_id)},
    )
    if not res.get("ok"):
        return RedirectResponse(f"/admin/mobile?err={urllib.parse.quote('Yetki kaldırılamadı: ' + str(res.get('error')))}", status_code=303)
    return RedirectResponse("/admin/mobile?msg=Etkinlik editör yetkisi kaldırıldı", status_code=303)


@app.post("/admin/mobile/news/{submission_id}/approve", include_in_schema=False)
async def admin_mobile_approve_news_submission(
    request: Request,
    submission_id: int,
    admin_note: str = Form(""),
    csrf_token: str = Form(...),
):
    _ = require_super_admin(request)
    verify_csrf_token(request, csrf_token)
    res = mobile_backend_admin_call(
        f"/admin/news/submissions/{int(submission_id)}/approve",
        method="POST",
        data={"admin_note": (admin_note or "").strip()},
    )
    if not res.get("ok"):
        return RedirectResponse(
            f"/admin/mobile?tab=news&err={urllib.parse.quote('Haber onaylanamadı: ' + str(res.get('error')))}",
            status_code=303,
        )
    _invalidate_admin_news_cache()
    data = res.get("data") or {}
    wp_url = (data.get("wp_post_url") or "").strip() if isinstance(data, dict) else ""
    msg = "Haber onaylandı ve WP'de yayınlandı"
    if wp_url:
        msg += f" | {wp_url}"
    return RedirectResponse(f"/admin/mobile?tab=news&msg={urllib.parse.quote(msg)}", status_code=303)


@app.post("/admin/mobile/news/{submission_id}/reject", include_in_schema=False)
async def admin_mobile_reject_news_submission(
    request: Request,
    submission_id: int,
    admin_note: str = Form(""),
    csrf_token: str = Form(...),
):
    _ = require_super_admin(request)
    verify_csrf_token(request, csrf_token)
    res = mobile_backend_admin_call(
        f"/admin/news/submissions/{int(submission_id)}/reject",
        method="POST",
        data={"admin_note": (admin_note or "").strip()},
    )
    if not res.get("ok"):
        return RedirectResponse(
            f"/admin/mobile?tab=news&err={urllib.parse.quote('Haber reddedilemedi: ' + str(res.get('error')))}",
            status_code=303,
        )
    _invalidate_admin_news_cache()
    return RedirectResponse("/admin/mobile?tab=news&msg=Haber reddedildi", status_code=303)


@app.post("/admin/mobile/news/{submission_id}/delete", include_in_schema=False)
async def admin_mobile_delete_news_submission(
    request: Request,
    submission_id: int,
    csrf_token: str = Form(...),
):
    _ = require_super_admin(request)
    verify_csrf_token(request, csrf_token)
    res = mobile_backend_admin_call(
        f"/admin/news/submissions/{int(submission_id)}/delete",
        method="POST",
    )
    if not res.get("ok"):
        return RedirectResponse(
            f"/admin/mobile?tab=news&err={urllib.parse.quote('Haber silinemedi: ' + str(res.get('error')))}",
            status_code=303,
        )
    _invalidate_admin_news_cache()
    return RedirectResponse("/admin/mobile?tab=news&msg=Haber silindi", status_code=303)


@app.get("/console/event/{slug}/qr.png")
async def console_event_qr(request: Request, slug: str):
    r = require_console_access(request)
    if isinstance(r, RedirectResponse):
        return r

    url = f"{PUBLIC_BASE_URL}/e/{slug}"
    out_path = os.path.join(QR_DIR, f"{slug}.png")

    if not os.path.exists(out_path):
        img = qrcode.make(url)
        img.save(out_path)

    return FileResponse(out_path, media_type="image/png")


@app.get("/qr/{slug}.png")
async def public_event_qr(slug: str):
    url = f"{PUBLIC_BASE_URL}/e/{slug}"
    out_path = os.path.join(QR_DIR, f"{slug}.png")

    if not os.path.exists(out_path):
        img = qrcode.make(url)
        img.save(out_path)

    return FileResponse(out_path, media_type="image/png")


@app.get("/media-thumb/{file_path:path}")
async def media_thumb(file_path: str, w: int = 360):
    max_side = max(120, min(int(w or 360), 1600))
    src_path = _safe_media_abs_path(file_path)
    if not os.path.exists(src_path) or not os.path.isfile(src_path):
        raise HTTPException(status_code=404, detail="Görsel bulunamadı")
    response_headers = {"Cache-Control": "public, max-age=2592000, immutable"}

    out_path = _thumb_cache_path(file_path, max_side)
    src_mtime = int(os.path.getmtime(src_path))
    if os.path.exists(out_path):
        try:
            if int(os.path.getmtime(out_path)) >= src_mtime:
                return FileResponse(out_path, media_type="image/jpeg", headers=response_headers)
        except Exception:
            pass

    try:
        img = Image.open(src_path)
        img = ImageOps.exif_transpose(img)
        if img.mode not in ("RGB", "L"):
            img = img.convert("RGB")
        elif img.mode == "L":
            img = img.convert("RGB")
        img = _resize_image(img, max_side=max_side)
        os.makedirs(os.path.dirname(out_path), exist_ok=True)
        quality = 74 if max_side <= 420 else 82
        img.save(out_path, format="JPEG", quality=quality, optimize=True, progressive=True)
    except FileNotFoundError:
        raise HTTPException(status_code=404, detail="Görsel bulunamadı")
    except HTTPException:
        raise
    except Exception:
        raise HTTPException(status_code=500, detail="Önizleme oluşturulamadı")

    return FileResponse(out_path, media_type="image/jpeg", headers=response_headers)


@app.get("/console/event/{slug}", response_class=HTMLResponse)
async def console_event_detail(
    request: Request,
    slug: str,
    tab: Optional[str] = None,
    mail_filter: Optional[str] = None,
    mail_page: Optional[int] = None,
    jobs_filter: Optional[str] = None,
    page: Optional[int] = None,
):
    r = require_console_access(request)
    if isinstance(r, RedirectResponse):
        return r
    admin_acc = r
    msg = request.query_params.get("msg")
    err = request.query_params.get("err")

    conn = db_conn()
    c = conn.cursor()

    c.execute("""
        SELECT
            se.slug, se.name, se.created_at,
            se.frame_landscape, se.frame_portrait, se.frame_square,
            se.external_source, se.external_event_id, se.ticket_url,
            COALESCE(se.album_enabled, TRUE) AS album_enabled,
            a.email AS owner_email
        FROM saas_events se
        JOIN accounts a ON a.id = se.account_id
        WHERE se.slug=?
        LIMIT 1
    """, (slug,))
    event = c.fetchone()

    if not event:
        conn.close()
        return RedirectResponse("/console?err=Etkinlik bulunamadı", status_code=302)
    if not bool(event["album_enabled"]):
        conn.close()
        return RedirectResponse("/console?err=Bu etkinlik için fotoğraf albümü kapalı", status_code=302)
    frame_paths = get_event_account_frames(slug, int(admin_acc["id"]))

    page_num = int(page or 1)
    if page_num < 1:
        page_num = 1
    per_page = 25
    photos_page = list_event_photos_for_slug_with_match_counts(slug, limit=per_page, offset=(page_num - 1) * per_page)
    photos = photos_page["items"]
    total_photos_all = photos_page["total"]

    attendees = []

    # stats
    total_users = 0
    c.execute("SELECT COUNT(*) AS cnt FROM event_photos WHERE event_id=?", (slug,))
    total_photos = int(c.fetchone()["cnt"])
    total_matches = 0
    if (jobs_filter or "").lower() == "all":
        c.execute("""
            SELECT id, pid, action, uploaded_count, processed_count, match_count, status, message, created_at, finished_at
            FROM jobs
            WHERE event_slug=?
            ORDER BY id DESC
            LIMIT 200
        """, (slug,))
        jobs = c.fetchall()
        c.execute("SELECT COUNT(*) AS cnt FROM jobs WHERE event_slug=? AND status='running'", (slug,))
        running_jobs = int(c.fetchone()["cnt"])
        c.execute("""
            SELECT id, action, status, created_at, finished_at, message
            FROM jobs
            WHERE event_slug=?
            ORDER BY id DESC
            LIMIT 1
        """, (slug,))
        last_job = c.fetchone()
    else:
        c.execute("""
            SELECT id, pid, action, uploaded_count, processed_count, match_count, status, message, created_at, finished_at
            FROM jobs
            WHERE event_slug=? AND action IN ('upload_only', 'console_upload_only')
            ORDER BY id DESC
            LIMIT 200
        """, (slug,))
        jobs = c.fetchall()
        c.execute("""
            SELECT COUNT(*) AS cnt FROM jobs
            WHERE event_slug=? AND status='running' AND action IN ('upload_only', 'console_upload_only')
        """, (slug,))
        running_jobs = int(c.fetchone()["cnt"])
        c.execute("""
            SELECT id, action, status, created_at, finished_at, message
            FROM jobs
            WHERE event_slug=? AND action IN ('upload_only', 'console_upload_only')
            ORDER BY id DESC
            LIMIT 1
        """, (slug,))
        last_job = c.fetchone()
    conn.close()

    batches = list_upload_batches_for_event(slug, limit=300)
    subalbums = list_event_subalbums(slug)
    qr_target = f"{PUBLIC_BASE_URL}/e/{slug}"
    qr_img = f"/console/event/{slug}/qr.png"
    proc_settings = get_event_processing_settings(slug)
    qr_scans = count_qr_scans(slug)
    download_count = count_photo_downloads(slug)
    mail_page_num = int(mail_page or 1)
    if mail_page_num < 1:
        mail_page_num = 1
    mail_per_page = 25
    mail_logs, mail_total = list_mail_logs(
        slug,
        limit=mail_per_page,
        offset=(mail_page_num - 1) * mail_per_page,
        status=mail_filter,
        with_total=True,
    )
    mail_total_pages = (mail_total // mail_per_page) + (1 if (mail_total % mail_per_page) > 0 else 0)

    attendee_rows = []
    for row in attendees:
        token = row["gallery_token"]
        gallery_url = f"{BASE_GALLERY_URL}{token}" if token else ""
        attendee_rows.append(
            (
                row["id"], row["name"], row["email"], row["selfie_path"], row["created_at"],
                token, gallery_url, int(row["match_count"] or 0)
            )
        )

    return render_template(
        request,
        "console_event.html",
        {
            "request": request,
            "active": "events",
            "header": "Albüm Düzenle",
            "owner_email": event["owner_email"],
            "event": event,
            "tab": tab or "media",
            "message": msg,
            "error": err,
            "slug": slug,
            "qr_target": qr_target,
            "qr_img": qr_img,
            "photos": photos,
            "batches": batches,
            "subalbums": subalbums,
            "page": page_num,
            "per_page": per_page,
            "total_photos_all": total_photos_all,
            "attendees": attendee_rows,
            "total_users": total_users,
            "total_photos": total_photos,
            "total_matches": total_matches,
            "running_jobs": running_jobs,
            "last_job": last_job,
            "jobs": jobs,
            "mail_logs": mail_logs,
            "mail_filter": mail_filter or "",
            "mail_page": mail_page_num,
            "mail_total_pages": mail_total_pages,
            "mail_total": mail_total,
            "report_total_users": total_users,
            "report_total_photos": total_photos,
            "report_total_matches": total_matches,
            "report_qr_scans": qr_scans,
            "report_downloads": download_count,
            "frame_ratio_1_1": frame_paths["ratio_1_1"],
            "frame_ratio_3_2": frame_paths["ratio_3_2"],
            "frame_ratio_2_3": frame_paths["ratio_2_3"],
            "frame_ratio_3_4": frame_paths["ratio_3_4"],
            "frame_ratio_4_3": frame_paths["ratio_4_3"],
            "frame_landscape": frame_paths["landscape"],
            "frame_portrait": frame_paths["portrait"],
            "frame_square": frame_paths["square"],
            "upload_batch_max_files": int(UPLOAD_BATCH_MAX_FILES),
            "processing_target_kb": int(proc_settings["target_kb"]),
            "processing_max_side": int(proc_settings["max_side"]),
        },
        csrf=True,
    )


@app.post("/console/event/{slug}/subalbums/create", include_in_schema=False)
async def console_event_subalbum_create(request: Request, slug: str):
    acc = require_super_admin(request)
    form = await request.form()
    verify_csrf_token(request, form.get(CSRF_PARAM))
    res = create_event_subalbum(slug, form.get("subalbum_name") or "", int(acc["id"]))
    if not res.get("ok"):
        return RedirectResponse(f"/console/event/{slug}?err={urllib.parse.quote(str(res.get('error') or 'Alt albüm oluşturulamadı'))}", status_code=302)
    msg = "Alt albüm oluşturuldu" if not res.get("existing") else "Alt albüm zaten vardı"
    return RedirectResponse(f"/console/event/{slug}?msg={urllib.parse.quote(msg)}", status_code=302)


@app.post("/console/event/{slug}/jobs/{job_id}/subalbum", include_in_schema=False)
async def console_event_job_subalbum_update(request: Request, slug: str, job_id: int):
    _ = require_super_admin(request)
    form = await request.form()
    verify_csrf_token(request, form.get(CSRF_PARAM))
    subalbum_id_raw = (form.get("subalbum_id") or "").strip()
    subalbum_id = int(subalbum_id_raw) if subalbum_id_raw.isdigit() and int(subalbum_id_raw) > 0 else None
    res = set_job_subalbum(slug, int(job_id), subalbum_id)
    if not res.get("ok"):
        return RedirectResponse(f"/console/event/{slug}?err={urllib.parse.quote(str(res.get('error') or 'Alt albüm güncellenemedi'))}", status_code=302)
    msg = "Paket ana albüme taşındı" if not subalbum_id else "Paket alt albüme bağlandı"
    return RedirectResponse(f"/console/event/{slug}?msg={urllib.parse.quote(msg)}", status_code=302)


@app.get("/console/event/{slug}/batch/{job_id}", response_class=HTMLResponse, include_in_schema=False)
async def console_event_batch_detail(
    request: Request,
    slug: str,
    job_id: int,
    page: Optional[int] = None,
):
    r = require_console_access(request)
    if isinstance(r, RedirectResponse):
        return r
    msg = request.query_params.get("msg")
    err = request.query_params.get("err")

    conn = db_conn()
    c = conn.cursor()
    c.execute(
        """
        SELECT se.slug, se.name, a.email AS owner_email
        FROM saas_events se
        JOIN accounts a ON a.id = se.account_id
        WHERE se.slug=?
        LIMIT 1
        """,
        (slug,),
    )
    event = c.fetchone()
    c.execute(
        """
        SELECT id, pid, status, created_at, finished_at, uploaded_count,
               COALESCE(match_start,0) AS match_start, COALESCE(match_end,0) AS match_end
        FROM jobs
        WHERE id=? AND event_slug=? AND action IN ('upload_only','console_upload_only')
        LIMIT 1
        """,
        (int(job_id), slug),
    )
    job = c.fetchone()
    conn.close()
    if not event:
        return RedirectResponse("/console?err=Albüm bulunamadı", status_code=302)
    if not job:
        return RedirectResponse(f"/console/event/{slug}?err=Yükleme paketi bulunamadı", status_code=302)

    page_num = int(page or 1)
    if page_num < 1:
        page_num = 1
    per_page = 40
    batch = list_photos_for_upload_batch(slug, int(job_id), limit=per_page, offset=(page_num - 1) * per_page)
    if not batch.get("found"):
        return RedirectResponse(f"/console/event/{slug}?err=Yükleme paketi bulunamadı", status_code=302)

    return render_template(
        request,
        "console_batch.html",
        {
            "request": request,
            "active": "events",
            "header": "Yükleme Paketi",
            "title": "Yükleme Paketi",
            "owner_email": event["owner_email"],
            "event_slug": slug,
            "event_name": event["name"],
            "job": job,
            "photos": batch["items"],
            "total_photos": int(batch["total"]),
            "page": page_num,
            "per_page": per_page,
            "message": msg,
            "error": err,
        },
        csrf=True,
    )


@app.post("/console/event/{slug}/batch/{job_id}/delete", include_in_schema=False)
async def console_event_batch_delete(
    request: Request,
    slug: str,
    job_id: int,
    csrf_token: str = Form(...),
):
    _ = require_super_admin(request)
    verify_csrf_token(request, csrf_token)

    conn = db_conn()
    c = conn.cursor()
    c.execute(
        """
        SELECT COALESCE(match_start,0) AS match_start, COALESCE(match_end,0) AS match_end
        FROM jobs
        WHERE id=? AND event_slug=? AND action IN ('upload_only','console_upload_only')
        LIMIT 1
        """,
        (int(job_id), slug),
    )
    row = c.fetchone()
    if not row:
        conn.close()
        return RedirectResponse(f"/console/event/{slug}?err=Yükleme paketi bulunamadı", status_code=302)
    match_start = int(row["match_start"] or 0)
    match_end = int(row["match_end"] or 0)
    if match_end <= match_start:
        c.execute("DELETE FROM jobs WHERE id=? AND event_slug=?", (int(job_id), slug))
        conn.commit()
        conn.close()
        return RedirectResponse(f"/console/event/{slug}?msg=Paket kaydı silindi", status_code=302)

    c.execute(
        "SELECT id, file_path FROM event_photos WHERE event_id=? AND id>? AND id<=?",
        (slug, match_start, match_end),
    )
    rows = c.fetchall() or []
    photo_ids = [int(r["id"]) for r in rows if r and r["id"] is not None]
    file_paths = [str(r["file_path"] or "") for r in rows if r and (r["file_path"] or "")]

    if photo_ids:
        for pid in photo_ids:
            c.execute("DELETE FROM photo_matches WHERE photo_id=?", (int(pid),))
        c.execute("DELETE FROM event_photos WHERE event_id=? AND id>? AND id<=?", (slug, match_start, match_end))
    c.execute("DELETE FROM jobs WHERE id=? AND event_slug=?", (int(job_id), slug))
    conn.commit()
    conn.close()

    for rel in file_paths:
        try:
            abs_path = os.path.join(ROOT_DIR, rel) if not os.path.isabs(rel) else rel
            if abs_path and os.path.exists(abs_path):
                os.remove(abs_path)
        except Exception:
            pass
    return RedirectResponse(f"/console/event/{slug}?msg=Yükleme paketi silindi", status_code=302)


@app.post("/console/event/{slug}/rename", include_in_schema=False)
async def console_rename_event(request: Request, slug: str, name: str = Form(...), csrf_token: str = Form(...)):
    r = require_console_access(request)
    if isinstance(r, RedirectResponse):
        return r
    verify_csrf_token(request, csrf_token)
    new_name = (name or "").strip()
    if len(new_name) < 2:
        return RedirectResponse(f"/console/event/{slug}?err=Etkinlik adı çok kısa", status_code=303)

    conn = db_conn()
    c = conn.cursor()
    c.execute("UPDATE saas_events SET name=? WHERE slug=?", (new_name, slug))
    conn.commit()
    conn.close()
    return RedirectResponse(f"/console/event/{slug}?msg=Etkinlik adı güncellendi", status_code=303)


@app.post("/console/event/{slug}/external_map", include_in_schema=False)
async def console_external_map_event(
    request: Request,
    slug: str,
    external_source: Optional[str] = Form(None),
    external_event_id: Optional[str] = Form(None),
    ticket_url: Optional[str] = Form(None),
    csrf_token: str = Form(...),
):
    r = require_console_access(request)
    if isinstance(r, RedirectResponse):
        return r
    verify_csrf_token(request, csrf_token)

    src = (external_source or "").strip().lower()
    ext_id = (external_event_id or "").strip()
    t_url = (ticket_url or "").strip()
    if src and src not in ("wp", "woo"):
        return RedirectResponse(f"/console/event/{slug}?err=Kaynak yalnızca wp veya woo olabilir", status_code=303)
    if t_url and not (t_url.startswith("http://") or t_url.startswith("https://")):
        return RedirectResponse(f"/console/event/{slug}?err=Bilet linki http:// veya https:// ile başlamalı", status_code=303)

    conn = db_conn()
    c = conn.cursor()
    c.execute(
        """
        UPDATE saas_events
        SET external_source=?, external_event_id=?, ticket_url=?
        WHERE slug=?
        """,
        (src or None, ext_id or None, t_url or None, slug),
    )
    conn.commit()
    conn.close()
    return RedirectResponse(f"/console/event/{slug}?msg=Harici etkinlik eşlemesi güncellendi", status_code=303)


@app.post("/console/event/{slug}/users/create")
async def console_create_user(request: Request, slug: str, name: str = Form(...), email: str = Form(...), selfie: Optional[UploadFile] = File(None)):
    _ = require_super_admin(request)
    form = await request.form()
    verify_csrf_token(request, form.get(CSRF_PARAM))
    return RedirectResponse(f"/console/event/{slug}?tab=users&err=Selfie tabanli katilimci kaydi kaldirildi", status_code=302)


@app.post("/console/event/{slug}/frames", include_in_schema=False)
async def console_event_frames(request: Request, slug: str):
    r = require_console_access(request)
    if isinstance(r, RedirectResponse):
        return r
    admin_acc = r

    form = await request.form()
    verify_csrf_token(request, form.get(CSRF_PARAM))

    frame_ratio_1_1 = form.get("frame_ratio_1_1")
    frame_ratio_3_2 = form.get("frame_ratio_3_2")
    frame_ratio_2_3 = form.get("frame_ratio_2_3")
    frame_ratio_3_4 = form.get("frame_ratio_3_4")
    frame_ratio_4_3 = form.get("frame_ratio_4_3")

    conn = db_conn()
    c = conn.cursor()
    c.execute("SELECT id FROM saas_events WHERE slug=? LIMIT 1", (slug,))
    row = c.fetchone()
    conn.close()
    if not row:
        return RedirectResponse("/console?err=Etkinlik bulunamadı", status_code=303)

    base_dir = os.path.join(FRAME_DIR, slug, str(int(admin_acc["id"])))
    os.makedirs(base_dir, exist_ok=True)
    updates = {}

    try:
        uploads = {
            "ratio_1_1": frame_ratio_1_1,
            "ratio_3_2": frame_ratio_3_2,
            "ratio_2_3": frame_ratio_2_3,
            "ratio_3_4": frame_ratio_3_4,
            "ratio_4_3": frame_ratio_4_3,
        }
        for kind, upload in uploads.items():
            if upload and getattr(upload, "filename", ""):
                path = os.path.join(base_dir, str(FRAME_KIND_META[kind]["filename"]))
                rel = await save_frame_file(upload, path)
                updates[f"frame_{kind}"] = rel
        if "frame_ratio_3_2" in updates:
            updates["frame_landscape"] = updates["frame_ratio_3_2"]
        if "frame_ratio_2_3" in updates:
            updates["frame_portrait"] = updates["frame_ratio_2_3"]
        if "frame_ratio_1_1" in updates:
            updates["frame_square"] = updates["frame_ratio_1_1"]
    except Exception as e:
        return RedirectResponse(f"/console/event/{slug}?err=Çerçeve yüklenemedi: {e}", status_code=303)

    if updates:
        upsert_event_account_frames(slug, int(admin_acc["id"]), updates)

    return RedirectResponse(f"/console/event/{slug}?msg=Çerçeveler güncellendi", status_code=303)


@app.post("/console/event/{slug}/reprocess", include_in_schema=False)
async def console_event_reprocess(request: Request, slug: str):
    r = require_console_access(request)
    if isinstance(r, RedirectResponse):
        return r
    admin_acc = r

    form = await request.form()
    verify_csrf_token(request, form.get(CSRF_PARAM))

    conn = db_conn()
    c = conn.cursor()
    c.execute("SELECT id FROM saas_events WHERE slug=? LIMIT 1", (slug,))
    event = c.fetchone()
    conn.close()
    if not event:
        return RedirectResponse("/console?err=Etkinlik bulunamadı", status_code=303)

    frame_paths = get_event_account_frames(slug, int(admin_acc["id"]))
    proc_settings = get_event_processing_settings(slug)
    count = reprocess_event_photos(
        slug,
        frame_paths,
        target_kb=int(proc_settings["target_kb"]),
        max_side=int(proc_settings["max_side"]),
        uploaded_by_account_id=int(admin_acc["id"]),
    )
    return RedirectResponse(f"/console/event/{slug}?msg=Çerçeve uygulandı: {count} foto", status_code=303)


@app.post("/console/event/{slug}/processing_settings", include_in_schema=False)
async def console_event_processing_settings(
    request: Request,
    slug: str,
    target_kb: int = Form(...),
    max_side: int = Form(...),
):
    _ = require_super_admin(request)
    form = await request.form()
    verify_csrf_token(request, form.get(CSRF_PARAM))

    try:
        tkb = int(target_kb)
        mside = int(max_side)
    except Exception:
        return RedirectResponse(f"/console/event/{slug}?err=İşleme ayarları sayısal olmalı", status_code=303)

    if tkb < 80 or tkb > 3000:
        return RedirectResponse(f"/console/event/{slug}?err=Hedef KB 80-3000 aralığında olmalı", status_code=303)
    if mside < 800 or mside > 8000:
        return RedirectResponse(f"/console/event/{slug}?err=Maks. uzun kenar 800-8000 aralığında olmalı", status_code=303)

    conn = db_conn()
    c = conn.cursor()
    c.execute("SELECT id FROM saas_events WHERE slug=? LIMIT 1", (slug,))
    row = c.fetchone()
    conn.close()
    if not row:
        return RedirectResponse("/console?err=Albüm bulunamadı", status_code=303)

    set_event_processing_settings(slug, tkb, mside)
    return RedirectResponse(f"/console/event/{slug}?msg=İşleme ayarları güncellendi", status_code=303)


@app.post("/console/event/{slug}/frames/delete", include_in_schema=False)
async def console_delete_frame(request: Request, slug: str):
    r = require_console_access(request)
    if isinstance(r, RedirectResponse):
        return r
    admin_acc = r

    form = await request.form()
    verify_csrf_token(request, form.get(CSRF_PARAM))
    kind = (form.get("kind") or "").strip().lower()

    conn = db_conn()
    c = conn.cursor()
    c.execute("SELECT id FROM saas_events WHERE slug=? LIMIT 1", (slug,))
    event = c.fetchone()
    conn.close()
    if not event:
        return RedirectResponse("/console?err=Etkinlik bulunamadı", status_code=303)

    try:
        clear_event_account_frame(slug, int(admin_acc["id"]), kind)
    except ValueError:
        return RedirectResponse(f"/console/event/{slug}?err=Geçersiz çerçeve türü", status_code=303)

    for filename in _frame_disk_names(kind):
        frame_file = os.path.join(FRAME_DIR, slug, str(int(admin_acc["id"])), filename)
        try:
            if os.path.exists(frame_file):
                os.remove(frame_file)
        except Exception:
            pass
    return RedirectResponse(f"/console/event/{slug}?msg=Çerçeve silindi", status_code=303)


@app.post("/console/event/create")
async def console_create_event(request: Request, slug: str = Form(...), name: str = Form(...)):
    acc = require_super_admin(request)
    form = await request.form()
    verify_csrf_token(request, form.get(CSRF_PARAM))

    slug = _slug_clean(slug)
    name = (name or "").strip()

    if len(slug) < 3 or len(name) < 2:
        return RedirectResponse("/console?err=Slug/isim hatalı", status_code=302)

    conn = db_conn()
    c = conn.cursor()

    c.execute("SELECT id FROM saas_events WHERE slug=? LIMIT 1", (slug,))
    if c.fetchone():
        conn.close()
        return RedirectResponse("/console?err=Bu slug zaten var", status_code=302)

    # ✅ Doğru tablo: saas_events
    c.execute(
        "INSERT INTO saas_events (account_id, name, slug, is_active, created_at) VALUES (?, ?, ?, 1, ?)",
        (acc["id"], name, slug, iso_now())
    )
    conn.commit()
    conn.close()

    return RedirectResponse(f"/console/event/{slug}", status_code=302)


@app.post("/console/event/{slug}/upload_photos")
async def console_upload_photos(request: Request, slug: str, photos: List[UploadFile] = File(...)):
    acc = require_super_admin(request)
    form = await request.form()
    verify_csrf_token(request, form.get(CSRF_PARAM))
    subalbum_id_raw = (form.get("subalbum_id") or "").strip()
    subalbum_id = int(subalbum_id_raw) if subalbum_id_raw.isdigit() and int(subalbum_id_raw) > 0 else None

    t0 = _now_s()
    files = [p for p in (photos or []) if p and (p.filename or "").strip()]
    if len(files) == 0:
        return RedirectResponse(f"/console/event/{slug}?err=Foto seçmediniz", status_code=302)
    if len(files) > int(UPLOAD_BATCH_MAX_FILES):
        return RedirectResponse(
            f"/console/event/{slug}?err=Tek partta en fazla {int(UPLOAD_BATCH_MAX_FILES)} fotoğraf yükleyebilirsiniz",
            status_code=302,
        )

    # job oluştur + worker (console upload)
    pid = generate_pid()
    prev_max_id = get_event_photos_max_id(slug)
    job_id = create_job(
        acc["id"],
        slug,
        action="console_upload_only",
        uploaded_count=len(files),
        subalbum_id=subalbum_id,
        status="uploading",
        pid=pid,
        match_start=prev_max_id,
        match_cursor=prev_max_id,
        match_end=None,
    )

    total_bytes = 0
    try:
        event_dir = os.path.join(EVENT_PHOTO_DIR, slug)
        os.makedirs(event_dir, exist_ok=True)

        frame_paths = get_event_account_frames(slug, int(acc["id"]))

        for photo in files:
            save_path = os.path.join(event_dir, f"{uuid.uuid4().hex}.jpg")
            raw = await photo.read()
            try:
                pil_probe = Image.open(BytesIO(raw))
                pil_format = pil_probe.format or "UNKNOWN"
                pil_probe.close()
            except Exception:
                pil_format = "UNKNOWN"
            log(f"[UPLOAD] console file={photo.filename} ctype={photo.content_type} bytes={len(raw)} pil={pil_format}")
            if photo.content_type and photo.content_type.lower() not in ALLOWED_IMAGE_MIME:
                raise ValueError(f"Sadece jpg/png/webp yükleyebilirsiniz (ctype={photo.content_type})")
            if len(raw) > int(IMAGE_MAX_BYTES):
                raise ValueError("Dosya çok büyük")
            size = process_event_photo_bytes(raw, save_path, frame_paths, target_kb=EVENT_TARGET_KB, max_side=EVENT_MAX_SIDE)
            total_bytes += size

            rel = os.path.relpath(save_path, ROOT_DIR).replace("\\", "/")
            insert_event_photo(slug, rel, uploaded_by_account_id=int(acc["id"]), file_size_bytes=int(size))

        dt = _now_s() - t0
        log(f"[UPLOAD] console slug={slug} files={len(files)} bytes={total_bytes} secs={dt:.2f}")
        new_max_id = get_event_photos_max_id(slug)
        update_job_match_range(
            job_id,
            prev_max_id,
            new_max_id,
            status="done",
            message=f"Yukleme tamamlandi. (PID {pid})",
        )
        return RedirectResponse(f"/console/event/{slug}?msg=Yuklendi. (PID {pid})", status_code=302)

    except Exception as e:
        finish_job(job_id, "error", f"Console upload hatası: {e}")
        return RedirectResponse(f"/console/event/{slug}?err=Upload hatası: {e}", status_code=302)


@app.post("/console/photo/{photo_id}/delete")
async def console_delete_photo(request: Request, photo_id: int):
    _ = require_super_admin(request)
    form = await request.form()
    verify_csrf_token(request, form.get(CSRF_PARAM))
    redirect_to = (form.get("redirect_to") or "").strip()

    conn = db_conn()
    c = conn.cursor()
    c.execute("SELECT event_id, file_path FROM event_photos WHERE id=?", (int(photo_id),))
    row = c.fetchone()
    if not row:
        conn.close()
        return RedirectResponse("/console", status_code=302)

    event_id = row["event_id"]
    file_path = row["file_path"]

    c.execute("DELETE FROM photo_matches WHERE photo_id=?", (int(photo_id),))
    c.execute("DELETE FROM event_photos WHERE id=?", (int(photo_id),))
    conn.commit()
    conn.close()

    try:
        abs_path = os.path.join(ROOT_DIR, file_path) if file_path else ""
        if abs_path and os.path.exists(abs_path):
            os.remove(abs_path)
    except Exception:
        pass

    if redirect_to.startswith(f"/console/event/{event_id}/batch/"):
        return RedirectResponse(redirect_to, status_code=302)
    return RedirectResponse(f"/console/event/{event_id}", status_code=302)


@app.post("/console/user/{user_id}/delete")
async def console_delete_user(request: Request, user_id: int, slug: str = Form(...)):
    _ = require_super_admin(request)
    form = await request.form()
    verify_csrf_token(request, form.get(CSRF_PARAM))

    conn = db_conn()
    c = conn.cursor()
    c.execute("SELECT selfie_path FROM users WHERE id=? AND event_id=? LIMIT 1", (int(user_id), slug))
    row = c.fetchone()
    if not row:
        conn.close()
        return RedirectResponse(f"/console/event/{slug}?err=Kullanıcı bulunamadı", status_code=302)

    selfie_path = row["selfie_path"]
    c.execute("DELETE FROM photo_matches WHERE user_id=? AND event_id=?", (int(user_id), slug))
    c.execute("DELETE FROM users WHERE id=? AND event_id=?", (int(user_id), slug))
    conn.commit()
    conn.close()

    try:
        abs_path = os.path.join(ROOT_DIR, selfie_path) if selfie_path and not os.path.isabs(selfie_path) else selfie_path
        if abs_path and os.path.exists(abs_path):
            os.remove(abs_path)
    except Exception:
        pass

    return RedirectResponse(f"/console/event/{slug}?msg=Kullanıcı silindi", status_code=302)


@app.post("/console/user/{user_id}/resend")
async def console_resend_gallery_mail(request: Request, user_id: int, slug: str = Form(...)):
    _ = require_super_admin(request)
    form = await request.form()
    verify_csrf_token(request, form.get(CSRF_PARAM))

    conn = db_conn()
    c = conn.cursor()
    c.execute("SELECT name, email, gallery_token FROM users WHERE id=? AND event_id=? LIMIT 1", (int(user_id), slug))
    row = c.fetchone()
    if not row:
        conn.close()
        return RedirectResponse(f"/console/event/{slug}?err=Kullanıcı bulunamadı", status_code=302)

    name = row["name"] or ""
    email = row["email"] or ""
    token = row["gallery_token"]
    if not token:
        token = secrets.token_urlsafe(16)
        c.execute("UPDATE users SET gallery_token=? WHERE id=?", (token, int(user_id)))
        conn.commit()

    conn.close()

    gallery_url = BASE_GALLERY_URL + token
    ok = send_gallery_email(email, name, gallery_url, event_slug=slug, user_id=int(user_id))
    if ok:
        return RedirectResponse(f"/console/event/{slug}?msg=Mail tekrar gönderildi", status_code=302)
    return RedirectResponse(f"/console/event/{slug}?err=Mail gönderilemedi", status_code=302)


@app.post("/console/event/{slug}/match")
async def console_match_event(request: Request, slug: str):
    _ = require_super_admin(request)
    form = await request.form()
    verify_csrf_token(request, form.get(CSRF_PARAM))
    return RedirectResponse(f"/console/event/{slug}?err=Yuz tanima eslestirme kaldirildi", status_code=302)


@app.post("/console/event/{slug}/delete")
async def console_delete_event(request: Request, slug: str):
    _ = require_super_admin(request)
    form = await request.form()
    verify_csrf_token(request, form.get(CSRF_PARAM))
    purge_res = purge_event_album_content(slug)
    if not purge_res.get("ok"):
        return RedirectResponse(
            f"/console/event/{slug}?err={urllib.parse.quote(str(purge_res.get('error') or 'Albüm silinemedi'))}",
            status_code=302,
        )

    conn = db_conn()
    c = conn.cursor()
    try:
        c.execute("SELECT 1 FROM saas_events WHERE slug=? LIMIT 1", (slug,))
        if not c.fetchone():
            conn.close()
            return RedirectResponse("/console?err=Albüm kaydı bulunamadı", status_code=302)

        c.execute("UPDATE saas_events SET album_enabled=FALSE WHERE slug=?", (slug,))
        c.execute(
            "UPDATE mobile_event_submissions SET create_photo_album=FALSE WHERE approved_event_slug=?",
            (slug,),
        )
        conn.commit()
        conn.close()
        return RedirectResponse("/console?msg=Albüm silindi, etkinlik kaydı korundu", status_code=302)
    except Exception as e:
        conn.rollback()
        conn.close()
        return RedirectResponse(f"/console?err={urllib.parse.quote(str(e)[:300])}", status_code=302)


# =========================
# EMAIL
# =========================

def send_gallery_email(to_email: str, to_name: str, gallery_url: str, event_slug: str = "", user_id: Optional[int] = None) -> bool:
    if not EMAIL_ENABLED:
        if event_slug:
            log_mail_event(event_slug, user_id, to_email, "disabled", "EMAIL_DISABLED")
        return False
    if not to_email:
        if event_slug:
            log_mail_event(event_slug, user_id, "", "error", "EMAIL_EMPTY")
        return False
    if not SMTP_LOGIN_USERNAME or not EMAIL_PASSWORD:
        log("[MAIL] SMTP bilgileri eksik, mail gönderilmiyor.")
        if event_slug:
            log_mail_event(event_slug, user_id, to_email, "error", "SMTP_MISSING")
        return False

    msg = EmailMessage()
    msg["Subject"] = "📸 Etkinlik Fotoğraflarınız Hazır"
    msg["From"] = EMAIL_FROM
    msg["To"] = to_email
    msg["Reply-To"] = EMAIL_FROM

    msg.set_content(
        f"Merhaba {to_name},\n\n"
        f"Etkinlik fotoğraflarınız hazır.\n\n"
        f"Galerinizi buradan açabilirsiniz:\n{gallery_url}\n"
    )

    logo_url = f"{PUBLIC_BASE_URL}/static/DMlogo.PNG"
    html = f"""
<!doctype html>
<html>
<head><meta charset="utf-8"></head>
<body style="margin:0;padding:0;background:#f4f6fb;">
  <table width="100%" style="padding:20px 0;">
    <tr><td align="center">
      <table width="600" style="background:#fff;border-radius:12px;">
        <tr>
          <td style="background:#111827;color:#fff;padding:18px;text-align:center;">
            <div style="margin-bottom:8px;">
              <img src="{logo_url}" alt="Dans Magazin" style="height:28px;">
            </div>
            <div style="font-size:20px;font-weight:700;">📸 Etkinlik Fotoğraflarınız Hazır</div>
          </td>
        </tr>
        <tr>
          <td style="padding:24px;font-size:15px;color:#111827;">
            <p>Merhaba <b>{to_name}</b>,</p>
            <p>Etkinlikte çekilen fotoğraflarınız sistemimizde bulundu.</p>
            <div style="text-align:center;margin:28px 0;">
              <a href="{gallery_url}"
                 style="background:#2563eb;color:#fff;padding:14px 26px;
                        border-radius:10px;text-decoration:none;font-weight:600;">
                Galerimi Aç
              </a>
            </div>
            <p style="font-size:12px;color:#6b7280;">
              Bu bağlantı sadece size özeldir.
            </p>
            <p style="font-size:13px;color:#2563eb;word-break:break-all;">
              <a href="{gallery_url}">{gallery_url}</a>
            </p>
          </td>
        </tr>
        <tr>
          <td style="background:#f9fafb;padding:18px;text-align:center;
                     font-size:12px;color:#6b7280;">
            Dans Magazin © {datetime.utcnow().year}
          </td>
        </tr>
      </table>
    </td></tr>
  </table>
</body>
</html>
"""
    msg.add_alternative(html, subtype="html")

    try:
        with smtplib.SMTP(SMTP_SERVER, SMTP_PORT, timeout=20) as smtp:
            smtp.ehlo()
            smtp.starttls()
            smtp.ehlo()
            smtp.login(SMTP_LOGIN_USERNAME, EMAIL_PASSWORD)
            smtp.send_message(msg)

        log(f"[MAIL] Gönderildi → {to_email}")
        if event_slug:
            log_mail_event(event_slug, user_id, to_email, "sent", "")
        return True

    except Exception as e:
        import traceback
        log(f"[MAIL HATA] {to_email} → {repr(e)}")
        log(traceback.format_exc())
        if event_slug:
            log_mail_event(event_slug, user_id, to_email, "error", repr(e))
        return False


# debug mail endpoint kaldırıldı (prod ortamda riskli)


# Face matching / selfie-based matching removed.


# =========================
# GALLERY
# =========================

@app.get("/gallery/{token}", response_class=HTMLResponse)
async def gallery(token: str, request: Request):
    return HTMLResponse("Selfie tabanli galeri kaldirildi.", status_code=410)


@app.get("/gallery/{token}/download/{photo_id}")
async def gallery_download(token: str, photo_id: int, request: Request):
    return HTMLResponse("Selfie tabanli galeri kaldirildi.", status_code=410)


# =========================
# HEALTH
# =========================

@app.get("/health")
def health():
    return {"ok": True}
