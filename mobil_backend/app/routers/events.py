import os
import re
import uuid
import json
import base64
import html
import logging
import random
from io import BytesIO
import hmac
import hashlib
from datetime import date, datetime, timedelta
from decimal import Decimal, InvalidOperation
from typing import Any, Dict, List, Optional
from zoneinfo import ZoneInfo
import unicodedata

import httpx
import psycopg2
import psycopg2.extras
import qrcode
from fastapi import APIRouter, File, Form, Header, HTTPException, UploadFile
from fastapi.responses import FileResponse, Response
from pydantic import BaseModel
from app.utils import get_db_connection, display_name

router = APIRouter(prefix="/events", tags=["Etkinlikler"])
admin_router = APIRouter(prefix="/admin/events", tags=["Admin Etkinlikler"])

DATABASE_URL = os.getenv("DATABASE_URL", "").strip()
ADMIN_TOKEN = os.getenv("MOBILE_ADMIN_TOKEN", "").strip()
ROOT_DIR = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
UPLOAD_DIR = os.path.join(ROOT_DIR, "media", "submission_covers")
ALT_UPLOAD_DIR = os.getenv("ALT_UPLOAD_DIR", "/home/ubuntu/etkinlik_fotograf_projesi/media/submission_covers")
PUBLIC_API_BASE = os.getenv("PUBLIC_API_BASE", "https://api2.dansmagazin.net").rstrip("/")
WOO_BASE_URL = os.getenv("WOO_BASE_URL", os.getenv("WP_BASE_URL", "https://dansmagazin.net")).rstrip("/")
WOO_CONSUMER_KEY = os.getenv("WOO_CONSUMER_KEY", "").strip()
WOO_CONSUMER_SECRET = os.getenv("WOO_CONSUMER_SECRET", "").strip()
WOO_SYNC_SECRET = os.getenv("WOO_SYNC_SECRET", "").strip()
QR_SIGNING_SECRET = (os.getenv("QR_SIGNING_SECRET", "").strip() or os.getenv("MOBILE_ADMIN_TOKEN", "").strip() or DATABASE_URL or "dansmagazin-ticket-secret")
APP_TIMEZONE = (os.getenv("APP_TIMEZONE", "Europe/Istanbul") or "Europe/Istanbul").strip()
logger = logging.getLogger("mobil_backend.events")

ALLOWED_EVENT_KINDS = {"dance_night", "festival", "competition", "promo_lesson"}
ALLOWED_DANCE_STYLES = {"salsa", "bachata", "kizomba", "tango", "lindy_hop", "hip_hop"}
ALLOWED_COVER_CROPS = {"top", "center", "bottom"}
DEFAULT_AUTO_EVENT_NOTIFICATION_TITLE_TEMPLATE = "Bu akşam: {event_name}"
DEFAULT_AUTO_EVENT_NOTIFICATION_BODY_TEMPLATE = "{event_name} bu akşam başlıyor. Programı incele, geç kalmadan yerini al."
EVENT_COVER_INPUT_MAX_BYTES = 45 * 1024 * 1024
EVENT_COVER_TARGET_MAX_BYTES = 1500 * 1024
EVENT_COVER_MAX_SIDE_STEPS = (1600, 1440, 1280, 1080, 960)
EVENT_COVER_QUALITY_STEPS = (86, 82, 78, 74, 70, 66)


# Renamed _db_conn to db_conn for consistency
db_conn = get_db_connection
_db_conn = db_conn
_display_name = display_name

def _parse_dance_styles(raw: Any) -> List[str]:
    if raw is None:
        return []
    if isinstance(raw, list):
        parts = [str(x).strip().lower() for x in raw]
    else:
        text = str(raw).strip()
        if not text:
            return []
        parts = [x.strip().lower() for x in text.split(",")]
    out: List[str] = []
    seen = set()
    for part in parts:
        if not part or part not in ALLOWED_DANCE_STYLES or part in seen:
            continue
        seen.add(part)
        out.append(part)
    return out


def _serialize_dance_styles(raw: Any) -> str:
    return ",".join(_parse_dance_styles(raw))


def _deserialize_dance_styles(raw: Any) -> List[str]:
    return _parse_dance_styles(raw)


def _normalize_cover_crop(raw: Any, default: str = "center") -> str:
    value = str(raw or "").strip().lower()
    if value in ALLOWED_COVER_CROPS:
        return value
    return default


def _normalize_auto_event_notification_template(raw: Any, *, max_len: int) -> str:
    text = str(raw or "").replace("\r\n", "\n").replace("\r", "\n").strip()
    if not text:
        return ""
    return text[:max_len]


def _render_auto_event_notification(
    *,
    event_name: Any,
    city: Any,
    title_template: Any = None,
    body_template: Any = None,
) -> Dict[str, str]:
    context = {
        "event_name": str(event_name or "").strip(),
        "city": str(city or "").strip(),
    }
    fallback_title = DEFAULT_AUTO_EVENT_NOTIFICATION_TITLE_TEMPLATE.format(**context).strip()
    fallback_body = DEFAULT_AUTO_EVENT_NOTIFICATION_BODY_TEMPLATE.format(**context).strip()
    title_tpl = _normalize_auto_event_notification_template(
        title_template,
        max_len=160,
    ) or DEFAULT_AUTO_EVENT_NOTIFICATION_TITLE_TEMPLATE
    body_tpl = _normalize_auto_event_notification_template(
        body_template,
        max_len=2000,
    ) or DEFAULT_AUTO_EVENT_NOTIFICATION_BODY_TEMPLATE

    try:
        title = title_tpl.format(**context).strip()
    except Exception:
        title = fallback_title
    try:
        body = body_tpl.format(**context).strip()
    except Exception:
        body = fallback_body

    return {
        "title": (title or fallback_title)[:160],
        "body": (body or fallback_body)[:2000],
    }


def init_event_submission_tables():
    conn = db_conn()
    cur = conn.cursor()
    cur.execute(
        """
        CREATE TABLE IF NOT EXISTS mobile_event_submissions (
            id SERIAL PRIMARY KEY,
            submitter_name TEXT,
            submitter_email TEXT,
            event_name TEXT NOT NULL,
            description TEXT,
            event_date TEXT,
            venue TEXT,
            venue_map_url TEXT,
            city TEXT,
            event_kind TEXT,
            dance_styles TEXT,
            ticket_sales_enabled BOOLEAN NOT NULL DEFAULT TRUE,
            create_photo_album BOOLEAN NOT NULL DEFAULT FALSE,
            repeat_weekly BOOLEAN NOT NULL DEFAULT FALSE,
            repeat_weekday INTEGER,
            repeat_origin_submission_id INTEGER,
            organizer_name TEXT,
            program_text TEXT,
            cover_path TEXT,
            cover_crop TEXT,
            start_at TEXT,
            end_at TEXT,
            entry_fee NUMERIC(12,2),
            status TEXT NOT NULL DEFAULT 'pending',
            admin_note TEXT,
            created_at TEXT NOT NULL,
            approved_at TEXT
        )
        """
    )
    cur.execute(
        """
        DO $$
        BEGIN
            IF NOT EXISTS (
                SELECT 1 FROM information_schema.columns
                WHERE table_name='mobile_event_submissions' AND column_name='approved_event_slug'
            ) THEN
                ALTER TABLE mobile_event_submissions ADD COLUMN approved_event_slug TEXT;
            END IF;
        END$$;
        """
    )
    cur.execute(
        """
        DO $$
        BEGIN
            IF NOT EXISTS (
                SELECT 1 FROM information_schema.columns
                WHERE table_name='mobile_event_submissions' AND column_name='source_type'
            ) THEN
                ALTER TABLE mobile_event_submissions ADD COLUMN source_type TEXT;
            END IF;
            IF NOT EXISTS (
                SELECT 1 FROM information_schema.columns
                WHERE table_name='mobile_event_submissions' AND column_name='source_ref'
            ) THEN
                ALTER TABLE mobile_event_submissions ADD COLUMN source_ref TEXT;
            END IF;
        END$$;
        """
    )
    cur.execute(
        """
        DO $$
        BEGIN
            IF NOT EXISTS (
                SELECT 1 FROM information_schema.columns
                WHERE table_name='mobile_event_submissions' AND column_name='event_date'
            ) THEN
                ALTER TABLE mobile_event_submissions ADD COLUMN event_date TEXT;
            END IF;
            IF NOT EXISTS (
                SELECT 1 FROM information_schema.columns
                WHERE table_name='mobile_event_submissions' AND column_name='venue'
            ) THEN
                ALTER TABLE mobile_event_submissions ADD COLUMN venue TEXT;
            END IF;
            IF NOT EXISTS (
                SELECT 1 FROM information_schema.columns
                WHERE table_name='mobile_event_submissions' AND column_name='city'
            ) THEN
                ALTER TABLE mobile_event_submissions ADD COLUMN city TEXT;
            END IF;
            IF NOT EXISTS (
                SELECT 1 FROM information_schema.columns
                WHERE table_name='mobile_event_submissions' AND column_name='venue_map_url'
            ) THEN
                ALTER TABLE mobile_event_submissions ADD COLUMN venue_map_url TEXT;
            END IF;
            IF NOT EXISTS (
                SELECT 1 FROM information_schema.columns
                WHERE table_name='mobile_event_submissions' AND column_name='event_kind'
            ) THEN
                ALTER TABLE mobile_event_submissions ADD COLUMN event_kind TEXT;
            END IF;
            IF NOT EXISTS (
                SELECT 1 FROM information_schema.columns
                WHERE table_name='mobile_event_submissions' AND column_name='dance_styles'
            ) THEN
                ALTER TABLE mobile_event_submissions ADD COLUMN dance_styles TEXT;
            END IF;
            IF NOT EXISTS (
                SELECT 1 FROM information_schema.columns
                WHERE table_name='mobile_event_submissions' AND column_name='ticket_sales_enabled'
            ) THEN
                ALTER TABLE mobile_event_submissions ADD COLUMN ticket_sales_enabled BOOLEAN NOT NULL DEFAULT TRUE;
            END IF;
            IF NOT EXISTS (
                SELECT 1 FROM information_schema.columns
                WHERE table_name='mobile_event_submissions' AND column_name='create_photo_album'
            ) THEN
                ALTER TABLE mobile_event_submissions ADD COLUMN create_photo_album BOOLEAN NOT NULL DEFAULT FALSE;
            END IF;
            IF NOT EXISTS (
                SELECT 1 FROM information_schema.columns
                WHERE table_name='mobile_event_submissions' AND column_name='organizer_name'
            ) THEN
                ALTER TABLE mobile_event_submissions ADD COLUMN organizer_name TEXT;
            END IF;
            IF NOT EXISTS (
                SELECT 1 FROM information_schema.columns
                WHERE table_name='mobile_event_submissions' AND column_name='program_text'
            ) THEN
                ALTER TABLE mobile_event_submissions ADD COLUMN program_text TEXT;
            END IF;
            IF NOT EXISTS (
                SELECT 1 FROM information_schema.columns
                WHERE table_name='mobile_event_submissions' AND column_name='cover_crop'
            ) THEN
                ALTER TABLE mobile_event_submissions ADD COLUMN cover_crop TEXT;
            END IF;
            IF NOT EXISTS (
                SELECT 1 FROM information_schema.columns
                WHERE table_name='mobile_event_submissions' AND column_name='repeat_weekly'
            ) THEN
                ALTER TABLE mobile_event_submissions ADD COLUMN repeat_weekly BOOLEAN NOT NULL DEFAULT FALSE;
            END IF;
            IF NOT EXISTS (
                SELECT 1 FROM information_schema.columns
                WHERE table_name='mobile_event_submissions' AND column_name='repeat_weekday'
            ) THEN
                ALTER TABLE mobile_event_submissions ADD COLUMN repeat_weekday INTEGER;
            END IF;
            IF NOT EXISTS (
                SELECT 1 FROM information_schema.columns
                WHERE table_name='mobile_event_submissions' AND column_name='repeat_origin_submission_id'
            ) THEN
                ALTER TABLE mobile_event_submissions ADD COLUMN repeat_origin_submission_id INTEGER;
            END IF;
            IF NOT EXISTS (
                SELECT 1 FROM information_schema.columns
                WHERE table_name='mobile_event_submissions' AND column_name='auto_notification_title_template'
            ) THEN
                ALTER TABLE mobile_event_submissions ADD COLUMN auto_notification_title_template TEXT;
            END IF;
            IF NOT EXISTS (
                SELECT 1 FROM information_schema.columns
                WHERE table_name='mobile_event_submissions' AND column_name='auto_notification_body_template'
            ) THEN
                ALTER TABLE mobile_event_submissions ADD COLUMN auto_notification_body_template TEXT;
            END IF;
        END$$;
        """
    )
    cur.execute(
        """
        DO $$
        BEGIN
            IF EXISTS (
                SELECT 1 FROM information_schema.tables
                WHERE table_name='saas_events'
            ) AND NOT EXISTS (
                SELECT 1 FROM information_schema.columns
                WHERE table_name='saas_events' AND column_name='album_enabled'
            ) THEN
                ALTER TABLE saas_events ADD COLUMN album_enabled BOOLEAN NOT NULL DEFAULT TRUE;
            END IF;
        END$$;
        """
    )
    cur.execute(
        """
        CREATE TABLE IF NOT EXISTS mobile_event_attendees (
            submission_id INTEGER NOT NULL REFERENCES mobile_event_submissions(id) ON DELETE CASCADE,
            account_id INTEGER NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
            created_at TEXT NOT NULL,
            PRIMARY KEY (submission_id, account_id)
        )
        """
    )
    cur.execute(
        """
        CREATE TABLE IF NOT EXISTS mobile_event_comments (
            id SERIAL PRIMARY KEY,
            thread_submission_id INTEGER NOT NULL REFERENCES mobile_event_submissions(id) ON DELETE CASCADE,
            author_account_id INTEGER NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
            body TEXT NOT NULL,
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL,
            UNIQUE (thread_submission_id, author_account_id)
        )
        """
    )
    cur.execute(
        """
        CREATE TABLE IF NOT EXISTS mobile_event_raffles (
            id SERIAL PRIMARY KEY,
            submission_id INTEGER NOT NULL UNIQUE REFERENCES mobile_event_submissions(id) ON DELETE CASCADE,
            starts_at TEXT NOT NULL,
            ends_at TEXT NOT NULL,
            winner_count INTEGER NOT NULL,
            status TEXT NOT NULL DEFAULT 'draft',
            created_by_account_id INTEGER REFERENCES accounts(id) ON DELETE SET NULL,
            drawn_by_account_id INTEGER REFERENCES accounts(id) ON DELETE SET NULL,
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL,
            drawn_at TEXT
        )
        """
    )
    cur.execute(
        """
        CREATE TABLE IF NOT EXISTS mobile_event_raffle_entries (
            raffle_id INTEGER NOT NULL REFERENCES mobile_event_raffles(id) ON DELETE CASCADE,
            account_id INTEGER NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
            created_at TEXT NOT NULL,
            PRIMARY KEY (raffle_id, account_id)
        )
        """
    )
    cur.execute(
        """
        CREATE TABLE IF NOT EXISTS mobile_event_raffle_winners (
            raffle_id INTEGER NOT NULL REFERENCES mobile_event_raffles(id) ON DELETE CASCADE,
            account_id INTEGER NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
            winner_kind TEXT NOT NULL DEFAULT 'primary',
            position INTEGER NOT NULL,
            created_at TEXT NOT NULL,
            PRIMARY KEY (raffle_id, account_id),
            UNIQUE (raffle_id, winner_kind, position)
        )
        """
    )
    cur.execute(
        """
        DO $$
        BEGIN
            IF NOT EXISTS (
                SELECT 1 FROM information_schema.columns
                WHERE table_name='mobile_event_raffles' AND column_name='status'
            ) THEN
                ALTER TABLE mobile_event_raffles ADD COLUMN status TEXT NOT NULL DEFAULT 'draft';
            END IF;
        END$$;
        """
    )
    cur.execute(
        """
        DO $$
        BEGIN
            IF NOT EXISTS (
                SELECT 1 FROM information_schema.columns
                WHERE table_name='mobile_event_raffle_winners' AND column_name='winner_kind'
            ) THEN
                ALTER TABLE mobile_event_raffle_winners ADD COLUMN winner_kind TEXT NOT NULL DEFAULT 'primary';
            END IF;
        END$$;
        """
    )
    cur.execute(
        """
        DO $$
        BEGIN
            IF EXISTS (
                SELECT 1
                FROM pg_constraint
                WHERE conname='mobile_event_raffle_winners_raffle_id_position_key'
            ) THEN
                ALTER TABLE mobile_event_raffle_winners
                DROP CONSTRAINT mobile_event_raffle_winners_raffle_id_position_key;
            END IF;
        END$$;
        """
    )
    cur.execute(
        """
        DO $$
        BEGIN
            IF NOT EXISTS (
                SELECT 1
                FROM pg_constraint
                WHERE conname='mobile_event_raffle_winners_raffle_kind_position_key'
            ) THEN
                ALTER TABLE mobile_event_raffle_winners
                ADD CONSTRAINT mobile_event_raffle_winners_raffle_kind_position_key
                UNIQUE (raffle_id, winner_kind, position);
            END IF;
        END$$;
        """
    )
    cur.execute(
        """
        CREATE TABLE IF NOT EXISTS mobile_friendships (
            user_a_id INTEGER NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
            user_b_id INTEGER NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
            created_at TEXT NOT NULL,
            PRIMARY KEY (user_a_id, user_b_id),
            CHECK (user_a_id < user_b_id)
        )
        """
    )
    cur.execute(
        """
        CREATE TABLE IF NOT EXISTS mobile_friend_requests (
            id SERIAL PRIMARY KEY,
            requester_id INTEGER NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
            target_id INTEGER NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
            status TEXT NOT NULL DEFAULT 'pending',
            created_at TEXT NOT NULL,
            responded_at TEXT,
            CHECK (requester_id <> target_id)
        )
        """
    )
    cur.execute(
        """
        CREATE TABLE IF NOT EXISTS mobile_direct_messages (
            id SERIAL PRIMARY KEY,
            sender_account_id INTEGER NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
            receiver_account_id INTEGER NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
            body TEXT NOT NULL,
            created_at TEXT NOT NULL,
            read_at TEXT
        )
        """
    )
    cur.execute(
        """
        CREATE TABLE IF NOT EXISTS mobile_tickets (
            id SERIAL PRIMARY KEY,
            account_id INTEGER NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
            submission_id INTEGER NOT NULL REFERENCES mobile_event_submissions(id) ON DELETE CASCADE,
            event_slug TEXT NOT NULL,
            event_name TEXT NOT NULL,
            woo_order_id TEXT,
            woo_order_item_id TEXT,
            qr_token TEXT UNIQUE NOT NULL,
            status TEXT NOT NULL DEFAULT 'active',
            created_at TEXT NOT NULL,
            used_at TEXT,
            used_by_account_id INTEGER REFERENCES accounts(id) ON DELETE SET NULL
        )
        """
    )
    cur.execute(
        """
        DO $$
        BEGIN
            IF NOT EXISTS (
                SELECT 1 FROM information_schema.columns
                WHERE table_name='mobile_tickets' AND column_name='woo_order_status'
            ) THEN
                ALTER TABLE mobile_tickets ADD COLUMN woo_order_status TEXT;
            END IF;
        END$$;
        """
    )
    cur.execute(
        """
        DO $$
        BEGIN
            IF NOT EXISTS (
                SELECT 1 FROM information_schema.columns
                WHERE table_name='mobile_tickets' AND column_name='ticket_type'
            ) THEN
                ALTER TABLE mobile_tickets ADD COLUMN ticket_type TEXT NOT NULL DEFAULT 'paid';
            END IF;
            IF NOT EXISTS (
                SELECT 1 FROM information_schema.columns
                WHERE table_name='mobile_tickets' AND column_name='issued_by_account_id'
            ) THEN
                ALTER TABLE mobile_tickets ADD COLUMN issued_by_account_id INTEGER REFERENCES accounts(id) ON DELETE SET NULL;
            END IF;
            IF NOT EXISTS (
                SELECT 1 FROM information_schema.columns
                WHERE table_name='mobile_tickets' AND column_name='source_guest_list_id'
            ) THEN
                ALTER TABLE mobile_tickets ADD COLUMN source_guest_list_id BIGINT;
            END IF;
            IF NOT EXISTS (
                SELECT 1 FROM information_schema.columns
                WHERE table_name='mobile_tickets' AND column_name='reward_origin_submission_id'
            ) THEN
                ALTER TABLE mobile_tickets ADD COLUMN reward_origin_submission_id INTEGER;
            END IF;
            IF NOT EXISTS (
                SELECT 1 FROM information_schema.columns
                WHERE table_name='mobile_tickets' AND column_name='reward_cycle'
            ) THEN
                ALTER TABLE mobile_tickets ADD COLUMN reward_cycle INTEGER;
            END IF;
        END$$;
        """
    )
    cur.execute(
        """
        CREATE TABLE IF NOT EXISTS mobile_event_invitees (
            id BIGSERIAL PRIMARY KEY,
            submission_id INTEGER NOT NULL REFERENCES mobile_event_submissions(id) ON DELETE CASCADE,
            account_id INTEGER NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
            source_guest_list_id BIGINT,
            invited_by_account_id INTEGER REFERENCES accounts(id) ON DELETE SET NULL,
            ticket_id INTEGER REFERENCES mobile_tickets(id) ON DELETE SET NULL,
            created_at TEXT NOT NULL,
            UNIQUE (submission_id, account_id)
        )
        """
    )
    cur.execute(
        """
        CREATE TABLE IF NOT EXISTS mobile_ticket_scan_permissions (
            id SERIAL PRIMARY KEY,
            submission_id INTEGER NOT NULL REFERENCES mobile_event_submissions(id) ON DELETE CASCADE,
            account_id INTEGER NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
            granted_by_account_id INTEGER REFERENCES accounts(id) ON DELETE SET NULL,
            created_at TEXT NOT NULL,
            UNIQUE (submission_id, account_id)
        )
        """
    )
    cur.execute(
        """
        CREATE TABLE IF NOT EXISTS mobile_ticket_scan_logs (
            id SERIAL PRIMARY KEY,
            ticket_id INTEGER NOT NULL REFERENCES mobile_tickets(id) ON DELETE CASCADE,
            submission_id INTEGER NOT NULL REFERENCES mobile_event_submissions(id) ON DELETE CASCADE,
            scanner_account_id INTEGER REFERENCES accounts(id) ON DELETE SET NULL,
            scan_result TEXT NOT NULL,
            scan_at TEXT NOT NULL
        )
        """
    )
    cur.execute(
        """
        DO $$
        BEGIN
            IF NOT EXISTS (
                SELECT 1 FROM information_schema.columns
                WHERE table_name='mobile_ticket_scan_logs' AND column_name='buyer_account_id'
            ) THEN
                ALTER TABLE mobile_ticket_scan_logs ADD COLUMN buyer_account_id INTEGER REFERENCES accounts(id) ON DELETE SET NULL;
            END IF;
            IF NOT EXISTS (
                SELECT 1 FROM information_schema.columns
                WHERE table_name='mobile_ticket_scan_logs' AND column_name='ticket_type'
            ) THEN
                ALTER TABLE mobile_ticket_scan_logs ADD COLUMN ticket_type TEXT;
            END IF;
            IF NOT EXISTS (
                SELECT 1 FROM information_schema.columns
                WHERE table_name='mobile_ticket_scan_logs' AND column_name='source_profile_school_name'
            ) THEN
                ALTER TABLE mobile_ticket_scan_logs ADD COLUMN source_profile_school_name TEXT;
            END IF;
            IF NOT EXISTS (
                SELECT 1 FROM information_schema.columns
                WHERE table_name='mobile_ticket_scan_logs' AND column_name='source_profile_school_key'
            ) THEN
                ALTER TABLE mobile_ticket_scan_logs ADD COLUMN source_profile_school_key TEXT;
            END IF;
            IF NOT EXISTS (
                SELECT 1 FROM information_schema.columns
                WHERE table_name='mobile_ticket_scan_logs' AND column_name='entry_origin_submission_id'
            ) THEN
                ALTER TABLE mobile_ticket_scan_logs ADD COLUMN entry_origin_submission_id INTEGER;
            END IF;
            IF NOT EXISTS (
                SELECT 1 FROM information_schema.columns
                WHERE table_name='mobile_ticket_scan_logs' AND column_name='reward_cycle'
            ) THEN
                ALTER TABLE mobile_ticket_scan_logs ADD COLUMN reward_cycle INTEGER;
            END IF;
            IF NOT EXISTS (
                SELECT 1 FROM information_schema.columns
                WHERE table_name='mobile_ticket_scan_logs' AND column_name='reward_ticket_id'
            ) THEN
                ALTER TABLE mobile_ticket_scan_logs ADD COLUMN reward_ticket_id INTEGER REFERENCES mobile_tickets(id) ON DELETE SET NULL;
            END IF;
        END$$;
        """
    )
    cur.execute(
        """
        CREATE TABLE IF NOT EXISTS mobile_event_entry_sources (
            id BIGSERIAL PRIMARY KEY,
            submission_id INTEGER NOT NULL REFERENCES mobile_event_submissions(id) ON DELETE CASCADE,
            label TEXT NOT NULL,
            qr_token TEXT UNIQUE NOT NULL,
            created_by_account_id INTEGER REFERENCES accounts(id) ON DELETE SET NULL,
            is_active BOOLEAN NOT NULL DEFAULT TRUE,
            created_at TEXT NOT NULL
        )
        """
    )
    cur.execute(
        """
        DO $$
        BEGIN
            IF NOT EXISTS (
                SELECT 1 FROM information_schema.columns
                WHERE table_name='mobile_event_entry_sources' AND column_name='is_active'
            ) THEN
                ALTER TABLE mobile_event_entry_sources ADD COLUMN is_active BOOLEAN NOT NULL DEFAULT TRUE;
            END IF;
        END$$;
        """
    )
    cur.execute(
        """
        CREATE TABLE IF NOT EXISTS mobile_event_entry_source_scans (
            id BIGSERIAL PRIMARY KEY,
            source_id BIGINT NOT NULL REFERENCES mobile_event_entry_sources(id) ON DELETE CASCADE,
            submission_id INTEGER NOT NULL REFERENCES mobile_event_submissions(id) ON DELETE CASCADE,
            scanner_account_id INTEGER REFERENCES accounts(id) ON DELETE SET NULL,
            scanned_at TEXT NOT NULL
        )
        """
    )
    cur.execute("CREATE INDEX IF NOT EXISTS idx_mob_attendees_acc ON mobile_event_attendees(account_id)")
    cur.execute(
        "CREATE INDEX IF NOT EXISTS idx_mob_event_comments_thread ON mobile_event_comments(thread_submission_id, updated_at DESC, created_at DESC)"
    )
    cur.execute(
        "CREATE INDEX IF NOT EXISTS idx_mob_event_raffle_entries_raffle ON mobile_event_raffle_entries(raffle_id, created_at ASC)"
    )
    cur.execute(
        "CREATE INDEX IF NOT EXISTS idx_mob_event_raffle_winners_raffle ON mobile_event_raffle_winners(raffle_id, position ASC)"
    )
    cur.execute("CREATE INDEX IF NOT EXISTS idx_mob_friend_req_target ON mobile_friend_requests(target_id, status)")
    cur.execute("CREATE INDEX IF NOT EXISTS idx_mob_friend_req_requester ON mobile_friend_requests(requester_id, status)")
    cur.execute("CREATE INDEX IF NOT EXISTS idx_mob_msg_pair ON mobile_direct_messages(sender_account_id, receiver_account_id)")
    cur.execute("CREATE INDEX IF NOT EXISTS idx_mob_msg_created ON mobile_direct_messages(created_at)")
    cur.execute("CREATE INDEX IF NOT EXISTS idx_mob_tickets_acc ON mobile_tickets(account_id, created_at DESC)")
    cur.execute("CREATE INDEX IF NOT EXISTS idx_mob_tickets_sub ON mobile_tickets(submission_id, created_at DESC)")
    cur.execute("CREATE INDEX IF NOT EXISTS idx_mob_tickets_type_sub ON mobile_tickets(ticket_type, submission_id, created_at DESC)")
    cur.execute("CREATE INDEX IF NOT EXISTS idx_mob_tickets_reward_cycle ON mobile_tickets(account_id, reward_origin_submission_id, reward_cycle)")
    cur.execute("CREATE INDEX IF NOT EXISTS idx_mob_event_invitees_sub ON mobile_event_invitees(submission_id, created_at DESC)")
    cur.execute("CREATE INDEX IF NOT EXISTS idx_mob_event_invitees_acc ON mobile_event_invitees(account_id, created_at DESC)")
    cur.execute("CREATE INDEX IF NOT EXISTS idx_mob_ticket_logs_sub ON mobile_ticket_scan_logs(submission_id, scan_at DESC)")
    cur.execute("CREATE INDEX IF NOT EXISTS idx_mob_ticket_logs_buyer_origin ON mobile_ticket_scan_logs(buyer_account_id, entry_origin_submission_id, scan_at DESC)")
    cur.execute("CREATE INDEX IF NOT EXISTS idx_mob_ticket_logs_school_origin ON mobile_ticket_scan_logs(entry_origin_submission_id, source_profile_school_key, scan_at DESC)")
    cur.execute("CREATE INDEX IF NOT EXISTS idx_mob_entry_sources_sub ON mobile_event_entry_sources(submission_id, created_at DESC)")
    cur.execute("CREATE INDEX IF NOT EXISTS idx_mob_entry_sources_token ON mobile_event_entry_sources(qr_token)")
    cur.execute("CREATE INDEX IF NOT EXISTS idx_mob_entry_scans_source ON mobile_event_entry_source_scans(source_id, scanned_at DESC)")
    cur.execute("CREATE INDEX IF NOT EXISTS idx_mob_entry_scans_sub ON mobile_event_entry_source_scans(submission_id, scanned_at DESC)")
    conn.commit()
    conn.close()
    os.makedirs(UPLOAD_DIR, exist_ok=True)
    os.makedirs(ALT_UPLOAD_DIR, exist_ok=True)


def _require_admin(x_admin_token: Optional[str]):
    if not ADMIN_TOKEN:
        raise HTTPException(status_code=503, detail="Admin token tanımlı değil")
    if not x_admin_token or x_admin_token.strip() != ADMIN_TOKEN:
        raise HTTPException(status_code=401, detail="Yetkisiz")


def _parse_admin_submission_ids_csv(raw_value: Any) -> List[int]:
    raw_items = [x.strip() for x in str(raw_value or "").split(",")]
    parsed: List[int] = []
    seen = set()
    for raw in raw_items:
        if not raw:
            continue
        try:
            value = int(raw)
        except Exception:
            continue
        if value <= 0 or value in seen:
            continue
        seen.add(value)
        parsed.append(value)
    return parsed


def _iso_now() -> str:
    return datetime.utcnow().isoformat(timespec="seconds") + "Z"


def _json_time_text(value: Any) -> str:
    if value is None:
        return ""
    if hasattr(value, "isoformat"):
        try:
            return value.isoformat()
        except Exception:
            pass
    return str(value)


def _normalize_school_key(value: Any) -> str:
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


def _is_visnelik_event(event_name: Any, event_slug: Any = None) -> bool:
    return "visnelik" in _normalize_school_key(event_name) or "visnelik" in _normalize_school_key(event_slug)


