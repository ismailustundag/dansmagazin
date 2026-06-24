import os
import re
import uuid
from datetime import datetime
from typing import Any, Dict, List, Optional

import httpx
import psycopg2
import psycopg2.extras
from fastapi import APIRouter, File, Form, Header, HTTPException, UploadFile
from fastapi.responses import FileResponse

router = APIRouter(prefix="/news", tags=["Haberler"])
admin_router = APIRouter(prefix="/admin/news", tags=["Admin Haberler"])

DATABASE_URL = os.getenv("DATABASE_URL", "").strip()
ADMIN_TOKEN = os.getenv("MOBILE_ADMIN_TOKEN", "").strip()
ROOT_DIR = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
UPLOAD_DIR = os.path.join(ROOT_DIR, "media", "news_submission_covers")
ALT_UPLOAD_DIR = "/home/ubuntu/etkinlik_fotograf_projesi/media/news_submission_covers"
PUBLIC_API_BASE = os.getenv("PUBLIC_API_BASE", "https://api2.dansmagazin.net").rstrip("/")
WP_BASE_URL = os.getenv("WP_BASE_URL", "https://www.dansmagazin.net").rstrip("/")
WP_JWT_TOKEN_URL = os.getenv("WP_JWT_TOKEN_URL", f"{WP_BASE_URL}/wp-json/jwt-auth/v1/token").strip()
WP_POST_SYNC_USERNAME = (
    os.getenv("WP_POST_SYNC_USERNAME", "").strip()
    or os.getenv("WP_SYNC_ADMIN_USERNAME", "").strip()
)
WP_POST_SYNC_PASSWORD = (
    os.getenv("WP_POST_SYNC_PASSWORD", "").strip()
    or os.getenv("WP_SYNC_ADMIN_PASSWORD", "").strip()
)


def _db_conn():
    if not DATABASE_URL:
        raise RuntimeError("DATABASE_URL missing")
    return psycopg2.connect(DATABASE_URL, cursor_factory=psycopg2.extras.RealDictCursor)


def _iso_now() -> str:
    return datetime.utcnow().isoformat(timespec="seconds") + "Z"


