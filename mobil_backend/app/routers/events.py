import os
import uuid
from datetime import datetime
from decimal import Decimal, InvalidOperation
from typing import Any, Dict, List, Optional

import psycopg2
import psycopg2.extras
from fastapi import APIRouter, File, Form, Header, HTTPException, UploadFile
from fastapi.responses import FileResponse

router = APIRouter(prefix="/events", tags=["Etkinlikler"])
admin_router = APIRouter(prefix="/admin/events", tags=["Admin Etkinlikler"])

DATABASE_URL = os.getenv("DATABASE_URL", "").strip()
ADMIN_TOKEN = os.getenv("MOBILE_ADMIN_TOKEN", "").strip()
ROOT_DIR = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
UPLOAD_DIR = os.path.join(ROOT_DIR, "media", "submission_covers")
ALT_UPLOAD_DIR = "/home/ubuntu/etkinlik_fotograf_projesi/media/submission_covers"
PUBLIC_API_BASE = os.getenv("PUBLIC_API_BASE", "https://api2.dansmagazin.net").rstrip("/")


def _db_conn():
    if not DATABASE_URL:
        raise RuntimeError("DATABASE_URL missing")
    return psycopg2.connect(DATABASE_URL, cursor_factory=psycopg2.extras.RealDictCursor)