def _decode_ticket_qr_payload(qr_token: str) -> Dict[str, Any]:
    token = (qr_token or "").strip()
    if not token:
        return {"raw_token": ""}
    if not token.startswith("dmqr1."):
        return {"raw_token": token}
    parts = token.split(".", 2)
    if len(parts) != 3:
        return {"raw_token": token}
    encoded = parts[1].strip()
    signature = parts[2].strip().lower()
    expected = hmac.new(
        QR_SIGNING_SECRET.encode("utf-8"),
        encoded.encode("utf-8"),
        hashlib.sha256,
    ).hexdigest()[:24]
    if signature != expected:
        raise HTTPException(status_code=400, detail="Geçersiz QR imzası")
    padded = encoded + "=" * (-len(encoded) % 4)
    try:
        raw = base64.urlsafe_b64decode(padded.encode("ascii"))
        payload = json.loads(raw.decode("utf-8"))
    except Exception:
        raise HTTPException(status_code=400, detail="Geçersiz QR verisi")
    if not isinstance(payload, dict):
        raise HTTPException(status_code=400, detail="Geçersiz QR verisi")
    return {
        "raw_token": str(payload.get("tk") or "").strip(),
        "ticket_id": int(payload.get("ti") or 0) if str(payload.get("ti") or "").strip() else 0,
        "submission_id": int(payload.get("si") or 0) if str(payload.get("si") or "").strip() else 0,
        "account_id": int(payload.get("ai") or 0) if str(payload.get("ai") or "").strip() else 0,
        "school_name": str(payload.get("sn") or "").strip(),
        "school_id": int(payload.get("sid") or 0) if str(payload.get("sid") or "").strip() else 0,
    }


def _now_local() -> datetime:
    return datetime.now(ZoneInfo(APP_TIMEZONE))


def _parse_event_date_text(raw: str) -> Optional[date]:
    v = (raw or "").strip()
    if not v:
        return None
    for fmt in ("%Y-%m-%d", "%d-%m-%Y", "%d.%m.%Y"):
        try:
            return datetime.strptime(v, fmt).date()
        except Exception:
            pass
    if "T" in v or "-" in v:
        try:
            dt = datetime.fromisoformat(v.replace("Z", "").replace(" ", "T"))
            return dt.date()
        except Exception:
            pass
    return None


def _normalize_event_dt_text(raw: str) -> str:
    v = (raw or "").strip()
    if not v:
        return ""
    normalized = v.replace(" ", "T")
    if re.fullmatch(r"\d{4}-\d{1,2}-\d{1,2}", normalized):
        return normalized
    if re.search(r"(Z|[+\-]\d{2}:\d{2})$", normalized):
        return normalized
    m = re.fullmatch(r"(\d{4})-(\d{1,2})-(\d{1,2})T(\d{1,2}):(\d{2})(?::(\d{2}))?", normalized)
    if not m:
        return normalized
    try:
        y = int(m.group(1))
        mo = int(m.group(2))
        d = int(m.group(3))
        hh = int(m.group(4))
        mm = int(m.group(5))
        ss = int(m.group(6) or 0)
        dt = datetime(y, mo, d, hh, mm, ss, tzinfo=ZoneInfo(APP_TIMEZONE))
        return dt.isoformat(timespec="seconds")
    except Exception:
        if re.fullmatch(r"\d{4}-\d{1,2}-\d{1,2}T\d{1,2}:\d{2}", normalized):
            return f"{normalized}:00+03:00"
        return f"{normalized}+03:00"


def _parse_event_dt_value(raw: str) -> Optional[datetime]:
    normalized = _normalize_event_dt_text(raw)
    if not normalized:
        return None
    try:
        if re.fullmatch(r"\d{4}-\d{1,2}-\d{1,2}", normalized):
            parsed = datetime.strptime(normalized, "%Y-%m-%d")
            return parsed.replace(tzinfo=ZoneInfo(APP_TIMEZONE))
        parsed = datetime.fromisoformat(normalized.replace("Z", "+00:00"))
        if parsed.tzinfo is None:
            return parsed.replace(tzinfo=ZoneInfo(APP_TIMEZONE))
        return parsed.astimezone(ZoneInfo(APP_TIMEZONE))
    except Exception:
        return None


def _is_truthy(value: Any) -> bool:
    return str(value or "").strip().lower() in {"1", "true", "yes", "on"}


def _normalize_repeat_mode(raw: Any, *, repeat_weekly_enabled: bool = False) -> str:
    value = str(raw or "").strip().lower()
    if value in {"weekly_fixed", "selected_dates", "none"}:
        return value
    if value in {"weekly", "fixed", "same_weekday"}:
        return "weekly_fixed"
    if repeat_weekly_enabled:
        return "weekly_fixed"
    return "none"


def _parse_repeat_selected_dates(raw: Any, *, max_dates: int = 180) -> List[date]:
    if raw is None:
        return []
    if isinstance(raw, list):
        parts = [str(item or "").strip() for item in raw]
    else:
        text = str(raw or "").replace("\n", ",").replace(";", ",").replace("|", ",")
        parts = [chunk.strip() for chunk in text.split(",")]
    picked: List[date] = []
    seen = set()
    for part in parts:
        if not part:
            continue
        parsed = _parse_event_date_text(part)
        if parsed is None:
            raise HTTPException(status_code=400, detail=f"Geçersiz tekrar tarihi: {part}")
        iso_key = parsed.isoformat()
        if iso_key in seen:
            continue
        seen.add(iso_key)
        picked.append(parsed)
    picked.sort()
    if len(picked) > max_dates:
        raise HTTPException(status_code=400, detail=f"En fazla {max_dates} tarih seçebilirsiniz")
    return picked


def _shift_event_dt_to_date(raw: str, target_day: date) -> str:
    v = (raw or "").strip()
    if not v:
        return target_day.isoformat()
    normalized = _normalize_event_dt_text(v)
    if re.fullmatch(r"\d{4}-\d{1,2}-\d{1,2}", normalized):
        return target_day.isoformat()
    try:
        parsed = datetime.fromisoformat(normalized.replace("Z", "+00:00"))
        tz = parsed.tzinfo or ZoneInfo(APP_TIMEZONE)
        shifted = datetime(
            target_day.year,
            target_day.month,
            target_day.day,
            parsed.hour,
            parsed.minute,
            parsed.second,
            tzinfo=tz,
        )
        return shifted.isoformat(timespec="seconds")
    except Exception:
        return target_day.isoformat()


def _coerce_event_window(event_date_raw: str, start_at_raw: str, end_at_raw: str) -> tuple[str, str, str]:
    event_date_val = _normalize_event_dt_text(event_date_raw)
    start_at_val = _normalize_event_dt_text(start_at_raw) or event_date_val
    end_at_val = _normalize_event_dt_text(end_at_raw) or event_date_val
    start_dt = _parse_event_dt_value(start_at_val)
    end_dt = _parse_event_dt_value(end_at_val)
    if start_dt and end_dt and end_dt < start_dt and start_dt.date() == end_dt.date():
        end_at_val = (end_dt + timedelta(days=1)).isoformat(timespec="seconds")
    return event_date_val, start_at_val, end_at_val


def _shift_event_window_to_date(start_raw: str, end_raw: str, target_day: date) -> tuple[str, str]:
    start_val = _normalize_event_dt_text(start_raw)
    end_val = _normalize_event_dt_text(end_raw)
    start_dt = _parse_event_dt_value(start_val)
    end_dt = _parse_event_dt_value(end_val)
    if start_dt and end_dt:
        if end_dt < start_dt and start_dt.date() == end_dt.date():
            end_dt = end_dt + timedelta(days=1)
        duration = end_dt - start_dt
        shifted_start = datetime(
            target_day.year,
            target_day.month,
            target_day.day,
            start_dt.hour,
            start_dt.minute,
            start_dt.second,
            tzinfo=start_dt.tzinfo or ZoneInfo(APP_TIMEZONE),
        )
        shifted_end = shifted_start + duration
        return shifted_start.isoformat(timespec="seconds"), shifted_end.isoformat(timespec="seconds")
    return (
        _shift_event_dt_to_date(start_raw, target_day),
        _shift_event_dt_to_date(end_raw or start_raw, target_day),
    )


def _submission_event_day(row: Dict[str, Any]) -> Optional[date]:
    return _parse_event_date_text((row.get("event_date") or row.get("start_at") or "").strip())


def _ticket_type_label(ticket_type: Any) -> str:
    normalized = str(ticket_type or "").strip().lower() or "paid"
    if normalized == "guest":
        return "Davetli"
    if normalized == "paid":
        return "Satın alınmış"
    if normalized == "loyalty_reward":
        return "Ücretsiz"
    return normalized or "Bilet"


def _ticket_type_sort_key(ticket_type: Any) -> int:
    normalized = str(ticket_type or "").strip().lower() or "paid"
    if normalized == "paid":
        return 0
    if normalized == "guest":
        return 1
    if normalized == "loyalty_reward":
        return 2
    return 9


def _ticket_control_summary_text(summary: Dict[str, Any], *, include_zero: bool = False) -> str:
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


def _build_active_ticket_control_map(conn, submission_ids: List[int]) -> Dict[int, Dict[str, Any]]:
    normalized_submission_ids = sorted({int(item) for item in (submission_ids or []) if int(item) > 0})
    if not normalized_submission_ids:
        return {}

    mapped: Dict[int, Dict[str, Any]] = {
        submission_id: {
            "summary": {
                "submission_id": submission_id,
                "active_ticket_count": 0,
                "active_holder_count": 0,
                "paid_ticket_count": 0,
                "guest_ticket_count": 0,
                "reward_ticket_count": 0,
                "summary_text": _ticket_control_summary_text({"active_ticket_count": 0}, include_zero=True),
            },
            "holders": [],
        }
        for submission_id in normalized_submission_ids
    }

    cur = conn.cursor()
    cur.execute(
        """
        SELECT
            t.submission_id,
            COUNT(*)::INT AS active_ticket_count,
            COUNT(DISTINCT t.account_id)::INT AS active_holder_count,
            COUNT(*) FILTER (WHERE COALESCE(t.ticket_type,'paid')='paid')::INT AS paid_ticket_count,
            COUNT(*) FILTER (WHERE COALESCE(t.ticket_type,'paid')='guest')::INT AS guest_ticket_count,
            COUNT(*) FILTER (WHERE COALESCE(t.ticket_type,'paid')='loyalty_reward')::INT AS reward_ticket_count
        FROM mobile_tickets t
        WHERE t.submission_id = ANY(%s)
          AND COALESCE(t.status,'active')='active'
          AND t.used_at IS NULL
        GROUP BY t.submission_id
        """,
        (normalized_submission_ids,),
    )
    for row in (cur.fetchall() or []):
        submission_id = int(row.get("submission_id") or 0)
        if submission_id <= 0 or submission_id not in mapped:
            continue
        summary = {
            "submission_id": submission_id,
            "active_ticket_count": int(row.get("active_ticket_count") or 0),
            "active_holder_count": int(row.get("active_holder_count") or 0),
            "paid_ticket_count": int(row.get("paid_ticket_count") or 0),
            "guest_ticket_count": int(row.get("guest_ticket_count") or 0),
            "reward_ticket_count": int(row.get("reward_ticket_count") or 0),
        }
        summary["summary_text"] = _ticket_control_summary_text(summary, include_zero=True)
        mapped[submission_id]["summary"] = summary

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
            COALESCE(a.name,'') AS buyer_name,
            COALESCE(a.email,'') AS buyer_email,
            COALESCE(a.role,'') AS buyer_role,
            COALESCE(a.can_create_mobile_event,0) AS can_create_mobile_event,
            COALESCE(ps.username,'') AS buyer_username,
            COALESCE(ps.avatar_url,'') AS buyer_avatar_url,
            COALESCE(ps.is_verified, FALSE) AS buyer_is_verified
        FROM mobile_tickets t
        JOIN accounts a ON a.id = t.account_id
        LEFT JOIN mobile_profile_settings ps ON ps.account_id = t.account_id
        LEFT JOIN mobile_guest_lists gl ON gl.id = t.source_guest_list_id
        WHERE t.submission_id = ANY(%s)
          AND COALESCE(t.status,'active')='active'
          AND t.used_at IS NULL
        GROUP BY
            t.submission_id,
            t.account_id,
            COALESCE(t.ticket_type,'paid'),
            gl.name,
            a.name,
            a.email,
            a.role,
            a.can_create_mobile_event,
            ps.username,
            ps.avatar_url,
            ps.is_verified
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
        (normalized_submission_ids,),
    )
    for row in (cur.fetchall() or []):
        submission_id = int(row.get("submission_id") or 0)
        if submission_id <= 0 or submission_id not in mapped:
            continue
        raw_ticket_type = (row.get("ticket_type") or "paid").strip().lower()
        mapped[submission_id]["holders"].append(
            {
                "account_id": int(row.get("account_id") or 0),
                "name": display_name(
                    (row.get("buyer_name") or ""),
                    (row.get("buyer_email") or ""),
                    (row.get("buyer_username") or ""),
                ),
                "email": (row.get("buyer_email") or "").strip(),
                "avatar_url": (row.get("buyer_avatar_url") or "").strip(),
                "is_verified": bool(row.get("buyer_is_verified"))
                or bool(int(row.get("can_create_mobile_event") or 0))
                or str(row.get("buyer_role") or "").strip().lower() in {"super_admin", "editor"},
                "ticket_type": raw_ticket_type,
                "ticket_type_label": _ticket_type_label(raw_ticket_type),
                "ticket_type_sort_key": _ticket_type_sort_key(raw_ticket_type),
                "ticket_count": int(row.get("ticket_count") or 0),
                "source_guest_list_name": (row.get("source_guest_list_name") or "").strip(),
                "first_created_at": _json_time_text(row.get("first_created_at")),
                "last_created_at": _json_time_text(row.get("last_created_at")),
            }
        )

    return mapped


def _management_status_text(raw_status: Any, ticket_control_summary: Dict[str, Any]) -> str:
    normalized = str(raw_status or "").strip().lower()
    base_label = {
        "approved": "Yayında",
        "pending": "Beklemede",
        "rejected": "Reddedildi",
        "expired": "Süresi geçti",
    }.get(normalized, str(raw_status or "").strip() or "-")
    ticket_summary_text = _ticket_control_summary_text(ticket_control_summary, include_zero=True)
    if not ticket_summary_text:
        return base_label
    return f"{base_label} · {ticket_summary_text}"


def _pick_submission_candidate(
    rows: List[Dict[str, Any]],
    *,
    reference_day: Optional[date] = None,
) -> Optional[Dict[str, Any]]:
    if not rows:
        return None

    def _fallback_key(row: Dict[str, Any]) -> tuple[Any, ...]:
        status_priority = 0 if str(row.get("status") or "").strip().lower() == "approved" else 1
        return (status_priority, -int(row.get("id") or 0))

    if reference_day is None:
        return sorted(rows, key=_fallback_key)[0]

    ranked: List[tuple[Any, ...]] = []
    for row in rows:
        event_day = _submission_event_day(row)
        status_priority = 0 if str(row.get("status") or "").strip().lower() == "approved" else 1
        if event_day is None:
            ranked.append((2, 999999, status_priority, -int(row.get("id") or 0), row))
            continue
        delta_days = (event_day - reference_day).days
        bucket = 0 if delta_days >= 0 else 1
        distance = delta_days if delta_days >= 0 else abs(delta_days)
        ranked.append((bucket, distance, status_priority, -int(row.get("id") or 0), row))

    ranked.sort(key=lambda item: item[:-1])
    return ranked[0][-1]


def _expire_past_event_tickets(
    conn,
    *,
    submission_ids: Optional[List[int]] = None,
    account_id: Optional[int] = None,
) -> int:
    cur = conn.cursor()
    wheres = ["COALESCE(t.status,'active') NOT IN ('cancelled','failed','refunded','trash','expired')"]
    vals: List[Any] = []
    normalized_submission_ids = sorted({int(item) for item in (submission_ids or []) if int(item) > 0})
    if normalized_submission_ids:
        wheres.append("t.submission_id = ANY(%s)")
        vals.append(normalized_submission_ids)
    if account_id is not None and int(account_id) > 0:
        wheres.append("t.account_id=%s")
        vals.append(int(account_id))

    cur.execute(
        f"""
        SELECT
            t.id,
            COALESCE(mes.status,'') AS submission_status,
            COALESCE(mes.event_date,'') AS event_date,
            COALESCE(mes.start_at,'') AS start_at
        FROM mobile_tickets t
        LEFT JOIN mobile_event_submissions mes ON mes.id = t.submission_id
        WHERE {' AND '.join(wheres)}
        """,
        tuple(vals),
    )
    rows = cur.fetchall() or []
    if not rows:
        return 0

    today = _now_local().date()
    expired_ids: List[int] = []
    for row in rows:
        submission_status = (row.get("submission_status") or "").strip().lower()
        if submission_status == "expired":
            expired_ids.append(int(row["id"]))
            continue
        event_day = _submission_event_day(row)
        if event_day is not None and event_day < today:
            expired_ids.append(int(row["id"]))

    if not expired_ids:
        return 0

    cur.execute(
        """
        UPDATE mobile_tickets
        SET status='expired'
        WHERE id = ANY(%s)
        """,
        (expired_ids,),
    )
    return len(expired_ids)


def _is_selected_dates_series_submission(row: Dict[str, Any]) -> bool:
    if bool(row.get("repeat_weekly")):
        return False
    try:
        return int(row.get("repeat_origin_submission_id") or 0) > 0
    except Exception:
        return False


def _build_submission_full_description(row: Dict[str, Any]) -> str:
    base_desc = (row.get("description") or "").strip()
    extra_desc_parts: List[str] = []
    if (row.get("venue") or "").strip():
        extra_desc_parts.append(f"Mekan: {(row.get('venue') or '').strip()}")
    if (row.get("organizer_name") or "").strip():
        extra_desc_parts.append(f"Organizatör: {(row.get('organizer_name') or '').strip()}")
    if (row.get("program_text") or "").strip():
        extra_desc_parts.append(f"Program: {(row.get('program_text') or '').strip()}")
    if not extra_desc_parts:
        return base_desc
    return (base_desc + "\n\n" if base_desc else "") + "\n".join(extra_desc_parts)


def _create_woo_event_product(
    *,
    event_name: str,
    description: str = "",
    start_at: str = "",
    end_at: str = "",
    entry_fee: Any = 0,
    cover_path: str = "",
) -> Dict[str, Any]:
    if not (WOO_BASE_URL and WOO_CONSUMER_KEY and WOO_CONSUMER_SECRET):
        return {"ok": False, "error": "Woo ayarları eksik (WOO_BASE_URL/CK/CS)"}

    try:
        fee = float(entry_fee or 0)
    except Exception:
        fee = 0.0
    if fee < 0:
        fee = 0.0

    full_desc = (description or "").strip()
    start_fmt = _normalize_event_dt_text(start_at) or "-"
    end_fmt = _normalize_event_dt_text(end_at) or "-"
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
            image_url = f"{PUBLIC_API_BASE}/events/submission-cover/{os.path.basename(cp)}"

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

    try:
        with httpx.Client(timeout=25.0, follow_redirects=True) as client:
            resp = client.post(
                f"{WOO_BASE_URL}/wp-json/wc/v3/products",
                params={
                    "consumer_key": WOO_CONSUMER_KEY,
                    "consumer_secret": WOO_CONSUMER_SECRET,
                },
                json=payload,
            )
        if resp.status_code >= 400:
            return {"ok": False, "error": f"Woo HTTP {resp.status_code}: {resp.text[:600]}"}
        data = resp.json() if resp.content else {}
        if not isinstance(data, dict):
            data = {}
        return {
            "ok": True,
            "woo_id": str(data.get("id") or ""),
            "ticket_url": str(data.get("permalink") or ""),
            "raw": data,
        }
    except Exception as exc:
        return {"ok": False, "error": f"Woo bağlantı hatası: {exc}"}


def _set_woo_event_product_publish_state(woo_product_id: str, publish: bool) -> Dict[str, Any]:
    pid = (woo_product_id or "").strip()
    if not pid:
        return {"ok": False, "error": "Woo ürün id boş"}
    if not (WOO_BASE_URL and WOO_CONSUMER_KEY and WOO_CONSUMER_SECRET):
        return {"ok": False, "error": "Woo ayarları eksik (WOO_BASE_URL/CK/CS)"}
    try:
        with httpx.Client(timeout=25.0, follow_redirects=True) as client:
            resp = client.put(
                f"{WOO_BASE_URL}/wp-json/wc/v3/products/{pid}",
                params={
                    "consumer_key": WOO_CONSUMER_KEY,
                    "consumer_secret": WOO_CONSUMER_SECRET,
                },
                json={"status": "publish" if publish else "draft"},
            )
        if resp.status_code >= 400:
            return {"ok": False, "error": f"Woo HTTP {resp.status_code}: {resp.text[:600]}"}
        data = resp.json() if resp.content else {}
        if not isinstance(data, dict):
            data = {}
        return {
            "ok": True,
            "woo_id": str(data.get("id") or pid),
            "status": str(data.get("status") or ("publish" if publish else "draft")),
            "ticket_url": str(data.get("permalink") or ""),
            "raw": data,
        }
    except Exception as exc:
        return {"ok": False, "error": f"Woo bağlantı hatası: {exc}"}


def _ensure_live_event_state(conn, submission_id: int, *, activate: bool) -> None:
    cur = conn.cursor()
    cur.execute(
        """
        SELECT
            mes.*,
            COALESCE(se.id, 0) AS saas_event_id,
            COALESCE(se.external_event_id, '') AS woo_product_id,
            COALESCE(se.ticket_url, '') AS ticket_url
        FROM mobile_event_submissions mes
        LEFT JOIN saas_events se ON se.slug = mes.approved_event_slug
        WHERE mes.id=%s
        LIMIT 1
        """,
        (int(submission_id),),
    )
    row = cur.fetchone()
    if not row:
        return

    event_name = (row.get("event_name") or "").strip() or f"Etkinlik {submission_id}"
    submitter_email = (row.get("submitter_email") or "").strip().lower()
    slug = (row.get("approved_event_slug") or "").strip()
    saas_event_id = int(row.get("saas_event_id") or 0)
    album_enabled = bool(row.get("create_photo_album"))

    if not activate and not slug and saas_event_id <= 0:
        return

    owner_id, _, _ = _resolve_owner_account(conn, submitter_email)
    if saas_event_id > 0:
        cur.execute(
            """
            UPDATE saas_events
            SET account_id=%s,
                name=%s,
                is_active=%s,
                album_enabled=%s
            WHERE id=%s
            """,
            (owner_id, event_name, 1 if activate else 0, True if album_enabled else False, saas_event_id),
        )
    else:
        base_slug = slug or _slug_clean(event_name) or f"event-{submission_id}"
        final_slug = slug or _unique_event_slug(conn, base_slug)
        cur.execute(
            """
            INSERT INTO saas_events (account_id, name, slug, is_active, created_at, album_enabled)
            VALUES (%s,%s,%s,%s,%s,%s)
            RETURNING id
            """,
            (owner_id, event_name, final_slug, 1 if activate else 0, _iso_now(), True if album_enabled else False),
        )
        saas_event_id = int((cur.fetchone() or {}).get("id") or 0)
        slug = final_slug
        cur.execute(
            "UPDATE mobile_event_submissions SET approved_event_slug=%s WHERE id=%s",
            (slug, int(submission_id)),
        )

    woo_product_id = (row.get("woo_product_id") or "").strip()
    ticket_sales_enabled = bool(row.get("ticket_sales_enabled") if row.get("ticket_sales_enabled") is not None else True)
    next_ticket_url = (row.get("ticket_url") or "").strip()
    if ticket_sales_enabled:
        if woo_product_id:
            sync = _set_woo_event_product_publish_state(woo_product_id, publish=activate)
            if sync.get("ok"):
                next_ticket_url = str(sync.get("ticket_url") or next_ticket_url).strip()
                cur.execute(
                    """
                    UPDATE saas_events
                    SET external_source='woo',
                        external_event_id=%s,
                        ticket_url=%s
                    WHERE slug=%s
                    """,
                    (str(sync.get("woo_id") or woo_product_id).strip() or None, next_ticket_url or None, slug),
                )
            else:
                logger.warning("Woo publish state sync failed for submission %s: %s", submission_id, sync.get("error"))
        elif activate:
            woo_res = _create_woo_event_product(
                event_name=event_name,
                description=_build_submission_full_description(row),
                start_at=(row.get("start_at") or "").strip(),
                end_at=(row.get("end_at") or "").strip(),
                entry_fee=row.get("entry_fee") or 0,
                cover_path=(row.get("cover_path") or "").strip(),
            )
            if woo_res.get("ok"):
                cur.execute(
                    """
                    UPDATE saas_events
                    SET external_source='woo',
                        external_event_id=%s,
                        ticket_url=%s
                    WHERE slug=%s
                    """,
                    (
                        str(woo_res.get("woo_id") or "").strip() or None,
                        str(woo_res.get("ticket_url") or "").strip() or None,
                        slug,
                    ),
                )
            else:
                logger.warning("Woo product create failed for submission %s: %s", submission_id, woo_res.get("error"))
    elif woo_product_id:
        sync = _set_woo_event_product_publish_state(woo_product_id, publish=False)
        if sync.get("ok"):
            next_ticket_url = str(sync.get("ticket_url") or next_ticket_url).strip()
            cur.execute(
                """
                UPDATE saas_events
                SET external_source='woo',
                    external_event_id=%s,
                    ticket_url=%s
                WHERE slug=%s
                """,
                (str(sync.get("woo_id") or woo_product_id).strip() or None, next_ticket_url or None, slug),
            )
        else:
            logger.warning("Woo draft sync failed for submission %s: %s", submission_id, sync.get("error"))


def _activate_selected_dates_series(conn, origin_id: int, *, exclude_submission_id: Optional[int] = None) -> None:
    cur = conn.cursor()
    cur.execute(
        """
        SELECT
            mes.id,
            mes.status,
            mes.event_date,
            mes.start_at,
            mes.end_at,
            mes.repeat_weekly,
            mes.repeat_origin_submission_id,
            COALESCE(se.is_active, 0) AS event_is_active
        FROM mobile_event_submissions mes
        LEFT JOIN saas_events se ON se.slug = mes.approved_event_slug
        WHERE COALESCE(mes.repeat_origin_submission_id, mes.id)=%s
          AND COALESCE(mes.repeat_weekly, FALSE)=FALSE
        ORDER BY COALESCE(mes.event_date, mes.start_at, mes.created_at) ASC, mes.id ASC
        """,
        (int(origin_id),),
    )
    rows = cur.fetchall() or []
    today = _now_local().date()
    target_id: Optional[int] = None

    for row in rows:
        row_id = int(row.get("id") or 0)
        if row_id <= 0 or row_id == int(exclude_submission_id or 0):
            continue
        status = (row.get("status") or "").strip().lower()
        if status == "rejected":
            continue
        event_day = _submission_event_day(row)
        if status == "approved" and event_day is not None and event_day < today:
            _ensure_live_event_state(conn, row_id, activate=False)
            cur.execute("UPDATE mobile_event_submissions SET status='expired' WHERE id=%s", (row_id,))
            continue
        if status == "approved" and (event_day is None or event_day >= today) and target_id is None:
            target_id = row_id

    for row in rows:
        row_id = int(row.get("id") or 0)
        if row_id <= 0 or row_id == int(exclude_submission_id or 0):
            continue
        if (row.get("status") or "").strip().lower() != "approved":
            continue
        event_day = _submission_event_day(row)
        if event_day is not None and event_day < today:
            continue
        _ensure_live_event_state(conn, row_id, activate=row_id == target_id)


def _insert_mobile_event_submission(
    cur,
    *,
    submitter_name: str,
    submitter_email: str,
    event_name: str,
    description: str,
    event_date: str,
    venue: str,
    venue_map_url: str,
    city: str,
    event_kind: str,
    dance_styles: str,
    ticket_sales_enabled: bool,
    create_photo_album: bool,
    repeat_weekly: bool,
    repeat_weekday: Optional[int],
    repeat_origin_submission_id: Optional[int],
    organizer_name: str,
    program_text: str,
    cover_path: str,
    start_at: str,
    end_at: str,
    entry_fee: Decimal,
    status: str,
    created_at: str,
    approved_at: Optional[str] = None,
    approved_event_slug: Optional[str] = None,
    source_type: Optional[str] = None,
    source_ref: Optional[str] = None,
    admin_note: Optional[str] = None,
) -> int:
    cur.execute(
        """
        INSERT INTO mobile_event_submissions
        (
            submitter_name, submitter_email, event_name, description, event_date,
            venue, venue_map_url, city, event_kind, dance_styles, ticket_sales_enabled, create_photo_album,
            repeat_weekly, repeat_weekday, repeat_origin_submission_id,
            organizer_name, program_text, cover_path, start_at, end_at, entry_fee,
            status, admin_note, created_at, approved_at, approved_event_slug, source_type, source_ref
        )
        VALUES (%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s)
        RETURNING id
        """,
        (
            submitter_name,
            submitter_email,
            event_name,
            description,
            event_date,
            venue,
            venue_map_url,
            city,
            event_kind,
            dance_styles,
            ticket_sales_enabled,
            create_photo_album,
            repeat_weekly,
            repeat_weekday,
            repeat_origin_submission_id,
            organizer_name,
            program_text,
            cover_path,
            start_at,
            end_at,
            entry_fee,
            status,
            admin_note,
            created_at,
            approved_at,
            approved_event_slug,
            source_type,
            source_ref,
        ),
    )
    inserted = cur.fetchone() or {}
    return int(inserted.get("id") or 0)


def _normalize_map_url(raw: str) -> str:
    v = (raw or "").strip()
    if not v:
        return ""
    if v.startswith("www."):
        v = f"https://{v}"
    if not (v.startswith("http://") or v.startswith("https://")):
        return ""
    return v


def _split_venue_fields(venue: str, venue_map_url: str) -> tuple[str, str]:
    map_url = _normalize_map_url(venue_map_url or "")
    raw = (venue or "").strip()
    if map_url:
        return raw, map_url
    m = re.search(r"https?://\S+", raw, flags=re.IGNORECASE)
    if not m:
        return raw, ""
    link = (m.group(0) or "").strip()
    label = raw.replace(link, "").strip()
    return label or raw, link


def _next_weekday_on_or_after(base_day: date, weekday: int) -> date:
    delta = (int(weekday) - base_day.weekday()) % 7
    return base_day + timedelta(days=delta)