def init_news_submission_tables():
    conn = _db_conn()
    cur = conn.cursor()
    cur.execute(
        """
        CREATE TABLE IF NOT EXISTS mobile_news_submissions (
            id SERIAL PRIMARY KEY,
            submitter_account_id INTEGER NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
            submitter_name TEXT,
            submitter_email TEXT,
            title TEXT NOT NULL,
            body_text TEXT,
            source_link TEXT,
            cover_path TEXT,
            status TEXT NOT NULL DEFAULT 'pending',
            admin_note TEXT,
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL,
            approved_at TEXT,
            wp_post_id BIGINT,
            wp_post_url TEXT
        )
        """
    )
    cur.execute(
        "CREATE INDEX IF NOT EXISTS idx_mobile_news_status_created ON mobile_news_submissions(status, created_at DESC)"
    )
    cur.execute(
        "CREATE INDEX IF NOT EXISTS idx_mobile_news_submitter_created ON mobile_news_submissions(submitter_account_id, created_at DESC)"
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


def _require_bearer(authorization: Optional[str]) -> str:
    if not authorization or not authorization.lower().startswith("bearer "):
        raise HTTPException(status_code=401, detail="Bearer token gerekli")
    token = authorization.split(" ", 1)[1].strip()
    if not token:
        raise HTTPException(status_code=401, detail="Token boş")
    return token


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
            COALESCE(a.can_create_mobile_event,0) AS can_create_mobile_event,
            COALESCE(ps.username,'') AS profile_username
        FROM sessions s
        JOIN accounts a ON a.id=s.account_id
        LEFT JOIN mobile_profile_settings ps ON ps.account_id=a.id
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
        raise HTTPException(status_code=403, detail="Haber oluşturma yetkisi yok (editor gerekli)")
    display_name = (row.get("profile_username") or "").strip() or (row.get("name") or "").strip()
    if not display_name:
        email = (row.get("email") or "").strip().lower()
        display_name = email.split("@", 1)[0] if "@" in email else "editor"
    return {
        "account_id": int(row["account_id"]),
        "name": display_name,
        "email": (row.get("email") or "").strip().lower(),
        "role": role,
    }


def _require_super_admin_account(conn, authorization: Optional[str]) -> Dict[str, Any]:
    actor = _require_editor_account(conn, authorization)
    if (actor.get("role") or "").strip().lower() != "super_admin":
        raise HTTPException(status_code=403, detail="Sadece super admin onaylayabilir")
    return actor


def _cover_url(path: str) -> str:
    if not path:
        return ""
    return f"{PUBLIC_API_BASE}/news/submission-cover/{os.path.basename(path)}"


def _cover_exists(path: str) -> bool:
    if not path:
        return False
    bn = os.path.basename(path)
    return os.path.exists(os.path.join(UPLOAD_DIR, bn)) or os.path.exists(os.path.join(ALT_UPLOAD_DIR, bn))


def _delete_cover_file(path: str):
    bn = os.path.basename((path or "").strip())
    if not bn:
        return
    for root in (UPLOAD_DIR, ALT_UPLOAD_DIR):
        p = os.path.join(root, bn)
        if os.path.exists(p):
            try:
                os.remove(p)
            except Exception:
                pass


def _save_cover(upload: UploadFile) -> str:
    filename = f"{uuid.uuid4().hex}.jpg"
    abs_path = os.path.join(ALT_UPLOAD_DIR, filename)
    raw = upload.file.read()
    if len(raw) > 8 * 1024 * 1024:
        raise HTTPException(status_code=400, detail="Görsel çok büyük (max 8MB)")
    with open(abs_path, "wb") as f:
        f.write(raw)
    return abs_path


def _normalize_link(raw: str) -> str:
    v = (raw or "").strip()
    if not v:
        return ""
    if v.startswith("www."):
        v = f"https://{v}"
    if not (v.startswith("http://") or v.startswith("https://")):
        return ""
    return v


def _linkify_plain_text(text: str) -> str:
    src = (text or "").strip()
    if not src:
        return ""
    escaped = (
        src.replace("&", "&amp;")
        .replace("<", "&lt;")
        .replace(">", "&gt;")
    )

    def repl(match: re.Match[str]) -> str:
        url = match.group(0)
        return f'<a href="{url}" target="_blank" rel="noopener noreferrer">{url}</a>'

    escaped = re.sub(r"https?://[^\s<]+", repl, escaped)
    return escaped.replace("\r\n", "\n").replace("\r", "\n").replace("\n", "<br/>")


def _wp_login_token() -> str:
    if not WP_POST_SYNC_USERNAME or not WP_POST_SYNC_PASSWORD:
        raise HTTPException(
            status_code=503,
            detail="WP haber yayınlama ayarı eksik (WP_POST_SYNC_USERNAME/PASSWORD)",
        )
    payload = {
        "username": WP_POST_SYNC_USERNAME,
        "password": WP_POST_SYNC_PASSWORD,
    }
    try:
        resp = httpx.post(
            WP_JWT_TOKEN_URL,
            data=payload,
            headers={"Content-Type": "application/x-www-form-urlencoded"},
            timeout=20.0,
        )
    except Exception as e:
        raise HTTPException(status_code=502, detail=f"WP token isteği başarısız: {e}")
    if resp.status_code != 200:
        raise HTTPException(status_code=502, detail=f"WP token alınamadı ({resp.status_code})")
    data = resp.json() if resp.content else {}
    token = (data.get("token") or "").strip() if isinstance(data, dict) else ""
    if not token:
        raise HTTPException(status_code=502, detail="WP token cevabı geçersiz")
    return token


def _resolve_wp_author_id(conn, account_id: int) -> Optional[int]:
    cur = conn.cursor()
    cur.execute(
        """
        SELECT wp_user_id
        FROM identity_map
        WHERE app_account_id=%s AND is_active=TRUE
        LIMIT 1
        """,
        (int(account_id),),
    )
    row = cur.fetchone() or {}
    wp_uid = row.get("wp_user_id")
    try:
        return int(wp_uid) if wp_uid is not None else None
    except Exception:
        return None


def _wp_upload_media(token: str, *, file_path: str, title: str) -> Optional[int]:
    if not file_path:
        return None
    bn = os.path.basename(file_path)
    path = os.path.join(ALT_UPLOAD_DIR, bn)
    if not os.path.exists(path):
        path = os.path.join(UPLOAD_DIR, bn)
    if not os.path.exists(path):
        return None
    with open(path, "rb") as f:
        raw = f.read()
    headers = {
        "Authorization": f"Bearer {token}",
        "Content-Disposition": f'attachment; filename="{bn}"',
        "Content-Type": "image/jpeg",
    }
    try:
        resp = httpx.post(
            f"{WP_BASE_URL}/wp-json/wp/v2/media",
            headers=headers,
            content=raw,
            timeout=30.0,
        )
    except Exception as e:
        raise HTTPException(status_code=502, detail=f"WP medya yükleme hatası: {e}")
    if resp.status_code not in {200, 201}:
        raise HTTPException(status_code=502, detail=f"WP medya yüklenemedi ({resp.status_code})")
    data = resp.json() if resp.content else {}
    media_id = int(data.get("id") or 0) if isinstance(data, dict) else 0
    if media_id <= 0:
        return None
    # Başlığı güncelleme best-effort
    try:
        httpx.post(
            f"{WP_BASE_URL}/wp-json/wp/v2/media/{media_id}",
            headers={"Authorization": f"Bearer {token}"},
            json={"title": title[:180]},
            timeout=15.0,
        )
    except Exception:
        pass
    return media_id


def _wp_publish_post(
    conn,
    *,
    title: str,
    body_text: str,
    source_link: str,
    submitter_name: str,
    submitter_account_id: int,
    cover_path: str,
) -> Dict[str, Any]:
    token = _wp_login_token()
    author_id = _resolve_wp_author_id(conn, submitter_account_id)
    parts: List[str] = []
    if submitter_name:
        parts.append(f"<p><strong>Yazar:</strong> {submitter_name}</p>")
    content_html = _linkify_plain_text(body_text)
    if content_html:
        parts.append(f"<p>{content_html}</p>")
    src = _normalize_link(source_link)
    if src:
        parts.append(
            f'<p><a href="{src}" target="_blank" rel="noopener noreferrer">Kaynak bağlantısı</a></p>'
        )
    final_content = "\n".join(parts).strip() or "<p></p>"
    media_id = _wp_upload_media(token, file_path=cover_path, title=title)

    payload: Dict[str, Any] = {
        "title": title.strip(),
        "content": final_content,
        "status": "publish",
    }
    if author_id:
        payload["author"] = int(author_id)
    if media_id:
        payload["featured_media"] = int(media_id)

    try:
        resp = httpx.post(
            f"{WP_BASE_URL}/wp-json/wp/v2/posts",
            headers={"Authorization": f"Bearer {token}"},
            json=payload,
            timeout=30.0,
        )
    except Exception as e:
        raise HTTPException(status_code=502, detail=f"WP haber yayınlama hatası: {e}")
    if resp.status_code not in {200, 201}:
        raise HTTPException(status_code=502, detail=f"WP haber yayınlanamadı ({resp.status_code})")
    data = resp.json() if resp.content else {}
    post_id = int(data.get("id") or 0) if isinstance(data, dict) else 0
    link = (data.get("link") or "").strip() if isinstance(data, dict) else ""
    if post_id <= 0:
        raise HTTPException(status_code=502, detail="WP haber cevabı geçersiz")
    return {"post_id": post_id, "link": link}


def _wp_existing_post_ids(post_ids: List[int]) -> set[int]:
    ids = sorted({int(x) for x in post_ids if int(x) > 0})
    if not ids:
        return set()
    out: set[int] = set()
    # İstek başarısız olursa yanlışlıkla veri silmemek için "hepsi var" kabul ediyoruz.
    fallback_all = set(ids)
    try:
        with httpx.Client(timeout=15.0) as client:
            for i in range(0, len(ids), 100):
                chunk = ids[i : i + 100]
                resp = client.get(
                    f"{WP_BASE_URL}/wp-json/wp/v2/posts",
                    params={
                        "include": ",".join(str(x) for x in chunk),
                        "per_page": len(chunk),
                        "_fields": "id,status",
                        "status": "publish",
                    },
                )
                if resp.status_code != 200:
                    return fallback_all
                arr = resp.json() if resp.content else []
                if not isinstance(arr, list):
                    return fallback_all
                for row in arr:
                    try:
                        out.add(int((row or {}).get("id") or 0))
                    except Exception:
                        continue
    except Exception:
        return fallback_all
    return out


def _wp_delete_post(post_id: int):
    pid = int(post_id or 0)
    if pid <= 0:
        return {"ok": True, "already_missing": True}
    token = _wp_login_token()
    try:
        resp = httpx.delete(
            f"{WP_BASE_URL}/wp-json/wp/v2/posts/{pid}",
            headers={"Authorization": f"Bearer {token}"},
            params={"force": "true"},
            timeout=20.0,
        )
    except Exception as e:
        raise HTTPException(status_code=502, detail=f"WP haber silme hatası: {e}")
    if resp.status_code in {200, 404, 410}:
        return {"ok": True, "already_missing": resp.status_code in {404, 410}}
    raise HTTPException(status_code=502, detail=f"WP haber silinemedi ({resp.status_code})")


def _prune_missing_wp_posts(conn) -> int:
    cur = conn.cursor()
    cur.execute(
        """
        SELECT id, COALESCE(wp_post_id,0) AS wp_post_id, COALESCE(cover_path,'') AS cover_path
        FROM mobile_news_submissions
        WHERE status='approved' AND COALESCE(wp_post_id,0) > 0
        """
    )
    rows = cur.fetchall() or []
    wp_ids = [int(r.get("wp_post_id") or 0) for r in rows if int(r.get("wp_post_id") or 0) > 0]
    existing_wp_ids = _wp_existing_post_ids(wp_ids)
    removed = 0
    for row in rows:
        sid = int(row.get("id") or 0)
        wp_post_id = int(row.get("wp_post_id") or 0)
        if sid <= 0 or wp_post_id <= 0 or wp_post_id in existing_wp_ids:
            continue
        cur.execute("DELETE FROM mobile_news_submissions WHERE id=%s", (sid,))
        _delete_cover_file((row.get("cover_path") or "").strip())
        removed += 1
    if removed > 0:
        conn.commit()
        _invalidate_discover_cache()
    return removed


def _invalidate_discover_cache():
    try:
        from app.routers import discover as discover_router

        discover_router._NEWS_CACHE.clear()
        discover_router._DISCOVER_HOME_CACHE["ts"] = 0.0
        discover_router._DISCOVER_HOME_CACHE["items"] = {}
    except Exception:
        pass


@router.post("/submissions", summary="Yeni haber talebi oluştur")
async def create_news_submission(
    title: str = Form(...),
    body_text: str = Form(...),
    source_link: str = Form(""),
    cover_image: Optional[UploadFile] = File(None),
    authorization: Optional[str] = Header(default=None),
):
    if len(title.strip()) < 3:
        raise HTTPException(status_code=400, detail="Haber başlığı çok kısa")
    if len(body_text.strip()) < 10:
        raise HTTPException(status_code=400, detail="Haber metni çok kısa")
    source_link_val = _normalize_link(source_link)
    cover_path = ""
    if cover_image and getattr(cover_image, "filename", ""):
        cover_path = _save_cover(cover_image)

    conn = _db_conn()
    try:
        actor = _require_editor_account(conn, authorization)
        now = _iso_now()
        cur = conn.cursor()
        cur.execute(
            """
            INSERT INTO mobile_news_submissions
            (
                submitter_account_id, submitter_name, submitter_email,
                title, body_text, source_link, cover_path,
                status, admin_note, created_at, updated_at
            )
            VALUES (%s,%s,%s,%s,%s,%s,%s,'pending','',%s,%s)
            RETURNING id
            """,
            (
                int(actor["account_id"]),
                (actor.get("name") or "").strip(),
                (actor.get("email") or "").strip().lower(),
                title.strip(),
                body_text.strip(),
                source_link_val,
                cover_path,
                now,
                now,
            ),
        )
        row = cur.fetchone() or {}
        conn.commit()
        return {"ok": True, "submission_id": int(row.get("id") or 0)}
    finally:
        conn.close()


@router.get("/manage/items", summary="Editör/Super admin: haber talepleri")
def list_manage_news_items(
    authorization: Optional[str] = Header(default=None),
):
    conn = _db_conn()
    try:
        actor = _require_editor_account(conn, authorization)
        _prune_missing_wp_posts(conn)
        role = (actor.get("role") or "").strip().lower()
        account_id = int(actor["account_id"])
        cur = conn.cursor()
        if role == "super_admin":
            cur.execute(
                """
                SELECT *
                FROM mobile_news_submissions
                ORDER BY created_at DESC
                LIMIT 300
                """
            )
        else:
            cur.execute(
                """
                SELECT *
                FROM mobile_news_submissions
                WHERE submitter_account_id=%s
                ORDER BY created_at DESC
                LIMIT 300
                """,
                (account_id,),
            )
        rows = cur.fetchall() or []
        items: List[Dict[str, Any]] = []
        for r in rows:
            cp = (r.get("cover_path") or "").strip()
            cover = cp if (cp.startswith("http://") or cp.startswith("https://")) else (
                _cover_url(cp) if cp and _cover_exists(cp) else ""
            )
            items.append(
                {
                    "submission_id": int(r["id"]),
                    "submitter_account_id": int(r.get("submitter_account_id") or 0),
                    "submitter_name": (r.get("submitter_name") or "").strip(),
                    "submitter_email": (r.get("submitter_email") or "").strip(),
                    "title": (r.get("title") or "").strip(),
                    "body_text": (r.get("body_text") or "").strip(),
                    "source_link": (r.get("source_link") or "").strip(),
                    "cover_url": cover,
                    "status": (r.get("status") or "").strip(),
                    "admin_note": (r.get("admin_note") or "").strip(),
                    "created_at": (r.get("created_at") or "").strip(),
                    "updated_at": (r.get("updated_at") or "").strip(),
                    "approved_at": (r.get("approved_at") or "").strip(),
                    "wp_post_id": int(r.get("wp_post_id") or 0),
                    "wp_post_url": (r.get("wp_post_url") or "").strip(),
                }
            )
        return {"is_super_admin": role == "super_admin", "items": items}
    finally:
        conn.close()


@router.post("/manage/items/{submission_id}/update", summary="Editör: haber güncelle")
async def update_manage_news_item(
    submission_id: int,
    title: Optional[str] = Form(default=None),
    body_text: Optional[str] = Form(default=None),
    source_link: Optional[str] = Form(default=None),
    cover_image: Optional[UploadFile] = File(None),
    authorization: Optional[str] = Header(default=None),
):
    conn = _db_conn()
    try:
        actor = _require_editor_account(conn, authorization)
        role = (actor.get("role") or "").strip().lower()
        account_id = int(actor["account_id"])
        cur = conn.cursor()
        cur.execute(
            """
            SELECT id, submitter_account_id, status
            FROM mobile_news_submissions
            WHERE id=%s
            LIMIT 1
            """,
            (int(submission_id),),
        )
        row = cur.fetchone()
        if not row:
            raise HTTPException(status_code=404, detail="Haber bulunamadı")
        owner_id = int(row.get("submitter_account_id") or 0)
        if role != "super_admin" and owner_id != account_id:
            raise HTTPException(status_code=403, detail="Bu haberi düzenleme yetkiniz yok")

        fields_sql: List[str] = []
        vals: List[Any] = []
        if title is not None:
            if len(title.strip()) < 3:
                raise HTTPException(status_code=400, detail="Haber başlığı çok kısa")
            fields_sql.append("title=%s")
            vals.append(title.strip())
        if body_text is not None:
            if len(body_text.strip()) < 10:
                raise HTTPException(status_code=400, detail="Haber metni çok kısa")
            fields_sql.append("body_text=%s")
            vals.append(body_text.strip())
        if source_link is not None:
            fields_sql.append("source_link=%s")
            vals.append(_normalize_link(source_link))
        if cover_image and getattr(cover_image, "filename", ""):
            fields_sql.append("cover_path=%s")
            vals.append(_save_cover(cover_image))
        if not fields_sql:
            return {"ok": True, "submission_id": int(submission_id)}
        fields_sql.append("updated_at=%s")
        vals.append(_iso_now())
        vals.append(int(submission_id))
        cur.execute(
            f"UPDATE mobile_news_submissions SET {', '.join(fields_sql)} WHERE id=%s",
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


@router.post("/manage/items/{submission_id}/approve", summary="Super admin: haberi onayla ve WP'de yayınla")
def approve_manage_news_item(
    submission_id: int,
    admin_note: str = Form(""),
    authorization: Optional[str] = Header(default=None),
):
    conn = _db_conn()
    try:
        _require_super_admin_account(conn, authorization)
        cur = conn.cursor()
        cur.execute(
            """
            SELECT *
            FROM mobile_news_submissions
            WHERE id=%s
            FOR UPDATE
            LIMIT 1
            """,
            (int(submission_id),),
        )
        row = cur.fetchone()
        if not row:
            raise HTTPException(status_code=404, detail="Haber bulunamadı")
        if (row.get("status") or "").strip().lower() == "approved" and int(row.get("wp_post_id") or 0) > 0:
            return {
                "ok": True,
                "submission_id": int(submission_id),
                "wp_post_id": int(row.get("wp_post_id") or 0),
                "wp_post_url": (row.get("wp_post_url") or "").strip(),
            }

        pub = _wp_publish_post(
            conn,
            title=(row.get("title") or "").strip(),
            body_text=(row.get("body_text") or "").strip(),
            source_link=(row.get("source_link") or "").strip(),
            submitter_name=(row.get("submitter_name") or "").strip(),
            submitter_account_id=int(row.get("submitter_account_id") or 0),
            cover_path=(row.get("cover_path") or "").strip(),
        )
        now = _iso_now()
        cur.execute(
            """
            UPDATE mobile_news_submissions
            SET status='approved',
                approved_at=%s,
                admin_note=%s,
                updated_at=%s,
                wp_post_id=%s,
                wp_post_url=%s
            WHERE id=%s
            """,
            (
                now,
                (admin_note or "").strip()[:500],
                now,
                int(pub.get("post_id") or 0),
                (pub.get("link") or "").strip(),
                int(submission_id),
            ),
        )
        conn.commit()
        _invalidate_discover_cache()
        return {
            "ok": True,
            "submission_id": int(submission_id),
            "wp_post_id": int(pub.get("post_id") or 0),
            "wp_post_url": (pub.get("link") or "").strip(),
        }
    except HTTPException:
        conn.rollback()
        raise
    except Exception as e:
        conn.rollback()
        raise HTTPException(status_code=500, detail=f"Onaylama hatası: {e}")
    finally:
        conn.close()


@router.post("/manage/items/{submission_id}/reject", summary="Super admin: haberi reddet")
def reject_manage_news_item(
    submission_id: int,
    admin_note: str = Form(""),
    authorization: Optional[str] = Header(default=None),
):
    conn = _db_conn()
    try:
        _require_super_admin_account(conn, authorization)
        cur = conn.cursor()
        cur.execute(
            """
            UPDATE mobile_news_submissions
            SET status='rejected',
                admin_note=%s,
                updated_at=%s
            WHERE id=%s
            """,
            (
                (admin_note or "").strip()[:500],
                _iso_now(),
                int(submission_id),
            ),
        )
        conn.commit()
        return {"ok": True, "submission_id": int(submission_id)}
    except HTTPException:
        conn.rollback()
        raise
    finally:
        conn.close()


@router.post("/manage/items/{submission_id}/delete", summary="Editör/Super admin: haberi sil")
def delete_manage_news_item(
    submission_id: int,
    authorization: Optional[str] = Header(default=None),
):
    conn = _db_conn()
    try:
        actor = _require_editor_account(conn, authorization)
        role = (actor.get("role") or "").strip().lower()
        account_id = int(actor["account_id"])
        cur = conn.cursor()
        cur.execute(
            """
            SELECT id, submitter_account_id, COALESCE(wp_post_id,0) AS wp_post_id, COALESCE(cover_path,'') AS cover_path
            FROM mobile_news_submissions
            WHERE id=%s
            LIMIT 1
            """,
            (int(submission_id),),
        )
        row = cur.fetchone()
        if not row:
            raise HTTPException(status_code=404, detail="Haber bulunamadı")
        owner_id = int(row.get("submitter_account_id") or 0)
        if role != "super_admin" and owner_id != account_id:
            raise HTTPException(status_code=403, detail="Bu haberi silme yetkiniz yok")

        wp_post_id = int(row.get("wp_post_id") or 0)
        if wp_post_id > 0:
            _wp_delete_post(wp_post_id)
        cur.execute("DELETE FROM mobile_news_submissions WHERE id=%s", (int(submission_id),))
        conn.commit()
        _invalidate_discover_cache()
        _delete_cover_file((row.get("cover_path") or "").strip())
        return {"ok": True, "submission_id": int(submission_id), "wp_deleted": wp_post_id > 0}
    except HTTPException:
        conn.rollback()
        raise
    finally:
        conn.close()


@admin_router.get("/submissions", summary="Panel admin: haber talepleri")
def admin_list_news_submissions(
    status: str = "pending",
    x_admin_token: Optional[str] = Header(default=None),
):
    _require_admin(x_admin_token)
    status_val = (status or "pending").strip().lower()
    if status_val not in {"pending", "approved", "rejected", "all"}:
        status_val = "pending"
    conn = _db_conn()
    try:
        _prune_missing_wp_posts(conn)
        cur = conn.cursor()
        if status_val == "all":
            cur.execute(
                """
                SELECT *
                FROM mobile_news_submissions
                ORDER BY created_at DESC
                LIMIT 300
                """
            )
        else:
            cur.execute(
                """
                SELECT *
                FROM mobile_news_submissions
                WHERE status=%s
                ORDER BY created_at DESC
                LIMIT 300
                """,
                (status_val,),
            )
        rows = cur.fetchall() or []
        out: List[Dict[str, Any]] = []
        for r in rows:
            item = dict(r)
            cp = (item.get("cover_path") or "").strip()
            item["cover_url"] = cp if cp.startswith("http") else (_cover_url(cp) if cp and _cover_exists(cp) else "")
            out.append(item)
        return {"items": out}
    finally:
        conn.close()


@admin_router.post("/submissions/{submission_id}/approve", summary="Panel admin: haberi onayla")
def admin_approve_news_submission(
    submission_id: int,
    admin_note: str = Form(""),
    x_admin_token: Optional[str] = Header(default=None),
):
    _require_admin(x_admin_token)
    conn = _db_conn()
    try:
        cur = conn.cursor()
        cur.execute(
            """
            SELECT *
            FROM mobile_news_submissions
            WHERE id=%s
            FOR UPDATE
            LIMIT 1
            """,
            (int(submission_id),),
        )
        row = cur.fetchone()
        if not row:
            raise HTTPException(status_code=404, detail="Haber bulunamadı")
        if (row.get("status") or "").strip().lower() == "approved" and int(row.get("wp_post_id") or 0) > 0:
            conn.commit()
            return {
                "ok": True,
                "submission_id": int(submission_id),
                "wp_post_id": int(row.get("wp_post_id") or 0),
                "wp_post_url": (row.get("wp_post_url") or "").strip(),
            }
        pub = _wp_publish_post(
            conn,
            title=(row.get("title") or "").strip(),
            body_text=(row.get("body_text") or "").strip(),
            source_link=(row.get("source_link") or "").strip(),
            submitter_name=(row.get("submitter_name") or "").strip(),
            submitter_account_id=int(row.get("submitter_account_id") or 0),
            cover_path=(row.get("cover_path") or "").strip(),
        )
        now = _iso_now()
        cur.execute(
            """
            UPDATE mobile_news_submissions
            SET status='approved',
                approved_at=%s,
                admin_note=%s,
                updated_at=%s,
                wp_post_id=%s,
                wp_post_url=%s
            WHERE id=%s
            """,
            (
                now,
                (admin_note or "").strip()[:500],
                now,
                int(pub.get("post_id") or 0),
                (pub.get("link") or "").strip(),
                int(submission_id),
            ),
        )
        conn.commit()
        _invalidate_discover_cache()
        return {"ok": True, "submission_id": int(submission_id), "wp_post_url": (pub.get("link") or "").strip()}
    finally:
        conn.close()


@admin_router.post("/submissions/{submission_id}/reject", summary="Panel admin: haberi reddet")
def admin_reject_news_submission(
    submission_id: int,
    admin_note: str = Form(""),
    x_admin_token: Optional[str] = Header(default=None),
):
    _require_admin(x_admin_token)
    conn = _db_conn()
    try:
        cur = conn.cursor()
        cur.execute(
            """
            UPDATE mobile_news_submissions
            SET status='rejected',
                admin_note=%s,
                updated_at=%s
            WHERE id=%s
            """,
            (
                (admin_note or "").strip()[:500],
                _iso_now(),
                int(submission_id),
            ),
        )
        conn.commit()
        return {"ok": True, "submission_id": int(submission_id)}
    finally:
        conn.close()


@admin_router.post("/submissions/{submission_id}/delete", summary="Panel admin: haberi sil")
def admin_delete_news_submission(
    submission_id: int,
    x_admin_token: Optional[str] = Header(default=None),
):
    _require_admin(x_admin_token)
    conn = _db_conn()
    try:
        cur = conn.cursor()
        cur.execute(
            """
            SELECT id, COALESCE(wp_post_id,0) AS wp_post_id, COALESCE(cover_path,'') AS cover_path
            FROM mobile_news_submissions
            WHERE id=%s
            LIMIT 1
            """,
            (int(submission_id),),
        )
        row = cur.fetchone()
        if not row:
            raise HTTPException(status_code=404, detail="Haber bulunamadı")

        wp_post_id = int(row.get("wp_post_id") or 0)
        if wp_post_id > 0:
            _wp_delete_post(wp_post_id)
        cur.execute("DELETE FROM mobile_news_submissions WHERE id=%s", (int(submission_id),))
        conn.commit()
        _invalidate_discover_cache()
        _delete_cover_file((row.get("cover_path") or "").strip())
        return {"ok": True, "submission_id": int(submission_id), "wp_deleted": wp_post_id > 0}
    except HTTPException:
        conn.rollback()
        raise
    finally:
        conn.close()


@router.get("/submission-cover/{filename}", include_in_schema=False)
def get_news_submission_cover(filename: str):
    safe = os.path.basename(filename)
    p1 = os.path.join(UPLOAD_DIR, safe)
    p2 = os.path.join(ALT_UPLOAD_DIR, safe)
    if os.path.exists(p2):
        return FileResponse(p2)
    if os.path.exists(p1):
        return FileResponse(p1)
    raise HTTPException(status_code=404, detail="cover not found")
