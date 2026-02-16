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
PUBLIC_BASE = os.getenv("PUBLIC_WEB_BASE", "https://foto.dansmagazin.net").rstrip("/")


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
    conn.commit()
    conn.close()
    os.makedirs(UPLOAD_DIR, exist_ok=True)


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
    return f"{PUBLIC_BASE}/events/submission-cover/{os.path.basename(path)}"


def _save_cover(upload: UploadFile) -> str:
    filename = f"{uuid.uuid4().hex}.jpg"
    abs_path = os.path.join(UPLOAD_DIR, filename)
    raw = upload.file.read()
    if len(raw) > 8 * 1024 * 1024:
        raise HTTPException(status_code=400, detail="Görsel çok büyük (max 8MB)")
    with open(abs_path, "wb") as f:
        f.write(raw)
    return abs_path


@router.get("", summary="Onaylanmış etkinlik listesi")
def list_events(limit: int = 50):
    conn = _db_conn()
    cur = conn.cursor()
    cur.execute(
        """
        SELECT id, event_name, description, cover_path, start_at, end_at, entry_fee, created_at, approved_at
        FROM mobile_event_submissions
        WHERE status='approved'
        ORDER BY COALESCE(approved_at, created_at) DESC
        LIMIT %s
        """,
        (max(1, min(int(limit), 200)),),
    )
    rows = cur.fetchall() or []
    conn.close()
    items = []
    for r in rows:
        items.append(
            {
                "id": r["id"],
                "name": r["event_name"],
                "description": r["description"] or "",
                "cover": _cover_url(r["cover_path"] or ""),
                "start_at": r["start_at"] or "",
                "end_at": r["end_at"] or "",
                "entry_fee": float(r["entry_fee"]) if r["entry_fee"] is not None else 0.0,
            }
        )
    return {"section": "etkinlikler", "items": items}


@router.post("/submissions", summary="Yeni etkinlik talebi oluştur")
async def create_submission(
    submitter_name: str = Form(...),
    submitter_email: str = Form(...),
    event_name: str = Form(...),
    description: str = Form(""),
    start_at: str = Form(""),
    end_at: str = Form(""),
    entry_fee: str = Form("0"),
    cover_image: Optional[UploadFile] = File(None),
):
    if len(event_name.strip()) < 2:
        raise HTTPException(status_code=400, detail="Etkinlik adı çok kısa")
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
        (submitter_name, submitter_email, event_name, description, cover_path, start_at, end_at, entry_fee, status, created_at)
        VALUES (%s,%s,%s,%s,%s,%s,%s,%s,'pending',%s)
        RETURNING id
        """,
        (
            submitter_name.strip(),
            submitter_email.strip().lower(),
            event_name.strip(),
            description.strip(),
            cover_path,
            start_at.strip(),
            end_at.strip(),
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
        raise HTTPException(status_code=404, detail="Dosya bulunamadı")
    return FileResponse(abs_path)