def _rollover_and_expire_events(conn) -> None:
    cur = conn.cursor()
    cur.execute(
        """
        SELECT
            id, submitter_name, submitter_email, event_name, description, event_date, venue, venue_map_url,
            city, event_kind, COALESCE(dance_styles,'') AS dance_styles,
            ticket_sales_enabled, repeat_weekly, repeat_weekday, repeat_origin_submission_id,
            organizer_name, program_text, cover_path, start_at, end_at, entry_fee, admin_note,
            COALESCE(auto_notification_title_template,'') AS auto_notification_title_template,
            COALESCE(auto_notification_body_template,'') AS auto_notification_body_template,
            approved_event_slug, source_type, source_ref
        FROM mobile_event_submissions
        WHERE status='approved'
          AND COALESCE(source_type,'') <> 'woo'
        """
    )
    rows = cur.fetchall() or []
    now_local = _now_local()
    today = now_local.date()
    now_iso = _iso_now()
    expired_submission_ids: List[int] = []

    for r in rows:
        current_date = _parse_event_date_text((r.get("event_date") or r.get("start_at") or ""))
        if current_date is None or current_date >= today:
            continue

        repeat_weekly = bool(r.get("repeat_weekly"))
        repeat_weekday_raw = r.get("repeat_weekday")
        repeat_weekday: Optional[int]
        try:
            repeat_weekday = int(repeat_weekday_raw) if repeat_weekday_raw is not None else None
        except Exception:
            repeat_weekday = None
        if repeat_weekly and (repeat_weekday is None or repeat_weekday < 0 or repeat_weekday > 6):
            repeat_weekday = current_date.weekday()

        if repeat_weekly and repeat_weekday is not None:
            next_day = _next_weekday_on_or_after(today, repeat_weekday)
            next_date = next_day.isoformat()
            shifted_start_at, shifted_end_at = _shift_event_window_to_date(
                (r.get("start_at") or r.get("event_date") or ""),
                (r.get("end_at") or r.get("start_at") or r.get("event_date") or ""),
                next_day,
            )
            origin_id = int(r.get("repeat_origin_submission_id") or r["id"])
            cur.execute(
                """
                SELECT id
                FROM mobile_event_submissions
                WHERE status='approved'
                  AND COALESCE(repeat_origin_submission_id,id)=%s
                  AND LEFT(COALESCE(event_date, start_at, ''), 10)=%s
                LIMIT 1
                """,
                (origin_id, next_date),
            )
            exists = cur.fetchone()
            if not exists:
                cur.execute(
                    """
                    INSERT INTO mobile_event_submissions
                    (
                        submitter_name, submitter_email, event_name, description, event_date,
                        venue, venue_map_url, city, event_kind, dance_styles, ticket_sales_enabled,
                        repeat_weekly, repeat_weekday, repeat_origin_submission_id,
                        organizer_name, program_text, cover_path, start_at, end_at, entry_fee,
                        status, admin_note, auto_notification_title_template, auto_notification_body_template,
                        created_at, approved_at, approved_event_slug, source_type, source_ref
                    )
                    VALUES (%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,'approved',%s,%s,%s,%s,%s,%s,%s,%s)
                    RETURNING id
                    """,
                    (
                        (r.get("submitter_name") or "").strip(),
                        (r.get("submitter_email") or "").strip().lower(),
                        (r.get("event_name") or "").strip(),
                        (r.get("description") or "").strip(),
                        _shift_event_dt_to_date((r.get("event_date") or r.get("start_at") or ""), next_day),
                        (r.get("venue") or "").strip(),
                        (r.get("venue_map_url") or "").strip(),
                        (r.get("city") or "").strip(),
                        (r.get("event_kind") or "").strip(),
                        _serialize_dance_styles(r.get("dance_styles")),
                        bool(r.get("ticket_sales_enabled")),
                        True,
                        int(repeat_weekday),
                        origin_id,
                        (r.get("organizer_name") or "").strip(),
                        (r.get("program_text") or "").strip(),
                        (r.get("cover_path") or "").strip(),
                        shifted_start_at,
                        shifted_end_at,
                        r.get("entry_fee"),
                        (r.get("admin_note") or "").strip(),
                        _normalize_auto_event_notification_template(
                            r.get("auto_notification_title_template"),
                            max_len=160,
                        )
                        or None,
                        _normalize_auto_event_notification_template(
                            r.get("auto_notification_body_template"),
                            max_len=2000,
                        )
                        or None,
                        now_iso,
                        now_iso,
                        (r.get("approved_event_slug") or "").strip(),
                        (r.get("source_type") or "").strip(),
                        (r.get("source_ref") or "").strip(),
                    ),
                )
                inserted = cur.fetchone() or {}
                new_submission_id = int(inserted.get("id") or 0)
                if new_submission_id > 0:
                    _clone_ticket_scan_permissions(
                        conn,
                        from_submission_id=int(r["id"]),
                        to_submission_id=new_submission_id,
                    )
        elif _is_selected_dates_series_submission(r):
            _ensure_live_event_state(conn, int(r["id"]), activate=False)
            origin_id = int(r.get("repeat_origin_submission_id") or r["id"])
            _activate_selected_dates_series(
                conn,
                origin_id,
                exclude_submission_id=int(r["id"]),
            )

        cur.execute("UPDATE mobile_event_submissions SET status='expired' WHERE id=%s", (int(r["id"]),))
        expired_submission_ids.append(int(r["id"]))
    if expired_submission_ids:
        _expire_past_event_tickets(conn, submission_ids=expired_submission_ids)


def _require_bearer(authorization: Optional[str]) -> str:
    if not authorization or not authorization.lower().startswith("bearer "):
        raise HTTPException(status_code=401, detail="Bearer token gerekli")
    token = authorization.split(" ", 1)[1].strip()
    if not token:
        raise HTTPException(status_code=401, detail="Token boş")
    return token


def _require_account_id(conn, authorization: Optional[str]) -> int:
    token = _require_bearer(authorization)
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