def init_event_submission_tables():
    conn = _db_conn()
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
            city TEXT,
            event_kind TEXT,
            ticket_sales_enabled BOOLEAN NOT NULL DEFAULT TRUE,
            organizer_name TEXT,
            program_text TEXT,
            cover_path TEXT,
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
                WHERE table_name='mobile_event_submissions' AND column_name='event_kind'
            ) THEN
                ALTER TABLE mobile_event_submissions ADD COLUMN event_kind TEXT;
            END IF;
            IF NOT EXISTS (
                SELECT 1 FROM information_schema.columns
                WHERE table_name='mobile_event_submissions' AND column_name='ticket_sales_enabled'
            ) THEN
                ALTER TABLE mobile_event_submissions ADD COLUMN ticket_sales_enabled BOOLEAN NOT NULL DEFAULT TRUE;
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
        END$$;
        """
    )
    conn.commit()
    conn.close()
    os.makedirs(UPLOAD_DIR, exist_ok=True)
    os.makedirs(ALT_UPLOAD_DIR, exist_ok=True)


def _require_admin(x_admin_token: Optional[str]):
    if not ADMIN_TOKEN:
        raise HTTPException(status_code=503, detail="Admin token tanımlı değil")
    if not x_admin_token or x_admin_token.strip() != ADMIN_TOKEN:
        raise HTTPException(status_code=401, detail="Yetkisiz")


def _iso_now() -> str:
    return datetime.utcnow().isoformat(timespec="seconds") + "Z"


def _cover_url(path: str) -> str:
    if not path:
        return ""
    return f"{PUBLIC_API_BASE}/events/submission-cover/{os.path.basename(path)}"


def _cover_exists(path: str) -> bool:
    if not path:
        return False
    bn = os.path.basename(path)
    return os.path.exists(os.path.join(UPLOAD_DIR, bn)) or os.path.exists(os.path.join(ALT_UPLOAD_DIR, bn))


def _save_cover(upload: UploadFile) -> str:
    filename = f"{uuid.uuid4().hex}.jpg"
    # Kalıcı dizin olarak ana proje altını kullan; deploy sırasında silinmez.
    abs_path = os.path.join(ALT_UPLOAD_DIR, filename)
    raw = upload.file.read()
    if len(raw) > 8 * 1024 * 1024:
        raise HTTPException(status_code=400, detail="Görsel çok büyük (max 8MB)")
    with open(abs_path, "wb") as f:
        f.write(raw)
    return abs_path


@router.get("", summary="Onaylanmış etkinlik listesi")
def list_events(limit: int = 50, city: str = "", event_kind: str = ""):
    conn = _db_conn()
    cur = conn.cursor()
    wheres = ["mes.status='approved'", "COALESCE(se.is_active, 1)=1"]
    vals: List[Any] = []
    city_q = (city or "").strip().lower()
    kind_q = (event_kind or "").strip().lower()
    if city_q:
        wheres.append("LOWER(COALESCE(mes.city,''))=%s")
        vals.append(city_q)
    if kind_q and kind_q != "all":
        wheres.append("LOWER(COALESCE(mes.event_kind,''))=%s")
        vals.append(kind_q)
    cur.execute(
        f"""
        SELECT
            mes.id,
            mes.event_name,
            mes.description,
            mes.event_date,
            mes.venue,
            COALESCE(mes.city,'') AS city,
            COALESCE(mes.event_kind,'') AS event_kind,
            COALESCE(mes.ticket_sales_enabled, TRUE) AS ticket_sales_enabled,
            mes.organizer_name,
            mes.program_text,
            mes.cover_path,
            mes.start_at,
            mes.end_at,
            mes.entry_fee,
            mes.created_at,
            mes.approved_at,
            mes.approved_event_slug,
            COALESCE(se.ticket_url, '') AS ticket_url,
            COALESCE(se.external_event_id, '') AS woo_product_id
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
        cover_path = (r["cover_path"] or "").strip()
        cover_url = ""
        if cover_path and _cover_exists(cover_path):
            cover_url = _cover_url(cover_path)
        items.append(
            {
                "id": r["id"],
                "name": r["event_name"],
                "description": r["description"] or "",
                "event_date": r["event_date"] or r["start_at"] or "",
                "venue": r["venue"] or "",
                "city": r.get("city") or "",
                "event_kind": r.get("event_kind") or "",
                "ticket_sales_enabled": bool(r.get("ticket_sales_enabled") if r.get("ticket_sales_enabled") is not None else True),
                "organizer_name": r["organizer_name"] or "",
                "program_text": r["program_text"] or "",
                "cover": cover_url,
                "start_at": r["start_at"] or "",
                "end_at": r["end_at"] or "",
                "entry_fee": float(r["entry_fee"]) if r["entry_fee"] is not None else 0.0,
                "ticket_url": r["ticket_url"] or "",
                "woo_product_id": r["woo_product_id"] or "",
                "slug": r["approved_event_slug"] or "",
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
    city: str = Form(""),
    event_kind: str = Form("dance_night"),
    ticket_sales_enabled: str = Form("1"),
    organizer_name: str = Form(""),
    program_text: str = Form(""),
    start_at: str = Form(""),
    end_at: str = Form(""),
    entry_fee: str = Form("0"),
    cover_image: Optional[UploadFile] = File(None),
):
    if len(event_name.strip()) < 2:
        raise HTTPException(status_code=400, detail="Etkinlik adı çok kısa")
    city_val = city.strip()
    if not city_val:
        raise HTTPException(status_code=400, detail="Şehir zorunlu")
    kind_val = (event_kind or "").strip().lower() or "dance_night"
    if kind_val not in {"dance_night", "festival", "competition"}:
        raise HTTPException(status_code=400, detail="Geçersiz etkinlik türü")
    ticket_sales_val = (ticket_sales_enabled or "").strip().lower() in {
        "1",
        "true",
        "yes",
        "on",
    }
    try:
        fee_val = Decimal(entry_fee or "0")
    except InvalidOperation:
        raise HTTPException(status_code=400, detail="Geçersiz giriş ücreti")
    cover_path = ""
    if cover_image and getattr(cover_image, "filename", ""):
        cover_path = _save_cover(cover_image)
    conn = _db_conn()
    cur = conn.cursor()
    cur.execute(
        """
        INSERT INTO mobile_event_submissions
        (
            submitter_name, submitter_email, event_name, description, event_date,
            venue, city, event_kind, ticket_sales_enabled,
            organizer_name, program_text, cover_path, start_at, end_at, entry_fee,
            status, created_at
        )
        VALUES (%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,'pending',%s)
        RETURNING id
        """,
        (
            (submitter_name.strip() or "mobile-user"),
            (submitter_email.strip().lower() or "mobile-user@dansmagazin.net"),
            event_name.strip(),
            description.strip(),
            event_date.strip(),
            venue.strip(),
            city_val,
            kind_val,
            ticket_sales_val,
            organizer_name.strip(),
            program_text.strip(),
            cover_path,
            (start_at.strip() or event_date.strip()),
            (end_at.strip() or event_date.strip()),
            fee_val,
            _iso_now(),
        ),
    )
    row = cur.fetchone()
    conn.commit()
    conn.close()
    return {"ok": True, "submission_id": int(row["id"])}


@admin_router.get("/submissions", summary="Admin: etkinlik talepleri")
def admin_list_submissions(
    status: str = "pending",
    x_admin_token: Optional[str] = Header(default=None),
):
    _require_admin(x_admin_token)
    status = (status or "pending").strip().lower()
    if status not in {"pending", "approved", "rejected", "all"}:
        status = "pending"
    conn = _db_conn()
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
        item["cover_url"] = _cover_url(item.get("cover_path") or "")
        out.append(item)
    return {"items": out}


@admin_router.post("/submissions/{submission_id}/approve", summary="Admin: talebi onayla")
def admin_approve_submission(
    submission_id: int,
    admin_note: str = Form(""),
    x_admin_token: Optional[str] = Header(default=None),
):
    _require_admin(x_admin_token)
    conn = _db_conn()
    cur = conn.cursor()
    cur.execute(
        """
        UPDATE mobile_event_submissions
        SET status='approved', approved_at=%s, admin_note=%s
        WHERE id=%s
        """,
        (_iso_now(), admin_note[:500], int(submission_id)),
    )
    conn.commit()
    conn.close()
    return {"ok": True}


@admin_router.post("/submissions/{submission_id}/reject", summary="Admin: talebi reddet")
def admin_reject_submission(
    submission_id: int,
    admin_note: str = Form(""),
    x_admin_token: Optional[str] = Header(default=None),
):
    _require_admin(x_admin_token)
    conn = _db_conn()
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