def _require_editor_account(conn, authorization: Optional[str]) -> Dict[str, Any]:
    token = _require_bearer(authorization)
    cur = conn.cursor()
    cur.execute(
        """
        SELECT
            a.id AS account_id,
            COALESCE(a.name, '') AS name,
            COALESCE(a.email, '') AS email,
            COALESCE(a.role, '') AS role,
            COALESCE(a.can_create_mobile_event,0) AS can_create_mobile_event
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
    role = (row.get("role") or "").strip().lower()
    can_create_mobile_event = bool(int(row.get("can_create_mobile_event") or 0))
    if role not in {"editor", "super_admin"} and not can_create_mobile_event:
        raise HTTPException(status_code=403, detail="Etkinlik oluşturma yetkisi yok (editor gerekli)")
    return {
        "account_id": int(row["account_id"]),
        "name": (row.get("name") or "").strip(),
        "email": (row.get("email") or "").strip().lower(),
        "role": role,
    }


def _friend_pair(a: int, b: int) -> tuple[int, int]:
    return (a, b) if a < b else (b, a)


def _friendship_exists(conn, a: int, b: int) -> bool:
    x, y = _friend_pair(int(a), int(b))
    cur = conn.cursor()
    cur.execute("SELECT 1 FROM mobile_friendships WHERE user_a_id=%s AND user_b_id=%s LIMIT 1", (x, y))
    return bool(cur.fetchone())


def _event_exists(conn, submission_id: int) -> bool:
    cur = conn.cursor()
    cur.execute(
        """
        SELECT 1
        FROM mobile_event_submissions mes
        WHERE mes.id=%s AND mes.status='approved'
        LIMIT 1
        """,
        (int(submission_id),),
    )
    return bool(cur.fetchone())


def _get_event_submission(conn, submission_id: int) -> Optional[Dict[str, Any]]:
    cur = conn.cursor()
    cur.execute(
        """
        SELECT mes.id, mes.event_name, mes.approved_event_slug, mes.status,
               se.account_id AS owner_account_id,
               COALESCE(se.external_event_id,'') AS woo_product_id
        FROM mobile_event_submissions mes
        LEFT JOIN saas_events se ON se.slug = mes.approved_event_slug
        WHERE mes.id=%s
        LIMIT 1
        """,
        (int(submission_id),),
    )
    return cur.fetchone()


def _get_event_comment_anchor(conn, submission_id: int) -> Optional[Dict[str, Any]]:
    cur = conn.cursor()
    cur.execute(
        """
        SELECT
            mes.id,
            mes.status,
            COALESCE(mes.event_name, '') AS event_name,
            COALESCE(mes.event_date, mes.start_at, '') AS event_date_text,
            COALESCE(mes.repeat_origin_submission_id, mes.id) AS thread_submission_id
        FROM mobile_event_submissions mes
        WHERE mes.id=%s
        LIMIT 1
        """,
        (int(submission_id),),
    )
    return cur.fetchone()


def _repeat_thread_origin_id(conn, submission_id: int) -> int:
    cur = conn.cursor()
    cur.execute(
        """
        SELECT COALESCE(repeat_origin_submission_id, id) AS origin_id
        FROM mobile_event_submissions
        WHERE id=%s
        LIMIT 1
        """,
        (int(submission_id),),
    )
    row = cur.fetchone() or {}
    return int(row.get("origin_id") or submission_id)


def _repeat_thread_submission_ids(conn, submission_id: int) -> List[int]:
    origin_id = _repeat_thread_origin_id(conn, submission_id)
    cur = conn.cursor()
    cur.execute(
        """
        SELECT id
        FROM mobile_event_submissions
        WHERE COALESCE(repeat_origin_submission_id, id)=%s
        ORDER BY id ASC
        """,
        (int(origin_id),),
    )
    rows = cur.fetchall() or []
    ids = [int(r["id"]) for r in rows if int(r.get("id") or 0) > 0]
    return ids or [int(submission_id)]


def _clone_ticket_scan_permissions(conn, *, from_submission_id: int, to_submission_id: int) -> None:
    cur = conn.cursor()
    cur.execute(
        """
        INSERT INTO mobile_ticket_scan_permissions (submission_id, account_id, granted_by_account_id, created_at)
        SELECT %s, account_id, granted_by_account_id, %s
        FROM mobile_ticket_scan_permissions
        WHERE submission_id=%s
        ON CONFLICT (submission_id, account_id) DO NOTHING
        """,
        (int(to_submission_id), _iso_now(), int(from_submission_id)),
    )


def _clone_event_attendees(conn, *, from_submission_id: int, to_submission_id: int) -> None:
    cur = conn.cursor()
    cur.execute(
        """
        INSERT INTO mobile_event_attendees (submission_id, account_id, created_at)
        SELECT %s, account_id, created_at
        FROM mobile_event_attendees
        WHERE submission_id=%s
        ON CONFLICT (submission_id, account_id) DO NOTHING
        """,
        (int(to_submission_id), int(from_submission_id)),
    )


def _actor_can_manage_submission(
    conn,
    *,
    submission_id: int,
    account_id: int,
    role: str,
    actor_email: str,
) -> bool:
    cur = conn.cursor()
    cur.execute(
        """
        SELECT
            COALESCE(mes.submitter_email,'') AS submitter_email,
            COALESCE(se.account_id,0) AS owner_account_id
        FROM mobile_event_submissions mes
        LEFT JOIN saas_events se ON se.slug = mes.approved_event_slug
        WHERE mes.id=%s
        LIMIT 1
        """,
        (int(submission_id),),
    )
    row = cur.fetchone()
    if not row:
        return False
    if (role or "").strip().lower() == "super_admin":
        return True
    if int(row.get("owner_account_id") or 0) == int(account_id):
        return True
    if actor_email and (row.get("submitter_email") or "").strip().lower() == actor_email:
        return True
    cur.execute(
        """
        SELECT 1
        FROM mobile_ticket_scan_permissions
        WHERE submission_id=%s AND account_id=%s
        LIMIT 1
        """,
        (int(submission_id), int(account_id)),
    )
    return bool(cur.fetchone())


def _fetch_event_raffle_row(conn, submission_id: int) -> Optional[Dict[str, Any]]:
    cur = conn.cursor()
    cur.execute(
        """
        SELECT
            r.id,
            r.submission_id,
            r.starts_at,
            r.ends_at,
            r.winner_count,
            COALESCE(r.status, 'draft') AS status,
            r.created_by_account_id,
            r.drawn_by_account_id,
            r.created_at,
            r.updated_at,
            r.drawn_at
        FROM mobile_event_raffles r
        WHERE r.submission_id=%s
        LIMIT 1
        """,
        (int(submission_id),),
    )
    return cur.fetchone()


def _raffle_state_for_row(row: Dict[str, Any]) -> str:
    if not row:
        return "none"
    if (row.get("drawn_at") or "").strip():
        return "drawn"
    status = (row.get("status") or "").strip().lower()
    if status in {"draft", "active", "closed"}:
        return status

    # Legacy fallback for old time-based raffles that may not have a status yet.
    now_local = _now_local()
    starts_at = _parse_event_dt_value((row.get("starts_at") or "").strip())
    ends_at = _parse_event_dt_value((row.get("ends_at") or "").strip())
    if starts_at is not None and now_local < starts_at:
        return "draft"
    if ends_at is not None and now_local > ends_at:
        return "closed"
    if starts_at is not None or ends_at is not None:
        return "active"
    return "draft"


def _serialize_event_raffle(
    conn,
    row: Dict[str, Any],
    *,
    my_account_id: Optional[int],
    can_manage: bool,
) -> Dict[str, Any]:
    cur = conn.cursor()
    raffle_id = int(row["id"])
    cur.execute(
        """
        SELECT COUNT(*)::INT AS cnt
        FROM mobile_event_raffle_entries
        WHERE raffle_id=%s
        """,
        (raffle_id,),
    )
    entry_count = int((cur.fetchone() or {}).get("cnt") or 0)

    has_joined = False
    if my_account_id:
        cur.execute(
            """
            SELECT 1
            FROM mobile_event_raffle_entries
            WHERE raffle_id=%s AND account_id=%s
            LIMIT 1
            """,
            (raffle_id, int(my_account_id)),
        )
        has_joined = bool(cur.fetchone())

    cur.execute(
        """
        SELECT
            w.winner_kind,
            w.position,
            w.account_id,
            COALESCE(a.name, '') AS name,
            COALESCE(a.email, '') AS email,
            COALESCE(ps.username, '') AS username
        FROM mobile_event_raffle_winners w
        JOIN accounts a ON a.id = w.account_id
        LEFT JOIN mobile_profile_settings ps ON ps.account_id = w.account_id
        WHERE w.raffle_id=%s
        ORDER BY
            CASE
                WHEN w.winner_kind='primary' THEN 0
                WHEN w.winner_kind='reserve' THEN 1
                ELSE 2
            END,
            w.position ASC,
            w.account_id ASC
        """,
        (raffle_id,),
    )
    winners_rows = cur.fetchall() or []
    primary_winners = [
        {
            "position": int(w["position"]),
            "account_id": int(w["account_id"]),
            "name": display_name((w.get("name") or ""), (w.get("email") or ""), (w.get("username") or "")),
        }
        for w in winners_rows
        if (w.get("winner_kind") or "primary").strip().lower() != "reserve"
    ]
    reserve_winners = [
        {
            "position": int(w["position"]),
            "account_id": int(w["account_id"]),
            "name": display_name((w.get("name") or ""), (w.get("email") or ""), (w.get("username") or "")),
        }
        for w in winners_rows
        if (w.get("winner_kind") or "").strip().lower() == "reserve"
    ]
    visible_reserve_winners = reserve_winners if can_manage else []
    visible_reserve_count = int(row.get("winner_count") or 0) if can_manage else 0

    state = _raffle_state_for_row(row)
    is_drawn = state == "drawn"
    can_join = bool(my_account_id and state == "active" and not has_joined)
    can_draw = bool(can_manage and state == "closed" and not is_drawn)
    can_open = bool(can_manage and not is_drawn and state in {"draft", "closed"})
    can_close = bool(can_manage and not is_drawn and state == "active")
    can_edit = bool(can_manage and not is_drawn)
    return {
        "id": raffle_id,
        "submission_id": int(row["submission_id"]),
        "starts_at": _normalize_event_dt_text((row.get("starts_at") or "").strip()),
        "ends_at": _normalize_event_dt_text((row.get("ends_at") or "").strip()),
        "winner_count": int(row.get("winner_count") or 0),
        "reserve_count": visible_reserve_count,
        "created_at": (row.get("created_at") or "").strip(),
        "updated_at": (row.get("updated_at") or "").strip(),
        "drawn_at": (row.get("drawn_at") or "").strip(),
        "entry_count": entry_count,
        "state": state,
        "is_drawn": is_drawn,
        "has_joined": has_joined,
        "can_join": can_join,
        "can_manage": can_manage,
        "can_draw": can_draw,
        "can_open": can_open,
        "can_close": can_close,
        "can_edit": can_edit,
        "winners": primary_winners,
        "primary_winners": primary_winners,
        "reserve_winners": visible_reserve_winners,
        "winner_names": [w["name"] for w in primary_winners],
    }


def _account_comment_moderation(conn, account_id: int) -> Dict[str, Any]:
    cur = conn.cursor()
    cur.execute(
        """
        SELECT
            COALESCE(role, 'customer') AS role,
            COALESCE(can_create_mobile_event, 0) AS can_create_mobile_event
        FROM accounts
        WHERE id=%s
        LIMIT 1
        """,
        (int(account_id),),
    )
    row = cur.fetchone() or {}
    role = (row.get("role") or "customer").strip().lower()
    can_moderate = role == "super_admin"
    return {
        "role": role,
        "can_moderate": can_moderate,
    }


def _has_past_attendance_for_thread(conn, thread_submission_id: int, account_id: int) -> bool:
    cur = conn.cursor()
    cur.execute(
        """
        SELECT COALESCE(mes.event_date, mes.start_at, '') AS event_date_text
        FROM mobile_event_attendees mea
        JOIN mobile_event_submissions mes ON mes.id = mea.submission_id
        WHERE mea.account_id=%s
          AND COALESCE(mes.repeat_origin_submission_id, mes.id)=%s
        ORDER BY mea.created_at DESC, mes.id DESC
        """,
        (int(account_id), int(thread_submission_id)),
    )
    rows = cur.fetchall() or []
    today = _now_local().date()
    for row in rows:
        event_day = _parse_event_date_text((row.get("event_date_text") or "").strip())
        if event_day is None or event_day <= today:
            return True
    return False


def _serialize_event_comment(
    row: Dict[str, Any],
    *,
    my_account_id: Optional[int],
    can_moderate: bool,
) -> Dict[str, Any]:
    author_account_id = int(row["author_account_id"])
    created_at = (row.get("created_at") or "").strip()
    updated_at = (row.get("updated_at") or "").strip()
    is_mine = bool(my_account_id and my_account_id == author_account_id)
    return {
        "id": int(row["id"]),
        "thread_submission_id": int(row["thread_submission_id"]),
        "author_account_id": author_account_id,
        "author_name": display_name(
            (row.get("author_name") or ""),
            (row.get("author_email") or ""),
            (row.get("author_username") or ""),
        ),
        "author_is_verified": bool(row.get("author_is_verified")) or str(row.get("author_role") or "").strip().lower() in {"super_admin", "editor"},
        "body": (row.get("body") or "").strip(),
        "created_at": created_at,
        "updated_at": updated_at,
        "is_mine": is_mine,
        "can_edit": is_mine,
        "can_delete": bool(is_mine or can_moderate),
        "is_edited": bool(updated_at and created_at and updated_at != created_at),
    }


def _fetch_thread_comment_rows(conn, thread_submission_id: int) -> List[Dict[str, Any]]:
    cur = conn.cursor()
    cur.execute(
        """
        SELECT
            c.id,
            c.thread_submission_id,
            c.author_account_id,
            c.body,
            c.created_at,
            c.updated_at,
            COALESCE(a.name, '') AS author_name,
            COALESCE(a.email, '') AS author_email,
            COALESCE(a.role, '') AS author_role,
            COALESCE(ps.username, '') AS author_username,
            COALESCE(ps.is_verified, FALSE) AS author_is_verified
        FROM mobile_event_comments c
        JOIN accounts a ON a.id = c.author_account_id
        LEFT JOIN mobile_profile_settings ps ON ps.account_id = c.author_account_id
        WHERE c.thread_submission_id=%s
        ORDER BY c.updated_at DESC, c.created_at DESC, c.id DESC
        """,
        (int(thread_submission_id),),
    )
    return cur.fetchall() or []


class EventCommentUpsertRequest(BaseModel):
    body: str


class EventRaffleUpsertRequest(BaseModel):
    winner_count: int


def _can_scan_tickets(conn, submission_id: int, account_id: int) -> bool:
    cur = conn.cursor()
    cur.execute(
        """
        SELECT COALESCE(role,'customer') AS role
        FROM accounts
        WHERE id=%s
        LIMIT 1
        """,
        (int(account_id),),
    )
    row = cur.fetchone() or {}
    role = (row.get("role") or "customer").strip().lower()
    if role == "super_admin":
        return True

    ev = _get_event_submission(conn, submission_id)
    if not ev:
        return False
    owner_id = int(ev["owner_account_id"]) if ev.get("owner_account_id") is not None else 0
    if owner_id and owner_id == int(account_id):
        return True

    cur.execute(
        """
        SELECT 1
        FROM mobile_ticket_scan_permissions
        WHERE submission_id=%s AND account_id=%s
        LIMIT 1
        """,
        (int(submission_id), int(account_id)),
    )
    return bool(cur.fetchone())


def _resolve_account_by_email_or_wp(conn, email: str, wp_user_id: Optional[int] = None) -> Optional[int]:
    cur = conn.cursor()
    if wp_user_id:
        cur.execute(
            """
            SELECT app_account_id
            FROM identity_map
            WHERE wp_user_id=%s AND is_active=TRUE
            LIMIT 1
            """,
            (int(wp_user_id),),
        )
        row = cur.fetchone()
        if row and row.get("app_account_id") is not None:
            return int(row["app_account_id"])
    if email:
        cur.execute("SELECT id FROM accounts WHERE LOWER(email)=LOWER(%s) LIMIT 1", (email.strip().lower(),))
        row = cur.fetchone()
        if row:
            return int(row["id"])
    return None


def _create_ticket_rows(
    conn,
    *,
    account_id: int,
    submission_id: int,
    event_slug: str,
    event_name: str,
    woo_order_id: str,
    woo_order_item_id: str,
    woo_order_status: str,
    ticket_status: str,
    quantity: int,
) -> List[int]:
    qty = max(1, min(int(quantity), 20))
    cur = conn.cursor()
    created_ticket_ids: List[int] = []
    for i in range(qty):
        token = f"tkt_{uuid.uuid4().hex}"
        cur.execute(
            """
            INSERT INTO mobile_tickets
            (account_id, submission_id, event_slug, event_name, woo_order_id, woo_order_item_id, woo_order_status, qr_token, status, created_at, ticket_type)
            VALUES (%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,'paid')
            RETURNING id
            """,
            (
                int(account_id),
                int(submission_id),
                (event_slug or "").strip(),
                (event_name or "").strip(),
                (woo_order_id or "").strip(),
                f"{woo_order_item_id}-{i+1}",
                (woo_order_status or "").strip(),
                token,
                (ticket_status or "payment_pending").strip(),
                _iso_now(),
            ),
        )
        created_row = cur.fetchone() or {}
        created_id = int(created_row.get("id") or 0)
        if created_id > 0:
            created_ticket_ids.append(created_id)
    return created_ticket_ids


def _send_ticket_created_notifications(
    conn,
    *,
    notifications: List[Dict[str, Any]],
    submission_id: int,
    event_name: str,
    ticket_type: str,
) -> Dict[str, Any]:
    normalized_notifications: List[Dict[str, Any]] = []
    seen_targets = set()
    for item in notifications or []:
        if not isinstance(item, dict):
            continue
        account_id = int(item.get("account_id") or 0)
        if account_id <= 0:
            continue
        ticket_id = int(item.get("ticket_id") or 0)
        route = f"/profile/tickets/{ticket_id}" if ticket_id > 0 else "/profile/tickets"
        target_key = (account_id, route)
        if target_key in seen_targets:
            continue
        seen_targets.add(target_key)
        normalized_notifications.append(
            {
                "account_id": account_id,
                "ticket_id": ticket_id,
                "route": route,
            }
        )

    if not normalized_notifications:
        return {"ok": True, "inserted": 0, "push": {"attempted": 0, "success": 0, "failure": 0}}

    try:
        from app.routers.profile import _dispatch_push_for_accounts, _resolve_system_sender_account_id
    except Exception as exc:
        logger.warning(
            "ticket_created_notification_import_failed submission_id=%s ticket_type=%s err=%s",
            int(submission_id or 0),
            (ticket_type or "").strip(),
            str(exc),
        )
        return {"ok": False, "inserted": 0, "error": "notification_import_failed"}

    sender_account_id = 0
    try:
        sender_account_id = int(_resolve_system_sender_account_id(conn) or 0)
    except Exception as exc:
        logger.warning(
            "ticket_created_notification_sender_resolve_failed submission_id=%s ticket_type=%s err=%s",
            int(submission_id or 0),
            (ticket_type or "").strip(),
            str(exc),
        )

    safe_event_name = (event_name or "").strip() or "Bu etkinlik"
    title = "Dijital biletiniz oluşturuldu"
    body = f"{safe_event_name} organizasyonuna dijital biletiniz oluşturulmuştur. İyi eğlenceler dileriz."
    batch_id = f"ticket_created_{(ticket_type or 'paid').strip().lower()}_{int(submission_id or 0)}_{uuid.uuid4().hex[:10]}"

    try:
        cur = conn.cursor()
        cur.executemany(
            """
            INSERT INTO mobile_user_notifications
                (account_id, title, body, notification_type, sent_by_account_id, send_batch_id, send_to_all, target_route, created_at)
            VALUES (%s, %s, %s, 'ticket_created', %s, %s, FALSE, %s, NOW())
            """,
            [
                (
                    int(item["account_id"]),
                    title[:160],
                    body[:2000],
                    int(sender_account_id) if sender_account_id > 0 else None,
                    batch_id,
                    str(item["route"]),
                )
                for item in normalized_notifications
            ],
        )
        conn.commit()

        push_attempted = 0
        push_success = 0
        push_failure = 0
        push_errors: List[str] = []
        for item in normalized_notifications:
            push_attempted += 1
            try:
                push_result = _dispatch_push_for_accounts(
                    conn=conn,
                    account_ids=[int(item["account_id"])],
                    title=title,
                    body=body,
                    sender_account_id=int(sender_account_id) if sender_account_id > 0 else 0,
                    route=str(item["route"]),
                    notification_type="ticket_created",
                    extra_data={
                        "event_submission_id": int(submission_id or 0),
                        "event_name": safe_event_name,
                        "ticket_type": (ticket_type or "paid").strip().lower() or "paid",
                        "ticket_id": int(item.get("ticket_id") or 0),
                    },
                )
                push_success += int(push_result.get("success") or 0)
                push_failure += int(push_result.get("failure") or 0)
                for err in push_result.get("errors") or []:
                    if err:
                        push_errors.append(str(err))
            except Exception as exc:
                push_failure += 1
                push_errors.append(str(exc))

        push_summary = {
            "attempted": push_attempted,
            "success": push_success,
            "failure": push_failure,
        }
        if push_errors:
            push_summary["errors"] = push_errors[:10]
        logger.info(
            "ticket_created_notification_sent submission_id=%s ticket_type=%s accounts=%s push=%s",
            int(submission_id or 0),
            (ticket_type or "paid").strip().lower() or "paid",
            [int(item["account_id"]) for item in normalized_notifications],
            json.dumps(push_summary, ensure_ascii=False),
        )
        return {
            "ok": True,
            "inserted": len(normalized_notifications),
            "push": push_summary,
        }
    except Exception as exc:
        conn.rollback()
        logger.warning(
            "ticket_created_notification_failed submission_id=%s ticket_type=%s accounts=%s err=%s",
            int(submission_id or 0),
            (ticket_type or "paid").strip().lower() or "paid",
            [int(item["account_id"]) for item in normalized_notifications],
            str(exc),
        )
        return {"ok": False, "inserted": 0, "error": str(exc)}


def _ensure_guest_ticket(
    conn,
    *,
    account_id: int,
    submission_id: int,
    event_slug: str,
    event_name: str,
    guest_list_id: int,
    issued_by_account_id: int,
) -> tuple[int, bool]:
    cur = conn.cursor()
    cur.execute(
        """
        SELECT id, status, used_at
        FROM mobile_tickets
        WHERE submission_id=%s
          AND account_id=%s
          AND COALESCE(ticket_type,'paid')='guest'
        ORDER BY id DESC
        LIMIT 1
        """,
        (int(submission_id), int(account_id)),
    )
    existing = cur.fetchone()
    if existing and existing.get("id") is not None:
        cur.execute(
            """
            UPDATE mobile_tickets
            SET source_guest_list_id=%s,
                issued_by_account_id=%s,
                status=CASE
                    WHEN used_at IS NULL AND COALESCE(status,'active')='cancelled' THEN 'active'
                    ELSE status
                END
            WHERE id=%s
            """,
            (int(guest_list_id), int(issued_by_account_id), int(existing["id"])),
        )
        return int(existing["id"]), False

    token = f"guest_{uuid.uuid4().hex}"
    cur.execute(
        """
        INSERT INTO mobile_tickets
            (account_id, submission_id, event_slug, event_name, woo_order_id, woo_order_item_id, woo_order_status, qr_token, status, created_at, ticket_type, issued_by_account_id, source_guest_list_id)
        VALUES
            (%s,%s,%s,%s,'','',NULL,%s,'active',%s,'guest',%s,%s)
        RETURNING id
        """,
        (
            int(account_id),
            int(submission_id),
            (event_slug or "").strip(),
            (event_name or "").strip(),
            token,
            _iso_now(),
            int(issued_by_account_id),
            int(guest_list_id),
        ),
    )
    created = cur.fetchone() or {}
    return int(created.get("id") or 0), True


def _sync_guest_list_member_to_submission(
    conn,
    *,
    submission_id: int,
    guest_list_id: int,
    member_account_id: int,
    issued_by_account_id: int,
) -> Dict[str, Any]:
    cur = conn.cursor()
    cur.execute(
        """
        SELECT
            id,
            COALESCE(event_name,'') AS event_name,
            COALESCE(approved_event_slug,'') AS approved_event_slug,
            COALESCE(status,'') AS status
        FROM mobile_event_submissions
        WHERE id=%s
        LIMIT 1
        """,
        (int(submission_id),),
    )
    event_row = cur.fetchone()
    if not event_row:
        return {
            "submission_id": int(submission_id),
            "account_id": int(member_account_id),
            "event_name": "",
            "event_slug": "",
            "ticket_id": 0,
            "invitee_exists": False,
            "invitee_created": False,
            "ticket_created": False,
            "skipped_reason": "submission_not_found",
        }

    event_status = str(event_row.get("status") or "").strip().lower()
    if event_status != "approved":
        return {
            "submission_id": int(submission_id),
            "account_id": int(member_account_id),
            "event_name": (event_row.get("event_name") or "").strip(),
            "event_slug": (event_row.get("approved_event_slug") or "").strip(),
            "ticket_id": 0,
            "invitee_exists": False,
            "invitee_created": False,
            "ticket_created": False,
            "skipped_reason": f"submission_status_{event_status or 'unknown'}",
        }

    event_slug = (event_row.get("approved_event_slug") or "").strip()
    event_name = (event_row.get("event_name") or "").strip()

    cur.execute(
        """
        SELECT ticket_id
        FROM mobile_event_invitees
        WHERE submission_id=%s AND account_id=%s
        LIMIT 1
        """,
        (int(submission_id), int(member_account_id)),
    )
    existing_invitee = cur.fetchone()
    if existing_invitee:
        existing_ticket_id = int(existing_invitee.get("ticket_id") or 0)
        if existing_ticket_id > 0:
            return {
                "submission_id": int(submission_id),
                "account_id": int(member_account_id),
                "event_name": event_name,
                "event_slug": event_slug,
                "ticket_id": existing_ticket_id,
                "invitee_exists": True,
                "invitee_created": False,
                "ticket_created": False,
                "skipped_reason": "invitee_already_exists",
            }

        ticket_id, created_ticket = _ensure_guest_ticket(
            conn,
            account_id=int(member_account_id),
            submission_id=int(submission_id),
            event_slug=event_slug,
            event_name=event_name,
            guest_list_id=int(guest_list_id),
            issued_by_account_id=int(issued_by_account_id),
        )
        cur.execute(
            """
            UPDATE mobile_event_invitees
            SET ticket_id=%s
            WHERE submission_id=%s AND account_id=%s
            """,
            (ticket_id or None, int(submission_id), int(member_account_id)),
        )
        return {
            "submission_id": int(submission_id),
            "account_id": int(member_account_id),
            "event_name": event_name,
            "event_slug": event_slug,
            "ticket_id": int(ticket_id or 0),
            "invitee_exists": True,
            "invitee_created": False,
            "ticket_created": bool(created_ticket),
            "skipped_reason": "",
        }

    ticket_id, created_ticket = _ensure_guest_ticket(
        conn,
        account_id=int(member_account_id),
        submission_id=int(submission_id),
        event_slug=event_slug,
        event_name=event_name,
        guest_list_id=int(guest_list_id),
        issued_by_account_id=int(issued_by_account_id),
    )
    cur.execute(
        """
        INSERT INTO mobile_event_invitees
            (submission_id, account_id, source_guest_list_id, invited_by_account_id, ticket_id, created_at)
        VALUES
            (%s,%s,%s,%s,%s,%s)
        ON CONFLICT (submission_id, account_id) DO NOTHING
        """,
        (int(submission_id), int(member_account_id), int(guest_list_id), int(issued_by_account_id), ticket_id or None, _iso_now()),
    )
    return {
        "submission_id": int(submission_id),
        "account_id": int(member_account_id),
        "event_name": event_name,
        "event_slug": event_slug,
        "ticket_id": int(ticket_id or 0),
        "invitee_exists": False,
        "invitee_created": bool(cur.rowcount > 0),
        "ticket_created": bool(created_ticket),
        "skipped_reason": "",
    }


def _fetch_profile_school_snapshot(conn, account_id: int) -> Dict[str, Any]:
    cur = conn.cursor()
    cur.execute(
        """
        SELECT
            COALESCE(ds.name, ps.dance_school, '') AS school_name,
            ps.dance_school_id
        FROM accounts a
        LEFT JOIN mobile_profile_settings ps ON ps.account_id = a.id
        LEFT JOIN mobile_dance_schools ds ON ds.id = ps.dance_school_id
        WHERE a.id=%s
        LIMIT 1
        """,
        (int(account_id),),
    )
    row = cur.fetchone() or {}
    school_name = str(row.get("school_name") or "").strip()
    return {
        "school_name": school_name,
        "school_key": _normalize_school_key(school_name),
        "school_id": int(row.get("dance_school_id") or 0) if row.get("dance_school_id") else None,
    }


def _find_next_loyalty_submission(conn, *, origin_submission_id: int, current_submission_id: int) -> Optional[Dict[str, Any]]:
    cur = conn.cursor()
    cur.execute(
        """
        SELECT
            id,
            COALESCE(event_name,'') AS event_name,
            COALESCE(approved_event_slug,'') AS approved_event_slug,
            COALESCE(event_date, start_at, '') AS event_day_text
        FROM mobile_event_submissions
        WHERE status='approved'
          AND COALESCE(repeat_origin_submission_id, id)=%s
        ORDER BY COALESCE(event_date, start_at, created_at) ASC, id ASC
        """,
        (int(origin_submission_id),),
    )
    rows = cur.fetchall() or []
    current_seen = False
    today = _now_local().date()
    for row in rows:
        row_id = int(row["id"])
        if row_id == int(current_submission_id):
            current_seen = True
            continue
        event_day = _parse_event_date_text((row.get("event_day_text") or "").strip())
        if not current_seen and row_id != int(current_submission_id):
            continue
        if event_day is not None and event_day < today:
            continue
        return row
    return None


def _ensure_loyalty_reward_ticket(
    conn,
    *,
    account_id: int,
    origin_submission_id: int,
    current_submission_id: int,
    reward_cycle: int,
) -> Dict[str, Any]:
    cur = conn.cursor()
    cur.execute(
        """
        SELECT
            id,
            submission_id,
            event_name,
            status
        FROM mobile_tickets
        WHERE account_id=%s
          AND COALESCE(ticket_type,'paid')='loyalty_reward'
          AND COALESCE(reward_origin_submission_id,0)=%s
          AND COALESCE(reward_cycle,0)=%s
        ORDER BY id DESC
        LIMIT 1
        """,
        (int(account_id), int(origin_submission_id), int(reward_cycle)),
    )
    existing = cur.fetchone()
    if existing:
        return {
            "ticket_id": int(existing["id"]),
            "submission_id": int(existing.get("submission_id") or 0),
            "event_name": (existing.get("event_name") or "").strip(),
            "created": False,
        }

    target = _find_next_loyalty_submission(
        conn,
        origin_submission_id=int(origin_submission_id),
        current_submission_id=int(current_submission_id),
    )
    if not target:
        return {"ticket_id": 0, "submission_id": 0, "event_name": "", "created": False}

    event_name = (target.get("event_name") or "").strip()
    reward_name = event_name if "ucretsiz" in _normalize_school_key(event_name) else f"{event_name} - Ucretsiz Giris"
    token = f"reward_{uuid.uuid4().hex}"
    cur.execute(
        """
        INSERT INTO mobile_tickets
            (account_id, submission_id, event_slug, event_name, woo_order_id, woo_order_item_id, woo_order_status, qr_token, status, created_at, ticket_type, reward_origin_submission_id, reward_cycle)
        VALUES
            (%s,%s,%s,%s,'','',NULL,%s,'active',%s,'loyalty_reward',%s,%s)
        RETURNING id
        """,
        (
            int(account_id),
            int(target["id"]),
            (target.get("approved_event_slug") or "").strip(),
            reward_name,
            token,
            _iso_now(),
            int(origin_submission_id),
            int(reward_cycle),
        ),
    )
    row = cur.fetchone() or {}
    return {
        "ticket_id": int(row.get("id") or 0),
        "submission_id": int(target["id"]),
        "event_name": reward_name,
        "created": True,
    }


def _record_visnelik_loyalty_scan(
    conn,
    *,
    ticket_id: int,
    submission_id: int,
    account_id: int,
    ticket_type: str,
    school_name: str,
) -> Dict[str, Any]:
    origin_submission_id = _repeat_thread_origin_id(conn, submission_id)
    school_name_clean = str(school_name or "").strip()
    school_key = _normalize_school_key(school_name_clean)
    cur = conn.cursor()
    cur.execute(
        """
        SELECT COUNT(*)::INT AS cnt
        FROM mobile_ticket_scan_logs
        WHERE buyer_account_id=%s
          AND COALESCE(entry_origin_submission_id,0)=%s
          AND scan_result='accepted'
          AND COALESCE(ticket_type,'paid') <> 'loyalty_reward'
        """,
        (int(account_id), int(origin_submission_id)),
    )
    qualifying_visits = int((cur.fetchone() or {}).get("cnt") or 0)
    next_remaining = 0 if qualifying_visits % 5 == 0 else 5 - (qualifying_visits % 5)
    reward_cycle = qualifying_visits // 5 if qualifying_visits > 0 and qualifying_visits % 5 == 0 else 0
    reward_info: Dict[str, Any] = {"ticket_id": 0, "submission_id": 0, "event_name": "", "created": False}
    if reward_cycle > 0:
        reward_info = _ensure_loyalty_reward_ticket(
            conn,
            account_id=int(account_id),
            origin_submission_id=int(origin_submission_id),
            current_submission_id=int(submission_id),
            reward_cycle=int(reward_cycle),
        )

    cur.execute(
        """
        SELECT COUNT(*)::INT AS cnt
        FROM mobile_ticket_scan_logs
        WHERE COALESCE(entry_origin_submission_id,0)=%s
          AND scan_result='accepted'
          AND COALESCE(source_profile_school_key,'')=%s
        """,
        (int(origin_submission_id), school_key),
    )
    school_count = int((cur.fetchone() or {}).get("cnt") or 0) if school_key else 0
    return {
        "origin_submission_id": int(origin_submission_id),
        "school_name": school_name_clean,
        "school_key": school_key,
        "school_count": school_count,
        "qualifying_visits": qualifying_visits,
        "next_remaining": next_remaining,
        "reward_cycle": reward_cycle,
        "reward_ticket_id": int(reward_info.get("ticket_id") or 0),
        "reward_event_name": (reward_info.get("event_name") or "").strip(),
        "reward_created": bool(reward_info.get("created")),
    }


def _build_admin_loyalty_reports(conn, submission_ids: List[int]) -> Dict[str, Dict[str, Any]]:
    target_ids = [int(x) for x in (submission_ids or []) if int(x or 0) > 0]
    if not target_ids:
        return {}

    cur = conn.cursor()
    cur.execute(
        """
        SELECT
            id,
            COALESCE(event_name, '') AS event_name,
            COALESCE(status, '') AS status,
            COALESCE(event_date, start_at, '') AS event_day_text,
            COALESCE(repeat_origin_submission_id, id) AS origin_id
        FROM mobile_event_submissions
        WHERE id = ANY(%s)
        """,
        (target_ids,),
    )
    submission_rows = cur.fetchall() or []
    if not submission_rows:
        return {}

    origin_ids = sorted(
        {
            int(row.get("origin_id") or row.get("id") or 0)
            for row in submission_rows
            if int(row.get("origin_id") or row.get("id") or 0) > 0
        }
    )
    if not origin_ids:
        origin_ids = target_ids[:]

    cur.execute(
        """
        SELECT
            COALESCE(repeat_origin_submission_id, id) AS origin_id,
            COUNT(*)::INT AS thread_size
        FROM mobile_event_submissions
        WHERE COALESCE(repeat_origin_submission_id, id) = ANY(%s)
        GROUP BY 1
        """,
        (origin_ids,),
    )
    thread_sizes = {
        int(row["origin_id"]): int(row.get("thread_size") or 0)
        for row in (cur.fetchall() or [])
        if int(row.get("origin_id") or 0) > 0
    }

    cur.execute(
        """
        SELECT
            submission_id,
            COUNT(*) FILTER (WHERE scan_result='accepted')::INT AS accepted_scans,
            COUNT(DISTINCT buyer_account_id) FILTER (
                WHERE scan_result='accepted' AND buyer_account_id IS NOT NULL
            )::INT AS unique_buyers,
            COUNT(*) FILTER (WHERE scan_result='already_used')::INT AS already_used_hits,
            MAX(scan_at) FILTER (WHERE scan_result='accepted') AS last_scan_at
        FROM mobile_ticket_scan_logs
        WHERE submission_id = ANY(%s)
        GROUP BY submission_id
        """,
        (target_ids,),
    )
    current_counts = {
        int(row["submission_id"]): {
            "accepted_scans": int(row.get("accepted_scans") or 0),
            "unique_buyers": int(row.get("unique_buyers") or 0),
            "already_used_hits": int(row.get("already_used_hits") or 0),
            "last_scan_at": _json_time_text(row.get("last_scan_at") or ""),
        }
        for row in (cur.fetchall() or [])
        if int(row.get("submission_id") or 0) > 0
    }

    cur.execute(
        """
        SELECT
            COALESCE(entry_origin_submission_id, 0) AS origin_id,
            COUNT(*) FILTER (WHERE scan_result='accepted')::INT AS accepted_scans,
            COUNT(DISTINCT buyer_account_id) FILTER (
                WHERE scan_result='accepted' AND buyer_account_id IS NOT NULL
            )::INT AS unique_buyers,
            MAX(scan_at) FILTER (WHERE scan_result='accepted') AS last_scan_at
        FROM mobile_ticket_scan_logs
        WHERE COALESCE(entry_origin_submission_id, 0) = ANY(%s)
        GROUP BY 1
        """,
        (origin_ids,),
    )
    series_counts = {
        int(row["origin_id"]): {
            "accepted_scans": int(row.get("accepted_scans") or 0),
            "unique_buyers": int(row.get("unique_buyers") or 0),
            "last_scan_at": _json_time_text(row.get("last_scan_at") or ""),
        }
        for row in (cur.fetchall() or [])
        if int(row.get("origin_id") or 0) > 0
    }

    cur.execute(
        """
        SELECT
            COALESCE(entry_origin_submission_id, 0) AS origin_id,
            COALESCE(source_profile_school_key, '') AS school_key,
            COALESCE(NULLIF(MAX(source_profile_school_name), ''), 'Belirtilmedi') AS school_name,
            COUNT(*)::INT AS accepted_scans,
            COUNT(DISTINCT buyer_account_id)::INT AS unique_buyers,
            MAX(scan_at) AS last_scan_at
        FROM mobile_ticket_scan_logs
        WHERE COALESCE(entry_origin_submission_id, 0) = ANY(%s)
          AND scan_result='accepted'
        GROUP BY 1, 2
        ORDER BY accepted_scans DESC, school_name ASC
        """,
        (origin_ids,),
    )
    school_rows_map: Dict[int, List[Dict[str, Any]]] = {}
    for row in (cur.fetchall() or []):
        origin_id = int(row.get("origin_id") or 0)
        if origin_id <= 0:
            continue
        school_rows_map.setdefault(origin_id, []).append(
            {
                "school_key": (row.get("school_key") or "").strip(),
                "school_name": (row.get("school_name") or "Belirtilmedi").strip() or "Belirtilmedi",
                "accepted_scans": int(row.get("accepted_scans") or 0),
                "unique_buyers": int(row.get("unique_buyers") or 0),
                "last_scan_at": _json_time_text(row.get("last_scan_at") or ""),
            }
        )

    cur.execute(
        """
        SELECT
            COALESCE(l.entry_origin_submission_id, 0) AS origin_id,
            l.buyer_account_id,
            COALESCE(a.name, '') AS buyer_name,
            COALESCE(a.email, '') AS buyer_email,
            COALESCE(ps.username, '') AS buyer_username,
            COALESCE(NULLIF(MAX(l.source_profile_school_name), ''), '') AS school_name,
            COUNT(*)::INT AS qualifying_visits,
            MAX(l.scan_at) AS last_scan_at
        FROM mobile_ticket_scan_logs l
        JOIN accounts a ON a.id = l.buyer_account_id
        LEFT JOIN mobile_profile_settings ps ON ps.account_id = a.id
        WHERE COALESCE(l.entry_origin_submission_id, 0) = ANY(%s)
          AND l.scan_result='accepted'
          AND COALESCE(l.ticket_type, 'paid') <> 'loyalty_reward'
          AND COALESCE(l.buyer_account_id, 0) > 0
        GROUP BY 1, 2, a.name, a.email, ps.username
        ORDER BY origin_id ASC, qualifying_visits DESC, MAX(l.scan_at) DESC
        """,
        (origin_ids,),
    )
    user_progress_map: Dict[int, List[Dict[str, Any]]] = {}
    for row in (cur.fetchall() or []):
        origin_id = int(row.get("origin_id") or 0)
        if origin_id <= 0:
            continue
        visit_count = int(row.get("qualifying_visits") or 0)
        next_remaining = 0 if visit_count <= 0 or visit_count % 5 == 0 else 5 - (visit_count % 5)
        user_progress_map.setdefault(origin_id, []).append(
            {
                "account_id": int(row.get("buyer_account_id") or 0),
                "buyer_name": display_name(
                    (row.get("buyer_name") or ""),
                    (row.get("buyer_email") or ""),
                    (row.get("buyer_username") or ""),
                ),
                "buyer_email": (row.get("buyer_email") or "").strip(),
                "school_name": (row.get("school_name") or "").strip(),
                "qualifying_visits": visit_count,
                "earned_rewards": visit_count // 5,
                "next_remaining": next_remaining,
                "last_scan_at": _json_time_text(row.get("last_scan_at") or ""),
            }
        )

    cur.execute(
        """
        SELECT
            COALESCE(t.reward_origin_submission_id, 0) AS origin_id,
            t.id,
            t.account_id,
            t.submission_id,
            COALESCE(t.event_name, '') AS event_name,
            COALESCE(t.status, 'active') AS status,
            t.used_at,
            COALESCE(t.reward_cycle, 0)::INT AS reward_cycle,
            COALESCE(a.name, '') AS buyer_name,
            COALESCE(a.email, '') AS buyer_email,
            COALESCE(ps.username, '') AS buyer_username
        FROM mobile_tickets t
        JOIN accounts a ON a.id = t.account_id
        LEFT JOIN mobile_profile_settings ps ON ps.account_id = a.id
        WHERE COALESCE(t.ticket_type, 'paid')='loyalty_reward'
          AND COALESCE(t.reward_origin_submission_id, 0) = ANY(%s)
        ORDER BY origin_id ASC, reward_cycle DESC, t.id DESC
        """,
        (origin_ids,),
    )
    reward_rows_map: Dict[int, List[Dict[str, Any]]] = {}
    for row in (cur.fetchall() or []):
        origin_id = int(row.get("origin_id") or 0)
        if origin_id <= 0:
            continue
        used_at = _json_time_text(row.get("used_at") or "")
        reward_rows_map.setdefault(origin_id, []).append(
            {
                "ticket_id": int(row.get("id") or 0),
                "account_id": int(row.get("account_id") or 0),
                "submission_id": int(row.get("submission_id") or 0),
                "event_name": (row.get("event_name") or "").strip(),
                "status": (row.get("status") or "active").strip(),
                "used_at": used_at,
                "reward_cycle": int(row.get("reward_cycle") or 0),
                "buyer_name": display_name(
                    (row.get("buyer_name") or ""),
                    (row.get("buyer_email") or ""),
                    (row.get("buyer_username") or ""),
                ),
                "buyer_email": (row.get("buyer_email") or "").strip(),
                "is_used": bool(used_at),
            }
        )

    reports: Dict[str, Dict[str, Any]] = {}
    for row in submission_rows:
        submission_id = int(row.get("id") or 0)
        if submission_id <= 0:
            continue
        origin_id = int(row.get("origin_id") or submission_id)
        current_summary = current_counts.get(submission_id) or {}
        series_summary = series_counts.get(origin_id) or {}
        school_rows = school_rows_map.get(origin_id) or []
        user_rows = (user_progress_map.get(origin_id) or [])[:25]
        reward_rows = (reward_rows_map.get(origin_id) or [])[:20]
        reward_ticket_count = len(reward_rows_map.get(origin_id) or [])
        reward_ticket_used_count = sum(1 for item in (reward_rows_map.get(origin_id) or []) if item.get("is_used"))
        reward_ticket_active_count = sum(
            1
            for item in (reward_rows_map.get(origin_id) or [])
            if not item.get("is_used") and (item.get("status") or "").strip().lower() != "cancelled"
        )
        reports[str(submission_id)] = {
            "submission_id": submission_id,
            "origin_submission_id": origin_id,
            "event_name": (row.get("event_name") or "").strip(),
            "event_day_text": (row.get("event_day_text") or "").strip(),
            "status": (row.get("status") or "").strip(),
            "thread_size": int(thread_sizes.get(origin_id) or 1),
            "loyalty_enabled": bool(_is_visnelik_event(row.get("event_name"), "")),
            "summary": {
                "current_accepted_scans": int(current_summary.get("accepted_scans") or 0),
                "current_unique_buyers": int(current_summary.get("unique_buyers") or 0),
                "current_already_used_hits": int(current_summary.get("already_used_hits") or 0),
                "series_accepted_scans": int(series_summary.get("accepted_scans") or 0),
                "series_unique_buyers": int(series_summary.get("unique_buyers") or 0),
                "school_count": len(school_rows),
                "reward_ticket_count": reward_ticket_count,
                "reward_ticket_active_count": reward_ticket_active_count,
                "reward_ticket_used_count": reward_ticket_used_count,
                "last_scan_at": str(current_summary.get("last_scan_at") or series_summary.get("last_scan_at") or ""),
            },
            "schools": school_rows[:20],
            "user_progress": user_rows,
            "reward_tickets": reward_rows,
        }
    return reports


def _serialize_event_invitee(row: Dict[str, Any]) -> Dict[str, Any]:
    return {
        "account_id": int(row.get("account_id") or 0),
        "name": display_name(
            (row.get("name") or ""),
            (row.get("email") or ""),
            (row.get("username") or ""),
        ),
        "email": (row.get("email") or "").strip(),
        "avatar_url": (row.get("avatar_url") or "").strip(),
        "is_verified": bool(row.get("is_verified")) or str(row.get("role") or "").strip().lower() in {"super_admin", "editor"},
        "source_guest_list_id": int(row.get("source_guest_list_id") or 0) if row.get("source_guest_list_id") else None,
        "source_guest_list_name": (row.get("source_guest_list_name") or "").strip(),
        "ticket_id": int(row.get("ticket_id") or 0) if row.get("ticket_id") else None,
        "invited_at": _json_time_text(row.get("created_at")),
    }


def _fetch_event_invitees(conn, submission_id: int) -> List[Dict[str, Any]]:
    cur = conn.cursor()
    cur.execute(
        """
        SELECT
            ei.account_id,
            ei.source_guest_list_id,
            ei.ticket_id,
            ei.created_at,
            COALESCE(gl.name,'') AS source_guest_list_name,
            COALESCE(a.name,'') AS name,
            COALESCE(a.email,'') AS email,
            COALESCE(a.role,'') AS role,
            COALESCE(a.can_create_mobile_event,0) AS can_create_mobile_event,
            COALESCE(ps.username,'') AS username,
            COALESCE(ps.avatar_url,'') AS avatar_url,
            COALESCE(ps.is_verified, FALSE) AS is_verified
        FROM mobile_event_invitees ei
        JOIN accounts a ON a.id = ei.account_id
        LEFT JOIN mobile_profile_settings ps ON ps.account_id = ei.account_id
        LEFT JOIN mobile_guest_lists gl ON gl.id = ei.source_guest_list_id
        WHERE ei.submission_id=%s
        ORDER BY ei.created_at ASC, ei.account_id ASC
        """,
        (int(submission_id),),
    )
    rows = cur.fetchall() or []
    items: List[Dict[str, Any]] = []
    for row in rows:
        item = _serialize_event_invitee(row)
        if not item["is_verified"] and bool(int(row.get("can_create_mobile_event") or 0)):
            item["is_verified"] = True
        items.append(item)
    return items


def _render_qr_png_bytes(payload: str) -> bytes:
    qr = qrcode.QRCode(
        version=None,
        error_correction=qrcode.constants.ERROR_CORRECT_M,
        box_size=10,
        border=4,
    )
    qr.add_data((payload or "").strip())
    qr.make(fit=True)
    image = qr.make_image(fill_color="black", back_color="white")
    buf = BytesIO()
    image.save(buf, format="PNG")
    return buf.getvalue()


def _serialize_event_entry_source(row: Dict[str, Any]) -> Dict[str, Any]:
    source_id = int(row.get("source_id") or row.get("id") or 0)
    submission_id = int(row.get("submission_id") or 0)
    return {
        "source_id": source_id,
        "submission_id": submission_id,
        "label": (row.get("label") or "").strip(),
        "qr_token": (row.get("qr_token") or "").strip(),
        "is_active": bool(row.get("is_active")),
        "scan_count": int(row.get("scan_count") or 0),
        "last_scan_at": _json_time_text(row.get("last_scan_at")),
        "created_at": _json_time_text(row.get("created_at")),
        "qr_png_url": f"{PUBLIC_API_BASE}/events/manage/items/{submission_id}/entry-sources/{source_id}/qr.png",
    }


def _fetch_event_entry_sources(conn, submission_id: int) -> List[Dict[str, Any]]:
    cur = conn.cursor()
    cur.execute(
        """
        SELECT
            es.id AS source_id,
            es.submission_id,
            es.label,
            es.qr_token,
            es.is_active,
            es.created_at,
            COUNT(sc.id)::INT AS scan_count,
            MAX(sc.scanned_at) AS last_scan_at
        FROM mobile_event_entry_sources es
        LEFT JOIN mobile_event_entry_source_scans sc ON sc.source_id = es.id
        WHERE es.submission_id=%s
        GROUP BY es.id, es.submission_id, es.label, es.qr_token, es.is_active, es.created_at
        ORDER BY es.created_at ASC, es.id ASC
        """,
        (int(submission_id),),
    )
    rows = cur.fetchall() or []
    return [_serialize_event_entry_source(row) for row in rows]


def _event_entry_sources_payload(
    conn,
    *,
    submission_id: int,
    event_name: str,
) -> Dict[str, Any]:
    items = _fetch_event_entry_sources(conn, int(submission_id))
    return {
        "submission_id": int(submission_id),
        "event_name": (event_name or "").strip(),
        "total_sources": len(items),
        "active_sources": sum(1 for item in items if item["is_active"]),
        "total_scan_count": sum(int(item.get("scan_count") or 0) for item in items),
        "items": items,
    }


def _ticket_status_from_woo_status(order_status: str) -> str:
    s = (order_status or "").strip().lower()
    if s in {"completed", "processing"}:
        return "active"
    if s in {"pending", "on-hold", "checkout-draft"}:
        return "payment_pending"
    if s in {"failed", "cancelled", "refunded", "trash"}:
        return "cancelled"
    return "payment_pending"


def _fetch_woo_order_statuses(order_ids: List[str]) -> Dict[str, str]:
    ids: List[str] = []
    seen = set()
    for raw in order_ids or []:
        oid = str(raw or "").strip()
        if not oid or not oid.isdigit() or oid in seen:
            continue
        seen.add(oid)
        ids.append(oid)
    if not ids or not (WOO_BASE_URL and WOO_CONSUMER_KEY and WOO_CONSUMER_SECRET):
        return {}

    out: Dict[str, str] = {}
    try:
        with httpx.Client(timeout=8.0, follow_redirects=True) as client:
            for oid in ids[:25]:
                try:
                    resp = client.get(
                        f"{WOO_BASE_URL}/wp-json/wc/v3/orders/{oid}",
                        params={
                            "consumer_key": WOO_CONSUMER_KEY,
                            "consumer_secret": WOO_CONSUMER_SECRET,
                        },
                    )
                    if resp.status_code >= 400:
                        continue
                    data = resp.json() if resp.content else {}
                    if not isinstance(data, dict):
                        continue
                    status = str(data.get("status") or "").strip().lower()
                    order_id = str(data.get("id") or oid).strip()
                    if order_id and status:
                        out[order_id] = status
                except Exception as order_exc:
                    logger.warning("woo order status fetch failed order_id=%s err=%s", oid, order_exc)
    except Exception as exc:
        logger.warning("woo order status fetch batch failed err=%s", exc)
        return {}
    return out


def _find_or_create_submission_for_woo_product(
    conn,
    product_id: str,
    *,
    reference_day: Optional[date] = None,
) -> Optional[Dict[str, Any]]:
    pid = str(product_id or "").strip()
    if not pid:
        return None
    cur = conn.cursor()
    cur.execute(
        """
        SELECT id, event_name, approved_event_slug, status, event_date, start_at
        FROM mobile_event_submissions
        WHERE source_type='woo'
          AND source_ref=%s
          AND COALESCE(status,'') IN ('approved','expired')
        """,
        (pid,),
    )
    exact_rows = cur.fetchall() or []

    cur.execute(
        """
        SELECT
            COALESCE(slug,'') AS slug,
            COALESCE(name,'') AS name,
            COALESCE(ticket_url,'') AS ticket_url,
            COALESCE(is_active,0) AS is_active
        FROM saas_events
        WHERE external_source='woo' AND external_event_id=%s
        ORDER BY id DESC
        LIMIT 1
        """,
        (pid,),
    )
    se = cur.fetchone()
    slug = ""
    name = ""
    if se:
        slug = (se.get("slug") or "").strip()
        name = (se.get("name") or "").strip()

    candidate_rows: Dict[int, Dict[str, Any]] = {}
    for row in exact_rows:
        row_id = int(row.get("id") or 0)
        if row_id > 0:
            candidate_rows[row_id] = row

    if slug:
        cur.execute(
            """
            SELECT id, event_name, approved_event_slug, status, event_date, start_at
            FROM mobile_event_submissions
            WHERE approved_event_slug=%s
              AND COALESCE(status,'') IN ('approved','expired')
            """,
            (slug,),
        )
        for row in cur.fetchall() or []:
            row_id = int(row.get("id") or 0)
            if row_id > 0:
                candidate_rows[row_id] = row

    if name:
        cur.execute(
            """
            SELECT id, event_name, approved_event_slug, status, event_date, start_at
            FROM mobile_event_submissions
            WHERE LOWER(COALESCE(event_name,''))=LOWER(%s)
              AND COALESCE(status,'') IN ('approved','expired')
            """,
            (name,),
        )
        for row in cur.fetchall() or []:
            row_id = int(row.get("id") or 0)
            if row_id > 0:
                candidate_rows[row_id] = row

    picked = _pick_submission_candidate(list(candidate_rows.values()), reference_day=reference_day)
    if picked:
        return picked

    if not se:
        return None

    name = name or f"Woo Event {pid}"
    if slug:
        cur.execute(
            """
            SELECT id, event_name, approved_event_slug, status, event_date, start_at
            FROM mobile_event_submissions
            WHERE approved_event_slug=%s
              AND COALESCE(status,'') IN ('approved','expired')
            """,
            (slug,),
        )
        row = _pick_submission_candidate(cur.fetchall() or [], reference_day=reference_day)
        if row:
            return row
    else:
        slug = _slug_clean(name) or f"woo-{pid}"

    if not _is_truthy(se.get("is_active")):
        return None

    cur.execute(
        """
        INSERT INTO mobile_event_submissions
        (submitter_name, submitter_email, event_name, description, event_date, venue, organizer_name, program_text, cover_path, start_at, end_at, entry_fee, status, admin_note, created_at, approved_at, approved_event_slug, source_type, source_ref)
        VALUES (%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,'approved',%s,%s,%s,%s,'woo',%s)
        RETURNING id, event_name, approved_event_slug
        """,
        (
            "woo-sync",
            "woo-sync@dansmagazin.net",
            name,
            "",
            "",
            "",
            "",
            "",
            "",
            "",
            "",
            Decimal("0"),
            "Auto-created from saas_events Woo mapping",
            _iso_now(),
            _iso_now(),
            slug,
            pid,
        ),
    )
    return cur.fetchone()


def _cover_url(path: str) -> str:
    if not path:
        return ""
    return f"{PUBLIC_API_BASE}/events/submission-cover/{os.path.basename(path)}"


def _cover_exists(path: str) -> bool:
    if not path:
        return False
    bn = os.path.basename(path)
    return os.path.exists(os.path.join(UPLOAD_DIR, bn)) or os.path.exists(os.path.join(ALT_UPLOAD_DIR, bn))


def _convert_cover_to_jpeg_bytes(raw: bytes) -> bytes:
    if not raw:
        raise HTTPException(status_code=400, detail="Bos gorsel yuklenemedi")
    if len(raw) > EVENT_COVER_INPUT_MAX_BYTES:
        raise HTTPException(status_code=400, detail="Gorsel islenemeyecek kadar buyuk (max 45MB)")
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

            original = img.copy()
            resample = getattr(getattr(Image, "Resampling", Image), "LANCZOS", Image.LANCZOS)
            best: bytes = b""

            for max_side_limit in EVENT_COVER_MAX_SIDE_STEPS:
                work = original.copy()
                max_side = max(int(work.width or 0), int(work.height or 0))
                if max_side > max_side_limit:
                    scale = max_side_limit / float(max_side)
                    target = (
                        max(1, int(round(work.width * scale))),
                        max(1, int(round(work.height * scale))),
                    )
                    work = work.resize(target, resample)

                for quality in EVENT_COVER_QUALITY_STEPS:
                    out = BytesIO()
                    work.save(out, format="JPEG", quality=quality, optimize=True, progressive=True)
                    candidate = out.getvalue()
                    if not best or len(candidate) < len(best):
                        best = candidate
                    if len(candidate) <= EVENT_COVER_TARGET_MAX_BYTES:
                        return candidate

            if best:
                return best
    except HTTPException:
        raise
    except Exception:
        raise HTTPException(status_code=400, detail="Gorsel okunamadi. Lutfen gecerli bir fotograf secin.")

    raise HTTPException(status_code=400, detail="Gorsel islenemedi")


def _save_cover(upload: UploadFile) -> str:
    filename = f"{uuid.uuid4().hex}.jpg"
    # Kalıcı dizin olarak ana proje altını kullan; deploy sırasında silinmez.
    abs_path = os.path.join(ALT_UPLOAD_DIR, filename)
    raw = upload.file.read()
    jpeg_data = _convert_cover_to_jpeg_bytes(raw)
    with open(abs_path, "wb") as f:
        f.write(jpeg_data)
    return abs_path


def _slug_clean(v: str) -> str:
    s = re.sub(r"[^a-z0-9]+", "-", (v or "").strip().lower())
    return re.sub(r"-{2,}", "-", s).strip("-")


def _unique_event_slug(conn, base_slug: str) -> str:
    slug = _slug_clean(base_slug) or f"woo-{uuid.uuid4().hex[:8]}"
    c = conn.cursor()
    n = 2
    while True:
        c.execute("SELECT 1 FROM saas_events WHERE slug=%s LIMIT 1", (slug,))
        if not c.fetchone():
            return slug
        slug = f"{_slug_clean(base_slug) or 'woo-event'}-{n}"
        n += 1


def _resolve_owner_account(conn, submitter_email: str) -> tuple[int, str, str]:
    email = (submitter_email or "").strip().lower()
    c = conn.cursor()
    if email:
        c.execute(
            """
            SELECT id, COALESCE(name,'') AS name, COALESCE(email,'') AS email
            FROM accounts
            WHERE LOWER(email)=LOWER(%s) AND COALESCE(is_active,1)=1
            LIMIT 1
            """,
            (email,),
        )
        row = c.fetchone()
        if row:
            return int(row["id"]), (row.get("name") or "").strip(), (row.get("email") or "").strip().lower()

    c.execute(
        """
        SELECT id, COALESCE(name,'') AS name, COALESCE(email,'') AS email
        FROM accounts
        WHERE COALESCE(is_active,1)=1
        ORDER BY CASE WHEN COALESCE(role,'')='super_admin' THEN 0 ELSE 1 END, id ASC
        LIMIT 1
        """
    )
    row = c.fetchone()
    if not row:
        raise HTTPException(status_code=500, detail="accounts tablosunda aktif kullanıcı bulunamadı")
    return int(row["id"]), (row.get("name") or "").strip(), (row.get("email") or "").strip().lower()


def _parse_entry_fee(product: Dict[str, Any]) -> Decimal:
    # wc/v3 => regular_price/price (e.g. "250")
    raw = (product.get("regular_price") or product.get("price") or "").__str__().strip()
    if raw:
        try:
            return Decimal(raw)
        except Exception:
            pass

    # wc/store/v1 => prices.price in minor units (e.g. "25000" for 250.00)
    prices = product.get("prices") if isinstance(product.get("prices"), dict) else {}
    minor = str(prices.get("price") or "").strip()
    if minor.isdigit():
        return (Decimal(minor) / Decimal("100")).quantize(Decimal("0.01"))
    return Decimal("0")


def _meta_get(product: Dict[str, Any], *keys: str) -> str:
    wanted = {k.strip().lower() for k in keys if k.strip()}
    md = product.get("meta_data")
    if isinstance(md, list):
        for item in md:
            if not isinstance(item, dict):
                continue
            k = (item.get("key") or "").__str__().strip().lower()
            if k in wanted:
                return (item.get("value") or "").__str__().strip()
    for k in keys:
        if k in product and product.get(k) is not None:
            return str(product.get(k)).strip()
    return ""


def _extract_cover_url(product: Dict[str, Any]) -> str:
    images = product.get("images")
    if isinstance(images, list) and images:
        first = images[0] if isinstance(images[0], dict) else {}
        for k in ("src", "thumbnail", "url"):
            v = (first.get(k) or "").__str__().strip()
            if v:
                return v
    img = product.get("image")
    if isinstance(img, dict):
        for k in ("src", "thumbnail", "url"):
            v = (img.get(k) or "").__str__().strip()
            if v:
                return v
    return ""


def _clean_html_text(s: str) -> str:
    x = html.unescape((s or "").strip())
    x = re.sub(r"<(script|style)\b[^>]*>.*?</\1>", " ", x, flags=re.IGNORECASE | re.DOTALL)
    x = re.sub(r"<[^>]+>", " ", x)
    x = re.sub(r"\s+", " ", x).strip()
    return x


def _extract_woo_product(product: Dict[str, Any]) -> Dict[str, Any]:
    pid = int(product.get("id") or 0)
    name = (product.get("name") or "").__str__().strip()
    slug = (product.get("slug") or "").__str__().strip()
    if not slug:
        slug = _slug_clean(name) or f"woo-{pid}"
    ticket_url = (product.get("permalink") or "").__str__().strip()
    status = (product.get("status") or "publish").__str__().strip().lower()
    description = _clean_html_text((product.get("description") or product.get("short_description") or "").__str__().strip())
    entry_fee = _parse_entry_fee(product)
    event_date = _meta_get(product, "event_date", "_event_date", "start_at", "_start_at") or (
        product.get("date_created") or product.get("date_modified") or ""
    ).__str__().strip()
    submitter_email = _meta_get(product, "submitter_email", "_submitter_email", "organizer_email").lower()
    venue = _meta_get(product, "venue", "_venue", "event_location", "_event_location", "location")
    organizer_name = _meta_get(product, "organizer_name", "_organizer_name", "organizer")
    program_text = _meta_get(product, "program_text", "_program_text", "program", "_program")
    cover_url = _extract_cover_url(product)
    is_active = 1 if status in {"publish", "private"} else 0
    return {
        "woo_id": str(pid),
        "name": name or f"Woo Ürün {pid}",
        "slug": slug,
        "ticket_url": ticket_url,
        "status": status,
        "is_active": is_active,
        "description": description,
        "event_date": event_date,
        "entry_fee": entry_fee,
        "submitter_email": submitter_email,
        "venue": venue,
        "organizer_name": organizer_name,
        "program_text": program_text,
        "cover_url": cover_url,
    }


def _upsert_from_woo_product(conn, product_data: Dict[str, Any]) -> Dict[str, Any]:
    p = _extract_woo_product(product_data)
    event_dt = _normalize_event_dt_text(p.get("event_date") or "")
    woo_id = p["woo_id"]
    if not woo_id or woo_id == "0":
        raise HTTPException(status_code=400, detail="Woo product id eksik")

    owner_id, owner_name, owner_email = _resolve_owner_account(conn, p["submitter_email"])
    c = conn.cursor()

    c.execute(
        """
        SELECT id, slug
        FROM saas_events
        WHERE (external_source='woo' AND external_event_id=%s)
           OR (ticket_url=%s AND %s <> '')
           OR slug=%s
        ORDER BY id ASC
        LIMIT 1
        """,
        (woo_id, p["ticket_url"], p["ticket_url"], p["slug"]),
    )
    event = c.fetchone()
    created_event = False
    if event:
        event_id = int(event["id"])
        final_slug = (event.get("slug") or "").strip() or p["slug"]
        c.execute(
            """
            UPDATE saas_events
            SET account_id=%s,
                name=%s,
                slug=%s,
                is_active=%s,
                external_source='woo',
                external_event_id=%s,
                ticket_url=%s
            WHERE id=%s
            """,
            (owner_id, p["name"], final_slug, p["is_active"], woo_id, p["ticket_url"], event_id),
        )
    else:
        final_slug = _unique_event_slug(conn, p["slug"])
        c.execute(
            """
            INSERT INTO saas_events (account_id, name, slug, is_active, created_at, external_source, external_event_id, ticket_url, album_enabled)
            VALUES (%s,%s,%s,%s,%s,'woo',%s,%s,FALSE)
            RETURNING id
            """,
            (owner_id, p["name"], final_slug, p["is_active"], _iso_now(), woo_id, p["ticket_url"]),
        )
        event_id = int(c.fetchone()["id"])
        created_event = True

    c.execute(
        """
        SELECT id
        FROM mobile_event_submissions
        WHERE approved_event_slug=%s
        ORDER BY id DESC
        LIMIT 1
        """,
        (final_slug,),
    )
    sub = c.fetchone()
    created_submission = False
    if sub:
        submission_id = int(sub["id"])
        c.execute(
            """
            UPDATE mobile_event_submissions
            SET submitter_name=%s,
                submitter_email=%s,
                event_name=%s,
                description=%s,
                event_date=%s,
                venue=%s,
                organizer_name=%s,
                program_text=%s,
                cover_path=%s,
                start_at=%s,
                end_at=%s,
                entry_fee=%s,
                status='approved',
                approved_at=COALESCE(approved_at, %s),
                approved_event_slug=%s,
                source_type='woo',
                source_ref=%s,
                admin_note=COALESCE(admin_note,'')
            WHERE id=%s
            """,
            (
                owner_name or "woo-sync",
                owner_email or p["submitter_email"] or "woo-sync@dansmagazin.net",
                p["name"],
                p["description"],
                event_dt,
                p["venue"],
                p["organizer_name"],
                p["program_text"],
                p["cover_url"],
                event_dt,
                event_dt,
                p["entry_fee"],
                _iso_now(),
                final_slug,
                woo_id,
                submission_id,
            ),
        )
    else:
        c.execute(
            """
            INSERT INTO mobile_event_submissions
            (submitter_name, submitter_email, event_name, description, event_date, venue, organizer_name, program_text, cover_path, start_at, end_at, entry_fee, status, admin_note, created_at, approved_at, approved_event_slug, source_type, source_ref)
            VALUES (%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,'approved','Woo backfill/sync',%s,%s,%s,'woo',%s)
            RETURNING id
            """,
            (
                owner_name or "woo-sync",
                owner_email or p["submitter_email"] or "woo-sync@dansmagazin.net",
                p["name"],
                p["description"],
                event_dt,
                p["venue"],
                p["organizer_name"],
                p["program_text"],
                p["cover_url"],
                event_dt,
                event_dt,
                p["entry_fee"],
                _iso_now(),
                _iso_now(),
                final_slug,
                woo_id,
            ),
        )
        submission_id = int(c.fetchone()["id"])
        created_submission = True

    return {
        "woo_id": woo_id,
        "slug": final_slug,
        "ticket_url": p["ticket_url"],
        "is_active": p["is_active"],
        "event_id": event_id,
        "submission_id": submission_id,
        "created_event": created_event,
        "created_submission": created_submission,
    }


def _fetch_woo_products_backfill(per_page: int, max_pages: int) -> tuple[str, List[Dict[str, Any]]]:
    products: List[Dict[str, Any]] = []
    per_page = max(1, min(int(per_page), 100))
    max_pages = max(1, min(int(max_pages), 50))

    # 1) wc/v3 (auth) -> tum status'leri okuyabilir
    if WOO_BASE_URL and WOO_CONSUMER_KEY and WOO_CONSUMER_SECRET:
        with httpx.Client(timeout=25.0) as client:
            for page in range(1, max_pages + 1):
                r = client.get(
                    f"{WOO_BASE_URL}/wp-json/wc/v3/products",
                    params={
                        "consumer_key": WOO_CONSUMER_KEY,
                        "consumer_secret": WOO_CONSUMER_SECRET,
                        "per_page": per_page,
                        "page": page,
                        "orderby": "date",
                        "order": "desc",
                        "status": "any",
                    },
                )
                if r.status_code != 200:
                    raise HTTPException(status_code=502, detail=f"Woo v3 products okunamadı (HTTP {r.status_code})")
                rows = r.json()
                if not isinstance(rows, list) or not rows:
                    break
                products.extend([x for x in rows if isinstance(x, dict)])
                if len(rows) < per_page:
                    break
        return "wc_v3", products

    # 2) Public wc/store/v1 fallback (yalniz publish)
    if not WOO_BASE_URL:
        raise HTTPException(status_code=500, detail="WOO_BASE_URL eksik")
    with httpx.Client(timeout=25.0) as client:
        for page in range(1, max_pages + 1):
            r = client.get(
                f"{WOO_BASE_URL}/wp-json/wc/store/v1/products",
                params={"per_page": per_page, "page": page, "orderby": "date", "order": "desc"},
            )
            if r.status_code != 200:
                raise HTTPException(status_code=502, detail=f"Woo store products okunamadı (HTTP {r.status_code})")
            rows = r.json()
            if not isinstance(rows, list) or not rows:
                break
            products.extend([x for x in rows if isinstance(x, dict)])
            if len(rows) < per_page:
                break
    return "wc_store_v1", products


@router.get("", summary="Onaylanmış etkinlik listesi")
def list_events(limit: int = 50, city: str = "", event_kind: str = "", dance_styles: str = ""):
    conn = db_conn()
    cur = conn.cursor()
    _rollover_and_expire_events(conn)
    conn.commit()
    wheres = ["mes.status='approved'", "COALESCE(se.is_active, 1)=1"]
    vals: List[Any] = []
    city_q = (city or "").strip().lower()
    kind_q = (event_kind or "").strip().lower()
    style_q = _parse_dance_styles(dance_styles)
    if city_q:
        wheres.append("LOWER(COALESCE(mes.city,''))=%s")
        vals.append(city_q)
    if kind_q and kind_q != "all":
        wheres.append("LOWER(COALESCE(mes.event_kind,''))=%s")
        vals.append(kind_q)
    if style_q:
        style_clauses = []
        for style in style_q:
            style_clauses.append("(',' || LOWER(COALESCE(mes.dance_styles,'')) || ',') LIKE %s")
            vals.append(f"%,{style},%")
        wheres.append("(" + " OR ".join(style_clauses) + ")")
    cur.execute(
        f"""
        SELECT
            mes.id,
            mes.event_name,
            mes.description,
            mes.event_date,
            mes.venue,
            COALESCE(mes.venue_map_url,'') AS venue_map_url,
            COALESCE(mes.city,'') AS city,
            COALESCE(mes.event_kind,'') AS event_kind,
            COALESCE(mes.dance_styles,'') AS dance_styles,
            COALESCE(mes.ticket_sales_enabled, TRUE) AS ticket_sales_enabled,
            COALESCE(mes.repeat_weekly, FALSE) AS repeat_weekly,
            mes.repeat_weekday,
            mes.organizer_name,
            mes.program_text,
            mes.cover_path,
            COALESCE(mes.cover_crop, 'center') AS cover_crop,
            mes.start_at,
            mes.end_at,
            mes.entry_fee,
            mes.created_at,
            mes.approved_at,
            mes.approved_event_slug,
            COALESCE(se.ticket_url, '') AS ticket_url,
            COALESCE(se.external_event_id, '') AS woo_product_id,
            (
                SELECT COUNT(*)
                FROM mobile_event_attendees mea
                WHERE mea.submission_id = mes.id
            ) AS attendees_count
        FROM mobile_event_submissions mes
        LEFT JOIN saas_events se ON se.slug = mes.approved_event_slug
        WHERE {' AND '.join(wheres)}
        ORDER BY COALESCE(mes.event_date, mes.start_at, mes.approved_at, mes.created_at) ASC
        LIMIT %s
        """,
        tuple(vals + [max(1, min(int(limit), 500))]),
    )
    rows = cur.fetchall() or []
    conn.close()
    items = []
    for r in rows:
        venue_name, venue_map = _split_venue_fields((r.get("venue") or ""), (r.get("venue_map_url") or ""))
        cover_path = (r["cover_path"] or "").strip()
        cover_url = ""
        if cover_path.startswith("http://") or cover_path.startswith("https://"):
            cover_url = cover_path
        elif cover_path and _cover_exists(cover_path):
            cover_url = _cover_url(cover_path)
        ticket_sales_enabled = bool(
            r.get("ticket_sales_enabled") if r.get("ticket_sales_enabled") is not None else True
        )
        ticket_url = (r["ticket_url"] or "").strip() if ticket_sales_enabled else ""
        woo_product_id = (r["woo_product_id"] or "").strip() if ticket_sales_enabled else ""
        event_date_out = _normalize_event_dt_text(r["event_date"] or r["start_at"] or "")
        start_at_out = _normalize_event_dt_text(r["start_at"] or "")
        end_at_out = _normalize_event_dt_text(r["end_at"] or "")
        # Backward compatibility: older app builds prioritize woo_product_id and force cart.
        # If we already have a product page URL, leave woo_product_id empty so app opens product detail page.
        if ticket_url and ("/urun/" in ticket_url or "post_type=product" in ticket_url):
            woo_product_id = ""
        items.append(
            {
                "id": r["id"],
                "name": r["event_name"],
                "description": _clean_html_text(r["description"] or ""),
                "event_date": event_date_out,
                "venue": venue_name,
                "venue_map_url": venue_map,
                "city": (r.get("city") or "").strip(),
                "event_kind": (r.get("event_kind") or "").strip(),
                "dance_styles": _deserialize_dance_styles(r.get("dance_styles")),
                "cover_crop": _normalize_cover_crop(r.get("cover_crop")),
                "ticket_sales_enabled": ticket_sales_enabled,
                "repeat_weekly": bool(r.get("repeat_weekly")),
                "repeat_weekday": (
                    int(r.get("repeat_weekday"))
                    if r.get("repeat_weekday") is not None and str(r.get("repeat_weekday")).strip() != ""
                    else None
                ),
                "organizer_name": r["organizer_name"] or "",
                "program_text": r["program_text"] or "",
                "cover": cover_url,
                "start_at": start_at_out,
                "end_at": end_at_out,
                "entry_fee": float(r["entry_fee"]) if r["entry_fee"] is not None else 0.0,
                "ticket_url": ticket_url,
                "woo_product_id": woo_product_id,
                "slug": r["approved_event_slug"] or "",
                "attendees_count": int(r.get("attendees_count") or 0),
            }
        )
    return {"section": "etkinlikler", "items": items}


@router.post("/submissions", summary="Yeni etkinlik talebi oluştur")
async def create_submission(
    submitter_name: str = Form(""),
    submitter_email: str = Form(""),
    event_name: str = Form(...),
    description: str = Form(""),
    event_date: str = Form(""),
    venue: str = Form(""),
    venue_map_url: str = Form(""),
    city: str = Form(""),
    event_kind: str = Form("dance_night"),
    dance_styles: str = Form(""),
    ticket_sales_enabled: str = Form("0"),
    create_photo_album: str = Form("0"),
    repeat_mode: Optional[str] = Form(default=None),
    repeat_weekly: str = Form("0"),
    repeat_weekday: str = Form(""),
    repeat_selected_dates: Optional[str] = Form(default=None),
    organizer_name: str = Form(""),
    program_text: str = Form(""),
    start_at: str = Form(""),
    end_at: str = Form(""),
    entry_fee: str = Form("0"),
    clone_attendees_from_submission_id: Optional[int] = Form(default=None),
    cover_image: Optional[UploadFile] = File(None),
    authorization: Optional[str] = Header(default=None),
): # Changed _db_conn to db_conn
    if len(event_name.strip()) < 2:
        raise HTTPException(status_code=400, detail="Etkinlik adı çok kısa")
    city_val = city.strip()
    if not city_val:
        raise HTTPException(status_code=400, detail="Şehir zorunlu")
    kind_val = (event_kind or "").strip().lower() or "dance_night"
    if kind_val not in ALLOWED_EVENT_KINDS:
        raise HTTPException(status_code=400, detail="Geçersiz etkinlik türü")
    dance_styles_val = _serialize_dance_styles(dance_styles)
    ticket_sales_val = (ticket_sales_enabled or "").strip().lower() in {
        "1",
        "true",
        "yes",
        "on",
    }
    create_photo_album_val = (create_photo_album or "").strip().lower() in {"1", "true", "yes", "on"}
    repeat_weekly_requested = (repeat_weekly or "").strip().lower() in {"1", "true", "yes", "on"}
    repeat_mode_val = _normalize_repeat_mode(repeat_mode, repeat_weekly_enabled=repeat_weekly_requested)
    event_date_val, start_at_val, end_at_val = _coerce_event_window(event_date, start_at, end_at)
    if kind_val == "promo_lesson":
        # Tanitim dersi uygulamaya ozeldir; bilet/woo/tekrar akisini acmaz.
        ticket_sales_val = False
        repeat_mode_val = "none"
    repeat_weekday_val: Optional[int] = None
    repeat_selected_dates_val: List[date] = []
    repeat_weekly_val = repeat_mode_val == "weekly_fixed"
    if repeat_mode_val == "weekly_fixed":
        raw = (repeat_weekday or "").strip()
        if raw:
            if not raw.isdigit() or int(raw) < 0 or int(raw) > 6:
                raise HTTPException(status_code=400, detail="Tekrar günü geçersiz")
            repeat_weekday_val = int(raw)
        else:
            parsed = _parse_event_date_text(event_date_val)
            if parsed is None:
                raise HTTPException(status_code=400, detail="Tekrar için etkinlik tarihi zorunlu")
            repeat_weekday_val = parsed.weekday()
    elif repeat_mode_val == "selected_dates":
        repeat_selected_dates_val = _parse_repeat_selected_dates(repeat_selected_dates)
        if not repeat_selected_dates_val:
            raise HTTPException(status_code=400, detail="Toplu oluşturma için en az bir tarih seçin")
    venue_map_url_val = _normalize_map_url(venue_map_url)
    try:
        fee_val = Decimal(entry_fee or "0")
    except InvalidOperation:
        raise HTTPException(status_code=400, detail="Geçersiz giriş ücreti")
    cover_path = "" # Changed _db_conn to db_conn
    if cover_image and getattr(cover_image, "filename", ""):
        cover_path = _save_cover(cover_image)
    conn = db_conn()
    cur = conn.cursor()
    actor = _require_editor_account(conn, authorization)
    actor_account_id = int(actor["account_id"])
    actor_role = (actor.get("role") or "").strip().lower()
    actor_email = (actor.get("email") or "").strip().lower()
    fallback_name = actor["name"] or submitter_name.strip() or "mobile-user"
    fallback_email = actor["email"] or submitter_email.strip().lower() or "mobile-user@dansmagazin.net"
    created_at = _iso_now()
    created_ids: List[int] = []
    clone_attendees_from_id = int(clone_attendees_from_submission_id or 0) if clone_attendees_from_submission_id else 0
    clone_thread_origin_id: Optional[int] = None
    if clone_attendees_from_id > 0 and not _actor_can_manage_submission(
        conn,
        submission_id=clone_attendees_from_id,
        account_id=actor_account_id,
        role=actor_role,
        actor_email=actor_email,
    ):
        conn.close()
        raise HTTPException(status_code=403, detail="Kaynak etkinliğin katılımcıları kopyalanamadı")
    if clone_attendees_from_id > 0:
        clone_thread_origin_id = _repeat_thread_origin_id(conn, clone_attendees_from_id)
    if repeat_mode_val == "selected_dates":
        base_event_source = event_date_val or start_at_val
        origin_submission_id: Optional[int] = clone_thread_origin_id
        for target_day in repeat_selected_dates_val:
            shifted_start_at, shifted_end_at = _shift_event_window_to_date(
                start_at_val or event_date_val,
                end_at_val or start_at_val or event_date_val,
                target_day,
            )
            created_id = _insert_mobile_event_submission(
                cur,
                submitter_name=fallback_name,
                submitter_email=fallback_email,
                event_name=event_name.strip(),
                description=description.strip(),
                event_date=_shift_event_dt_to_date(base_event_source, target_day),
                venue=venue.strip(),
                venue_map_url=venue_map_url_val,
                city=city_val,
                event_kind=kind_val,
                dance_styles=dance_styles_val,
                ticket_sales_enabled=ticket_sales_val,
                create_photo_album=create_photo_album_val,
                repeat_weekly=False,
                repeat_weekday=None,
                repeat_origin_submission_id=origin_submission_id,
                organizer_name=organizer_name.strip(),
                program_text=program_text.strip(),
                cover_path=cover_path,
                start_at=shifted_start_at,
                end_at=shifted_end_at,
                entry_fee=fee_val,
                status="pending",
                created_at=created_at,
            )
            if created_id > 0:
                if origin_submission_id is None:
                    origin_submission_id = created_id
                    cur.execute(
                        "UPDATE mobile_event_submissions SET repeat_origin_submission_id=%s WHERE id=%s",
                        (origin_submission_id, created_id),
                    )
                created_ids.append(created_id)
    else:
        created_id = _insert_mobile_event_submission(
            cur,
            submitter_name=fallback_name,
            submitter_email=fallback_email,
            event_name=event_name.strip(),
            description=description.strip(),
            event_date=event_date_val,
            venue=venue.strip(),
            venue_map_url=venue_map_url_val,
            city=city_val,
            event_kind=kind_val,
            dance_styles=dance_styles_val,
            ticket_sales_enabled=ticket_sales_val,
            create_photo_album=create_photo_album_val,
            repeat_weekly=repeat_weekly_val,
            repeat_weekday=repeat_weekday_val,
            repeat_origin_submission_id=clone_thread_origin_id,
            organizer_name=organizer_name.strip(),
            program_text=program_text.strip(),
            cover_path=cover_path,
            start_at=start_at_val,
            end_at=end_at_val,
            entry_fee=fee_val,
            status="pending",
            created_at=created_at,
        )
        if created_id > 0:
            created_ids.append(created_id)
    if clone_attendees_from_id > 0:
        for created_id in created_ids:
            if int(created_id) == clone_attendees_from_id:
                continue
            _clone_event_attendees(
                conn,
                from_submission_id=clone_attendees_from_id,
                to_submission_id=int(created_id),
            )
    conn.commit()
    conn.close()
    if not created_ids:
        raise HTTPException(status_code=500, detail="Etkinlik kaydı oluşturulamadı")
    return {
        "ok": True,
        "submission_id": int(created_ids[0]),
        "submission_ids": created_ids,
        "created_count": len(created_ids),
        "repeat_mode": repeat_mode_val,
    }


@router.get("/manage/items", summary="Editör: yönetebileceği etkinlikler")
def list_manage_items(
    authorization: Optional[str] = Header(default=None),
):
    conn = db_conn()
    try:
        actor = _require_editor_account(conn, authorization)
        _rollover_and_expire_events(conn)
        conn.commit()
        account_id = int(actor["account_id"])
        role = (actor.get("role") or "").strip().lower()
        actor_email = (actor.get("email") or "").strip().lower()

        cur = conn.cursor()
        if role == "super_admin":
            cur.execute(
                """
            SELECT
                mes.id,
                mes.event_name,
                mes.description,
                mes.event_date,
                mes.start_at,
                mes.end_at,
                mes.venue,
                COALESCE(mes.venue_map_url,'') AS venue_map_url,
                COALESCE(mes.city,'') AS city,
                COALESCE(mes.event_kind,'') AS event_kind,
                COALESCE(mes.dance_styles,'') AS dance_styles,
                COALESCE(mes.ticket_sales_enabled, TRUE) AS ticket_sales_enabled,
                COALESCE(mes.repeat_weekly, FALSE) AS repeat_weekly,
                mes.repeat_weekday,
                mes.organizer_name,
                mes.program_text,
                mes.cover_path,
                COALESCE(mes.cover_crop, 'center') AS cover_crop,
                mes.entry_fee,
                mes.status,
                    mes.created_at,
                    mes.approved_at,
                    mes.approved_event_slug,
                    COALESCE(se.account_id,0) AS owner_account_id
                FROM mobile_event_submissions mes
                LEFT JOIN saas_events se ON se.slug = mes.approved_event_slug
                ORDER BY mes.created_at DESC
                LIMIT 300
                """
            )
        else:
            cur.execute(
                """
                SELECT
                    mes.id,
                    mes.event_name,
                    mes.description,
                    mes.event_date,
                    mes.start_at,
                    mes.end_at,
                    mes.venue,
                    COALESCE(mes.venue_map_url,'') AS venue_map_url,
                    COALESCE(mes.city,'') AS city,
                    COALESCE(mes.event_kind,'') AS event_kind,
                    COALESCE(mes.dance_styles,'') AS dance_styles,
                    COALESCE(mes.ticket_sales_enabled, TRUE) AS ticket_sales_enabled,
                    COALESCE(mes.repeat_weekly, FALSE) AS repeat_weekly,
                    mes.repeat_weekday,
                    mes.organizer_name,
                    mes.program_text,
                    mes.cover_path,
                    mes.entry_fee,
                    mes.status,
                    mes.created_at,
                    mes.approved_at,
                    mes.approved_event_slug,
                    COALESCE(se.account_id,0) AS owner_account_id
                FROM mobile_event_submissions mes
                LEFT JOIN saas_events se ON se.slug = mes.approved_event_slug
                WHERE LOWER(COALESCE(mes.submitter_email,''))=%s
                   OR COALESCE(se.account_id,0)=%s
                   OR EXISTS (
                       SELECT 1
                       FROM mobile_ticket_scan_permissions p
                       WHERE p.submission_id = mes.id
                         AND p.account_id = %s
                   )
                ORDER BY mes.created_at DESC
                LIMIT 300
                """,
                (actor_email, account_id, account_id),
            )
        rows = cur.fetchall() or []
        ticket_control_map = _build_active_ticket_control_map(
            conn,
            [int(row.get("id") or 0) for row in rows if int(row.get("id") or 0) > 0],
        )
        items = []
        for r in rows:
            if (r.get("status") or "").strip().lower() != "approved":
                continue
            submission_id = int(r["id"])
            ticket_control = ticket_control_map.get(submission_id) or {}
            ticket_summary = ticket_control.get("summary") or {}
            venue_name, venue_map = _split_venue_fields((r.get("venue") or ""), (r.get("venue_map_url") or ""))
            cp = (r.get("cover_path") or "").strip()
            if cp.startswith("http://") or cp.startswith("https://"):
                cover = cp
            else:
                cover = _cover_url(cp) if cp and _cover_exists(cp) else ""
            items.append(
                {
                    "submission_id": submission_id,
                    "name": (r.get("event_name") or "").strip(),
                    "description": (r.get("description") or "").strip(),
                    "event_date": _normalize_event_dt_text((r.get("event_date") or "").strip()),
                    "start_at": _normalize_event_dt_text((r.get("start_at") or "").strip()),
                    "end_at": _normalize_event_dt_text((r.get("end_at") or "").strip()),
                    "venue": venue_name,
                    "venue_map_url": venue_map,
                    "city": (r.get("city") or "").strip(),
                    "event_kind": (r.get("event_kind") or "").strip(),
                    "dance_styles": _deserialize_dance_styles(r.get("dance_styles")),
                    "cover_crop": _normalize_cover_crop(r.get("cover_crop")),
                    "ticket_sales_enabled": bool(
                        r.get("ticket_sales_enabled") if r.get("ticket_sales_enabled") is not None else True
                    ),
                    "repeat_weekly": bool(r.get("repeat_weekly")),
                    "repeat_weekday": (
                        int(r.get("repeat_weekday"))
                        if r.get("repeat_weekday") is not None and str(r.get("repeat_weekday")).strip() != ""
                        else None
                    ),
                    "organizer_name": (r.get("organizer_name") or "").strip(),
                    "program_text": (r.get("program_text") or "").strip(),
                    "cover_url": cover,
                    "entry_fee": float(r.get("entry_fee") or 0),
                    "status": _management_status_text((r.get("status") or "").strip(), ticket_summary),
                    "workflow_status": (r.get("status") or "").strip(),
                    "created_at": (r.get("created_at") or "").strip(),
                    "approved_at": (r.get("approved_at") or "").strip(),
                    "slug": (r.get("approved_event_slug") or "").strip(),
                    "active_ticket_count": int(ticket_summary.get("active_ticket_count") or 0),
                    "active_ticket_holder_count": int(ticket_summary.get("active_holder_count") or 0),
                    "paid_ticket_count": int(ticket_summary.get("paid_ticket_count") or 0),
                    "guest_ticket_count": int(ticket_summary.get("guest_ticket_count") or 0),
                    "reward_ticket_count": int(ticket_summary.get("reward_ticket_count") or 0),
                    "active_ticket_summary": (ticket_summary.get("summary_text") or "").strip(),
                }
            )
        return {"items": items}
    finally:
        conn.close()


@router.post("/manage/items/{submission_id}/update", summary="Editör: kendi etkinliğini güncelle")
def update_manage_item(
    submission_id: int,
    description: Optional[str] = Form(default=None),
    event_date: Optional[str] = Form(default=None),
    start_at: Optional[str] = Form(default=None),
    end_at: Optional[str] = Form(default=None),
    venue: Optional[str] = Form(default=None),
    venue_map_url: Optional[str] = Form(default=None),
    city: Optional[str] = Form(default=None),
    event_kind: Optional[str] = Form(default=None),
    dance_styles: Optional[str] = Form(default=None),
    cover_crop: Optional[str] = Form(default=None),
    ticket_sales_enabled: Optional[str] = Form(default=None),
    repeat_weekly: Optional[str] = Form(default=None),
    repeat_weekday: Optional[str] = Form(default=None),
    organizer_name: Optional[str] = Form(default=None),
    program_text: Optional[str] = Form(default=None),
    cover_image: Optional[UploadFile] = File(None),
    authorization: Optional[str] = Header(default=None),
):
    conn = db_conn()
    try:
        actor = _require_editor_account(conn, authorization)
        account_id = int(actor["account_id"])
        role = (actor.get("role") or "").strip().lower()
        actor_email = (actor.get("email") or "").strip().lower()

        cur = conn.cursor()
        cur.execute(
            """
            SELECT
                mes.id,
                COALESCE(mes.submitter_email,'') AS submitter_email,
                COALESCE(mes.event_kind,'') AS event_kind,
                COALESCE(mes.dance_styles,'') AS dance_styles,
                COALESCE(mes.approved_event_slug,'') AS slug,
                COALESCE(se.account_id,0) AS owner_account_id
            FROM mobile_event_submissions mes
            LEFT JOIN saas_events se ON se.slug = mes.approved_event_slug
            WHERE mes.id=%s
            LIMIT 1
            """,
            (int(submission_id),),
        )
        row = cur.fetchone()
        if not row:
            raise HTTPException(status_code=404, detail="Etkinlik bulunamadı")

        allowed = False
        if role == "super_admin":
            allowed = True
        elif int(row.get("owner_account_id") or 0) == account_id:
            allowed = True
        elif (row.get("submitter_email") or "").strip().lower() == actor_email and actor_email:
            allowed = True
        else:
            cur.execute(
                """
                SELECT 1
                FROM mobile_ticket_scan_permissions
                WHERE submission_id=%s AND account_id=%s
                LIMIT 1
                """,
                (int(submission_id), int(account_id)),
            )
            allowed = bool(cur.fetchone())
        if not allowed:
            raise HTTPException(status_code=403, detail="Bu etkinliği düzenleme yetkiniz yok")

        selected_kind = (row.get("event_kind") or "").strip().lower()
        fields_sql: List[str] = []
        vals: List[Any] = []
        if description is not None:
            fields_sql.append("description=%s")
            vals.append(description.strip())
        if event_date is not None or start_at is not None or end_at is not None:
            cur.execute(
                """
                SELECT COALESCE(event_date,'') AS event_date,
                       COALESCE(start_at,'') AS start_at,
                       COALESCE(end_at,'') AS end_at
                FROM mobile_event_submissions
                WHERE id=%s
                LIMIT 1
                """,
                (int(submission_id),),
            )
            existing_window = cur.fetchone() or {}
            next_event_date = event_date if event_date is not None else (existing_window.get("event_date") or "")
            next_start_at = start_at if start_at is not None else (existing_window.get("start_at") or next_event_date)
            next_end_at = end_at if end_at is not None else (existing_window.get("end_at") or next_event_date)
            event_date_val, start_at_val, end_at_val = _coerce_event_window(next_event_date, next_start_at, next_end_at)
            fields_sql.append("event_date=%s")
            vals.append(event_date_val)
            fields_sql.append("start_at=%s")
            vals.append(start_at_val)
            fields_sql.append("end_at=%s")
            vals.append(end_at_val)
        if venue is not None:
            fields_sql.append("venue=%s")
            vals.append(venue.strip())
        if venue_map_url is not None:
            fields_sql.append("venue_map_url=%s")
            vals.append(_normalize_map_url(venue_map_url))
        if city is not None:
            city_val = city.strip()
            if not city_val:
                raise HTTPException(status_code=400, detail="Şehir boş olamaz")
            fields_sql.append("city=%s")
            vals.append(city_val)
        if event_kind is not None:
            kind_val = (event_kind or "").strip().lower()
            if kind_val not in ALLOWED_EVENT_KINDS:
                raise HTTPException(status_code=400, detail="Geçersiz etkinlik türü")
            fields_sql.append("event_kind=%s")
            vals.append(kind_val)
            selected_kind = kind_val
        if dance_styles is not None:
            fields_sql.append("dance_styles=%s")
            vals.append(_serialize_dance_styles(dance_styles))
        if cover_crop is not None:
            fields_sql.append("cover_crop=%s")
            vals.append(_normalize_cover_crop(cover_crop))
        if ticket_sales_enabled is not None or selected_kind == "promo_lesson":
            ts_val = (ticket_sales_enabled or "").strip().lower() in {"1", "true", "yes", "on"}
            if selected_kind == "promo_lesson":
                ts_val = False
            fields_sql.append("ticket_sales_enabled=%s")
            vals.append(ts_val)
        if repeat_weekly is not None or selected_kind == "promo_lesson":
            rw_val = (repeat_weekly or "").strip().lower() in {"1", "true", "yes", "on"}
            if selected_kind == "promo_lesson":
                rw_val = False
            fields_sql.append("repeat_weekly=%s")
            vals.append(rw_val)
            if rw_val:
                rw_day: Optional[int] = None
                raw_day = (repeat_weekday or "").strip() if repeat_weekday is not None else ""
                if raw_day:
                    if not raw_day.isdigit() or int(raw_day) < 0 or int(raw_day) > 6:
                        raise HTTPException(status_code=400, detail="Tekrar günü geçersiz")
                    rw_day = int(raw_day)
                else:
                    date_source = (event_date or "").strip()
                    if not date_source:
                        cur.execute("SELECT COALESCE(event_date,'') AS event_date FROM mobile_event_submissions WHERE id=%s", (int(submission_id),))
                        rr = cur.fetchone() or {}
                        date_source = (rr.get("event_date") or "").strip()
                    parsed = _parse_event_date_text(date_source)
                    if parsed is None:
                        raise HTTPException(status_code=400, detail="Tekrar için etkinlik tarihi zorunlu")
                    rw_day = parsed.weekday()
                fields_sql.append("repeat_weekday=%s")
                vals.append(rw_day)
            else:
                fields_sql.append("repeat_weekday=%s")
                vals.append(None)
        elif repeat_weekday is not None:
            raw_day = (repeat_weekday or "").strip()
            if selected_kind == "promo_lesson":
                fields_sql.append("repeat_weekday=%s")
                vals.append(None)
            elif raw_day == "":
                fields_sql.append("repeat_weekday=%s")
                vals.append(None)
            else:
                if not raw_day.isdigit() or int(raw_day) < 0 or int(raw_day) > 6:
                    raise HTTPException(status_code=400, detail="Tekrar günü geçersiz")
                fields_sql.append("repeat_weekday=%s")
                vals.append(int(raw_day))
        if organizer_name is not None:
            fields_sql.append("organizer_name=%s")
            vals.append(organizer_name.strip())
        if program_text is not None:
            fields_sql.append("program_text=%s")
            vals.append(program_text.strip())
        if cover_image and getattr(cover_image, "filename", ""):
            fields_sql.append("cover_path=%s")
            vals.append(_save_cover(cover_image))

        if fields_sql:
            vals.append(int(submission_id))
            cur.execute(
                f"UPDATE mobile_event_submissions SET {', '.join(fields_sql)} WHERE id=%s",
                tuple(vals),
            )

        conn.commit()
        return {"ok": True, "submission_id": int(submission_id)}
    except HTTPException:
        conn.rollback()
        raise
    except Exception as e:
        conn.rollback()
        raise HTTPException(status_code=500, detail=f"Güncelleme hatası: {e}")
    finally:
        conn.close()


class GuestListImportRequest(BaseModel):
    guest_list_id: int


@router.get("/manage/items/{submission_id}/invitees", summary="Editör: etkinliğin davetlileri")
def list_event_invitees(
    submission_id: int,
    authorization: Optional[str] = Header(default=None),
):
    conn = db_conn()
    try:
        actor = _require_editor_account(conn, authorization)
        if not _actor_can_manage_submission(
            conn,
            submission_id=int(submission_id),
            account_id=int(actor["account_id"]),
            role=(actor.get("role") or "").strip().lower(),
            actor_email=(actor.get("email") or "").strip().lower(),
        ):
            raise HTTPException(status_code=403, detail="Bu etkinliğin davetlilerini yönetme yetkiniz yok")

        cur = conn.cursor()
        cur.execute(
            """
            SELECT COALESCE(event_name,'') AS event_name
            FROM mobile_event_submissions
            WHERE id=%s
            LIMIT 1
            """,
            (int(submission_id),),
        )
        row = cur.fetchone()
        if not row:
            raise HTTPException(status_code=404, detail="Etkinlik bulunamadı")

        items = _fetch_event_invitees(conn, int(submission_id))
        return {
            "submission_id": int(submission_id),
            "event_name": (row.get("event_name") or "").strip(),
            "total": len(items),
            "items": items,
        }
    finally:
        conn.close()


@router.post("/manage/items/{submission_id}/invitees/import-guest-list", summary="Editör: davetli listesini etkinliğe aktar")
def import_guest_list_to_event(
    submission_id: int,
    payload: GuestListImportRequest,
    authorization: Optional[str] = Header(default=None),
):
    conn = db_conn()
    try:
        actor = _require_editor_account(conn, authorization)
        if not _actor_can_manage_submission(
            conn,
            submission_id=int(submission_id),
            account_id=int(actor["account_id"]),
            role=(actor.get("role") or "").strip().lower(),
            actor_email=(actor.get("email") or "").strip().lower(),
        ):
            raise HTTPException(status_code=403, detail="Bu etkinliğe davetli aktarma yetkiniz yok")

        cur = conn.cursor()
        cur.execute(
            """
            SELECT
                id,
                COALESCE(event_name,'') AS event_name,
                COALESCE(approved_event_slug,'') AS approved_event_slug,
                COALESCE(status,'') AS status
            FROM mobile_event_submissions
            WHERE id=%s
            LIMIT 1
            """,
            (int(submission_id),),
        )
        event_row = cur.fetchone()
        if not event_row:
            raise HTTPException(status_code=404, detail="Etkinlik bulunamadı")
        if (event_row.get("status") or "").strip().lower() != "approved":
            raise HTTPException(status_code=400, detail="Davetli aktarımı için etkinlik önce onaylanmış olmalı")

        guest_list_id = int(payload.guest_list_id)
        cur.execute(
            """
            SELECT id, COALESCE(name,'') AS name
            FROM mobile_guest_lists
            WHERE id=%s AND owner_account_id=%s
            LIMIT 1
            """,
            (guest_list_id, int(actor["account_id"])),
        )
        guest_list_row = cur.fetchone()
        if not guest_list_row:
            raise HTTPException(status_code=404, detail="Davetli listesi bulunamadı")

        cur.execute(
            """
            SELECT
                glm.account_id
            FROM mobile_guest_list_members glm
            JOIN accounts a ON a.id = glm.account_id
            WHERE glm.list_id=%s
              AND COALESCE(a.is_active,1)=1
            ORDER BY glm.created_at ASC, glm.account_id ASC
            """,
            (guest_list_id,),
        )
        member_rows = cur.fetchall() or []
        if not member_rows:
            raise HTTPException(status_code=400, detail="Bu davetli listesinde henüz kullanıcı yok")

        imported_count = 0
        existing_count = 0
        ticket_created_count = 0
        created_ticket_notifications: List[Dict[str, Any]] = []
        event_slug = (event_row.get("approved_event_slug") or "").strip()
        event_name = (event_row.get("event_name") or "").strip()
        actor_id = int(actor["account_id"])

        for member_row in member_rows:
            member_account_id = int(member_row["account_id"])
            sync_result = _sync_guest_list_member_to_submission(
                conn,
                submission_id=int(submission_id),
                guest_list_id=guest_list_id,
                member_account_id=member_account_id,
                issued_by_account_id=actor_id,
            )
            if sync_result.get("invitee_exists"):
                existing_count += 1
            if sync_result.get("invitee_created"):
                imported_count += 1
            if sync_result.get("ticket_created"):
                ticket_created_count += 1
                created_ticket_notifications.append(
                    {
                        "account_id": member_account_id,
                        "ticket_id": int(sync_result.get("ticket_id") or 0),
                    }
                )

        conn.commit()
        if created_ticket_notifications:
            _send_ticket_created_notifications(
                conn,
                notifications=created_ticket_notifications,
                submission_id=int(submission_id),
                event_name=event_name,
                ticket_type="guest",
            )
        items = _fetch_event_invitees(conn, int(submission_id))
        return {
            "ok": True,
            "submission_id": int(submission_id),
            "guest_list_id": guest_list_id,
            "guest_list_name": (guest_list_row.get("name") or "").strip(),
            "imported_count": imported_count,
            "existing_count": existing_count,
            "ticket_created_count": ticket_created_count,
            "total": len(items),
            "items": items,
        }
    except HTTPException:
        conn.rollback()
        raise
    except Exception as exc:
        conn.rollback()
        raise HTTPException(status_code=500, detail=f"Davetli listesi aktarılamadı: {exc}")
    finally:
        conn.close()


@router.delete("/manage/items/{submission_id}/invitees/{account_id}", summary="Editör: etkinlik davetlisini kaldır")
def remove_event_invitee(
    submission_id: int,
    account_id: int,
    authorization: Optional[str] = Header(default=None),
):
    conn = db_conn()
    try:
        actor = _require_editor_account(conn, authorization)
        if not _actor_can_manage_submission(
            conn,
            submission_id=int(submission_id),
            account_id=int(actor["account_id"]),
            role=(actor.get("role") or "").strip().lower(),
            actor_email=(actor.get("email") or "").strip().lower(),
        ):
            raise HTTPException(status_code=403, detail="Bu etkinliğin davetlilerini yönetme yetkiniz yok")

        cur = conn.cursor()
        cur.execute(
            """
            SELECT ticket_id
            FROM mobile_event_invitees
            WHERE submission_id=%s AND account_id=%s
            LIMIT 1
            """,
            (int(submission_id), int(account_id)),
        )
        row = cur.fetchone()
        if not row:
            raise HTTPException(status_code=404, detail="Davetli bulunamadı")

        ticket_id = int(row.get("ticket_id") or 0)
        cur.execute(
            "DELETE FROM mobile_event_invitees WHERE submission_id=%s AND account_id=%s",
            (int(submission_id), int(account_id)),
        )
        if ticket_id > 0:
            cur.execute(
                """
                UPDATE mobile_tickets
                SET status='cancelled'
                WHERE id=%s
                  AND submission_id=%s
                  AND account_id=%s
                  AND COALESCE(ticket_type,'paid')='guest'
                  AND used_at IS NULL
                """,
                (ticket_id, int(submission_id), int(account_id)),
            )

        conn.commit()
        items = _fetch_event_invitees(conn, int(submission_id))
        return {
            "ok": True,
            "submission_id": int(submission_id),
            "total": len(items),
            "items": items,
        }
    except HTTPException:
        conn.rollback()
        raise
    except Exception as exc:
        conn.rollback()
        raise HTTPException(status_code=500, detail=f"Davetli kaldırılamadı: {exc}")
    finally:
        conn.close()


@admin_router.get("/submissions", summary="Admin: etkinlik talepleri")
def admin_list_submissions(
    status: str = "pending",
    x_admin_token: Optional[str] = Header(default=None),
):
    _require_admin(x_admin_token) # Changed _db_conn to db_conn
    status = (status or "pending").strip().lower()
    if status not in {"pending", "approved", "rejected", "expired", "all"}:
        status = "pending"
    conn = db_conn()
    cur = conn.cursor()
    if status == "all":
        cur.execute(
            """
            SELECT *
            FROM mobile_event_submissions
            ORDER BY created_at DESC
            LIMIT 200
            """
        )
    else:
        cur.execute(
            """
            SELECT *
            FROM mobile_event_submissions
            WHERE status=%s
            ORDER BY created_at DESC
            LIMIT 200
            """,
            (status,),
        )
    rows = cur.fetchall() or []
    conn.close()
    out: List[Dict[str, Any]] = []
    for r in rows:
        item = dict(r)
        cp = (item.get("cover_path") or "").strip()
        if cp.startswith("http://") or cp.startswith("https://"):
            item["cover_url"] = cp
        else:
            item["cover_url"] = _cover_url(cp)
        out.append(item)
    return {"items": out}


@admin_router.post("/submissions/{submission_id}/approve", summary="Admin: talebi onayla")
def admin_approve_submission(
    submission_id: int,
    admin_note: str = Form(""),
    x_admin_token: Optional[str] = Header(default=None),
):
    _require_admin(x_admin_token) # Changed _db_conn to db_conn
    conn = db_conn()
    cur = conn.cursor()
    cur.execute("SELECT * FROM mobile_event_submissions WHERE id=%s LIMIT 1", (int(submission_id),))
    seed_row = cur.fetchone()
    if not seed_row:
        conn.close()
        raise HTTPException(status_code=404, detail="Talep bulunamadı")

    approved_at = _iso_now()
    note_text = admin_note[:500]
    if _is_selected_dates_series_submission(seed_row):
        origin_id = int(seed_row.get("repeat_origin_submission_id") or seed_row["id"])
        cur.execute(
            """
            SELECT *
            FROM mobile_event_submissions
            WHERE COALESCE(repeat_origin_submission_id, id)=%s
              AND COALESCE(repeat_weekly, FALSE)=FALSE
            ORDER BY COALESCE(event_date, start_at, created_at) ASC, id ASC
            """,
            (origin_id,),
        )
        rows = cur.fetchall() or []
        today = _now_local().date()
        target_id: Optional[int] = None
        for row in rows:
            if (row.get("status") or "").strip().lower() == "rejected":
                continue
            event_day = _submission_event_day(row)
            if event_day is not None and event_day < today:
                continue
            target_id = int(row["id"])
            break
        for row in rows:
            row_id = int(row["id"])
            if (row.get("status") or "").strip().lower() == "rejected":
                continue
            event_day = _submission_event_day(row)
            if event_day is not None and event_day < today:
                _ensure_live_event_state(conn, row_id, activate=False)
                cur.execute(
                    """
                    UPDATE mobile_event_submissions
                    SET status='expired',
                        approved_at=COALESCE(approved_at, %s),
                        admin_note=%s
                    WHERE id=%s
                    """,
                    (approved_at, note_text, row_id),
                )
                continue
            cur.execute(
                """
                UPDATE mobile_event_submissions
                SET status='approved', approved_at=%s, admin_note=%s
                WHERE id=%s
                """,
                (approved_at, note_text, row_id),
            )
            _ensure_live_event_state(conn, row_id, activate=row_id == target_id)
    else:
        cur.execute(
            """
            UPDATE mobile_event_submissions
            SET status='approved', approved_at=%s, admin_note=%s
            WHERE id=%s
            """,
            (approved_at, note_text, int(submission_id)),
        )
        _ensure_live_event_state(conn, int(submission_id), activate=True)
    conn.commit()
    conn.close()
    return {"ok": True}


@admin_router.post("/submissions/{submission_id}/reject", summary="Admin: talebi reddet")
def admin_reject_submission(
    submission_id: int,
    admin_note: str = Form(""),
    x_admin_token: Optional[str] = Header(default=None),
):
    _require_admin(x_admin_token) # Changed _db_conn to db_conn
    conn = db_conn()
    cur = conn.cursor()
    cur.execute(
        """
        UPDATE mobile_event_submissions
        SET status='rejected', admin_note=%s
        WHERE id=%s
        """,
        (admin_note[:500], int(submission_id)),
    )
    conn.commit()
    conn.close()
    return {"ok": True}


@admin_router.get("/items", summary="Admin: etkinlik listesi (panel yönetim)")
def admin_list_event_items(
    limit: int = 200,
    x_admin_token: Optional[str] = Header(default=None),
):
    _require_admin(x_admin_token) # Changed _db_conn to db_conn
    conn = db_conn()
    try:
        _rollover_and_expire_events(conn)
        conn.commit()
        cur = conn.cursor()
        cur.execute(
            """
            SELECT
                mes.id,
                mes.event_name,
                mes.description,
                mes.event_date,
                mes.venue,
                COALESCE(mes.venue_map_url,'') AS venue_map_url,
                COALESCE(mes.city,'') AS city,
                COALESCE(mes.event_kind,'') AS event_kind,
                COALESCE(mes.dance_styles,'') AS dance_styles,
                COALESCE(mes.ticket_sales_enabled, TRUE) AS ticket_sales_enabled,
                COALESCE(mes.create_photo_album, FALSE) AS create_photo_album,
                COALESCE(mes.repeat_weekly, FALSE) AS repeat_weekly,
                mes.repeat_weekday,
                mes.organizer_name,
                mes.program_text,
                mes.cover_path,
                COALESCE(mes.cover_crop, 'center') AS cover_crop,
                mes.start_at,
                mes.end_at,
                mes.entry_fee,
                mes.status,
                mes.source_type,
                mes.source_ref,
                mes.approved_event_slug,
                COALESCE(mes.auto_notification_title_template,'') AS auto_notification_title_template,
                COALESCE(mes.auto_notification_body_template,'') AS auto_notification_body_template,
                mes.created_at,
                mes.approved_at,
                COALESCE(se.ticket_url,'') AS ticket_url,
                COALESCE(se.external_event_id,'') AS woo_product_id,
                COALESCE(se.is_active,1) AS event_is_active,
                COALESCE(se.album_enabled, TRUE) AS photo_album_enabled
            FROM mobile_event_submissions mes
            LEFT JOIN saas_events se ON se.slug = mes.approved_event_slug
            ORDER BY COALESCE(mes.approved_at, mes.created_at) DESC
            LIMIT %s
            """,
            (max(1, min(int(limit), 1000)),),
        )
        rows = cur.fetchall() or []
        ticket_control_map = _build_active_ticket_control_map(
            conn,
            [int(row.get("id") or 0) for row in rows if int(row.get("id") or 0) > 0],
        )
        items: List[Dict[str, Any]] = []
        for r in rows:
            submission_id = int(r["id"])
            ticket_control = ticket_control_map.get(submission_id) or {}
            ticket_summary = ticket_control.get("summary") or {}
            venue_name, venue_map = _split_venue_fields((r.get("venue") or ""), (r.get("venue_map_url") or ""))
            cp = (r.get("cover_path") or "").strip()
            if cp.startswith("http://") or cp.startswith("https://"):
                cover = cp
            else:
                cover = _cover_url(cp) if cp and _cover_exists(cp) else ""
            items.append(
                {
                    "submission_id": submission_id,
                    "name": (r.get("event_name") or "").strip(),
                    "description": (r.get("description") or "").strip(),
                    "event_date": _normalize_event_dt_text((r.get("event_date") or "").strip()),
                    "start_at": _normalize_event_dt_text((r.get("start_at") or "").strip()),
                    "end_at": _normalize_event_dt_text((r.get("end_at") or "").strip()),
                    "venue": venue_name,
                    "venue_map_url": venue_map,
                    "city": (r.get("city") or "").strip(),
                    "event_kind": (r.get("event_kind") or "").strip(),
                    "dance_styles": _deserialize_dance_styles(r.get("dance_styles")),
                    "cover_crop": _normalize_cover_crop(r.get("cover_crop")),
                    "ticket_sales_enabled": bool(
                        r.get("ticket_sales_enabled") if r.get("ticket_sales_enabled") is not None else True
                    ),
                    "create_photo_album": bool(r.get("create_photo_album")),
                    "repeat_weekly": bool(r.get("repeat_weekly")),
                    "repeat_weekday": (
                        int(r.get("repeat_weekday"))
                        if r.get("repeat_weekday") is not None and str(r.get("repeat_weekday")).strip() != ""
                        else None
                    ),
                    "organizer_name": (r.get("organizer_name") or "").strip(),
                    "program_text": (r.get("program_text") or "").strip(),
                    "cover_url": cover,
                    "entry_fee": float(r.get("entry_fee") or 0),
                    "status": (r.get("status") or "").strip(),
                    "source_type": (r.get("source_type") or "").strip(),
                    "source_ref": (r.get("source_ref") or "").strip(),
                    "slug": (r.get("approved_event_slug") or "").strip(),
                    "ticket_url": (r.get("ticket_url") or "").strip(),
                    "woo_product_id": (r.get("woo_product_id") or "").strip(),
                    "event_is_active": bool(int(r.get("event_is_active") or 0)),
                    "photo_album_enabled": bool(
                        r.get("photo_album_enabled") if r.get("photo_album_enabled") is not None else True
                    ),
                    "created_at": (r.get("created_at") or "").strip(),
                    "approved_at": (r.get("approved_at") or "").strip(),
                    "auto_notification_title_template": (
                        r.get("auto_notification_title_template") or ""
                    ).strip(),
                    "auto_notification_body_template": (
                        r.get("auto_notification_body_template") or ""
                    ).strip(),
                    "active_ticket_count": int(ticket_summary.get("active_ticket_count") or 0),
                    "active_ticket_holder_count": int(ticket_summary.get("active_holder_count") or 0),
                    "paid_ticket_count": int(ticket_summary.get("paid_ticket_count") or 0),
                    "guest_ticket_count": int(ticket_summary.get("guest_ticket_count") or 0),
                    "reward_ticket_count": int(ticket_summary.get("reward_ticket_count") or 0),
                    "active_ticket_summary": (ticket_summary.get("summary_text") or "").strip(),
                }
            )
        return {"items": items}
    finally:
        conn.close()


@admin_router.post("/auto-notification-template/save", summary="Admin: otomatik etkinlik bildirimi içeriğini kaydet")
def admin_save_auto_notification_template(
    submission_id: Optional[str] = Form(default=None),
    title_template: Optional[str] = Form(default=None),
    body_template: Optional[str] = Form(default=None),
    apply_all: Optional[str] = Form(default=None),
    x_admin_token: Optional[str] = Header(default=None),
):
    _require_admin(x_admin_token) # Changed _db_conn to db_conn
    apply_all_flag = str(apply_all or "").strip().lower() in {"1", "true", "on", "yes"}
    try:
        submission_id_value = int(str(submission_id or "").strip() or "0")
    except Exception:
        submission_id_value = 0
    if not apply_all_flag and submission_id_value <= 0:
        raise HTTPException(status_code=400, detail="Etkinlik seçimi zorunlu")

    title_norm = _normalize_auto_event_notification_template(title_template, max_len=160)
    body_norm = _normalize_auto_event_notification_template(body_template, max_len=2000)

    conn = db_conn()
    try:
        cur = conn.cursor()
        if apply_all_flag:
            cur.execute(
                """
                UPDATE mobile_event_submissions
                SET auto_notification_title_template=%s,
                    auto_notification_body_template=%s
                """,
                (
                    title_norm or None,
                    body_norm or None,
                ),
            )
            updated_count = int(cur.rowcount or 0)
            scope = "all"
        else:
            cur.execute(
                "SELECT id FROM mobile_event_submissions WHERE id=%s LIMIT 1",
                (submission_id_value,),
            )
            if not cur.fetchone():
                raise HTTPException(status_code=404, detail="Etkinlik bulunamadı")
            cur.execute(
                """
                UPDATE mobile_event_submissions
                SET auto_notification_title_template=%s,
                    auto_notification_body_template=%s
                WHERE id=%s
                """,
                (
                    title_norm or None,
                    body_norm or None,
                    submission_id_value,
                ),
            )
            updated_count = int(cur.rowcount or 0)
            scope = "single"
        conn.commit()
        return {
            "ok": True,
            "scope": scope,
            "updated_count": updated_count,
            "submission_id": submission_id_value if submission_id_value > 0 else None,
            "title_template": title_norm,
            "body_template": body_norm,
        }
    finally:
        conn.close()


@admin_router.post("/items/{submission_id}/update", summary="Admin: etkinlik alanlarını güncelle")
def admin_update_event_item(
    submission_id: int,
    event_name: Optional[str] = Form(default=None),
    description: Optional[str] = Form(default=None),
    event_date: Optional[str] = Form(default=None),
    start_at: Optional[str] = Form(default=None),
    end_at: Optional[str] = Form(default=None),
    venue: Optional[str] = Form(default=None),
    venue_map_url: Optional[str] = Form(default=None),
    city: Optional[str] = Form(default=None),
    event_kind: Optional[str] = Form(default=None),
    dance_styles: Optional[str] = Form(default=None),
    cover_crop: Optional[str] = Form(default=None),
    ticket_sales_enabled: Optional[str] = Form(default=None),
    repeat_weekly: Optional[str] = Form(default=None),
    repeat_weekday: Optional[str] = Form(default=None),
    organizer_name: Optional[str] = Form(default=None),
    program_text: Optional[str] = Form(default=None),
    cover_url: Optional[str] = Form(default=None),
    cover_image: Optional[UploadFile] = File(default=None),
    entry_fee: Optional[str] = Form(default=None),
    woo_product_id: Optional[str] = Form(default=None),
    ticket_url: Optional[str] = Form(default=None),
    is_active: Optional[int] = Form(default=None),
    x_admin_token: Optional[str] = Header(default=None),
):
    _require_admin(x_admin_token) # Changed _db_conn to db_conn
    conn = db_conn()
    try:
        cur = conn.cursor()
        cur.execute(
            "SELECT id, approved_event_slug, COALESCE(event_kind,'') AS event_kind FROM mobile_event_submissions WHERE id=%s LIMIT 1",
            (int(submission_id),),
        )
        row = cur.fetchone()
        if not row:
            raise HTTPException(status_code=404, detail="submission bulunamadı")
        slug = (row.get("approved_event_slug") or "").strip()
        selected_kind = (row.get("event_kind") or "").strip().lower()

        fields_sql: List[str] = []
        vals: List[Any] = []
        if event_name is not None:
            fields_sql.append("event_name=%s")
            vals.append(event_name.strip())
        if description is not None:
            fields_sql.append("description=%s")
            vals.append(description.strip())
        if event_date is not None or start_at is not None or end_at is not None:
            cur.execute(
                """
                SELECT COALESCE(event_date,'') AS event_date,
                       COALESCE(start_at,'') AS start_at,
                       COALESCE(end_at,'') AS end_at
                FROM mobile_event_submissions
                WHERE id=%s
                LIMIT 1
                """,
                (int(submission_id),),
            )
            existing_window = cur.fetchone() or {}
            next_event_date = event_date if event_date is not None else (existing_window.get("event_date") or "")
            next_start_at = start_at if start_at is not None else (existing_window.get("start_at") or next_event_date)
            next_end_at = end_at if end_at is not None else (existing_window.get("end_at") or next_event_date)
            event_date_val, start_at_val, end_at_val = _coerce_event_window(next_event_date, next_start_at, next_end_at)
            fields_sql.append("event_date=%s")
            vals.append(event_date_val)
            fields_sql.append("start_at=%s")
            vals.append(start_at_val)
            fields_sql.append("end_at=%s")
            vals.append(end_at_val)
        if venue is not None:
            fields_sql.append("venue=%s")
            vals.append(venue.strip())
        if venue_map_url is not None:
            fields_sql.append("venue_map_url=%s")
            vals.append(_normalize_map_url(venue_map_url))
        if city is not None:
            city_val = city.strip()
            if not city_val:
                raise HTTPException(status_code=400, detail="Şehir boş olamaz")
            fields_sql.append("city=%s")
            vals.append(city_val)
        if event_kind is not None:
            kind_val = (event_kind or "").strip().lower()
            if kind_val not in ALLOWED_EVENT_KINDS:
                raise HTTPException(status_code=400, detail="Geçersiz etkinlik türü")
            fields_sql.append("event_kind=%s")
            vals.append(kind_val)
            selected_kind = kind_val
        if dance_styles is not None:
            fields_sql.append("dance_styles=%s")
            vals.append(_serialize_dance_styles(dance_styles))
        if cover_crop is not None:
            fields_sql.append("cover_crop=%s")
            vals.append(_normalize_cover_crop(cover_crop))
        if ticket_sales_enabled is not None or selected_kind == "promo_lesson":
            ts_val = (ticket_sales_enabled or "").strip().lower() in {"1", "true", "yes", "on"}
            if selected_kind == "promo_lesson":
                ts_val = False
            fields_sql.append("ticket_sales_enabled=%s")
            vals.append(ts_val)
        if repeat_weekly is not None or selected_kind == "promo_lesson":
            rw_val = (repeat_weekly or "").strip().lower() in {"1", "true", "yes", "on"}
            if selected_kind == "promo_lesson":
                rw_val = False
            fields_sql.append("repeat_weekly=%s")
            vals.append(rw_val)
            if rw_val:
                day_val: Optional[int] = None
                raw_day = (repeat_weekday or "").strip() if repeat_weekday is not None else ""
                if raw_day:
                    if not raw_day.isdigit() or int(raw_day) < 0 or int(raw_day) > 6:
                        raise HTTPException(status_code=400, detail="repeat_weekday geçersiz")
                    day_val = int(raw_day)
                else:
                    parsed = _parse_event_date_text((event_date or "").strip())
                    if parsed is not None:
                        day_val = parsed.weekday()
                fields_sql.append("repeat_weekday=%s")
                vals.append(day_val)
            else:
                fields_sql.append("repeat_weekday=%s")
                vals.append(None)
        elif repeat_weekday is not None:
            raw_day = (repeat_weekday or "").strip()
            if selected_kind == "promo_lesson":
                fields_sql.append("repeat_weekday=%s")
                vals.append(None)
            elif raw_day == "":
                fields_sql.append("repeat_weekday=%s")
                vals.append(None)
            else:
                if not raw_day.isdigit() or int(raw_day) < 0 or int(raw_day) > 6:
                    raise HTTPException(status_code=400, detail="repeat_weekday geçersiz")
                fields_sql.append("repeat_weekday=%s")
                vals.append(int(raw_day))
        if organizer_name is not None:
            fields_sql.append("organizer_name=%s")
            vals.append(organizer_name.strip())
        if program_text is not None:
            fields_sql.append("program_text=%s")
            vals.append(program_text.strip())
        if cover_image and getattr(cover_image, "filename", ""):
            fields_sql.append("cover_path=%s")
            vals.append(_save_cover(cover_image))
        elif cover_url is not None:
            fields_sql.append("cover_path=%s")
            vals.append(cover_url.strip())
        if entry_fee is not None:
            try:
                fee = Decimal((entry_fee or "0").strip() or "0")
            except Exception:
                raise HTTPException(status_code=400, detail="entry_fee geçersiz")
            fields_sql.append("entry_fee=%s")
            vals.append(fee)

        if fields_sql:
            vals.append(int(submission_id))
            cur.execute(
                f"UPDATE mobile_event_submissions SET {', '.join(fields_sql)} WHERE id=%s",
                tuple(vals),
            )

        if slug:
            se_fields: List[str] = []
            se_vals: List[Any] = []
            if event_name is not None:
                se_fields.append("name=%s")
                se_vals.append(event_name.strip())
            if woo_product_id is not None and woo_product_id.strip():
                se_fields.append("external_source=%s")
                se_vals.append("woo")
                se_fields.append("external_event_id=%s")
                se_vals.append(woo_product_id.strip())
            if ticket_url is not None:
                se_fields.append("ticket_url=%s")
                se_vals.append(ticket_url.strip())
            if is_active is not None:
                se_fields.append("is_active=%s")
                se_vals.append(1 if int(is_active) else 0)
            if se_fields:
                se_vals.append(slug)
                cur.execute(
                    f"UPDATE saas_events SET {', '.join(se_fields)} WHERE slug=%s",
                    tuple(se_vals),
                )
        conn.commit()
        return {"ok": True, "submission_id": int(submission_id)}
    except HTTPException:
        conn.rollback()
        raise
    except Exception as e:
        conn.rollback()
        raise HTTPException(status_code=500, detail=f"Güncelleme hatası: {e}")
    finally:
        conn.close()


@admin_router.post("/woo/sync-product", summary="Admin: tek Woo ürünü sync et (app+panel listesine dahil)")
def admin_sync_single_woo_product(
    payload: Dict[str, Any],
    x_admin_token: Optional[str] = Header(default=None),
    x_woo_sync_secret: Optional[str] = Header(default=None),
):
    # WP webhook icin secret, manuel admin cagrisi icin admin token
    if WOO_SYNC_SECRET:
        if not x_woo_sync_secret or x_woo_sync_secret.strip() != WOO_SYNC_SECRET:
            _require_admin(x_admin_token)
    else:
        _require_admin(x_admin_token)

    conn = db_conn()
    try:
        out = _upsert_from_woo_product(conn, payload or {})
        conn.commit()
        return {"ok": True, **out}
    except HTTPException:
        conn.rollback()
        raise
    except Exception as e:
        conn.rollback()
        raise HTTPException(status_code=500, detail=f"Woo sync hatası: {e}")
    finally:
        conn.close()
# Changed _db_conn to db_conn

@admin_router.post("/woo/backfill", summary="Admin: Woo ürünlerini toplu içeri al")
def admin_backfill_woo_products(
    per_page: int = 50,
    max_pages: int = 10,
    x_admin_token: Optional[str] = Header(default=None),
):
    _require_admin(x_admin_token) # Changed _db_conn to db_conn
    source, products = _fetch_woo_products_backfill(per_page=per_page, max_pages=max_pages)

    conn = db_conn()
    imported = 0
    updated = 0
    errors: List[Dict[str, Any]] = []
    try:
        for p in products:
            try:
                out = _upsert_from_woo_product(conn, p)
                if out.get("created_event") or out.get("created_submission"):
                    imported += 1
                else:
                    updated += 1
            except Exception as e:
                errors.append(
                    {
                        "woo_id": (p.get("id") if isinstance(p, dict) else None),
                        "name": (p.get("name") if isinstance(p, dict) else None),
                        "error": str(e),
                    }
                )
        conn.commit()
    except Exception:
        conn.rollback()
        raise
    finally:
        conn.close()

    return {
        "ok": True,
        "source": source,
        "total_products": len(products),
        "imported": imported,
        "updated": updated,
        "errors_count": len(errors),
        "errors": errors[:25],
    }


@admin_router.post("/woo/order-paid", summary="Woo paid order -> mobile ticket üret")
def admin_woo_order_paid(
    payload: Dict[str, Any],
    x_admin_token: Optional[str] = Header(default=None),
    x_woo_sync_secret: Optional[str] = Header(default=None),
):
    if WOO_SYNC_SECRET: # Changed _db_conn to db_conn
        if not x_woo_sync_secret or x_woo_sync_secret.strip() != WOO_SYNC_SECRET:
            _require_admin(x_admin_token)
    else:
        _require_admin(x_admin_token)

    data = payload or {}
    order_id = str(data.get("order_id") or data.get("id") or "").strip()
    order_status = str(data.get("status") or "").strip().lower()
    buyer_email = str(data.get("billing_email") or data.get("email") or "").strip().lower()
    wp_user_id_raw = data.get("customer_id") if data.get("customer_id") is not None else data.get("wp_user_id")
    wp_user_id = int(wp_user_id_raw) if str(wp_user_id_raw or "").isdigit() else None
    line_items = data.get("line_items") if isinstance(data.get("line_items"), list) else []
    if not line_items and isinstance(data.get("items"), list):
        line_items = data.get("items") or []
    if not line_items and (data.get("product_id") or data.get("woo_product_id")):
        line_items = [
            {
                "product_id": data.get("product_id") or data.get("woo_product_id"),
                "quantity": data.get("quantity") or 1,
                "id": data.get("order_item_id") or data.get("product_id") or data.get("woo_product_id"),
            }
        ]

    if not order_id:
        raise HTTPException(status_code=400, detail="order_id eksik")
    ticket_status = _ticket_status_from_woo_status(order_status)

    conn = db_conn()
    try:
        account_id = _resolve_account_by_email_or_wp(conn, buyer_email, wp_user_id)
        if not account_id:
            raise HTTPException(status_code=409, detail="Sipariş sahibi app hesabı ile eşleşmedi")

        cur = conn.cursor()
        created_total = 0
        created_ticket_events: Dict[int, Dict[str, Any]] = {}
        skipped_items: List[Dict[str, Any]] = []
        for li in line_items:
            if not isinstance(li, dict):
                continue
            product_id = str(li.get("product_id") or li.get("id") or "").strip()
            qty_raw = li.get("quantity") if li.get("quantity") is not None else 1
            qty = int(qty_raw) if str(qty_raw).isdigit() else 1
            order_item_id = str(li.get("id") or product_id or uuid.uuid4().hex[:8]).strip()

            if not product_id:
                skipped_items.append({"item_id": order_item_id, "reason": "product_id missing"})
                continue

            ev = _find_or_create_submission_for_woo_product(
                conn,
                product_id,
                reference_day=_parse_event_date_text(str(data.get("date_created") or data.get("date_paid") or "")),
            )
            if not ev:
                skipped_items.append({"product_id": product_id, "reason": "mapped event not found"})
                continue
            submission_id = int(ev["id"])
            event_name = (ev.get("event_name") or "").strip()
            event_slug = (ev.get("approved_event_slug") or "").strip()

            # Aynı order_item için tekrar üretmeyi engelle (idempotent)
            cur.execute(
                """
                SELECT COUNT(*) AS cnt
                FROM mobile_tickets
                WHERE woo_order_id=%s AND woo_order_item_id LIKE %s
                """,
                (order_id, f"{order_item_id}%"),
            )
            existing = int((cur.fetchone() or {}).get("cnt") or 0)
            # Var olan bilet satirlarinda siparis/odeme durumunu guncelle.
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
                WHERE woo_order_id=%s AND woo_order_item_id LIKE %s
                """,
                (order_status, ticket_status, ticket_status, ticket_status, order_id, f"{order_item_id}%"),
            )
            if existing >= qty:
                skipped_items.append(
                    {
                        "product_id": product_id,
                        "reason": "already created",
                        "existing": existing,
                        "updated_status": ticket_status,
                    }
                )
                continue

            to_create = qty - existing
            created_ticket_ids = _create_ticket_rows(
                conn,
                account_id=account_id,
                submission_id=submission_id,
                event_slug=event_slug,
                event_name=event_name,
                woo_order_id=order_id,
                woo_order_item_id=order_item_id,
                woo_order_status=order_status,
                ticket_status=ticket_status,
                quantity=to_create,
            )
            created_count = len(created_ticket_ids)
            created_total += created_count
            if created_count > 0:
                created_meta = created_ticket_events.setdefault(
                    submission_id,
                    {
                        "event_name": event_name,
                        "ticket_ids": [],
                    },
                )
                created_meta["ticket_ids"].extend(created_ticket_ids)

        conn.commit()
        for created_submission_id, meta in created_ticket_events.items():
            _send_ticket_created_notifications(
                conn,
                notifications=[
                    {
                        "account_id": int(account_id),
                        "ticket_id": int((meta.get("ticket_ids") or [0])[-1] or 0),
                    }
                ],
                submission_id=int(created_submission_id),
                event_name=(meta.get("event_name") or "").strip(),
                ticket_type="paid",
            )
        out = {
            "ok": True,
            "order_id": order_id,
            "order_status": order_status,
            "account_id": account_id,
            "created_tickets": created_total,
            "skipped_items": skipped_items,
        }
        logger.info(
            "woo.order_paid result order_id=%s account_id=%s created_tickets=%s skipped=%s",
            order_id,
            account_id,
            created_total,
            skipped_items,
        )
        return out
    except HTTPException:
        conn.rollback()
        raise
    except Exception as e:
        conn.rollback()
        raise HTTPException(status_code=500, detail=f"order-paid sync hatası: {e}")
    finally:
        conn.close()


@admin_router.get("/{submission_id}/scan-permissions", summary="Etkinlik editör yetki listesi")
def admin_ticket_scan_permissions(
    submission_id: int,
    x_admin_token: Optional[str] = Header(default=None),
):
    _require_admin(x_admin_token) # Changed _db_conn to db_conn
    conn = db_conn()
    try:
        cur = conn.cursor()
        cur.execute(
            """
            SELECT p.id, p.account_id, COALESCE(a.name,'') AS name, COALESCE(a.email,'') AS email, COALESCE(ps.username,'') AS username, p.created_at
            FROM mobile_ticket_scan_permissions p
            JOIN accounts a ON a.id=p.account_id
            LEFT JOIN mobile_profile_settings ps ON ps.account_id = p.account_id
            WHERE p.submission_id=%s
            ORDER BY p.id DESC
            """,
            (int(submission_id),),
        )
        rows = cur.fetchall() or []
        return {
            "submission_id": int(submission_id),
            "items": [
                {
                    "permission_id": int(r["id"]),
                    "account_id": int(r["account_id"]),
                    "name": display_name((r.get("name") or ""), (r.get("email") or ""), (r.get("username") or "")),
                    "email": (r.get("email") or ""),
                    "created_at": (r.get("created_at") or ""),
                }
                for r in rows
            ],
        }
    finally:
        conn.close()


@admin_router.post("/scan-permissions/bulk", summary="Etkinlik editör yetki listesi (toplu)")
def admin_ticket_scan_permissions_bulk(
    submission_ids_csv: Optional[str] = Form(default=""),
    x_admin_token: Optional[str] = Header(default=None),
):
    _require_admin(x_admin_token) # Changed _db_conn to db_conn
    raw_ids = [x.strip() for x in str(submission_ids_csv or "").split(",")]
    submission_ids: List[int] = []
    seen = set()
    for raw in raw_ids:
        if not raw:
            continue
        try:
            value = int(raw)
        except Exception:
            continue
        if value <= 0 or value in seen:
            continue
        seen.add(value)
        submission_ids.append(value)

    if not submission_ids:
        return {"items_by_submission": {}}

    conn = db_conn()
    try:
        cur = conn.cursor()
        cur.execute(
            """
            SELECT
                p.submission_id,
                p.id,
                p.account_id,
                COALESCE(a.name,'') AS name,
                COALESCE(a.email,'') AS email,
                COALESCE(ps.username,'') AS username,
                p.created_at
            FROM mobile_ticket_scan_permissions p
            JOIN accounts a ON a.id=p.account_id
            LEFT JOIN mobile_profile_settings ps ON ps.account_id = p.account_id
            WHERE p.submission_id = ANY(%s)
            ORDER BY p.submission_id DESC, p.id DESC
            """,
            (submission_ids,),
        )
        rows = cur.fetchall() or []
        items_by_submission: Dict[str, List[Dict[str, Any]]] = {str(sid): [] for sid in submission_ids}
        for r in rows:
            sid = int(r.get("submission_id") or 0)
            if sid <= 0:
                continue
            items_by_submission.setdefault(str(sid), []).append(
                {
                    "permission_id": int(r["id"]),
                    "account_id": int(r["account_id"]),
                    "name": display_name((r.get("name") or ""), (r.get("email") or ""), (r.get("username") or "")),
                    "email": (r.get("email") or ""),
                    "created_at": (r.get("created_at") or ""),
                }
            )
        return {"items_by_submission": items_by_submission}
    finally:
        conn.close()


@admin_router.post("/loyalty-reports/bulk", summary="Etkinlik bazlı okul ve ücretsiz bilet raporu (toplu)")
def admin_loyalty_reports_bulk(
    submission_ids_csv: Optional[str] = Form(default=""),
    x_admin_token: Optional[str] = Header(default=None),
):
    _require_admin(x_admin_token) # Changed _db_conn to db_conn
    submission_ids = _parse_admin_submission_ids_csv(submission_ids_csv)
    if not submission_ids:
        return {"items_by_submission": {}}

    conn = db_conn()
    try:
        return {
            "items_by_submission": _build_admin_loyalty_reports(conn, submission_ids),
        }
    finally:
        conn.close()


@admin_router.post("/{submission_id}/scan-permissions/grant", summary="Etkinlik editör yetkisi ver")
def admin_grant_ticket_scan_permission(
    submission_id: int,
    account_id: int = Form(...),
    x_admin_token: Optional[str] = Header(default=None),
):
    _require_admin(x_admin_token) # Changed _db_conn to db_conn
    conn = db_conn()
    try:
        cur = conn.cursor()
        affected_ids = _repeat_thread_submission_ids(conn, int(submission_id))
        now_iso = _iso_now()
        for target_submission_id in affected_ids:
            cur.execute(
                """
                INSERT INTO mobile_ticket_scan_permissions (submission_id, account_id, granted_by_account_id, created_at)
                VALUES (%s,%s,NULL,%s)
                ON CONFLICT (submission_id, account_id) DO NOTHING
                """,
                (int(target_submission_id), int(account_id), now_iso),
            )
        conn.commit()
        return {
            "ok": True,
            "submission_id": int(submission_id),
            "thread_submission_ids": affected_ids,
            "account_id": int(account_id),
        }
    finally:
        conn.close()


@admin_router.post("/{submission_id}/scan-permissions/revoke", summary="Etkinlik editör yetkisini kaldır")
def admin_revoke_ticket_scan_permission(
    submission_id: int,
    account_id: int = Form(...),
    x_admin_token: Optional[str] = Header(default=None),
):
    _require_admin(x_admin_token) # Changed _db_conn to db_conn
    conn = db_conn()
    try:
        cur = conn.cursor()
        affected_ids = _repeat_thread_submission_ids(conn, int(submission_id))
        cur.execute(
            """
            DELETE FROM mobile_ticket_scan_permissions
            WHERE submission_id = ANY(%s) AND account_id=%s
            """,
            (affected_ids, int(account_id)),
        )
        conn.commit()
        return {
            "ok": True,
            "submission_id": int(submission_id),
            "thread_submission_ids": affected_ids,
            "account_id": int(account_id),
        }
    finally:
        conn.close()


@router.get("/submission-cover/{filename}", include_in_schema=False)
def get_submission_cover(filename: str):
    safe_name = os.path.basename(filename)
    abs_path = os.path.join(UPLOAD_DIR, safe_name)
    if not os.path.exists(abs_path):
        alt_path = os.path.join(ALT_UPLOAD_DIR, safe_name)
        if os.path.exists(alt_path):
            return FileResponse(alt_path)
        raise HTTPException(status_code=404, detail="Dosya bulunamadı")
    return FileResponse(abs_path)


@router.get("/{submission_id}/attendees", summary="Etkinlik katılımcıları")
def event_attendees(
    submission_id: int,
    limit: int = 200,
    authorization: Optional[str] = Header(default=None),
): # Changed _db_conn to db_conn
    conn = _db_conn()
    try:
        if not _event_exists(conn, submission_id):
            raise HTTPException(status_code=404, detail="Etkinlik bulunamadı")
        my_account_id: Optional[int] = None
        if authorization:
            try:
                my_account_id = _require_account_id(conn, authorization)
            except HTTPException:
                my_account_id = None

        cur = conn.cursor()
        cur.execute(
            """
            SELECT
                mea.account_id,
                COALESCE(a.name, '') AS name,
                COALESCE(a.email, '') AS email,
                COALESCE(a.role, '') AS role,
                COALESCE(ps.username, '') AS username,
                COALESCE(ps.avatar_url, '') AS avatar_url,
                COALESCE(ps.is_verified, FALSE) AS is_verified,
                mea.created_at
            FROM mobile_event_attendees mea
            JOIN accounts a ON a.id = mea.account_id
            LEFT JOIN mobile_profile_settings ps ON ps.account_id = mea.account_id
            WHERE mea.submission_id=%s
            ORDER BY mea.created_at ASC
            LIMIT %s
            """,
            (int(submission_id), max(1, min(int(limit), 500))),
        )
        rows = cur.fetchall() or []

        friend_ids: set[int] = set()
        outgoing_reqs: Dict[int, int] = {}
        incoming_reqs: Dict[int, int] = {}
        if my_account_id:
            cur.execute(
                """
                SELECT user_a_id, user_b_id
                FROM mobile_friendships
                WHERE user_a_id=%s OR user_b_id=%s
                """,
                (my_account_id, my_account_id),
            )
            for fr in cur.fetchall() or []:
                ua = int(fr["user_a_id"])
                ub = int(fr["user_b_id"])
                friend_ids.add(ub if ua == my_account_id else ua)
            cur.execute(
                """
                SELECT id, target_id
                FROM mobile_friend_requests
                WHERE requester_id=%s AND status='pending'
                """,
                (my_account_id,),
            )
            for rr in cur.fetchall() or []:
                outgoing_reqs[int(rr["target_id"])] = int(rr["id"])
            cur.execute(
                """
                SELECT id, requester_id
                FROM mobile_friend_requests
                WHERE target_id=%s AND status='pending'
                """,
                (my_account_id,),
            )
            for rr in cur.fetchall() or []:
                incoming_reqs[int(rr["requester_id"])] = int(rr["id"])

        items: List[Dict[str, Any]] = []
        for r in rows:
            aid = int(r["account_id"])
            if my_account_id and aid in friend_ids:
                friend_status = "friend"
                req_id = None
            elif my_account_id and aid in outgoing_reqs:
                friend_status = "pending_outgoing"
                req_id = outgoing_reqs.get(aid)
            elif my_account_id and aid in incoming_reqs:
                friend_status = "pending_incoming"
                req_id = incoming_reqs.get(aid)
            else:
                friend_status = "none"
                req_id = None
            items.append(
                {
                    "account_id": aid,
                    "name": display_name((r.get("name") or ""), (r.get("email") or ""), (r.get("username") or "")),
                    "avatar_url": (r.get("avatar_url") or ""),
                    "is_verified": bool(r.get("is_verified")) or str(r.get("role") or "").strip().lower() in {"super_admin", "editor"},
                    "joined_at": (r.get("created_at") or ""),
                    "is_me": bool(my_account_id and aid == my_account_id),
                    "is_friend": bool(my_account_id and aid in friend_ids),
                    "friend_status": friend_status,
                    "friend_request_id": req_id,
                }
            )

        return {"submission_id": int(submission_id), "total": len(items), "items": items}
    finally:
        conn.close()


@router.post("/{submission_id}/attend", summary="Etkinliğe katılacağım")
def join_event(submission_id: int, authorization: Optional[str] = Header(default=None)):
    conn = _db_conn()
    try: # Changed _db_conn to db_conn
        if not _event_exists(conn, submission_id):
            raise HTTPException(status_code=404, detail="Etkinlik bulunamadı")
        account_id = _require_account_id(conn, authorization)
        cur = conn.cursor()
        cur.execute(
            """
            INSERT INTO mobile_event_attendees (submission_id, account_id, created_at)
            VALUES (%s, %s, %s)
            ON CONFLICT (submission_id, account_id) DO NOTHING
            """,
            (int(submission_id), int(account_id), _iso_now()),
        )
        conn.commit()
        return {"ok": True, "submission_id": int(submission_id), "account_id": int(account_id), "joined": True}
    finally:
        conn.close()


@router.delete("/{submission_id}/attend", summary="Etkinliğe katılımı iptal et")
def leave_event(submission_id: int, authorization: Optional[str] = Header(default=None)):
    conn = _db_conn()
    try: # Changed _db_conn to db_conn
        account_id = _require_account_id(conn, authorization)
        cur = conn.cursor()
        cur.execute(
            "DELETE FROM mobile_event_attendees WHERE submission_id=%s AND account_id=%s",
            (int(submission_id), int(account_id)),
        )
        conn.commit()
        return {"ok": True, "submission_id": int(submission_id), "account_id": int(account_id), "joined": False}
    finally:
        conn.close()


@router.get("/{submission_id}/comments", summary="Etkinlik yorumları")
def event_comments(
    submission_id: int,
    authorization: Optional[str] = Header(default=None),
):
    conn = db_conn()
    try:
        anchor = _get_event_comment_anchor(conn, submission_id)
        if not anchor or (anchor.get("status") or "").strip().lower() not in {"approved", "expired"}:
            raise HTTPException(status_code=404, detail="Etkinlik bulunamadı")

        my_account_id: Optional[int] = None
        can_moderate = False
        if authorization:
            try:
                my_account_id = _require_account_id(conn, authorization)
                can_moderate = bool(_account_comment_moderation(conn, my_account_id).get("can_moderate"))
            except HTTPException:
                my_account_id = None
                can_moderate = False

        thread_submission_id = int(anchor["thread_submission_id"])
        rows = _fetch_thread_comment_rows(conn, thread_submission_id)
        items = [
            _serialize_event_comment(
                row,
                my_account_id=my_account_id,
                can_moderate=can_moderate,
            )
            for row in rows
        ]
        my_comment = next((item for item in items if item["is_mine"]), None)

        can_comment = False
        eligibility = "login_required"
        if my_account_id:
            if my_comment is not None:
                can_comment = True
                eligibility = "can_edit"
            else:
                can_comment = True
                eligibility = "eligible"

        return {
            "ok": True,
            "submission_id": int(submission_id),
            "thread_submission_id": thread_submission_id,
            "event_name": (anchor.get("event_name") or "").strip(),
            "can_comment": can_comment,
            "can_moderate": can_moderate,
            "eligibility": eligibility,
            "items": items,
            "my_comment": my_comment,
            "count": len(items),
        }
    finally:
        conn.close()


@router.put("/{submission_id}/comments/me", summary="Etkinlik yorumu oluştur/güncelle")
def upsert_event_comment(
    submission_id: int,
    payload: EventCommentUpsertRequest,
    authorization: Optional[str] = Header(default=None),
):
    body = (payload.body or "").strip()
    if not body:
        raise HTTPException(status_code=400, detail="Yorum boş olamaz")
    if len(body) > 1200:
        raise HTTPException(status_code=400, detail="Yorum en fazla 1200 karakter olabilir")

    conn = db_conn()
    try:
        anchor = _get_event_comment_anchor(conn, submission_id)
        if not anchor or (anchor.get("status") or "").strip().lower() not in {"approved", "expired"}:
            raise HTTPException(status_code=404, detail="Etkinlik bulunamadı")

        account_id = _require_account_id(conn, authorization)
        moderation = _account_comment_moderation(conn, account_id)
        thread_submission_id = int(anchor["thread_submission_id"])
        now_iso = _iso_now()

        cur = conn.cursor()
        cur.execute(
            """
            SELECT id
            FROM mobile_event_comments
            WHERE thread_submission_id=%s AND author_account_id=%s
            LIMIT 1
            """,
            (thread_submission_id, int(account_id)),
        )
        existing = cur.fetchone()

        if existing:
            comment_id = int(existing["id"])
            cur.execute(
                """
                UPDATE mobile_event_comments
                SET body=%s, updated_at=%s
                WHERE id=%s
                RETURNING id
                """,
                (body, now_iso, comment_id),
            )
            action = "updated"
        else:
            cur.execute(
                """
                INSERT INTO mobile_event_comments (
                    thread_submission_id, author_account_id, body, created_at, updated_at
                )
                VALUES (%s, %s, %s, %s, %s)
                RETURNING id
                """,
                (thread_submission_id, int(account_id), body, now_iso, now_iso),
            )
            action = "created"
        comment_id = int(cur.fetchone()["id"])
        conn.commit()

        cur.execute(
            """
            SELECT
                c.id,
                c.thread_submission_id,
                c.author_account_id,
                c.body,
                c.created_at,
                c.updated_at,
                COALESCE(a.name, '') AS author_name,
                COALESCE(a.email, '') AS author_email,
                COALESCE(a.role, '') AS author_role,
                COALESCE(ps.username, '') AS author_username,
                COALESCE(ps.is_verified, FALSE) AS author_is_verified
            FROM mobile_event_comments c
            JOIN accounts a ON a.id = c.author_account_id
            LEFT JOIN mobile_profile_settings ps ON ps.account_id = c.author_account_id
            WHERE c.id=%s
            LIMIT 1
            """,
            (comment_id,),
        )
        row = cur.fetchone()
        item = _serialize_event_comment(
            row,
            my_account_id=account_id,
            can_moderate=bool(moderation.get("can_moderate")),
        )
        return {
            "ok": True,
            "action": action,
            "submission_id": int(submission_id),
            "thread_submission_id": thread_submission_id,
            "item": item,
        }
    finally:
        conn.close()


@router.delete("/{submission_id}/comments/{comment_id}", summary="Etkinlik yorumunu sil")
def delete_event_comment(
    submission_id: int,
    comment_id: int,
    authorization: Optional[str] = Header(default=None),
):
    conn = db_conn()
    try:
        anchor = _get_event_comment_anchor(conn, submission_id)
        if not anchor or (anchor.get("status") or "").strip().lower() not in {"approved", "expired"}:
            raise HTTPException(status_code=404, detail="Etkinlik bulunamadı")
        account_id = _require_account_id(conn, authorization)
        moderation = _account_comment_moderation(conn, account_id)
        thread_submission_id = int(anchor["thread_submission_id"])
        cur = conn.cursor()
        cur.execute(
            """
            SELECT author_account_id
            FROM mobile_event_comments
            WHERE id=%s AND thread_submission_id=%s
            LIMIT 1
            """,
            (int(comment_id), thread_submission_id),
        )
        comment_row = cur.fetchone()
        if not comment_row:
            raise HTTPException(status_code=404, detail="Yorum bulunamadı")
        comment_author_id = int(comment_row["author_account_id"])
        if comment_author_id != int(account_id) and not moderation.get("can_moderate"):
            raise HTTPException(status_code=403, detail="Yorum silme yetkiniz yok")
        cur.execute(
            """
            DELETE FROM mobile_event_comments
            WHERE id=%s AND thread_submission_id=%s
            RETURNING id
            """,
            (int(comment_id), thread_submission_id),
        )
        deleted = cur.fetchone()
        conn.commit()
        return {
            "ok": True,
            "submission_id": int(submission_id),
            "thread_submission_id": thread_submission_id,
            "comment_id": int(comment_id),
        }
    finally:
        conn.close()


@router.get("/{submission_id}/raffle", summary="Etkinlik içi çekiliş durumu")
def event_raffle_detail(
    submission_id: int,
    authorization: Optional[str] = Header(default=None),
):
    conn = db_conn()
    try:
        event_row = _get_event_submission(conn, submission_id)
        if not event_row:
            raise HTTPException(status_code=404, detail="Etkinlik bulunamadı")

        my_account_id: Optional[int] = None
        can_manage = False
        if authorization:
            try:
                my_account_id = _require_account_id(conn, authorization)
            except HTTPException:
                my_account_id = None
            if my_account_id:
                cur = conn.cursor()
                cur.execute(
                    """
                    SELECT COALESCE(role,'customer') AS role, COALESCE(email,'') AS email
                    FROM accounts
                    WHERE id=%s
                    LIMIT 1
                    """,
                    (int(my_account_id),),
                )
                actor_row = cur.fetchone() or {}
                can_manage = _actor_can_manage_submission(
                    conn,
                    submission_id=int(submission_id),
                    account_id=int(my_account_id),
                    role=(actor_row.get("role") or "").strip().lower(),
                    actor_email=(actor_row.get("email") or "").strip().lower(),
                )

        raffle_row = _fetch_event_raffle_row(conn, submission_id)
        raffle = (
            _serialize_event_raffle(
                conn,
                raffle_row,
                my_account_id=my_account_id,
                can_manage=can_manage,
            )
            if raffle_row
            else None
        )
        return {
            "ok": True,
            "submission_id": int(submission_id),
            "can_manage": can_manage,
            "raffle": raffle,
        }
    finally:
        conn.close()


@router.put("/{submission_id}/raffle", summary="Etkinlik içi çekiliş oluştur/güncelle")
def upsert_event_raffle(
    submission_id: int,
    payload: EventRaffleUpsertRequest,
    authorization: Optional[str] = Header(default=None),
):
    conn = db_conn()
    try:
        actor = _require_editor_account(conn, authorization)
        if not _get_event_submission(conn, submission_id):
            raise HTTPException(status_code=404, detail="Etkinlik bulunamadı")
        if not _actor_can_manage_submission(
            conn,
            submission_id=int(submission_id),
            account_id=int(actor["account_id"]),
            role=(actor.get("role") or "").strip().lower(),
            actor_email=(actor.get("email") or "").strip().lower(),
        ):
            raise HTTPException(status_code=403, detail="Bu etkinlik için çekiliş yönetme yetkiniz yok")

        winner_count = int(payload.winner_count or 0)
        if winner_count < 1 or winner_count > 100:
            raise HTTPException(status_code=400, detail="Talihli sayısı 1 ile 100 arasında olmalı")

        existing = _fetch_event_raffle_row(conn, submission_id)
        if existing and (existing.get("drawn_at") or "").strip():
            raise HTTPException(status_code=409, detail="Sonuçlanmış çekiliş tekrar düzenlenemez")

        now_iso = _iso_now()
        cur = conn.cursor()
        cur.execute(
            """
            INSERT INTO mobile_event_raffles (
                submission_id, starts_at, ends_at, winner_count, status,
                created_by_account_id, created_at, updated_at
            )
            VALUES (%s, %s, %s, %s, %s, %s, %s, %s)
            ON CONFLICT (submission_id) DO UPDATE SET
                winner_count=EXCLUDED.winner_count,
                updated_at=EXCLUDED.updated_at
            RETURNING id, submission_id, starts_at, ends_at, winner_count, status,
                      created_by_account_id, drawn_by_account_id, created_at, updated_at, drawn_at
            """,
            (
                int(submission_id),
                (existing.get("starts_at") or "").strip() if existing else "",
                (existing.get("ends_at") or "").strip() if existing else "",
                winner_count,
                (_raffle_state_for_row(existing) if existing else "draft"),
                int(actor["account_id"]),
                now_iso,
                now_iso,
            ),
        )
        raffle_row = cur.fetchone()
        conn.commit()
        return {
            "ok": True,
            "submission_id": int(submission_id),
            "raffle": _serialize_event_raffle(
                conn,
                raffle_row,
                my_account_id=int(actor["account_id"]),
                can_manage=True,
            ),
        }
    finally:
        conn.close()


@router.delete("/{submission_id}/raffle", summary="Etkinlik içi çekilişi sil")
def delete_event_raffle(
    submission_id: int,
    authorization: Optional[str] = Header(default=None),
):
    conn = db_conn()
    try:
        actor = _require_editor_account(conn, authorization)
        if not _get_event_submission(conn, submission_id):
            raise HTTPException(status_code=404, detail="Etkinlik bulunamadı")
        if not _actor_can_manage_submission(
            conn,
            submission_id=int(submission_id),
            account_id=int(actor["account_id"]),
            role=(actor.get("role") or "").strip().lower(),
            actor_email=(actor.get("email") or "").strip().lower(),
        ):
            raise HTTPException(status_code=403, detail="Bu etkinlik için çekiliş yönetme yetkiniz yok")

        raffle_row = _fetch_event_raffle_row(conn, submission_id)
        if not raffle_row:
            raise HTTPException(status_code=404, detail="Silinecek çekiliş bulunamadı")

        cur = conn.cursor()
        cur.execute(
            """
            DELETE FROM mobile_event_raffles
            WHERE id=%s
            """,
            (int(raffle_row["id"]),),
        )
        conn.commit()
        return {"ok": True, "submission_id": int(submission_id), "deleted": True}
    finally:
        conn.close()


@router.post("/{submission_id}/raffle/open", summary="Etkinlik çekilişi başvurularını aç")
def open_event_raffle(
    submission_id: int,
    authorization: Optional[str] = Header(default=None),
):
    conn = db_conn()
    try:
        actor = _require_editor_account(conn, authorization)
        if not _get_event_submission(conn, submission_id):
            raise HTTPException(status_code=404, detail="Etkinlik bulunamadı")
        if not _actor_can_manage_submission(
            conn,
            submission_id=int(submission_id),
            account_id=int(actor["account_id"]),
            role=(actor.get("role") or "").strip().lower(),
            actor_email=(actor.get("email") or "").strip().lower(),
        ):
            raise HTTPException(status_code=403, detail="Bu etkinlik için çekiliş yönetme yetkiniz yok")

        raffle_row = _fetch_event_raffle_row(conn, submission_id)
        if not raffle_row:
            raise HTTPException(status_code=404, detail="Önce çekilişi hazırlamalısınız")
        if (raffle_row.get("drawn_at") or "").strip():
            raise HTTPException(status_code=409, detail="Sonuçlanan çekiliş tekrar açılamaz")
        if _raffle_state_for_row(raffle_row) == "active":
            raise HTTPException(status_code=400, detail="Başvurular zaten açık")

        now_iso = _iso_now()
        cur = conn.cursor()
        cur.execute(
            """
            UPDATE mobile_event_raffles
            SET status='active', starts_at=%s, ends_at='', updated_at=%s
            WHERE id=%s
            RETURNING id, submission_id, starts_at, ends_at, winner_count, status,
                      created_by_account_id, drawn_by_account_id, created_at, updated_at, drawn_at
            """,
            (now_iso, now_iso, int(raffle_row["id"])),
        )
        updated_row = cur.fetchone()
        conn.commit()
        return {
            "ok": True,
            "submission_id": int(submission_id),
            "raffle": _serialize_event_raffle(
                conn,
                updated_row,
                my_account_id=int(actor["account_id"]),
                can_manage=True,
            ),
        }
    finally:
        conn.close()


@router.post("/{submission_id}/raffle/close", summary="Etkinlik çekilişi başvurularını durdur")
def close_event_raffle(
    submission_id: int,
    authorization: Optional[str] = Header(default=None),
):
    conn = db_conn()
    try:
        actor = _require_editor_account(conn, authorization)
        if not _get_event_submission(conn, submission_id):
            raise HTTPException(status_code=404, detail="Etkinlik bulunamadı")
        if not _actor_can_manage_submission(
            conn,
            submission_id=int(submission_id),
            account_id=int(actor["account_id"]),
            role=(actor.get("role") or "").strip().lower(),
            actor_email=(actor.get("email") or "").strip().lower(),
        ):
            raise HTTPException(status_code=403, detail="Bu etkinlik için çekiliş yönetme yetkiniz yok")

        raffle_row = _fetch_event_raffle_row(conn, submission_id)
        if not raffle_row:
            raise HTTPException(status_code=404, detail="Önce çekilişi hazırlamalısınız")
        if (raffle_row.get("drawn_at") or "").strip():
            raise HTTPException(status_code=409, detail="Sonuçlanan çekiliş kapatılamaz")
        if _raffle_state_for_row(raffle_row) != "active":
            raise HTTPException(status_code=400, detail="Başvurular zaten kapalı")

        now_iso = _iso_now()
        cur = conn.cursor()
        cur.execute(
            """
            UPDATE mobile_event_raffles
            SET status='closed', ends_at=%s, updated_at=%s
            WHERE id=%s
            RETURNING id, submission_id, starts_at, ends_at, winner_count, status,
                      created_by_account_id, drawn_by_account_id, created_at, updated_at, drawn_at
            """,
            (now_iso, now_iso, int(raffle_row["id"])),
        )
        updated_row = cur.fetchone()
        conn.commit()
        return {
            "ok": True,
            "submission_id": int(submission_id),
            "raffle": _serialize_event_raffle(
                conn,
                updated_row,
                my_account_id=int(actor["account_id"]),
                can_manage=True,
            ),
        }
    finally:
        conn.close()


@router.post("/{submission_id}/raffle/join", summary="Etkinlik çekilişine katıl")
def join_event_raffle(
    submission_id: int,
    authorization: Optional[str] = Header(default=None),
):
    conn = db_conn()
    try:
        event_row = _get_event_submission(conn, submission_id)
        if not event_row or (event_row.get("status") or "").strip().lower() not in {"approved", "expired"}:
            raise HTTPException(status_code=404, detail="Etkinlik bulunamadı")

        account_id = _require_account_id(conn, authorization)
        raffle_row = _fetch_event_raffle_row(conn, submission_id)
        if not raffle_row:
            raise HTTPException(status_code=404, detail="Bu etkinlik için aktif bir çekiliş yok")
        state = _raffle_state_for_row(raffle_row)
        if state != "active":
            if state == "draft":
                raise HTTPException(status_code=400, detail="Çekiliş başvuruları henüz açılmadı")
            if state == "closed":
                raise HTTPException(status_code=400, detail="Çekiliş başvuruları durduruldu")
            raise HTTPException(status_code=400, detail="Çekiliş şu anda katılıma açık değil")

        cur = conn.cursor()
        cur.execute(
            """
            INSERT INTO mobile_event_raffle_entries (raffle_id, account_id, created_at)
            VALUES (%s, %s, %s)
            ON CONFLICT (raffle_id, account_id) DO NOTHING
            """,
            (int(raffle_row["id"]), int(account_id), _iso_now()),
        )
        conn.commit()
        return {
            "ok": True,
            "submission_id": int(submission_id),
            "raffle": _serialize_event_raffle(
                conn,
                raffle_row,
                my_account_id=int(account_id),
                can_manage=False,
            ),
        }
    finally:
        conn.close()


@router.post("/{submission_id}/raffle/draw", summary="Etkinlik çekiliş kazananlarını belirle")
def draw_event_raffle(
    submission_id: int,
    authorization: Optional[str] = Header(default=None),
):
    conn = db_conn()
    try:
        actor = _require_editor_account(conn, authorization)
        if not _get_event_submission(conn, submission_id):
            raise HTTPException(status_code=404, detail="Etkinlik bulunamadı")
        if not _actor_can_manage_submission(
            conn,
            submission_id=int(submission_id),
            account_id=int(actor["account_id"]),
            role=(actor.get("role") or "").strip().lower(),
            actor_email=(actor.get("email") or "").strip().lower(),
        ):
            raise HTTPException(status_code=403, detail="Bu etkinlik için çekiliş yönetme yetkiniz yok")

        raffle_row = _fetch_event_raffle_row(conn, submission_id)
        if not raffle_row:
            raise HTTPException(status_code=404, detail="Önce etkinlik için çekiliş oluşturmalısınız")
        if (raffle_row.get("drawn_at") or "").strip():
            raise HTTPException(status_code=409, detail="Kazananlar zaten belirlenmiş")
        if _raffle_state_for_row(raffle_row) != "closed":
            raise HTTPException(status_code=400, detail="Önce başvuruları durdurmalısınız")

        cur = conn.cursor()
        cur.execute(
            """
            SELECT
                e.account_id,
                COALESCE(a.name, '') AS name,
                COALESCE(a.email, '') AS email
            FROM mobile_event_raffle_entries e
            JOIN accounts a ON a.id = e.account_id
            WHERE e.raffle_id=%s
            ORDER BY e.created_at ASC, e.account_id ASC
            """,
            (int(raffle_row["id"]),),
        )
        entries = cur.fetchall() or []
        if not entries:
            raise HTTPException(status_code=400, detail="Çekilişte seçilecek katılımcı yok")

        requested_count = max(int(raffle_row.get("winner_count") or 0), 0)
        primary_count = min(requested_count, len(entries))
        reserve_count = min(requested_count, max(len(entries) - primary_count, 0))
        chosen = random.SystemRandom().sample(entries, primary_count + reserve_count)
        now_iso = _iso_now()
        cur.execute("DELETE FROM mobile_event_raffle_winners WHERE raffle_id=%s", (int(raffle_row["id"]),))
        for idx, entry in enumerate(chosen[:primary_count], start=1):
            cur.execute(
                """
                INSERT INTO mobile_event_raffle_winners (raffle_id, account_id, winner_kind, position, created_at)
                VALUES (%s, %s, %s, %s, %s)
                """,
                (int(raffle_row["id"]), int(entry["account_id"]), "primary", idx, now_iso),
            )
        for idx, entry in enumerate(chosen[primary_count:], start=1):
            cur.execute(
                """
                INSERT INTO mobile_event_raffle_winners (raffle_id, account_id, winner_kind, position, created_at)
                VALUES (%s, %s, %s, %s, %s)
                """,
                (int(raffle_row["id"]), int(entry["account_id"]), "reserve", idx, now_iso),
            )
        cur.execute(
            """
            UPDATE mobile_event_raffles
            SET status='drawn', drawn_at=%s, drawn_by_account_id=%s, updated_at=%s
            WHERE id=%s
            RETURNING id, submission_id, starts_at, ends_at, winner_count, status,
                      created_by_account_id, drawn_by_account_id, created_at, updated_at, drawn_at
            """,
            (now_iso, int(actor["account_id"]), now_iso, int(raffle_row["id"])),
        )
        updated_row = cur.fetchone()
        conn.commit()
        return {
            "ok": True,
            "submission_id": int(submission_id),
            "raffle": _serialize_event_raffle(
                conn,
                updated_row,
                my_account_id=int(actor["account_id"]),
                can_manage=True,
            ),
        }
    finally:
        conn.close()


@router.get("/tickets/scannable-events", summary="Kullanıcının editör yetkisi olan etkinlikler")
def scannable_events(authorization: Optional[str] = Header(default=None)):
    conn = _db_conn()
    try: # Changed _db_conn to db_conn
        account_id = _require_account_id(conn, authorization)
        _rollover_and_expire_events(conn)
        conn.commit()
        cur = conn.cursor()
        cur.execute(
            "SELECT COALESCE(role,'customer') AS role FROM accounts WHERE id=%s LIMIT 1",
            (int(account_id),),
        )
        role_row = cur.fetchone() or {}
        role = (role_row.get("role") or "customer").strip().lower()

        if role == "super_admin":
            cur.execute(
                """
                SELECT mes.id AS submission_id,
                       COALESCE(mes.event_name,'') AS event_name,
                       COALESCE(mes.event_date,'') AS event_date,
                       COALESCE(mes.venue,'') AS venue
                FROM mobile_event_submissions mes
                WHERE mes.status='approved'
                ORDER BY mes.id DESC
                """
            )
        else:
            cur.execute(
                """
                SELECT DISTINCT
                    mes.id AS submission_id,
                    COALESCE(mes.event_name,'') AS event_name,
                    COALESCE(mes.event_date,'') AS event_date,
                    COALESCE(mes.venue,'') AS venue
                FROM mobile_event_submissions mes
                LEFT JOIN saas_events se ON se.slug = mes.approved_event_slug
                LEFT JOIN mobile_ticket_scan_permissions p
                       ON p.submission_id = mes.id AND p.account_id = %s
                WHERE mes.status='approved'
                  AND (COALESCE(se.account_id,0)=%s OR p.id IS NOT NULL)
                ORDER BY mes.id DESC
                """,
                (int(account_id), int(account_id)),
            )
        rows = cur.fetchall() or []
        return {
            "items": [
                {
                    "submission_id": int(r["submission_id"]),
                    "event_name": (r.get("event_name") or ""),
                    "event_date": _normalize_event_dt_text((r.get("event_date") or "")),
                    "venue": (r.get("venue") or ""),
                }
                for r in rows
            ]
        }
    finally:
        conn.close()


@router.get("/{submission_id}/tickets/used", summary="Kullanılmış biletler listesi")
def used_tickets(
    submission_id: int,
    limit: int = 200,
    authorization: Optional[str] = Header(default=None),
):
    conn = db_conn()
    try:
        scanner_id = _require_account_id(conn, authorization)
        if not _can_scan_tickets(conn, submission_id, scanner_id):
            raise HTTPException(status_code=403, detail="Bu etkinliğin editör yetkisi yok")

        cur = conn.cursor()
        cur.execute(
            """
            SELECT
                t.id,
                t.event_name,
                t.woo_order_id,
                t.created_at,
                t.used_at,
                COALESCE(a.name,'') AS buyer_name,
                COALESCE(a.email,'') AS buyer_email,
                COALESCE(aps.username,'') AS buyer_username,
                COALESCE(s.name,'') AS scanner_name,
                COALESCE(s.email,'') AS scanner_email,
                COALESCE(sps.username,'') AS scanner_username
            FROM mobile_tickets t
            JOIN accounts a ON a.id=t.account_id
            LEFT JOIN mobile_profile_settings aps ON aps.account_id=a.id
            LEFT JOIN accounts s ON s.id=t.used_by_account_id
            LEFT JOIN mobile_profile_settings sps ON sps.account_id=s.id
            WHERE t.submission_id=%s AND t.used_at IS NOT NULL
            ORDER BY t.used_at DESC, t.id DESC
            LIMIT %s
            """,
            (int(submission_id), max(1, min(int(limit), 1000))),
        )
        rows = cur.fetchall() or []
        return {
            "submission_id": int(submission_id),
            "items": [
                {
                    "ticket_id": int(r["id"]),
                    "event_name": (r.get("event_name") or ""),
                    "buyer_name": display_name((r.get("buyer_name") or ""), (r.get("buyer_email") or ""), (r.get("buyer_username") or "")),
                    "buyer_email": (r.get("buyer_email") or ""),
                    "woo_order_id": (r.get("woo_order_id") or ""),
                    "created_at": (r.get("created_at") or ""),
                    "used_at": (r.get("used_at") or ""),
                    "scanned_by": display_name((r.get("scanner_name") or ""), (r.get("scanner_email") or ""), (r.get("scanner_username") or "")),
                    "scanned_by_email": (r.get("scanner_email") or ""),
                }
                for r in rows
            ],
        }
    finally:
        conn.close()


@router.post("/{submission_id}/tickets/scan", summary="QR bilet doğrula/kullan")
def scan_ticket(
    submission_id: int,
    qr_token: str = Form(...),
    authorization: Optional[str] = Header(default=None),
):
    decoded_qr = _decode_ticket_qr_payload(qr_token)
    token = (decoded_qr.get("raw_token") or "").strip() # Changed _db_conn to db_conn
    if not token:
        raise HTTPException(status_code=400, detail="qr_token zorunlu")
    payload_submission_id = int(decoded_qr.get("submission_id") or 0)
    if payload_submission_id > 0 and payload_submission_id != int(submission_id):
        raise HTTPException(status_code=400, detail="Bu QR başka etkinliğe ait")

    conn = db_conn()
    try:
        scanner_id = _require_account_id(conn, authorization)
        if not _can_scan_tickets(conn, submission_id, scanner_id):
            raise HTTPException(status_code=403, detail="Bu etkinliğin editör yetkisi yok")
        _expire_past_event_tickets(conn, submission_ids=[int(submission_id)])

        cur = conn.cursor()
        cur.execute(
            """
            SELECT t.id, t.account_id, t.event_name, t.event_slug, COALESCE(t.ticket_type,'paid') AS ticket_type, t.status, t.used_at, t.used_by_account_id,
                   COALESCE(a.name,'') AS buyer_name, COALESCE(a.email,'') AS buyer_email,
                   COALESCE(ps.username,'') AS buyer_username
            FROM mobile_tickets t
            JOIN accounts a ON a.id=t.account_id
            LEFT JOIN mobile_profile_settings ps ON ps.account_id=a.id
            WHERE t.submission_id=%s AND t.qr_token=%s
            LIMIT 1
            """,
            (int(submission_id), token),
        )
        row = cur.fetchone()
        if not row:
            cur.execute(
                """
                INSERT INTO mobile_ticket_scan_logs (ticket_id, submission_id, scanner_account_id, scan_result, scan_at)
                VALUES (0, %s, %s, 'not_found', %s)
                """,
                (int(submission_id), int(scanner_id), _iso_now()),
            )
            conn.commit()
            raise HTTPException(status_code=404, detail="Bilet bulunamadı")

        ticket_id = int(row["id"])
        payload_ticket_id = int(decoded_qr.get("ticket_id") or 0)
        payload_account_id = int(decoded_qr.get("account_id") or 0)
        if payload_ticket_id > 0 and payload_ticket_id != ticket_id:
            raise HTTPException(status_code=400, detail="QR bileti doğrulanamadı")
        if payload_account_id > 0 and payload_account_id != int(row["account_id"]):
            raise HTTPException(status_code=400, detail="QR kullanıcı doğrulaması başarısız")
        if (row.get("status") or "").strip().lower() != "active":
            scan_result = "expired" if (row.get("status") or "").strip().lower() == "expired" else "inactive"
            message = "Bilet süresi dolmuş" if scan_result == "expired" else "Bilet aktif değil"
            state = "expired" if scan_result == "expired" else "inactive"
            cur.execute(
                """
                INSERT INTO mobile_ticket_scan_logs (ticket_id, submission_id, scanner_account_id, scan_result, scan_at)
                VALUES (%s, %s, %s, %s, %s)
                """,
                (ticket_id, int(submission_id), int(scanner_id), scan_result, _iso_now()),
            )
            conn.commit()
            return {"ok": False, "ticket_id": ticket_id, "state": state, "message": message}

        accepted_at = _iso_now()
        cur.execute(
            """
            UPDATE mobile_tickets
            SET used_at=%s, used_by_account_id=%s
            WHERE id=%s AND used_at IS NULL
            RETURNING id
            """,
            (accepted_at, int(scanner_id), ticket_id),
        )
        up = cur.fetchone()
        if up:
            profile_school = _fetch_profile_school_snapshot(conn, int(row["account_id"]))
            school_name = str(decoded_qr.get("school_name") or "").strip() or str(profile_school.get("school_name") or "").strip()
            school_key = _normalize_school_key(school_name)
            origin_submission_id = _repeat_thread_origin_id(conn, submission_id)
            cur.execute(
                """
                INSERT INTO mobile_ticket_scan_logs
                    (ticket_id, submission_id, scanner_account_id, buyer_account_id, ticket_type, source_profile_school_name, source_profile_school_key, entry_origin_submission_id, scan_result, scan_at)
                VALUES
                    (%s, %s, %s, %s, %s, %s, %s, %s, 'accepted', %s)
                RETURNING id
                """,
                (
                    ticket_id,
                    int(submission_id),
                    int(scanner_id),
                    int(row["account_id"]),
                    (row.get("ticket_type") or "paid"),
                    school_name,
                    school_key,
                    int(origin_submission_id),
                    accepted_at,
                ),
            )
            log_row = cur.fetchone() or {}
            log_id = int(log_row.get("id") or 0)
            loyalty_info = {
                "school_name": school_name,
                "school_count": 0,
                "qualifying_visits": 0,
                "next_remaining": 0,
                "reward_ticket_id": 0,
                "reward_event_name": "",
                "reward_created": False,
                "reward_cycle": 0,
            }
            if _is_visnelik_event(row.get("event_name"), row.get("event_slug")):
                loyalty_info = _record_visnelik_loyalty_scan(
                    conn,
                    ticket_id=ticket_id,
                    submission_id=int(submission_id),
                    account_id=int(row["account_id"]),
                    ticket_type=(row.get("ticket_type") or "paid"),
                    school_name=school_name,
                )
                if log_id > 0:
                    cur.execute(
                        """
                        UPDATE mobile_ticket_scan_logs
                        SET reward_cycle=%s,
                            reward_ticket_id=%s
                        WHERE id=%s
                        """,
                        (
                            int(loyalty_info.get("reward_cycle") or 0) or None,
                            int(loyalty_info.get("reward_ticket_id") or 0) or None,
                            log_id,
                        ),
                    )

            buyer_name = display_name((row.get("buyer_name") or ""), (row.get("buyer_email") or ""), (row.get("buyer_username") or ""))
            message_parts = [f"Giriş onaylandı: {buyer_name}"]
            if str(loyalty_info.get("school_name") or "").strip():
                message_parts.append(f"Okul: {str(loyalty_info.get('school_name') or '').strip()}")
            if _is_visnelik_event(row.get("event_name"), row.get("event_slug")):
                if int(loyalty_info.get("school_count") or 0) > 0 and str(loyalty_info.get("school_name") or "").strip():
                    message_parts.append(f"Okul girişi: {int(loyalty_info.get('school_count') or 0)}")
                if int(loyalty_info.get("qualifying_visits") or 0) > 0:
                    if int(loyalty_info.get("reward_ticket_id") or 0) > 0:
                        reward_event_name = str(loyalty_info.get("reward_event_name") or "").strip()
                        if reward_event_name:
                            message_parts.append(f"5 giriş tamamlandı, ücretsiz bilet hazır: {reward_event_name}")
                        else:
                            message_parts.append("5 giriş tamamlandı, ücretsiz bilet hazır")
                    elif int(loyalty_info.get("next_remaining") or 0) > 0:
                        message_parts.append(f"Ücretsiz bilet için {int(loyalty_info.get('next_remaining') or 0)} giriş kaldı")
            conn.commit()
            return {
                "ok": True,
                "ticket_id": ticket_id,
                "state": "accepted",
                "message": " | ".join(message_parts),
                "buyer_name": buyer_name,
                "buyer_email": (row.get("buyer_email") or ""),
                "school_name": str(loyalty_info.get("school_name") or "").strip(),
                "school_count": int(loyalty_info.get("school_count") or 0),
                "loyalty_visit_count": int(loyalty_info.get("qualifying_visits") or 0),
                "reward_ticket_id": int(loyalty_info.get("reward_ticket_id") or 0),
            }

        cur.execute(
            """
            SELECT t.used_at, COALESCE(a.name,'') AS scanner_name, COALESCE(a.email,'') AS scanner_email, COALESCE(ps.username,'') AS scanner_username
            FROM mobile_tickets t
            LEFT JOIN accounts a ON a.id=t.used_by_account_id
            LEFT JOIN mobile_profile_settings ps ON ps.account_id=a.id
            WHERE t.id=%s
            LIMIT 1
            """,
            (ticket_id,),
        )
        used = cur.fetchone() or {}
        cur.execute(
            """
            INSERT INTO mobile_ticket_scan_logs (ticket_id, submission_id, scanner_account_id, scan_result, scan_at)
            VALUES (%s, %s, %s, 'already_used', %s)
            """,
            (ticket_id, int(submission_id), int(scanner_id), _iso_now()),
        )
        conn.commit()
        return {
            "ok": False,
            "ticket_id": ticket_id,
            "state": "already_used",
            "message": "Bilet daha önce kullanıldı",
            "used_at": (used.get("used_at") or ""),
            "used_by": display_name((used.get("scanner_name") or ""), (used.get("scanner_email") or ""), (used.get("scanner_username") or "")),
            "buyer_name": display_name((row.get("buyer_name") or ""), (row.get("buyer_email") or ""), (row.get("buyer_username") or "")),
            "buyer_email": (row.get("buyer_email") or ""),
        }
    finally:
        conn.close()


@router.post("/{submission_id}/attendees/{target_account_id}/friend", summary="Katılımcıya arkadaşlık isteği gönder")
def add_friend_from_event(
    submission_id: int,
    target_account_id: int,
    authorization: Optional[str] = Header(default=None),
):
    conn = db_conn()
    try:
        if not _event_exists(conn, submission_id):
            raise HTTPException(status_code=404, detail="Etkinlik bulunamadı")
        my_account_id = _require_account_id(conn, authorization)
        target_account_id = int(target_account_id)
        if target_account_id == my_account_id:
            raise HTTPException(status_code=400, detail="Kendinizi arkadaş olarak ekleyemezsiniz")

        cur = conn.cursor()
        cur.execute(
            "SELECT 1 FROM mobile_event_attendees WHERE submission_id=%s AND account_id=%s LIMIT 1",
            (int(submission_id), int(my_account_id)),
        )
        if not cur.fetchone():
            raise HTTPException(status_code=400, detail="Önce etkinliğe katılmalısınız")
        cur.execute(
            "SELECT 1 FROM mobile_event_attendees WHERE submission_id=%s AND account_id=%s LIMIT 1",
            (int(submission_id), int(target_account_id)),
        )
        if not cur.fetchone():
            raise HTTPException(status_code=404, detail="Hedef kullanıcı etkinlik katılımcısı değil")

        if _friendship_exists(conn, my_account_id, target_account_id):
            return {"ok": True, "status": "already_friends", "target_account_id": target_account_id}

        cur.execute(
            """
            SELECT id
            FROM mobile_friend_requests
            WHERE requester_id=%s AND target_id=%s AND status='pending'
            LIMIT 1
            """,
            (int(my_account_id), int(target_account_id)),
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
            (int(target_account_id), int(my_account_id)),
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
            VALUES (%s, %s, 'pending', %s)
            RETURNING id
            """,
            (int(my_account_id), int(target_account_id), _iso_now()),
        )
        req_id = int(cur.fetchone()["id"])
        try:
            from app.routers import profile as profile_router

            profile_router._notify_friend_request(
                conn,
                requester_id=int(my_account_id),
                target_account_id=int(target_account_id),
                request_id=int(req_id),
            )
        except Exception as exc:
            logger.warning(
                "event_friend_request_notify_failed requester=%s target=%s request_id=%s err=%s",
                int(my_account_id),
                int(target_account_id),
                int(req_id),
                str(exc),
            )
        conn.commit()
        return {"ok": True, "status": "pending_outgoing", "request_id": req_id, "target_account_id": target_account_id}
    finally:
        conn.close()
