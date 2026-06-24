import os
import re
import uuid
from io import BytesIO
from datetime import datetime, timezone
from typing import Any, Dict, List, Optional

import psycopg2
import psycopg2.extras
from fastapi import APIRouter, File, Form, Header, HTTPException, Query, UploadFile
from pydantic import BaseModel, Field
from starlette.responses import FileResponse
from app.utils import get_db_connection, display_name, get_blocked_peer_ids

from app.routers.profile import _dispatch_push_for_accounts

router = APIRouter(prefix="/photos", tags=["Fotoğraflar"])

DATABASE_URL = os.getenv("DATABASE_URL", "").strip()
BASE_DIR = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
MEDIA_DIR = os.path.join(BASE_DIR, "media")
COMMUNITY_FEED_DIR = os.path.join(MEDIA_DIR, "community_feed")
PUBLIC_MEDIA_BASE = os.getenv("PUBLIC_MEDIA_BASE", "https://foto.dansmagazin.net").rstrip("/")
PUBLIC_WEB_BASE = os.getenv("PUBLIC_WEB_BASE", "https://foto.dansmagazin.net").rstrip("/")
PUBLIC_API_BASE = os.getenv("PUBLIC_BASE_URL", "https://api2.dansmagazin.net").rstrip("/")
BATCH_ALBUM_PREFIX = "batch"
SUBALBUM_PREFIX = "subalbum"
COMMUNITY_ALBUM_SLUG = "community-feed"
COMMUNITY_ALBUM_NAME = "Topluluk Albumu"
COMMUNITY_ALBUM_COVER_URL = f"{PUBLIC_WEB_BASE}/static/DMlogo.PNG"
COMMUNITY_PHOTO_ID_BASE = 1_000_000_000
INVISIBLE_SORT_ZERO = "\u200b"
INVISIBLE_SORT_ONE = "\u200c"
INVISIBLE_SORT_WIDTH = 64
COMMUNITY_FEED_IMAGE_MAX_SIDE = 1600
ALLOWED_FEED_IMAGE_CONTENT_TYPES = {
    "image/jpeg",
    "image/jpg",
    "image/png",
    "image/webp",
    "image/heic",
    "image/heif",
    "image/heic-sequence",
    "image/heif-sequence",
}
ALLOWED_FEED_IMAGE_EXTENSIONS = {".jpg", ".jpeg", ".png", ".webp", ".heic", ".heif"}
COMMUNITY_FEED_DAILY_POST_LIMIT = 10


db_conn = get_db_connection
_db_conn = db_conn

def init_photo_reaction_tables():
    conn = db_conn()
    if not conn:
        return
    try:
        os.makedirs(COMMUNITY_FEED_DIR, exist_ok=True)
        cur = conn.cursor()
        cur.execute(
            """
            CREATE TABLE IF NOT EXISTS photo_album_reactions (
                album_slug TEXT PRIMARY KEY,
                like_count INTEGER NOT NULL DEFAULT 0,
                updated_at TIMESTAMP WITHOUT TIME ZONE DEFAULT NOW()
            )
            """
        )
        cur.execute(
            """
            CREATE TABLE IF NOT EXISTS photo_album_user_likes (
                account_id INTEGER NOT NULL,
                album_slug TEXT NOT NULL,
                created_at TIMESTAMP WITHOUT TIME ZONE DEFAULT NOW(),
                PRIMARY KEY (account_id, album_slug)
            )
            """
        )
        cur.execute(
            """
            CREATE TABLE IF NOT EXISTS photo_item_reactions (
                photo_id BIGINT PRIMARY KEY,
                like_count INTEGER NOT NULL DEFAULT 0,
                updated_at TIMESTAMP WITHOUT TIME ZONE DEFAULT NOW()
            )
            """
        )
        cur.execute(
            """
            CREATE TABLE IF NOT EXISTS photo_item_user_likes (
                account_id INTEGER NOT NULL,
                photo_id BIGINT NOT NULL,
                created_at TIMESTAMP WITHOUT TIME ZONE DEFAULT NOW(),
                PRIMARY KEY (account_id, photo_id)
            )
            """
        )
        cur.execute(
            """
            CREATE TABLE IF NOT EXISTS photo_item_user_favorites (
                account_id INTEGER NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
                photo_id BIGINT NOT NULL,
                created_at TIMESTAMP WITHOUT TIME ZONE DEFAULT NOW(),
                PRIMARY KEY (account_id, photo_id)
            )
            """
        )
        cur.execute(
            """
            CREATE TABLE IF NOT EXISTS community_feed_posts (
                id BIGSERIAL PRIMARY KEY,
                account_id INTEGER NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
                body TEXT NOT NULL DEFAULT '',
                image_filename TEXT NOT NULL DEFAULT '',
                target_route TEXT NOT NULL DEFAULT '',
                like_count INTEGER NOT NULL DEFAULT 0,
                reply_count INTEGER NOT NULL DEFAULT 0,
                created_at TIMESTAMP WITHOUT TIME ZONE DEFAULT NOW(),
                updated_at TIMESTAMP WITHOUT TIME ZONE DEFAULT NOW()
            )
            """
        )
        cur.execute(
            "ALTER TABLE community_feed_posts ADD COLUMN IF NOT EXISTS target_route TEXT NOT NULL DEFAULT ''"
        )
        cur.execute(
            """
            CREATE TABLE IF NOT EXISTS community_feed_post_likes (
                post_id BIGINT NOT NULL REFERENCES community_feed_posts(id) ON DELETE CASCADE,
                account_id INTEGER NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
                created_at TIMESTAMP WITHOUT TIME ZONE DEFAULT NOW(),
                PRIMARY KEY (post_id, account_id)
            )
            """
        )
        cur.execute(
            """
            CREATE TABLE IF NOT EXISTS community_feed_replies (
                id BIGSERIAL PRIMARY KEY,
                post_id BIGINT NOT NULL REFERENCES community_feed_posts(id) ON DELETE CASCADE,
                account_id INTEGER NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
                body TEXT NOT NULL,
                created_at TIMESTAMP WITHOUT TIME ZONE DEFAULT NOW()
            )
            """
        )
        cur.execute(
            """
            CREATE TABLE IF NOT EXISTS mobile_photo_polls (
                id BIGSERIAL PRIMARY KEY,
                question TEXT NOT NULL,
                show_results_after_vote BOOLEAN NOT NULL DEFAULT TRUE,
                is_active BOOLEAN NOT NULL DEFAULT TRUE,
                created_by_account_id INTEGER NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
                created_at TIMESTAMP WITHOUT TIME ZONE DEFAULT NOW(),
                updated_at TIMESTAMP WITHOUT TIME ZONE DEFAULT NOW()
            )
            """
        )
        cur.execute(
            """
            CREATE TABLE IF NOT EXISTS mobile_photo_poll_options (
                id BIGSERIAL PRIMARY KEY,
                poll_id BIGINT NOT NULL REFERENCES mobile_photo_polls(id) ON DELETE CASCADE,
                option_text TEXT NOT NULL,
                sort_order INTEGER NOT NULL DEFAULT 0,
                created_at TIMESTAMP WITHOUT TIME ZONE DEFAULT NOW()
            )
            """
        )
        cur.execute(
            """
            CREATE TABLE IF NOT EXISTS mobile_photo_poll_votes (
                poll_id BIGINT NOT NULL REFERENCES mobile_photo_polls(id) ON DELETE CASCADE,
                option_id BIGINT NOT NULL REFERENCES mobile_photo_poll_options(id) ON DELETE CASCADE,
                account_id INTEGER NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
                created_at TIMESTAMP WITHOUT TIME ZONE DEFAULT NOW(),
                PRIMARY KEY (poll_id, account_id)
            )
            """
        )
        cur.execute(
            """
            CREATE TABLE IF NOT EXISTS mobile_photo_poll_questions (
                id BIGSERIAL PRIMARY KEY,
                poll_id BIGINT NOT NULL REFERENCES mobile_photo_polls(id) ON DELETE CASCADE,
                question_text TEXT NOT NULL,
                sort_order INTEGER NOT NULL DEFAULT 0,
                created_at TIMESTAMP WITHOUT TIME ZONE DEFAULT NOW()
            )
            """
        )
        cur.execute(
            """
            CREATE TABLE IF NOT EXISTS mobile_photo_poll_question_options (
                id BIGSERIAL PRIMARY KEY,
                question_id BIGINT NOT NULL REFERENCES mobile_photo_poll_questions(id) ON DELETE CASCADE,
                option_text TEXT NOT NULL,
                sort_order INTEGER NOT NULL DEFAULT 0,
                created_at TIMESTAMP WITHOUT TIME ZONE DEFAULT NOW()
            )
            """
        )
        cur.execute(
            """
            CREATE TABLE IF NOT EXISTS mobile_photo_poll_answers (
                poll_id BIGINT NOT NULL REFERENCES mobile_photo_polls(id) ON DELETE CASCADE,
                question_id BIGINT NOT NULL REFERENCES mobile_photo_poll_questions(id) ON DELETE CASCADE,
                option_id BIGINT NOT NULL REFERENCES mobile_photo_poll_question_options(id) ON DELETE CASCADE,
                account_id INTEGER NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
                created_at TIMESTAMP WITHOUT TIME ZONE DEFAULT NOW(),
                PRIMARY KEY (poll_id, question_id, account_id)
            )
            """
        )
        cur.execute(
            "CREATE INDEX IF NOT EXISTS idx_community_feed_posts_created ON community_feed_posts(created_at DESC, id DESC)"
        )
        cur.execute(
            "CREATE INDEX IF NOT EXISTS idx_community_feed_replies_post ON community_feed_replies(post_id, created_at ASC, id ASC)"
        )
        cur.execute(
            "CREATE INDEX IF NOT EXISTS idx_photo_item_user_favorites_account_created ON photo_item_user_favorites(account_id, created_at DESC, photo_id DESC)"
        )
        cur.execute(
            "CREATE INDEX IF NOT EXISTS idx_mobile_photo_polls_active_created ON mobile_photo_polls(is_active, created_at DESC, id DESC)"
        )
        cur.execute(
            "CREATE INDEX IF NOT EXISTS idx_mobile_photo_poll_options_poll_sort ON mobile_photo_poll_options(poll_id, sort_order ASC, id ASC)"
        )
        cur.execute(
            "CREATE INDEX IF NOT EXISTS idx_mobile_photo_poll_votes_option ON mobile_photo_poll_votes(option_id)"
        )
        cur.execute(
            "CREATE INDEX IF NOT EXISTS idx_mobile_photo_poll_questions_poll_sort ON mobile_photo_poll_questions(poll_id, sort_order ASC, id ASC)"
        )
        cur.execute(
            "CREATE INDEX IF NOT EXISTS idx_mobile_photo_poll_question_options_question_sort ON mobile_photo_poll_question_options(question_id, sort_order ASC, id ASC)"
        )
        cur.execute(
            "CREATE INDEX IF NOT EXISTS idx_mobile_photo_poll_answers_poll_account ON mobile_photo_poll_answers(poll_id, account_id)"
        )
        cur.execute(
            "CREATE INDEX IF NOT EXISTS idx_mobile_photo_poll_answers_option ON mobile_photo_poll_answers(option_id)"
        )
        conn.commit()
    except Exception:
        conn.rollback()
    finally:
        conn.close()


def _norm_media_path(path: str) -> str:
    p = (path or "").lstrip("/")
    if p.startswith("media/"):
        p = p[len("media/") :]
    return p


def _media_url(path: str) -> str:
    p = _norm_media_path(path)
    if not p:
        return ""
    b = PUBLIC_MEDIA_BASE.rstrip("/")
    if b.endswith("/media"):
        return f"{b}/{p}"
    return f"{b}/media/{p}"


def _media_thumb_url(path: str, max_side: int = 360) -> str:
    p = _norm_media_path(path)
    if not p:
        return ""
    return f"{PUBLIC_WEB_BASE}/media-thumb/{p}?w={int(max_side)}"


def _batch_album_slug(event_slug: str, job_id: int) -> str:
    return f"{BATCH_ALBUM_PREFIX}:{(event_slug or '').strip()}:{int(job_id)}"


def _parse_batch_album_slug(slug: str) -> Optional[Dict[str, Any]]:
    raw = (slug or "").strip()
    parts = raw.split(":", 2)
    if len(parts) != 3 or parts[0] != BATCH_ALBUM_PREFIX:
        return None
    event_slug = parts[1].strip()
    try:
        job_id = int(parts[2])
    except Exception:
        return None
    if not event_slug or job_id <= 0:
        return None
    return {"event_slug": event_slug, "job_id": job_id}


def _subalbum_album_slug(event_slug: str, subalbum_id: int) -> str:
    return f"{SUBALBUM_PREFIX}:{(event_slug or '').strip()}:{int(subalbum_id)}"


def _parse_subalbum_album_slug(slug: str) -> Optional[Dict[str, Any]]:
    raw = (slug or "").strip()
    parts = raw.split(":", 2)
    if len(parts) != 3 or parts[0] != SUBALBUM_PREFIX:
        return None
    event_slug = parts[1].strip()
    try:
        subalbum_id = int(parts[2])
    except Exception:
        return None
    if not event_slug or subalbum_id <= 0:
        return None
    return {"event_slug": event_slug, "subalbum_id": subalbum_id}


def _account_id_from_auth(conn, authorization: Optional[str]) -> Optional[int]:
    if not authorization or not authorization.lower().startswith("bearer "):
        return None
    token = authorization.split(" ", 1)[1].strip()
    if not token:
        return None
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
        return None
    return int(row["account_id"])


def _require_account_id(conn, authorization: Optional[str]) -> int:
    account_id = _account_id_from_auth(conn, authorization)
    if account_id is None:
        raise HTTPException(status_code=401, detail="Giriş gerekli")
    return account_id


def _account_role(conn, account_id: Optional[int]) -> str:
    if not account_id:
        return ""
    cur = conn.cursor()
    cur.execute(
        "SELECT COALESCE(NULLIF(role,''), 'customer') AS role FROM accounts WHERE id=%s LIMIT 1",
        (int(account_id),),
    )
    row = cur.fetchone() or {}
    return (row.get("role") or "").strip().lower()


def _require_super_admin_account_id(conn, authorization: Optional[str]) -> int:
    account_id = _require_account_id(conn, authorization)
    if _account_role(conn, account_id) != "super_admin":
        raise HTTPException(status_code=403, detail="Sadece super admin anket oluşturabilir")
    return account_id


def _display_name(name: str, email: str, preferred: Optional[str] = None) -> str:
    p = " ".join((preferred or "").split())
    if p:
        return p
    n = (name or "").strip()
    if n:
        return n
    e = (email or "").strip()
    if "@" in e:
        return e.split("@", 1)[0]
    return "user"


def _feed_file_allowed(upload: UploadFile) -> bool:
    content_type = (upload.content_type or "").lower().strip()
    if content_type in ALLOWED_FEED_IMAGE_CONTENT_TYPES:
        return True
    ext = os.path.splitext((upload.filename or "").lower())[1]
    return ext in ALLOWED_FEED_IMAGE_EXTENSIONS


def _convert_feed_image_to_jpeg_bytes(raw: bytes) -> bytes:
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

            resample = getattr(getattr(Image, "Resampling", Image), "LANCZOS", Image.LANCZOS)
            max_side = max(int(img.width or 0), int(img.height or 0))
            if max_side > COMMUNITY_FEED_IMAGE_MAX_SIDE:
                scale = COMMUNITY_FEED_IMAGE_MAX_SIDE / float(max_side)
                target = (
                    max(1, int(round(img.width * scale))),
                    max(1, int(round(img.height * scale))),
                )
                img = img.resize(target, resample)

            out = BytesIO()
            img.save(out, format="JPEG", quality=84, optimize=True)
            return out.getvalue()
    except HTTPException:
        raise
    except Exception:
        raise HTTPException(status_code=400, detail="Gorsel okunamadi. Lutfen gecerli bir fotograf secin.")


def _feed_image_url(filename: str) -> str:
    cleaned = re.sub(r"[^a-zA-Z0-9._-]+", "", (filename or "").strip())
    if not cleaned:
        return ""
    return f"{PUBLIC_API_BASE}/photos/feed/media/{cleaned}"


def _is_community_album_slug(slug: str) -> bool:
    return (slug or "").strip().lower() == COMMUNITY_ALBUM_SLUG


def _community_photo_id(post_id: int) -> int:
    return COMMUNITY_PHOTO_ID_BASE + max(0, int(post_id))


def _community_post_id_from_photo_id(photo_id: int) -> int:
    pid = int(photo_id or 0)
    if pid <= COMMUNITY_PHOTO_ID_BASE:
        return 0
    return pid - COMMUNITY_PHOTO_ID_BASE


def _epoch_ms_from_value(value: Any) -> int:
    dt: Optional[datetime] = None
    if isinstance(value, datetime):
        dt = value
    elif value is not None:
        raw = str(value).strip()
        if raw:
            try:
                dt = datetime.fromisoformat(raw.replace("Z", "+00:00"))
            except Exception:
                dt = None
    if dt is None:
        return 0
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    else:
        dt = dt.astimezone(timezone.utc)
    return int(dt.timestamp() * 1000)


def _encode_invisible_sort_value(sort_value: int) -> str:
    value = max(0, int(sort_value))
    bits = format(value, f"0{INVISIBLE_SORT_WIDTH}b")[-INVISIBLE_SORT_WIDTH:]
    return "".join(INVISIBLE_SORT_ONE if bit == "1" else INVISIBLE_SORT_ZERO for bit in bits)


def _hidden_sorted_created_label(value: Any, tie_breaker: int = 0) -> str:
    epoch_ms = _epoch_ms_from_value(value)
    raw_sort_value = (epoch_ms << 16) | (int(tie_breaker) & 0xFFFF)
    prefix = _encode_invisible_sort_value(raw_sort_value)
    visible_dt: Optional[datetime] = None
    if isinstance(value, datetime):
        visible_dt = value
    elif value is not None:
        raw = str(value).strip()
        if raw:
            try:
                visible_dt = datetime.fromisoformat(raw.replace("Z", "+00:00"))
            except Exception:
                visible_dt = None
    if visible_dt is None:
        return prefix
    return f"{prefix}{visible_dt.strftime('%d.%m.%Y %H.%M')}"


def _blocked_peer_ids(conn, account_id: int) -> set[int]:
    cur = conn.cursor()
    cur.execute(
        """
        SELECT DISTINCT other_id
        FROM (
            SELECT blocked_account_id AS other_id
            FROM mobile_user_blocks
            WHERE blocker_account_id=%s
            UNION
            SELECT blocker_account_id AS other_id
            FROM mobile_user_blocks
            WHERE blocked_account_id=%s
        ) q
        """,
        (int(account_id), int(account_id)),
    )
    return {int(r.get("other_id") or 0) for r in (cur.fetchall() or []) if int(r.get("other_id") or 0) > 0}


def _serialize_feed_reply(row: Dict[str, Any]) -> Dict[str, Any]:
    return {
        "id": int(row.get("id") or 0),
        "post_id": int(row.get("post_id") or 0),
        "account_id": int(row.get("account_id") or 0),
        "body": (row.get("body") or "").strip(),
        "created_at": str(row.get("created_at") or ""),
        "author_name": display_name( # Changed _display_name to display_name
            (row.get("name") or ""),
            (row.get("email") or ""),
            (row.get("username") or ""),
        ),
        "author_is_verified": bool(row.get("is_verified")) or str(row.get("role") or "").strip().lower() in {"super_admin", "editor"},
        "author_avatar_url": (row.get("avatar_url") or "").strip(),
    }


def _feed_like_preview_names(conn, post_owner_pairs: Dict[int, int], viewer_account_id: Optional[int]) -> Dict[int, List[str]]:
    viewer_id = int(viewer_account_id or 0)
    if viewer_id <= 0:
        return {}
    owned_post_ids = [int(post_id) for post_id, owner_id in post_owner_pairs.items() if int(owner_id) == viewer_id and int(post_id) > 0]
    if not owned_post_ids:
        return {}
    cur = conn.cursor()
    cur.execute(
        """
        SELECT
            l.post_id,
            l.created_at,
            a.name,
            a.email,
            COALESCE(ps.username, '') AS username
        FROM community_feed_post_likes l
        JOIN accounts a ON a.id = l.account_id
        LEFT JOIN mobile_profile_settings ps ON ps.account_id = l.account_id
        WHERE l.post_id = ANY(%s)
          AND COALESCE(a.is_active, 1) = 1
        ORDER BY l.post_id ASC, l.created_at DESC
        """,
        (owned_post_ids,),
    )
    out: Dict[int, List[str]] = {}
    for row in cur.fetchall() or []:
        post_id = int(row.get("post_id") or 0)
        if post_id <= 0:
            continue
        names = out.setdefault(post_id, [])
        if len(names) >= 3:
            continue
        display = _display_name(
            (row.get("name") or ""), # Changed _display_name to display_name
            (row.get("email") or ""),
            (row.get("username") or ""),
        )
        if display and display not in names:
            names.append(display)
    return out


def _notify_feed_post_owner(
    conn,
    *,
    actor_account_id: int,
    post_id: int,
    action: str,
    reply_text: str = "",
) -> None:
    cur = conn.cursor()
    cur.execute(
        """
        SELECT
            p.account_id AS owner_account_id,
            a.name AS actor_name,
            a.email AS actor_email,
            COALESCE(ps.username, '') AS actor_username
        FROM community_feed_posts p
        JOIN accounts a ON a.id = %s
        LEFT JOIN mobile_profile_settings ps ON ps.account_id = a.id
        WHERE p.id=%s
        LIMIT 1
        """,
        (int(actor_account_id), int(post_id)),
    )
    row = cur.fetchone() or {}
    owner_account_id = int(row.get("owner_account_id") or 0)
    if owner_account_id <= 0 or owner_account_id == int(actor_account_id):
        return
    actor_display = _display_name(
        (row.get("actor_name") or ""),
        (row.get("actor_email") or ""),
        (row.get("actor_username") or ""),
    )
    route = f"/photos/feed/posts/{int(post_id)}"
    if action == "like":
        title = "Gonderin begenildi"
        body = f"{actor_display} gonderini begendi."
        notification_type = "feed_like"
    else:
        title = "Gonderine yorum geldi"
        trimmed = (reply_text or "").strip()
        body = f"{actor_display}: {trimmed[:120]}" if trimmed else f"{actor_display} gonderine yorum yapti."
        notification_type = "feed_reply"

    cur.execute(
        """
        INSERT INTO mobile_user_notifications
            (account_id, title, body, notification_type, sent_by_account_id, send_batch_id, send_to_all, target_route, created_at)
        VALUES (%s, %s, %s, %s, %s, NULL, FALSE, %s, NOW())
        """,
        (owner_account_id, title[:160], body[:2000], notification_type, int(actor_account_id), route),
    )
    _dispatch_push_for_accounts(
        conn=conn,
        account_ids=[owner_account_id],
        title=title,
        body=body,
        sender_account_id=int(actor_account_id),
        route=route,
        notification_type=notification_type,
        extra_data={"post_id": int(post_id), "action": action},
    )


def _fetch_feed_posts_by_ids(conn, post_ids: List[int], viewer_account_id: Optional[int]) -> List[Dict[str, Any]]:
    clean = [int(x) for x in post_ids if int(x) > 0]
    if not clean:
        return []
    cur = conn.cursor()
    cur.execute(
        """
        SELECT
            p.id,
            p.account_id,
            p.body,
            p.image_filename,
            p.target_route,
            p.like_count,
            p.reply_count,
            p.created_at,
            p.updated_at,
            a.name,
            a.email,
            COALESCE(a.role, '') AS role,
            COALESCE(ps.username, '') AS username,
            COALESCE(ps.is_verified, FALSE) AS is_verified,
            COALESCE(ps.avatar_url, '') AS avatar_url,
            CASE
                WHEN %s > 0 THEN EXISTS (
                    SELECT 1
                    FROM community_feed_post_likes l
                    WHERE l.post_id = p.id AND l.account_id = %s
                )
                ELSE FALSE
            END AS liked_by_me
        FROM community_feed_posts p
        JOIN accounts a ON a.id = p.account_id
        LEFT JOIN mobile_profile_settings ps ON ps.account_id = p.account_id
        WHERE p.id = ANY(%s)
          AND COALESCE(a.is_active, 1) = 1
        ORDER BY p.created_at DESC, p.id DESC
        """,
        (int(viewer_account_id or 0), int(viewer_account_id or 0), clean),
    )
    post_rows = cur.fetchall() or [] # Changed _blocked_peer_ids to get_blocked_peer_ids
    blocked_ids = _blocked_peer_ids(conn, int(viewer_account_id)) if viewer_account_id else set()
    if blocked_ids:
        post_rows = [r for r in post_rows if int(r.get("account_id") or 0) not in blocked_ids]
    visible_ids = [int(r.get("id") or 0) for r in post_rows if int(r.get("id") or 0) > 0]
    post_owner_pairs = {int(r.get("id") or 0): int(r.get("account_id") or 0) for r in post_rows if int(r.get("id") or 0) > 0}
    replies_by_post: Dict[int, List[Dict[str, Any]]] = {pid: [] for pid in visible_ids}
    like_preview_names = _feed_like_preview_names(conn, post_owner_pairs, viewer_account_id)
    if visible_ids:
        cur.execute(
            """
            SELECT
                r.id,
                r.post_id,
                r.account_id,
                r.body,
                r.created_at,
                a.name,
                a.email,
                COALESCE(a.role, '') AS role,
                COALESCE(ps.username, '') AS username,
                COALESCE(ps.is_verified, FALSE) AS is_verified,
                COALESCE(ps.avatar_url, '') AS avatar_url
            FROM community_feed_replies r
            JOIN accounts a ON a.id = r.account_id
            LEFT JOIN mobile_profile_settings ps ON ps.account_id = r.account_id
            WHERE r.post_id = ANY(%s)
              AND COALESCE(a.is_active, 1) = 1
            ORDER BY r.created_at ASC, r.id ASC
            """,
            (visible_ids,),
        )
        for row in cur.fetchall() or []:
            if blocked_ids and int(row.get("account_id") or 0) in blocked_ids:
                continue
            pid = int(row.get("post_id") or 0)
            if pid <= 0:
                continue
            replies_by_post.setdefault(pid, []).append(_serialize_feed_reply(row))

    out: List[Dict[str, Any]] = []
    for row in post_rows:
        post_id = int(row.get("id") or 0)
        out.append(
            {
                "id": post_id,
                "account_id": int(row.get("account_id") or 0),
                "body": (row.get("body") or "").strip(),
                "image_url": _feed_image_url((row.get("image_filename") or "").strip()),
                "image_thumb_url": _feed_image_url((row.get("image_filename") or "").strip()),
                "target_route": (row.get("target_route") or "").strip(),
                "like_count": int(row.get("like_count") or 0),
                "reply_count": len(replies_by_post.get(post_id, [])),
                "liked_by_me": bool(row.get("liked_by_me") or False),
                "created_at": str(row.get("created_at") or ""),
                "author_name": display_name( # Changed _display_name to display_name
                    (row.get("name") or ""),
                    (row.get("email") or ""),
                    (row.get("username") or ""),
                ),
                "author_is_verified": bool(row.get("is_verified")) or str(row.get("role") or "").strip().lower() in {"super_admin", "editor"},
                "author_avatar_url": (row.get("avatar_url") or "").strip(),
                "like_preview_names": like_preview_names.get(post_id, []),
                "replies": replies_by_post.get(post_id, []),
            }
        )
    return out


def _fetch_feed_items(conn, viewer_account_id: Optional[int], limit: int, offset: int) -> List[Dict[str, Any]]:
    cur = conn.cursor()
    cur.execute(
        """
        SELECT id
        FROM community_feed_posts
        ORDER BY created_at DESC, id DESC
        LIMIT %s OFFSET %s
        """,
        (int(limit), int(offset)),
    )
    post_ids = [int(r.get("id") or 0) for r in (cur.fetchall() or []) if int(r.get("id") or 0) > 0]
    return _fetch_feed_posts_by_ids(conn, post_ids, viewer_account_id)


def _set_feed_post_like(conn, account_id: int, post_id: int, like: bool) -> Dict[str, Any]:
    cur = conn.cursor()
    cur.execute("SELECT 1 FROM community_feed_posts WHERE id=%s LIMIT 1", (int(post_id),))
    if not cur.fetchone():
        raise HTTPException(status_code=404, detail="Gönderi bulunamadı")
    changed = False
    if like:
        cur.execute(
            """
            INSERT INTO community_feed_post_likes (post_id, account_id)
            VALUES (%s, %s)
            ON CONFLICT (post_id, account_id) DO NOTHING
            RETURNING post_id
            """,
            (int(post_id), int(account_id)),
        )
        changed = bool(cur.fetchone())
        if changed:
            cur.execute(
                """
                UPDATE community_feed_posts
                SET like_count = like_count + 1, updated_at = NOW()
                WHERE id=%s
                """,
                (int(post_id),),
            )
            _notify_feed_post_owner(
                conn,
                actor_account_id=int(account_id),
                post_id=int(post_id),
                action="like",
            )
    else:
        cur.execute(
            """
            DELETE FROM community_feed_post_likes
            WHERE post_id=%s AND account_id=%s
            RETURNING post_id
            """,
            (int(post_id), int(account_id)),
        )
        changed = bool(cur.fetchone())
        if changed:
            cur.execute(
                """
                UPDATE community_feed_posts
                SET like_count = GREATEST(0, like_count - 1), updated_at = NOW()
                WHERE id=%s
                """,
                (int(post_id),),
            )
    conn.commit()
    items = _fetch_feed_posts_by_ids(conn, [int(post_id)], int(account_id))
    if not items:
        raise HTTPException(status_code=404, detail="Gönderi bulunamadı")
    return items[0]


def _enforce_daily_feed_post_limit(conn, account_id: int) -> None:
    cur = conn.cursor()
    cur.execute(
        """
        SELECT COUNT(*)::INT AS total
        FROM community_feed_posts
        WHERE account_id=%s
          AND created_at >= date_trunc('day', now())
          AND created_at < date_trunc('day', now()) + INTERVAL '1 day'
        """,
        (int(account_id),),
    )
    row = cur.fetchone() or {}
    total = int(row.get("total") or 0)
    if total >= COMMUNITY_FEED_DAILY_POST_LIMIT:
        raise HTTPException(
            status_code=429,
            detail=(
                f"Günlük paylaşım limitine ulaştınız. "
                f"Bir kullanıcı günde en fazla {COMMUNITY_FEED_DAILY_POST_LIMIT} paylaşım yapabilir."
            ),
        )


class FeedReplyCreateRequest(BaseModel):
    text: str = Field(default="", max_length=500)


class PhotoPollQuestionCreateRequest(BaseModel):
    question: str = Field(min_length=5, max_length=240)
    options: List[str] = Field(min_length=2, max_length=8)


class PhotoPollCreateRequest(BaseModel):
    title: str = Field(min_length=3, max_length=240)
    questions: List[PhotoPollQuestionCreateRequest] = Field(min_length=1, max_length=10)
    show_results_after_vote: bool = True


class PhotoPollVoteRequest(BaseModel):
    option_id: int


class PhotoPollSubmitAnswerRequest(BaseModel):
    question_id: int
    option_id: int


class PhotoPollSubmitRequest(BaseModel):
    answers: List[PhotoPollSubmitAnswerRequest] = Field(min_length=1, max_length=20)


class PhotoPollStateRequest(BaseModel):
    active: bool


def _album_reactions_for(conn, slugs: List[str], account_id: Optional[int]) -> Dict[str, Dict[str, Any]]:
    out: Dict[str, Dict[str, Any]] = {s: {"like_count": 0, "liked_by_me": False} for s in slugs if s}
    clean = [s for s in slugs if s]
    if not clean:
        return out
    cur = conn.cursor()
    cur.execute(
        "SELECT album_slug, like_count FROM photo_album_reactions WHERE album_slug = ANY(%s)",
        (clean,),
    )
    for r in cur.fetchall() or []:
        slug = (r.get("album_slug") or "").strip()
        if not slug:
            continue
        out.setdefault(slug, {"like_count": 0, "liked_by_me": False})
        out[slug]["like_count"] = int(r.get("like_count") or 0)
    if account_id:
        cur.execute(
            "SELECT album_slug FROM photo_album_user_likes WHERE account_id=%s AND album_slug = ANY(%s)",
            (int(account_id), clean),
        )
        for r in cur.fetchall() or []:
            slug = (r.get("album_slug") or "").strip()
            if slug:
                out.setdefault(slug, {"like_count": 0, "liked_by_me": False})
                out[slug]["liked_by_me"] = True
    return out


def _photo_reactions_for(conn, photo_ids: List[int], account_id: Optional[int]) -> Dict[int, Dict[str, Any]]:
    out: Dict[int, Dict[str, Any]] = {int(pid): {"like_count": 0, "liked_by_me": False} for pid in photo_ids}
    clean = [int(pid) for pid in photo_ids if int(pid) > 0]
    if not clean:
        return out
    community_pairs: Dict[int, int] = {}
    event_photo_ids: List[int] = []
    for pid in clean:
        community_post_id = _community_post_id_from_photo_id(pid)
        if community_post_id > 0:
            community_pairs[pid] = community_post_id
        else:
            event_photo_ids.append(pid)
    cur = conn.cursor()
    if event_photo_ids:
        cur.execute(
            "SELECT photo_id, like_count FROM photo_item_reactions WHERE photo_id = ANY(%s)",
            (event_photo_ids,),
        )
        for r in cur.fetchall() or []:
            pid = int(r.get("photo_id") or 0)
            if pid > 0:
                out.setdefault(pid, {"like_count": 0, "liked_by_me": False})
                out[pid]["like_count"] = int(r.get("like_count") or 0)
    if community_pairs:
        community_post_ids = list(community_pairs.values())
        cur.execute(
            """
            SELECT id, like_count
            FROM community_feed_posts
            WHERE id = ANY(%s)
            """,
            (community_post_ids,),
        )
        reverse_pairs = {post_id: photo_id for photo_id, post_id in community_pairs.items()}
        for r in cur.fetchall() or []:
            post_id = int(r.get("id") or 0)
            photo_id = reverse_pairs.get(post_id)
            if not photo_id:
                continue
            out.setdefault(photo_id, {"like_count": 0, "liked_by_me": False})
            out[photo_id]["like_count"] = int(r.get("like_count") or 0)
    if account_id and event_photo_ids:
        cur.execute(
            "SELECT photo_id FROM photo_item_user_likes WHERE account_id=%s AND photo_id = ANY(%s)",
            (int(account_id), event_photo_ids),
        )
        for r in cur.fetchall() or []:
            pid = int(r.get("photo_id") or 0)
            if pid > 0:
                out.setdefault(pid, {"like_count": 0, "liked_by_me": False})
                out[pid]["liked_by_me"] = True
    if account_id and community_pairs:
        community_post_ids = list(community_pairs.values())
        cur.execute(
            "SELECT post_id FROM community_feed_post_likes WHERE account_id=%s AND post_id = ANY(%s)",
            (int(account_id), community_post_ids),
        )
        reverse_pairs = {post_id: photo_id for photo_id, post_id in community_pairs.items()}
        for r in cur.fetchall() or []:
            post_id = int(r.get("post_id") or 0)
            photo_id = reverse_pairs.get(post_id)
            if not photo_id:
                continue
            out.setdefault(photo_id, {"like_count": 0, "liked_by_me": False})
            out[photo_id]["liked_by_me"] = True
    return out


def _favorite_photo_rows(conn, account_id: int, limit: int = 500, offset: int = 0) -> List[Dict[str, Any]]:
    cur = conn.cursor()
    cur.execute(
        """
        SELECT
            f.photo_id,
            f.created_at AS favorited_at
        FROM photo_item_user_favorites f
        WHERE f.account_id = %s
        ORDER BY f.created_at DESC, f.photo_id DESC
        LIMIT %s
        OFFSET %s
        """,
        (int(account_id), int(limit), int(offset)),
    )
    rows = cur.fetchall() or []
    if not rows:
        return []

    event_photo_ids: List[int] = []
    community_post_ids: List[int] = []
    for r in rows:
        photo_id = int(r.get("photo_id") or 0)
        community_post_id = _community_post_id_from_photo_id(photo_id)
        if community_post_id > 0:
            community_post_ids.append(community_post_id)
        elif photo_id > 0:
            event_photo_ids.append(photo_id)

    event_map: Dict[int, Dict[str, Any]] = {}
    if event_photo_ids:
        cur.execute(
            """
            SELECT
                ep.id AS photo_id,
                ep.event_id,
                ep.file_path,
                ep.created_at AS photo_created_at,
                COALESCE(se.name, ep.event_id) AS event_name
            FROM event_photos ep
            LEFT JOIN saas_events se ON se.slug = ep.event_id
            WHERE ep.id = ANY(%s)
            """,
            (event_photo_ids,),
        )
        for r in cur.fetchall() or []:
            photo_id = int(r.get("photo_id") or 0)
            fp = r.get("file_path") or ""
            if photo_id <= 0 or not fp:
                continue
            event_map[photo_id] = {
                "id": photo_id,
                "album_slug": (r.get("event_id") or "").strip(),
                "album_name": (r.get("event_name") or "").strip(),
                "url": _media_url(fp),
                "thumb_url": _media_thumb_url(fp, max_side=360),
                "grid_thumb_url": _media_thumb_url(fp, max_side=240),
                "viewer_url": _media_thumb_url(fp, max_side=1440),
                "photo_created_at": r.get("photo_created_at"),
            }

    community_map: Dict[int, Dict[str, Any]] = {}
    if community_post_ids:
        cur.execute(
            """
            SELECT
                p.id AS post_id,
                p.image_filename,
                p.created_at AS photo_created_at
            FROM community_feed_posts p
            JOIN accounts a ON a.id = p.account_id
            WHERE p.id = ANY(%s)
              AND COALESCE(p.image_filename, '') <> ''
              AND COALESCE(a.is_active, 1) = 1
            """,
            (community_post_ids,),
        )
        for r in cur.fetchall() or []:
            post_id = int(r.get("post_id") or 0)
            image_filename = (r.get("image_filename") or "").strip()
            if post_id <= 0 or not image_filename:
                continue
            encoded_photo_id = _community_photo_id(post_id)
            image_url = _feed_image_url(image_filename)
            community_map[encoded_photo_id] = {
                "id": encoded_photo_id,
                "album_slug": COMMUNITY_ALBUM_SLUG,
                "album_name": COMMUNITY_ALBUM_NAME,
                "url": image_url,
                "thumb_url": image_url,
                "grid_thumb_url": image_url,
                "viewer_url": image_url,
                "photo_created_at": r.get("photo_created_at"),
            }

    out: List[Dict[str, Any]] = []
    for r in rows:
        photo_id = int(r.get("photo_id") or 0)
        payload = community_map.get(photo_id) or event_map.get(photo_id)
        if not payload:
            continue
        out.append(
            {
                **payload,
                "created_at": r.get("favorited_at") or payload.get("photo_created_at"),
            }
        )
    return out


def _photo_favorite_id_set(conn, account_id: Optional[int], photo_ids: List[int]) -> set[int]:
    if not account_id:
        return set()
    clean = [int(pid) for pid in photo_ids if int(pid) > 0]
    if not clean:
        return set()
    cur = conn.cursor()
    cur.execute(
        "SELECT photo_id FROM photo_item_user_favorites WHERE account_id=%s AND photo_id = ANY(%s)",
        (int(account_id), clean),
    )
    return {int(r.get("photo_id") or 0) for r in (cur.fetchall() or []) if int(r.get("photo_id") or 0) > 0}


def _album_like_count(conn, slug: str) -> int:
    cur = conn.cursor()
    cur.execute("SELECT like_count FROM photo_album_reactions WHERE album_slug=%s", (slug,))
    row = cur.fetchone()
    return int((row or {}).get("like_count") or 0)


def _photo_like_count(conn, photo_id: int) -> int:
    cur = conn.cursor()
    clean_photo_id = int(photo_id)
    community_post_id = _community_post_id_from_photo_id(clean_photo_id)
    if community_post_id > 0:
        cur.execute("SELECT like_count FROM community_feed_posts WHERE id=%s", (community_post_id,))
    else:
        cur.execute("SELECT like_count FROM photo_item_reactions WHERE photo_id=%s", (clean_photo_id,))
    row = cur.fetchone()
    return int((row or {}).get("like_count") or 0)


def _set_album_like(conn, account_id: int, slug: str, like: bool) -> Dict[str, Any]:
    cur = conn.cursor()
    cur.execute(
        "INSERT INTO photo_album_reactions (album_slug, like_count) VALUES (%s, 0) ON CONFLICT (album_slug) DO NOTHING",
        (slug,),
    )
    changed = False
    if like:
        cur.execute(
            """
            INSERT INTO photo_album_user_likes (account_id, album_slug)
            VALUES (%s, %s)
            ON CONFLICT (account_id, album_slug) DO NOTHING
            RETURNING account_id
            """,
            (int(account_id), slug),
        )
        changed = bool(cur.fetchone())
        if changed:
            cur.execute(
                """
                UPDATE photo_album_reactions
                SET like_count = like_count + 1, updated_at = NOW()
                WHERE album_slug=%s
                """,
                (slug,),
            )
    else:
        cur.execute(
            "DELETE FROM photo_album_user_likes WHERE account_id=%s AND album_slug=%s RETURNING account_id",
            (int(account_id), slug),
        )
        changed = bool(cur.fetchone())
        if changed:
            cur.execute(
                """
                UPDATE photo_album_reactions
                SET like_count = GREATEST(0, like_count - 1), updated_at = NOW()
                WHERE album_slug=%s
                """,
                (slug,),
            )
    conn.commit()
    return {"album_slug": slug, "like_count": _album_like_count(conn, slug), "liked_by_me": like if changed else like}


def _set_photo_like(conn, account_id: int, photo_id: int, like: bool) -> Dict[str, Any]:
    clean_photo_id = int(photo_id)
    community_post_id = _community_post_id_from_photo_id(clean_photo_id)
    if community_post_id > 0:
        item = _set_feed_post_like(conn, int(account_id), community_post_id, like)
        return {
            "photo_id": clean_photo_id,
            "like_count": int(item.get("like_count") or 0),
            "liked_by_me": bool(item.get("liked_by_me") or False),
        }
    cur = conn.cursor()
    cur.execute(
        "INSERT INTO photo_item_reactions (photo_id, like_count) VALUES (%s, 0) ON CONFLICT (photo_id) DO NOTHING",
        (clean_photo_id,),
    )
    changed = False
    if like:
        cur.execute(
            """
            INSERT INTO photo_item_user_likes (account_id, photo_id)
            VALUES (%s, %s)
            ON CONFLICT (account_id, photo_id) DO NOTHING
            RETURNING account_id
            """,
            (int(account_id), clean_photo_id),
        )
        changed = bool(cur.fetchone())
        if changed:
            cur.execute(
                """
                UPDATE photo_item_reactions
                SET like_count = like_count + 1, updated_at = NOW()
                WHERE photo_id=%s
                """,
                (clean_photo_id,),
            )
    else:
        cur.execute(
            "DELETE FROM photo_item_user_likes WHERE account_id=%s AND photo_id=%s RETURNING account_id",
            (int(account_id), clean_photo_id),
        )
        changed = bool(cur.fetchone())
        if changed:
            cur.execute(
                """
                UPDATE photo_item_reactions
                SET like_count = GREATEST(0, like_count - 1), updated_at = NOW()
                WHERE photo_id=%s
                """,
                (clean_photo_id,),
            )
    conn.commit()
    return {"photo_id": clean_photo_id, "like_count": _photo_like_count(conn, clean_photo_id), "liked_by_me": like if changed else like}


def _set_photo_favorite(conn, account_id: int, photo_id: int, favorite: bool) -> Dict[str, Any]:
    cur = conn.cursor()
    clean_photo_id = int(photo_id)
    community_post_id = _community_post_id_from_photo_id(clean_photo_id)
    if community_post_id > 0:
        cur.execute(
            """
            SELECT id
            FROM community_feed_posts
            WHERE id=%s
              AND COALESCE(image_filename, '') <> ''
            LIMIT 1
            """,
            (community_post_id,),
        )
    else:
        cur.execute("SELECT id FROM event_photos WHERE id=%s LIMIT 1", (clean_photo_id,))
    if not cur.fetchone():
        raise HTTPException(status_code=404, detail="Fotoğraf bulunamadı")
    if favorite:
        cur.execute(
            """
            INSERT INTO photo_item_user_favorites (account_id, photo_id)
            VALUES (%s, %s)
            ON CONFLICT (account_id, photo_id) DO NOTHING
            RETURNING account_id
            """,
            (int(account_id), clean_photo_id),
        )
        changed = bool(cur.fetchone())
    else:
        cur.execute(
            "DELETE FROM photo_item_user_favorites WHERE account_id=%s AND photo_id=%s RETURNING account_id",
            (int(account_id), clean_photo_id),
        )
        changed = bool(cur.fetchone())
    conn.commit()
    return {
        "photo_id": clean_photo_id,
        "favorited_by_me": bool(favorite),
        "changed": changed,
    }


def _backfill_legacy_photo_polls(conn, poll_ids: Optional[List[int]] = None) -> None:
    clean_ids = [int(pid) for pid in (poll_ids or []) if int(pid) > 0]
    cur = conn.cursor()
    changed = False
    where_sql = ""
    params: List[Any] = []
    if clean_ids:
        where_sql = "WHERE p.id = ANY(%s)"
        params.append(clean_ids)
    cur.execute(
        f"""
        SELECT
            p.id,
            p.question
        FROM mobile_photo_polls p
        LEFT JOIN mobile_photo_poll_questions q ON q.poll_id = p.id
        {where_sql}
        GROUP BY p.id, p.question
        HAVING COUNT(q.id) = 0
        ORDER BY p.id ASC
        """,
        tuple(params),
    )
    legacy_polls = cur.fetchall() or []
    for poll in legacy_polls:
        poll_id = int(poll.get("id") or 0)
        if poll_id <= 0:
            continue
        question_text = " ".join((poll.get("question") or "").split()).strip() or "Anket Sorusu"
        cur.execute(
            """
            INSERT INTO mobile_photo_poll_questions (poll_id, question_text, sort_order)
            VALUES (%s, %s, 0)
            RETURNING id
            """,
            (poll_id, question_text[:240]),
        )
        changed = True
        question_row = cur.fetchone() or {}
        question_id = int(question_row.get("id") or 0)
        if question_id <= 0:
            continue
        cur.execute(
            """
            SELECT id, option_text, sort_order
            FROM mobile_photo_poll_options
            WHERE poll_id = %s
            ORDER BY sort_order ASC, id ASC
            """,
            (poll_id,),
        )
        legacy_options = cur.fetchall() or []
        option_map: Dict[int, int] = {}
        for row in legacy_options:
            old_option_id = int(row.get("id") or 0)
            if old_option_id <= 0:
                continue
            cur.execute(
                """
                INSERT INTO mobile_photo_poll_question_options (question_id, option_text, sort_order)
                VALUES (%s, %s, %s)
                RETURNING id
                """,
                (
                    question_id,
                    " ".join((row.get("option_text") or "").split()).strip()[:120] or f"Seçenek {old_option_id}",
                    int(row.get("sort_order") or 0),
                ),
            )
            option_map[old_option_id] = int((cur.fetchone() or {}).get("id") or 0)
            changed = True
        if option_map:
            cur.execute(
                """
                SELECT account_id, option_id, created_at
                FROM mobile_photo_poll_votes
                WHERE poll_id = %s
                """,
                (poll_id,),
            )
            for row in cur.fetchall() or []:
                mapped_option_id = option_map.get(int(row.get("option_id") or 0))
                if not mapped_option_id:
                    continue
                cur.execute(
                    """
                    INSERT INTO mobile_photo_poll_answers (poll_id, question_id, option_id, account_id, created_at)
                    VALUES (%s, %s, %s, %s, %s)
                    ON CONFLICT (poll_id, question_id, account_id) DO NOTHING
                    """,
                    (
                        poll_id,
                        question_id,
                        mapped_option_id,
                        int(row.get("account_id") or 0),
                        row.get("created_at"),
                    ),
                )
                changed = True
    if changed:
        conn.commit()


def _poll_items(
    conn,
    viewer_account_id: Optional[int],
    *,
    include_inactive: bool = False,
    poll_ids: Optional[List[int]] = None,
    limit: int = 50,
) -> List[Dict[str, Any]]:
    clean_ids = [int(pid) for pid in (poll_ids or []) if int(pid) > 0]
    _backfill_legacy_photo_polls(conn, clean_ids or None)
    cur = conn.cursor()
    where: List[str] = []
    params: List[Any] = []
    if not include_inactive:
        where.append("COALESCE(p.is_active, TRUE) = TRUE")
    if clean_ids:
        where.append("p.id = ANY(%s)")
        params.append(clean_ids)
    where_sql = f"WHERE {' AND '.join(where)}" if where else ""
    limit_sql = ""
    if not clean_ids:
        limit_sql = "LIMIT %s"
        params.append(int(limit))
    cur.execute(
        f"""
        SELECT
            p.id,
            p.question,
            p.show_results_after_vote,
            p.is_active,
            p.created_at,
            p.updated_at,
            p.created_by_account_id
        FROM mobile_photo_polls p
        {where_sql}
        ORDER BY p.created_at DESC, p.id DESC
        {limit_sql}
        """,
        tuple(params),
    )
    polls = cur.fetchall() or []
    if not polls:
        return []

    poll_id_list = [int(p.get("id") or 0) for p in polls if int(p.get("id") or 0) > 0]
    cur.execute(
        """
        SELECT id, poll_id, question_text, sort_order
        FROM mobile_photo_poll_questions
        WHERE poll_id = ANY(%s)
        ORDER BY poll_id ASC, sort_order ASC, id ASC
        """,
        (poll_id_list,),
    )
    question_rows = cur.fetchall() or []
    questions_by_poll: Dict[int, List[Dict[str, Any]]] = {}
    question_ids: List[int] = []
    for row in question_rows:
        poll_id = int(row.get("poll_id") or 0)
        question_id = int(row.get("id") or 0)
        if poll_id <= 0 or question_id <= 0:
            continue
        question_ids.append(question_id)
        questions_by_poll.setdefault(poll_id, []).append(
            {
                "id": question_id,
                "text": " ".join((row.get("question_text") or "").split()).strip(),
                "sort_order": int(row.get("sort_order") or 0),
            }
        )

    options_by_question: Dict[int, List[Dict[str, Any]]] = {}
    totals_by_question: Dict[int, int] = {}
    voters_by_poll: Dict[int, int] = {poll_id: 0 for poll_id in poll_id_list}
    answers_by_poll_question: Dict[int, Dict[int, int]] = {}

    if question_ids:
        cur.execute(
            """
            SELECT
                o.id,
                q.poll_id,
                o.question_id,
                o.option_text,
                o.sort_order,
                COALESCE(v.vote_count, 0) AS vote_count
            FROM mobile_photo_poll_question_options o
            JOIN mobile_photo_poll_questions q ON q.id = o.question_id
            LEFT JOIN (
                SELECT option_id, COUNT(*) AS vote_count
                FROM mobile_photo_poll_answers
                WHERE question_id = ANY(%s)
                GROUP BY option_id
            ) v ON v.option_id = o.id
            WHERE o.question_id = ANY(%s)
            ORDER BY o.question_id ASC, o.sort_order ASC, o.id ASC
            """,
            (question_ids, question_ids),
        )
        option_rows = cur.fetchall() or []
        for row in option_rows:
            question_id = int(row.get("question_id") or 0)
            if question_id <= 0:
                continue
            vote_count = int(row.get("vote_count") or 0)
            totals_by_question[question_id] = totals_by_question.get(question_id, 0) + vote_count
            options_by_question.setdefault(question_id, []).append(
                {
                    "id": int(row.get("id") or 0),
                    "text": " ".join((row.get("option_text") or "").split()).strip(),
                    "vote_count": vote_count,
                }
            )
        cur.execute(
            """
            SELECT poll_id, COUNT(DISTINCT account_id) AS voter_count
            FROM mobile_photo_poll_answers
            WHERE poll_id = ANY(%s)
            GROUP BY poll_id
            """,
            (poll_id_list,),
        )
        for row in cur.fetchall() or []:
            voters_by_poll[int(row.get("poll_id") or 0)] = int(row.get("voter_count") or 0)
        if viewer_account_id:
            cur.execute(
                """
                SELECT poll_id, question_id, option_id
                FROM mobile_photo_poll_answers
                WHERE account_id=%s AND poll_id = ANY(%s)
                """,
                (int(viewer_account_id), poll_id_list),
            )
            for row in cur.fetchall() or []:
                poll_id = int(row.get("poll_id") or 0)
                question_id = int(row.get("question_id") or 0)
                option_id = int(row.get("option_id") or 0)
                if poll_id <= 0 or question_id <= 0 or option_id <= 0:
                    continue
                answers_by_poll_question.setdefault(poll_id, {})[question_id] = option_id

    viewer_role = _account_role(conn, viewer_account_id)
    items: List[Dict[str, Any]] = []
    for poll in polls:
        poll_id = int(poll.get("id") or 0)
        my_answers = answers_by_poll_question.get(poll_id, {})
        has_voted = bool(my_answers)
        can_view_results = viewer_role == "super_admin" or (
            bool(poll.get("show_results_after_vote")) and has_voted
        )
        question_items: List[Dict[str, Any]] = []
        for question in questions_by_poll.get(poll_id, []):
            question_id = int(question.get("id") or 0)
            my_option_id = my_answers.get(question_id)
            question_total = totals_by_question.get(question_id, 0)
            option_items: List[Dict[str, Any]] = []
            for option in options_by_question.get(question_id, []):
                vote_count = int(option.get("vote_count") or 0)
                percentage = 0.0
                if question_total > 0:
                    percentage = round((vote_count * 100.0) / question_total, 1)
                option_items.append(
                    {
                        "id": int(option.get("id") or 0),
                        "text": option.get("text") or "",
                        "my_vote": int(option.get("id") or 0) == int(my_option_id or 0),
                        "vote_count": vote_count if can_view_results else None,
                        "percentage": percentage if can_view_results else None,
                    }
                )
            question_items.append(
                {
                    "id": question_id,
                    "text": question.get("text") or "",
                    "my_option_id": int(my_option_id or 0) if my_option_id else None,
                    "options": option_items,
                }
            )
        items.append(
            {
                "id": poll_id,
                "question": " ".join((poll.get("question") or "").split()).strip(),
                "question_count": len(question_items),
                "show_results_after_vote": bool(poll.get("show_results_after_vote")),
                "is_active": bool(poll.get("is_active")),
                "created_at": poll.get("created_at"),
                "updated_at": poll.get("updated_at"),
                "has_voted": has_voted,
                "can_view_results": can_view_results,
                "total_votes": voters_by_poll.get(poll_id, 0) if can_view_results else None,
                "questions": question_items,
                "options": question_items[0]["options"] if len(question_items) == 1 else [],
                "my_option_id": question_items[0].get("my_option_id") if len(question_items) == 1 else None,
            }
        )
    return items


def _albums(limit: int) -> List[Dict[str, Any]]:
    conn = db_conn()
    if not conn:
        return []
    try:
        cur = conn.cursor()
        cur.execute(
            """
            SELECT
                stats.event_id AS slug,
                COALESCE(se.name, stats.event_id) AS name,
                ep.file_path,
                ep.created_at,
                stats.photo_count
            FROM (
                SELECT event_id, MAX(id) AS max_photo_id, COUNT(*) AS photo_count
                FROM event_photos
                GROUP BY event_id
                ORDER BY MAX(id) DESC
                LIMIT %s
            ) stats
            JOIN event_photos ep ON ep.id = stats.max_photo_id
            LEFT JOIN saas_events se ON se.slug = stats.event_id
            ORDER BY ep.id DESC
            LIMIT %s
            """,
            (int(limit), int(limit)),
        )
        rows = cur.fetchall() or []
        out = []
        for r in rows:
            fp = r.get("file_path") or ""
            out.append(
                {
                    "slug": r.get("slug"),
                    "name": r.get("name"),
                    "cover": _media_url(fp),
                    "cover_thumb_url": _media_thumb_url(fp, max_side=720),
                    "photo_count": int(r.get("photo_count") or 0),
                    "created_at": r.get("created_at"),
                    "link": f"{PUBLIC_WEB_BASE}/e/{r.get('slug')}/all" if r.get("slug") else "",
                }
            )
        cur.execute(
            """
            SELECT p.id, p.image_filename, p.created_at
            FROM community_feed_posts p
            JOIN accounts a ON a.id = p.account_id
            WHERE COALESCE(p.image_filename, '') <> ''
              AND COALESCE(a.is_active, 1) = 1
            ORDER BY p.created_at DESC, p.id DESC
            LIMIT 1
            """
        )
        latest_community = cur.fetchone() or {}
        if latest_community:
            cur.execute(
                """
                SELECT COUNT(*) AS cnt
                FROM community_feed_posts p
                JOIN accounts a ON a.id = p.account_id
                WHERE COALESCE(p.image_filename, '') <> ''
                  AND COALESCE(a.is_active, 1) = 1
                """
            )
            community_count = int((cur.fetchone() or {}).get("cnt") or 0)
            image_filename = (latest_community.get("image_filename") or "").strip()
            if community_count > 0 and image_filename:
                out = [
                    {
                        "slug": COMMUNITY_ALBUM_SLUG,
                        "name": COMMUNITY_ALBUM_NAME,
                        "album_type": "community",
                        "cover": COMMUNITY_ALBUM_COVER_URL,
                        "cover_thumb_url": COMMUNITY_ALBUM_COVER_URL,
                        "photo_count": community_count,
                        "created_at": latest_community.get("created_at"),
                        "link": f"{PUBLIC_WEB_BASE}/?route=/photos/albums/{COMMUNITY_ALBUM_SLUG}",
                    },
                    *out,
                ]
        return out[: max(0, int(limit))]
    except Exception:
        return []
    finally:
        conn.close()


def _batch_albums(limit: int) -> List[Dict[str, Any]]:
    conn = db_conn()
    if not conn:
        return []
    try:
        cur = conn.cursor()
        cur.execute(
            """
            SELECT *
            FROM (
                SELECT
                    j.id AS job_id,
                    j.event_slug,
                    COALESCE(se.name, j.event_slug) AS event_name,
                    j.created_at,
                    COALESCE(j.match_start, 0) AS match_start,
                    COALESCE(j.match_end, 0) AS match_end,
                    ROW_NUMBER() OVER (PARTITION BY j.event_slug ORDER BY j.id ASC) AS part_number,
                    (
                        SELECT COUNT(*)
                        FROM event_photos ep
                        WHERE ep.event_id = j.event_slug
                          AND ep.id > COALESCE(j.match_start, 0)
                          AND ep.id <= COALESCE(j.match_end, 0)
                    ) AS photo_count,
                    (
                        SELECT ep.file_path
                        FROM event_photos ep
                        WHERE ep.event_id = j.event_slug
                          AND ep.id > COALESCE(j.match_start, 0)
                          AND ep.id <= COALESCE(j.match_end, 0)
                        ORDER BY ep.id DESC
                        LIMIT 1
                    ) AS file_path
                FROM jobs j
                LEFT JOIN saas_events se ON se.slug = j.event_slug
                WHERE j.action IN ('upload_only', 'console_upload_only')
                  AND COALESCE(j.match_end, 0) > COALESCE(j.match_start, 0)
            ) batches
            WHERE photo_count > 0
            ORDER BY job_id DESC
            LIMIT %s
            """,
            (int(limit),),
        )
        rows = cur.fetchall() or []
        out = []
        for r in rows:
            fp = r.get("file_path") or ""
            event_slug = (r.get("event_slug") or "").strip()
            job_id = int(r.get("job_id") or 0)
            part_number = int(r.get("part_number") or 0)
            event_name = (r.get("event_name") or event_slug).strip()
            out.append(
                {
                    "slug": _batch_album_slug(event_slug, job_id),
                    "name": f"{event_name} · Part {part_number}",
                    "album_type": "batch",
                    "event_slug": event_slug,
                    "event_name": event_name,
                    "job_id": job_id,
                    "part_number": part_number,
                    "cover": _media_url(fp),
                    "cover_thumb_url": _media_thumb_url(fp, max_side=720),
                    "photo_count": int(r.get("photo_count") or 0),
                    "created_at": r.get("created_at"),
                    "link": f"{PUBLIC_WEB_BASE}/e/{event_slug}/batch/{job_id}" if event_slug else "",
                }
            )
        return out
    except Exception:
        return []
    finally:
        conn.close()


def _latest(limit: int) -> List[Dict[str, Any]]:
    conn = db_conn()
    if not conn:
        return []
    try:
        cur = conn.cursor()
        cur.execute(
            """
            SELECT ep.id, ep.event_id, ep.file_path, ep.created_at, COALESCE(se.name, ep.event_id) AS event_name
            FROM event_photos ep
            LEFT JOIN saas_events se ON se.slug = ep.event_id
            ORDER BY ep.id DESC
            LIMIT %s
            """,
            (int(limit),),
        )
        rows = cur.fetchall() or []
        out = []
        for r in rows:
            fp = r.get("file_path") or ""
            out.append(
                {
                    "id": int(r.get("id") or 0),
                    "slug": r.get("event_id"),
                    "event_name": r.get("event_name"),
                    "image": _media_url(fp),
                    "thumb_url": _media_thumb_url(fp, max_side=360),
                    "grid_thumb_url": _media_thumb_url(fp, max_side=240),
                    "viewer_url": _media_thumb_url(fp, max_side=1440),
                    "created_at": r.get("created_at"),
                }
            )
        return out
    except Exception:
        return []
    finally:
        conn.close()


def _top_liked(limit: int, account_id: Optional[int]) -> List[Dict[str, Any]]:
    conn = db_conn()
    if not conn:
        return []
    try:
        cur = conn.cursor()
        cur.execute(
            """
            SELECT
                pir.photo_id,
                pir.like_count,
                ep.event_id,
                ep.file_path,
                ep.created_at,
                COALESCE(se.name, ep.event_id) AS event_name
            FROM photo_item_reactions pir
            JOIN event_photos ep ON ep.id = pir.photo_id
            LEFT JOIN saas_events se ON se.slug = ep.event_id
            WHERE pir.like_count > 0
            ORDER BY pir.like_count DESC, ep.id DESC
            LIMIT %s
            """,
            (int(limit),),
        )
        rows = cur.fetchall() or []
        photo_ids = [int(r.get("photo_id") or 0) for r in rows]
        react_map = _photo_reactions_for(conn, photo_ids, account_id) if photo_ids else {}
        favorite_ids = _photo_favorite_id_set(conn, account_id, photo_ids) if photo_ids else set()
        out = []
        for r in rows:
            fp = r.get("file_path") or ""
            pid = int(r.get("photo_id") or 0)
            rs = react_map.get(pid, {})
            out.append(
                {
                    "id": pid,
                    "slug": r.get("event_id"),
                    "event_name": r.get("event_name"),
                    "image": _media_url(fp),
                    "thumb_url": _media_thumb_url(fp, max_side=360),
                    "grid_thumb_url": _media_thumb_url(fp, max_side=240),
                    "viewer_url": _media_thumb_url(fp, max_side=1440),
                    "created_at": r.get("created_at"),
                    "like_count": int(rs.get("like_count") or r.get("like_count") or 0),
                    "liked_by_me": bool(rs.get("liked_by_me") or False),
                    "favorited_by_me": pid in favorite_ids,
                }
            )
        return out
    except Exception:
        return []
    finally:
        conn.close()


def _community_album_photos(slug: str, limit: int, offset: int = 0, viewer_account_id: Optional[int] = None) -> Dict[str, Any]:
    if not _is_community_album_slug(slug):
        return {"items": [], "total": 0}
    conn = db_conn()
    if not conn:
        return {"items": [], "total": 0}
    try:
        cur = conn.cursor()
        block_id = int(viewer_account_id or 0)
        filter_sql = """
            FROM community_feed_posts p
            JOIN accounts a ON a.id = p.account_id
            WHERE COALESCE(p.image_filename, '') <> ''
              AND COALESCE(a.is_active, 1) = 1
              AND (
                %s <= 0 OR NOT EXISTS (
                    SELECT 1
                    FROM mobile_user_blocks b
                    WHERE (b.blocker_account_id = %s AND b.blocked_account_id = p.account_id)
                       OR (b.blocker_account_id = p.account_id AND b.blocked_account_id = %s)
                )
              )
        """
        cur.execute(
            f"""
            SELECT COUNT(*) AS cnt
            {filter_sql}
            """,
            (block_id, block_id, block_id),
        )
        total = int((cur.fetchone() or {}).get("cnt") or 0)
        cur.execute(
            f"""
            SELECT
                p.id,
                p.body,
                p.image_filename,
                p.created_at
            {filter_sql}
            ORDER BY p.created_at DESC, p.id DESC
            LIMIT %s
            OFFSET %s
            """,
            (block_id, block_id, block_id, int(limit), int(offset)),
        )
        rows = cur.fetchall() or []
        out: List[Dict[str, Any]] = []
        for r in rows:
            image_filename = (r.get("image_filename") or "").strip()
            if not image_filename:
                continue
            post_id = int(r.get("id") or 0)
            photo_id = _community_photo_id(post_id)
            image_url = _feed_image_url(image_filename)
            out.append(
                {
                    "id": photo_id,
                    "post_id": post_id,
                    "image": image_url,
                    "thumb_url": image_url,
                    "grid_thumb_url": image_url,
                    "viewer_url": image_url,
                    "created_at": _hidden_sorted_created_label(r.get("created_at"), post_id),
                    "caption": (r.get("body") or "").strip(),
                    "album_slug": COMMUNITY_ALBUM_SLUG,
                    "album_name": COMMUNITY_ALBUM_NAME,
                }
            )
        return {"items": out, "total": total}
    except Exception:
        return {"items": [], "total": 0}
    finally:
        conn.close()


def _event_photos(slug: str, limit: int, offset: int = 0) -> Dict[str, Any]:
    conn = db_conn()
    if not conn:
        return {"items": [], "total": 0}
    try:
        cur = conn.cursor()
        cur.execute(
            """
            SELECT COUNT(*) AS cnt
            FROM event_photos
            WHERE event_id=%s
              AND NOT EXISTS (
                SELECT 1
                FROM jobs j
                WHERE j.event_slug = event_photos.event_id
                  AND COALESCE(j.subalbum_id, 0) > 0
                  AND event_photos.id > COALESCE(j.match_start, 0)
                  AND event_photos.id <= COALESCE(j.match_end, 0)
              )
            """,
            (slug,),
        )
        total = int((cur.fetchone() or {}).get("cnt") or 0)
        cur.execute(
            """
            SELECT id, file_path, created_at
            FROM event_photos
            WHERE event_id=%s
              AND NOT EXISTS (
                SELECT 1
                FROM jobs j
                WHERE j.event_slug = event_photos.event_id
                  AND COALESCE(j.subalbum_id, 0) > 0
                  AND event_photos.id > COALESCE(j.match_start, 0)
                  AND event_photos.id <= COALESCE(j.match_end, 0)
              )
            ORDER BY id DESC
            LIMIT %s
            OFFSET %s
            """,
            (slug, int(limit), int(offset)),
        )
        rows = cur.fetchall() or []
        out = []
        for r in rows:
            fp = r.get("file_path") or ""
            out.append(
                {
                    "id": int(r.get("id") or 0),
                    "image": _media_url(fp),
                    "thumb_url": _media_thumb_url(fp, max_side=360),
                    "grid_thumb_url": _media_thumb_url(fp, max_side=240),
                    "viewer_url": _media_thumb_url(fp, max_side=1440),
                    "created_at": r.get("created_at"),
                }
            )
        return {"items": out, "total": total}
    except Exception:
        return {"items": [], "total": 0}
    finally:
        conn.close()


def _batch_photos(event_slug: str, job_id: int, limit: int, offset: int = 0) -> Dict[str, Any]:
    conn = db_conn()
    if not conn:
        return {"items": [], "total": 0}
    try:
        cur = conn.cursor()
        cur.execute(
            """
            SELECT
                COALESCE(match_start, 0) AS match_start,
                COALESCE(match_end, 0) AS match_end
            FROM jobs
            WHERE id = %s
              AND event_slug = %s
              AND action IN ('upload_only', 'console_upload_only')
            LIMIT 1
            """,
            (int(job_id), event_slug),
        )
        job = cur.fetchone()
        if not job:
            return {"items": [], "total": 0}
        match_start = int(job.get("match_start") or 0)
        match_end = int(job.get("match_end") or 0)
        if match_end <= match_start:
            return {"items": [], "total": 0}
        cur.execute(
            """
            SELECT COUNT(*) AS cnt
            FROM event_photos
            WHERE event_id = %s
              AND id > %s
              AND id <= %s
            """,
            (event_slug, match_start, match_end),
        )
        total = int((cur.fetchone() or {}).get("cnt") or 0)
        cur.execute(
            """
            SELECT id, file_path, created_at
            FROM event_photos
            WHERE event_id = %s
              AND id > %s
              AND id <= %s
            ORDER BY id DESC
            LIMIT %s
            OFFSET %s
            """,
            (event_slug, match_start, match_end, int(limit), int(offset)),
        )
        rows = cur.fetchall() or []
        out = []
        for r in rows:
            fp = r.get("file_path") or ""
            out.append(
                {
                    "id": int(r.get("id") or 0),
                    "image": _media_url(fp),
                    "thumb_url": _media_thumb_url(fp, max_side=360),
                    "grid_thumb_url": _media_thumb_url(fp, max_side=240),
                    "viewer_url": _media_thumb_url(fp, max_side=1440),
                    "created_at": r.get("created_at"),
                }
            )
        return {"items": out, "total": total}
    except Exception:
        return {"items": [], "total": 0}
    finally:
        conn.close()


def _subalbum_photos(event_slug: str, subalbum_id: int, limit: int, offset: int = 0) -> Dict[str, Any]:
    conn = db_conn()
    if not conn:
        return {"items": [], "total": 0}
    try:
        cur = conn.cursor()
        cur.execute(
            """
            SELECT COUNT(*) AS cnt
            FROM jobs j
            JOIN event_photos ep
              ON ep.event_id = j.event_slug
             AND ep.id > COALESCE(j.match_start, 0)
             AND ep.id <= COALESCE(j.match_end, 0)
            WHERE j.event_slug = %s
              AND COALESCE(j.subalbum_id, 0) = %s
            """,
            (event_slug, int(subalbum_id)),
        )
        total = int((cur.fetchone() or {}).get("cnt") or 0)
        cur.execute(
            """
            SELECT id, file_path, created_at
            FROM event_photos
            WHERE event_id = %s
              AND id IN (
                SELECT ep.id
                FROM jobs j
                JOIN event_photos ep
                  ON ep.event_id = j.event_slug
                 AND ep.id > COALESCE(j.match_start, 0)
                 AND ep.id <= COALESCE(j.match_end, 0)
                WHERE j.event_slug = %s
                  AND COALESCE(j.subalbum_id, 0) = %s
            )
            ORDER BY id DESC
            LIMIT %s
            OFFSET %s
            """,
            (event_slug, event_slug, int(subalbum_id), int(limit), int(offset)),
        )
        rows = cur.fetchall() or []
        out = []
        for r in rows:
            fp = r.get("file_path") or ""
            out.append(
                {
                    "id": int(r.get("id") or 0),
                    "image": _media_url(fp),
                    "thumb_url": _media_thumb_url(fp, max_side=360),
                    "grid_thumb_url": _media_thumb_url(fp, max_side=240),
                    "viewer_url": _media_thumb_url(fp, max_side=1440),
                    "created_at": r.get("created_at"),
                }
            )
        return {"items": out, "total": total}
    except Exception:
        return {"items": [], "total": 0}
    finally:
        conn.close()


def _subalbums_for_event(event_slug: str) -> List[Dict[str, Any]]:
    conn = db_conn()
    if not conn:
        return []
    try:
        cur = conn.cursor()
        cur.execute(
            """
            SELECT *
            FROM (
                SELECT
                    sa.id AS subalbum_id,
                    sa.event_slug,
                    sa.name,
                    sa.created_at,
                    (
                        SELECT COUNT(*)
                        FROM jobs j
                        JOIN event_photos ep
                          ON ep.event_id = j.event_slug
                         AND ep.id > COALESCE(j.match_start, 0)
                         AND ep.id <= COALESCE(j.match_end, 0)
                        WHERE j.event_slug = sa.event_slug
                          AND COALESCE(j.subalbum_id, 0) = sa.id
                    ) AS photo_count,
                    (
                        SELECT ep.file_path
                        FROM jobs j
                        JOIN event_photos ep
                          ON ep.event_id = j.event_slug
                         AND ep.id > COALESCE(j.match_start, 0)
                         AND ep.id <= COALESCE(j.match_end, 0)
                        WHERE j.event_slug = sa.event_slug
                          AND COALESCE(j.subalbum_id, 0) = sa.id
                        ORDER BY ep.id DESC
                        LIMIT 1
                    ) AS file_path
                FROM event_subalbums sa
                WHERE sa.event_slug = %s
                  AND COALESCE(sa.is_active, 1) = 1
            ) subalbums
            WHERE photo_count > 0
            ORDER BY subalbum_id ASC
            """,
            (event_slug,),
        )
        rows = cur.fetchall() or []
        out = []
        for r in rows:
            fp = r.get("file_path") or ""
            sid = int(r.get("subalbum_id") or 0)
            out.append(
                {
                    "slug": _subalbum_album_slug(event_slug, sid),
                    "name": (r.get("name") or "").strip() or f"Alt Albüm {sid}",
                    "album_type": "subalbum",
                    "event_slug": event_slug,
                    "subalbum_id": sid,
                    "cover": _media_url(fp),
                    "cover_thumb_url": _media_thumb_url(fp, max_side=720),
                    "photo_count": int(r.get("photo_count") or 0),
                    "created_at": r.get("created_at"),
                    "link": "",
                }
            )
        return out
    except Exception:
        return []
    finally:
        conn.close()


@router.get("", summary="Fotoğraf akışı")
def list_photos(
    albums_limit: int = Query(default=20, ge=1, le=100),
    batch_limit: int = Query(default=20, ge=0, le=100),
    latest_limit: int = Query(default=60, ge=1, le=200),
    top_liked_limit: int = Query(default=20, ge=0, le=100),
    authorization: Optional[str] = Header(default=None),
):
    albums = _albums(albums_limit)
    batch_albums = _batch_albums(batch_limit) if batch_limit > 0 else []
    latest = _latest(latest_limit)
    top_liked = []
    favorites: List[Dict[str, Any]] = []
    conn = db_conn()
    account_id = None
    if conn:
        try:
            account_id = _account_id_from_auth(conn, authorization)
            album_slugs = [str(a.get("slug") or "").strip() for a in albums + batch_albums]
            album_react = _album_reactions_for(conn, album_slugs, account_id)
            latest_ids = [int(p.get("id") or 0) for p in latest]
            photo_react = _photo_reactions_for(conn, latest_ids, account_id)
            favorite_ids = _photo_favorite_id_set(conn, account_id, latest_ids)
            for a in albums + batch_albums:
                slug = str(a.get("slug") or "").strip()
                rs = album_react.get(slug, {})
                a["like_count"] = int(rs.get("like_count") or 0)
                a["liked_by_me"] = bool(rs.get("liked_by_me") or False)
            for p in latest:
                pid = int(p.get("id") or 0)
                rs = photo_react.get(pid, {})
                p["like_count"] = int(rs.get("like_count") or 0)
                p["liked_by_me"] = bool(rs.get("liked_by_me") or False)
                p["favorited_by_me"] = pid in favorite_ids
            favorites = _favorite_photo_rows(conn, account_id, limit=500, offset=0) if account_id else []
        finally:
            conn.close()
    else:
        favorites = []
    effective_top_liked_limit = max(0, min(int(top_liked_limit), 20))
    if effective_top_liked_limit > 0:
        top_liked = _top_liked(effective_top_liked_limit, account_id)
    return {
        "section": "fotograflar",
        "albums": albums,
        "batch_albums": batch_albums,
        "latest": latest,
        "top_liked": top_liked,
        "favorites": favorites,
        "stats": {
            "albums": len(albums),
            "batch_albums": len(batch_albums),
            "latest": len(latest),
            "top_liked": len(top_liked),
            "favorites": len(favorites),
        },
    }


@router.get("/albums", summary="Albüm listesi")
def list_albums(
    limit: int = Query(default=20, ge=1, le=100),
    authorization: Optional[str] = Header(default=None),
):
    items = _albums(limit) # Changed _db_conn to db_conn
    conn = _db_conn()
    if conn:
        try:
            account_id = _account_id_from_auth(conn, authorization)
            album_slugs = [str(a.get("slug") or "").strip() for a in items]
            album_react = _album_reactions_for(conn, album_slugs, account_id)
            for a in items:
                slug = str(a.get("slug") or "").strip()
                rs = album_react.get(slug, {})
                a["like_count"] = int(rs.get("like_count") or 0)
                a["liked_by_me"] = bool(rs.get("liked_by_me") or False)
        finally:
            conn.close()
    return {"section": "albumler", "items": items, "count": len(items)}


@router.get("/albums/{slug}", summary="Albüm fotoğrafları")
def album_photos(
    slug: str,
    limit: int = Query(default=200, ge=1, le=1000),
    offset: int = Query(default=0, ge=0, le=50000),
    authorization: Optional[str] = Header(default=None),
):
    batch_info = _parse_batch_album_slug(slug) # Changed _db_conn to db_conn
    subalbum_info = _parse_subalbum_album_slug(slug)
    is_community_album = _is_community_album_slug(slug)
    resolved_slug = COMMUNITY_ALBUM_SLUG if is_community_album else slug
    album_name = COMMUNITY_ALBUM_NAME if is_community_album else resolved_slug
    subalbums: List[Dict[str, Any]] = []
    conn = _db_conn()
    viewer_account_id: Optional[int] = None
    if conn:
        try:
            viewer_account_id = _account_id_from_auth(conn, authorization)
        except Exception:
            viewer_account_id = None
    if is_community_album:
        photo_data = _community_album_photos(resolved_slug, limit, offset, viewer_account_id)
    else:
        photo_data = _event_photos(slug, limit, offset)
        if batch_info:
            resolved_slug = batch_info["event_slug"]
            photo_data = _batch_photos(batch_info["event_slug"], int(batch_info["job_id"]), limit, offset)
        elif subalbum_info:
            resolved_slug = subalbum_info["event_slug"]
            photo_data = _subalbum_photos(subalbum_info["event_slug"], int(subalbum_info["subalbum_id"]), limit, offset)
        else:
            subalbums = _subalbums_for_event(slug)
    items = photo_data.get("items") or []
    total = int(photo_data.get("total") or 0)
    album_like_count = 0
    album_liked_by_me = False
    if conn:
        try:
            ars = _album_reactions_for(conn, [resolved_slug], viewer_account_id).get(resolved_slug, {})
            album_like_count = int(ars.get("like_count") or 0)
            album_liked_by_me = bool(ars.get("liked_by_me") or False)
            if subalbums:
                subalbum_slugs = [str(x.get("slug") or "").strip() for x in subalbums]
                subalbum_react = _album_reactions_for(conn, subalbum_slugs, viewer_account_id)
                for a in subalbums:
                    ars_sub = subalbum_react.get(str(a.get("slug") or "").strip(), {})
                    a["like_count"] = int(ars_sub.get("like_count") or 0)
                    a["liked_by_me"] = bool(ars_sub.get("liked_by_me") or False)
            photo_ids = [int(x.get("id") or 0) for x in items]
            photo_react = _photo_reactions_for(conn, photo_ids, viewer_account_id)
            favorite_ids = _photo_favorite_id_set(conn, viewer_account_id, photo_ids)
            for p in items:
                pid = int(p.get("id") or 0)
                prs = photo_react.get(pid, {})
                p["like_count"] = int(prs.get("like_count") or 0)
                p["liked_by_me"] = bool(prs.get("liked_by_me") or False)
                p["favorited_by_me"] = pid in favorite_ids
        finally:
            conn.close()
    return {
        "slug": resolved_slug,
        "name": album_name,
        "event_slug": resolved_slug,
        "album_type": "community" if is_community_album else ("batch" if batch_info else ("subalbum" if subalbum_info else "event")),
        "like_count": album_like_count,
        "liked_by_me": album_liked_by_me,
        "subalbums": subalbums,
        "total": total,
        "limit": int(limit),
        "offset": int(offset),
        "has_more": int(offset) + len(items) < total,
        "items": items,
    }


@router.get("/albums/{slug}/reactions", summary="Albüm beğeni bilgisi")
def album_reactions(slug: str, authorization: Optional[str] = Header(default=None)):
    conn = db_conn()
    if not conn:
        return {"album_slug": slug, "like_count": 0, "liked_by_me": False}
    try:
        account_id = _account_id_from_auth(conn, authorization)
        rs = _album_reactions_for(conn, [slug], account_id).get(slug, {})
        return {"album_slug": slug, "like_count": int(rs.get("like_count") or 0), "liked_by_me": bool(rs.get("liked_by_me") or False)}
    finally:
        conn.close()


@router.post("/albums/{slug}/like", summary="Albüm beğen")
def album_like(slug: str, authorization: Optional[str] = Header(default=None)):
    conn = _db_conn()
    if not conn: # Changed _db_conn to db_conn
        raise HTTPException(status_code=500, detail="DB bağlantısı yok")
    try:
        account_id = _require_account_id(conn, authorization)
        return _set_album_like(conn, account_id, slug, True)
    finally:
        conn.close()


@router.post("/albums/{slug}/unlike", summary="Albüm beğeniyi geri al")
def album_unlike(slug: str, authorization: Optional[str] = Header(default=None)):
    conn = _db_conn()
    if not conn: # Changed _db_conn to db_conn
        raise HTTPException(status_code=500, detail="DB bağlantısı yok")
    try:
        account_id = _require_account_id(conn, authorization)
        return _set_album_like(conn, account_id, slug, False)
    finally:
        conn.close()


@router.get("/items/{photo_id}/reactions", summary="Fotoğraf beğeni bilgisi")
def photo_reactions(photo_id: int, authorization: Optional[str] = Header(default=None)):
    conn = _db_conn()
    if not conn: # Changed _db_conn to db_conn
        return {"photo_id": int(photo_id), "like_count": 0, "liked_by_me": False}
    try:
        account_id = _account_id_from_auth(conn, authorization)
        rs = _photo_reactions_for(conn, [int(photo_id)], account_id).get(int(photo_id), {})
        return {"photo_id": int(photo_id), "like_count": int(rs.get("like_count") or 0), "liked_by_me": bool(rs.get("liked_by_me") or False)}
    finally:
        conn.close()


@router.post("/items/{photo_id}/like", summary="Fotoğraf beğen")
def photo_like(photo_id: int, authorization: Optional[str] = Header(default=None)):
    conn = _db_conn()
    if not conn: # Changed _db_conn to db_conn
        raise HTTPException(status_code=500, detail="DB bağlantısı yok")
    try:
        account_id = _require_account_id(conn, authorization)
        return _set_photo_like(conn, account_id, int(photo_id), True)
    finally:
        conn.close()


@router.post("/items/{photo_id}/unlike", summary="Fotoğraf beğeniyi geri al")
def photo_unlike(photo_id: int, authorization: Optional[str] = Header(default=None)):
    conn = _db_conn()
    if not conn: # Changed _db_conn to db_conn
        raise HTTPException(status_code=500, detail="DB bağlantısı yok")
    try:
        account_id = _require_account_id(conn, authorization)
        return _set_photo_like(conn, account_id, int(photo_id), False)
    finally:
        conn.close()


@router.get("/favorites", summary="Favori fotoğraflar")
def photo_favorites(
    limit: int = Query(default=500, ge=1, le=5000),
    offset: int = Query(default=0, ge=0, le=50000),
    authorization: Optional[str] = Header(default=None),
):
    conn = db_conn()
    if not conn:
        raise HTTPException(status_code=500, detail="DB bağlantısı yok")
    try:
        account_id = _require_account_id(conn, authorization)
        items = _favorite_photo_rows(conn, account_id, int(limit), int(offset))
        return {"ok": True, "items": items, "count": len(items)}
    finally:
        conn.close()


@router.post("/items/{photo_id}/favorite", summary="Fotoğrafı favorile")
def photo_favorite(photo_id: int, authorization: Optional[str] = Header(default=None)):
    conn = _db_conn()
    if not conn: # Changed _db_conn to db_conn
        raise HTTPException(status_code=500, detail="DB bağlantısı yok")
    try:
        account_id = _require_account_id(conn, authorization)
        return _set_photo_favorite(conn, account_id, int(photo_id), True)
    finally:
        conn.close()


@router.post("/items/{photo_id}/unfavorite", summary="Fotoğraf favorisini geri al")
def photo_unfavorite(photo_id: int, authorization: Optional[str] = Header(default=None)):
    conn = _db_conn()
    if not conn: # Changed _db_conn to db_conn
        raise HTTPException(status_code=500, detail="DB bağlantısı yok")
    try:
        account_id = _require_account_id(conn, authorization)
        return _set_photo_favorite(conn, account_id, int(photo_id), False)
    finally:
        conn.close()


@router.get("/polls", summary="Mobil anketler")
def list_photo_polls(
    include_inactive: bool = Query(default=False),
    limit: int = Query(default=50, ge=1, le=200),
    authorization: Optional[str] = Header(default=None),
):
    conn = db_conn()
    if not conn:
        raise HTTPException(status_code=500, detail="DB bağlantısı yok")
    try:
        viewer_account_id = _account_id_from_auth(conn, authorization)
        if include_inactive and _account_role(conn, viewer_account_id) != "super_admin":
            raise HTTPException(status_code=403, detail="Pasif anketleri sadece super admin gorebilir")
        items = _poll_items(
            conn,
            viewer_account_id,
            include_inactive=include_inactive,
            limit=int(limit),
        )
        return {"ok": True, "items": items, "count": len(items)}
    finally:
        conn.close()


@router.get("/polls/{poll_id}", summary="Tek anket detayı")
def get_photo_poll(
    poll_id: int,
    include_inactive: bool = Query(default=False),
    authorization: Optional[str] = Header(default=None),
):
    conn = db_conn()
    if not conn:
        raise HTTPException(status_code=500, detail="DB bağlantısı yok")
    try:
        viewer_account_id = _account_id_from_auth(conn, authorization)
        if include_inactive and _account_role(conn, viewer_account_id) != "super_admin":
            raise HTTPException(status_code=403, detail="Pasif anketleri sadece super admin gorebilir")
        items = _poll_items(
            conn,
            viewer_account_id,
            include_inactive=include_inactive,
            poll_ids=[int(poll_id)],
            limit=1,
        )
        if not items:
            raise HTTPException(status_code=404, detail="Anket bulunamadi")
        return {"ok": True, "item": items[0]}
    finally:
        conn.close()


@router.post("/polls/admin", summary="Anket oluştur")
def create_photo_poll(
    payload: PhotoPollCreateRequest,
    authorization: Optional[str] = Header(default=None),
):
    conn = db_conn()
    if not conn:
        raise HTTPException(status_code=500, detail="DB bağlantısı yok")
    try:
        account_id = _require_super_admin_account_id(conn, authorization)
        title = " ".join((payload.title or "").split()).strip()
        if len(title) < 3:
            raise HTTPException(status_code=400, detail="Anket başlığı çok kısa")
        question_payloads = payload.questions or []
        if not question_payloads:
            raise HTTPException(status_code=400, detail="En az 1 soru gerekli")
        if len(question_payloads) > 10:
            raise HTTPException(status_code=400, detail="En fazla 10 soru eklenebilir")
        cur = conn.cursor()
        cur.execute(
            """
            INSERT INTO mobile_photo_polls (
                question,
                show_results_after_vote,
                is_active,
                created_by_account_id
            )
            VALUES (%s, %s, TRUE, %s)
            RETURNING id
            """,
            (title, bool(payload.show_results_after_vote), int(account_id)),
        )
        row = cur.fetchone() or {}
        poll_id = int(row.get("id") or 0)
        for question_index, question_payload in enumerate(question_payloads):
            question_text = " ".join((question_payload.question or "").split()).strip()
            if len(question_text) < 5:
                raise HTTPException(status_code=400, detail=f"{question_index + 1}. soru çok kısa")
            option_texts = [" ".join((text or "").split()).strip() for text in (question_payload.options or [])]
            option_texts = [text for text in option_texts if text]
            if len(option_texts) < 2:
                raise HTTPException(status_code=400, detail=f"{question_index + 1}. soru için en az 2 seçenek gerekli")
            if len(option_texts) > 8:
                raise HTTPException(status_code=400, detail=f"{question_index + 1}. soru için en fazla 8 seçenek eklenebilir")
            if len(set(text.lower() for text in option_texts)) != len(option_texts):
                raise HTTPException(status_code=400, detail=f"{question_index + 1}. sorudaki seçenekler benzersiz olmalı")
            cur.execute(
                """
                INSERT INTO mobile_photo_poll_questions (poll_id, question_text, sort_order)
                VALUES (%s, %s, %s)
                RETURNING id
                """,
                (poll_id, question_text[:240], question_index),
            )
            question_id = int((cur.fetchone() or {}).get("id") or 0)
            for option_index, option_text in enumerate(option_texts):
                cur.execute(
                    """
                    INSERT INTO mobile_photo_poll_question_options (question_id, option_text, sort_order)
                    VALUES (%s, %s, %s)
                    """,
                    (question_id, option_text[:120], option_index),
                )
        conn.commit()
        items = _poll_items(conn, account_id, include_inactive=True, poll_ids=[poll_id], limit=1)
        return {"ok": True, "item": items[0] if items else None}
    finally:
        conn.close()


@router.post("/polls/{poll_id}/submit", summary="Anket cevaplarını gönder")
def submit_photo_poll(
    poll_id: int,
    payload: PhotoPollSubmitRequest,
    authorization: Optional[str] = Header(default=None),
):
    conn = db_conn()
    if not conn:
        raise HTTPException(status_code=500, detail="DB bağlantısı yok")
    try:
        account_id = _require_account_id(conn, authorization)
        _backfill_legacy_photo_polls(conn, [int(poll_id)])
        cur = conn.cursor()
        cur.execute(
            """
            SELECT id, is_active
            FROM mobile_photo_polls
            WHERE id=%s
            LIMIT 1
            """,
            (int(poll_id),),
        )
        poll_row = cur.fetchone()
        if not poll_row:
            raise HTTPException(status_code=404, detail="Anket bulunamadi")
        if poll_row.get("is_active") is False:
            raise HTTPException(status_code=400, detail="Bu anket artık yayında değil")
        cur.execute(
            "SELECT 1 FROM mobile_photo_poll_answers WHERE poll_id=%s AND account_id=%s LIMIT 1",
            (int(poll_id), int(account_id)),
        )
        if cur.fetchone():
            raise HTTPException(status_code=409, detail="Bu ankette zaten oy kullandiniz")
        cur.execute(
            """
            SELECT id
            FROM mobile_photo_poll_questions
            WHERE poll_id=%s
            ORDER BY sort_order ASC, id ASC
            """,
            (int(poll_id),),
        )
        question_ids = [int(row.get("id") or 0) for row in (cur.fetchall() or []) if int(row.get("id") or 0) > 0]
        if not question_ids:
            raise HTTPException(status_code=400, detail="Anket soruları bulunamadı")
        raw_answers = payload.answers or []
        if len(raw_answers) != len(question_ids):
            raise HTTPException(status_code=400, detail="Her soru için bir seçenek seçmelisiniz")
        answer_map: Dict[int, int] = {}
        for answer in raw_answers:
            question_id = int(answer.question_id)
            option_id = int(answer.option_id)
            if question_id in answer_map:
                raise HTTPException(status_code=400, detail="Aynı soru için birden fazla seçenek gönderildi")
            answer_map[question_id] = option_id
        if set(answer_map.keys()) != set(question_ids):
            raise HTTPException(status_code=400, detail="Eksik veya geçersiz soru cevapları gönderildi")
        cur.execute(
            """
            SELECT q.id AS question_id, o.id AS option_id
            FROM mobile_photo_poll_questions q
            JOIN mobile_photo_poll_question_options o ON o.question_id = q.id
            WHERE q.poll_id=%s
            """,
            (int(poll_id),),
        )
        valid_pairs = {
            (int(row.get("question_id") or 0), int(row.get("option_id") or 0))
            for row in (cur.fetchall() or [])
            if int(row.get("question_id") or 0) > 0 and int(row.get("option_id") or 0) > 0
        }
        for question_id, option_id in answer_map.items():
            if (question_id, option_id) not in valid_pairs:
                raise HTTPException(status_code=400, detail="Seçeneklerden biri bu soruya ait değil")
        for question_id in question_ids:
            cur.execute(
                """
                INSERT INTO mobile_photo_poll_answers (poll_id, question_id, option_id, account_id)
                VALUES (%s, %s, %s, %s)
                """,
                (int(poll_id), int(question_id), int(answer_map[question_id]), int(account_id)),
            )
        conn.commit()
        items = _poll_items(conn, account_id, include_inactive=False, poll_ids=[int(poll_id)], limit=1)
        return {"ok": True, "item": items[0] if items else None}
    finally:
        conn.close()


@router.post("/polls/{poll_id}/state", summary="Anket yayın durumunu değiştir")
def set_photo_poll_state(
    poll_id: int,
    payload: PhotoPollStateRequest,
    authorization: Optional[str] = Header(default=None),
):
    conn = db_conn()
    if not conn:
        raise HTTPException(status_code=500, detail="DB bağlantısı yok")
    try:
        account_id = _require_super_admin_account_id(conn, authorization)
        cur = conn.cursor()
        cur.execute(
            """
            UPDATE mobile_photo_polls
            SET is_active=%s, updated_at=NOW()
            WHERE id=%s
            RETURNING id
            """,
            (bool(payload.active), int(poll_id)),
        )
        if not cur.fetchone():
            raise HTTPException(status_code=404, detail="Anket bulunamadi")
        conn.commit()
        items = _poll_items(conn, account_id, include_inactive=True, poll_ids=[int(poll_id)], limit=1)
        return {"ok": True, "item": items[0] if items else None}
    finally:
        conn.close()


@router.delete("/polls/{poll_id}", summary="Anket sil")
def delete_photo_poll(
    poll_id: int,
    authorization: Optional[str] = Header(default=None),
):
    conn = db_conn()
    if not conn:
        raise HTTPException(status_code=500, detail="DB bağlantısı yok")
    try:
        _require_super_admin_account_id(conn, authorization)
        cur = conn.cursor()
        cur.execute("DELETE FROM mobile_photo_polls WHERE id=%s RETURNING id", (int(poll_id),))
        if not cur.fetchone():
            raise HTTPException(status_code=404, detail="Anket bulunamadi")
        conn.commit()
        return {"ok": True, "deleted": True, "poll_id": int(poll_id)}
    finally:
        conn.close()


@router.post("/polls/{poll_id}/vote", summary="Eski tek sorulu anket oyu")
def vote_photo_poll(
    poll_id: int,
    payload: PhotoPollVoteRequest,
    authorization: Optional[str] = Header(default=None),
):
    conn = db_conn()
    if not conn:
        raise HTTPException(status_code=500, detail="DB bağlantısı yok")
    try:
        account_id = _require_account_id(conn, authorization)
        _backfill_legacy_photo_polls(conn, [int(poll_id)])
        cur = conn.cursor()
        cur.execute(
            """
            SELECT id
            FROM mobile_photo_poll_questions
            WHERE poll_id=%s
            ORDER BY sort_order ASC, id ASC
            """,
            (int(poll_id),),
        )
        question_ids = [int(row.get("id") or 0) for row in (cur.fetchall() or []) if int(row.get("id") or 0) > 0]
        if len(question_ids) != 1:
            raise HTTPException(status_code=400, detail="Bu anket için uygulamayı güncelleyin")
        return submit_photo_poll(
            int(poll_id),
            PhotoPollSubmitRequest(
                answers=[
                    PhotoPollSubmitAnswerRequest(
                        question_id=int(question_ids[0]),
                        option_id=int(payload.option_id),
                    )
                ]
            ),
            authorization,
        )
    finally:
        conn.close()


@router.get("/feed", summary="Topluluk akışı")
def list_feed_posts(
    limit: int = Query(default=30, ge=1, le=60),
    offset: int = Query(default=0, ge=0, le=500),
    authorization: Optional[str] = Header(default=None),
):
    conn = db_conn()
    if not conn:
        raise HTTPException(status_code=500, detail="DB bağlantısı yok")
    try:
        viewer_account_id = _account_id_from_auth(conn, authorization)
        items = _fetch_feed_items(conn, viewer_account_id, int(limit), int(offset))
        return {"ok": True, "items": items, "count": len(items)}
    finally:
        conn.close()


@router.post("/feed/posts", summary="Akışa gönderi ekle")
async def create_feed_post(
    text: str = Form(default=""),
    image: Optional[UploadFile] = File(default=None),
    target_route: str = Form(default=""),
    authorization: Optional[str] = Header(default=None),
):
    conn = db_conn()
    if not conn:
        raise HTTPException(status_code=500, detail="DB bağlantısı yok")
    try:
        account_id = _require_account_id(conn, authorization)
        _enforce_daily_feed_post_limit(conn, account_id)
        body = (text or "").strip()
        safe_target_route = (target_route or "").strip()
        if safe_target_route and not safe_target_route.startswith("/"):
            safe_target_route = ""
        if len(safe_target_route) > 500:
            safe_target_route = safe_target_route[:500]
        if len(body) > 2000:
            raise HTTPException(status_code=400, detail="Metin çok uzun (max 2000 karakter)")
        image_filename = ""
        if image is not None:
            if not _feed_file_allowed(image):
                raise HTTPException(status_code=400, detail="Sadece jpg/png/webp/heic/heif desteklenir")
            raw = await image.read()
            if not raw:
                raise HTTPException(status_code=400, detail="Boş dosya")
            if len(raw) > 12 * 1024 * 1024:
                raise HTTPException(status_code=400, detail="Dosya çok büyük (max 12MB)")
            os.makedirs(COMMUNITY_FEED_DIR, exist_ok=True)
            image_filename = f"{int(account_id)}_{uuid.uuid4().hex}.jpg"
            image_path = os.path.join(COMMUNITY_FEED_DIR, image_filename)
            jpeg_data = _convert_feed_image_to_jpeg_bytes(raw)
            with open(image_path, "wb") as f:
                f.write(jpeg_data)
        if not body and not image_filename:
            raise HTTPException(status_code=400, detail="Metin veya görsel gerekli")
        cur = conn.cursor()
        cur.execute(
            """
            INSERT INTO community_feed_posts (account_id, body, image_filename, target_route)
            VALUES (%s, %s, %s, %s)
            RETURNING id
            """,
            (int(account_id), body, image_filename, safe_target_route),
        )
        row = cur.fetchone() or {}
        conn.commit()
        post_id = int(row.get("id") or 0)
        items = _fetch_feed_posts_by_ids(conn, [post_id], int(account_id))
        if not items:
            raise HTTPException(status_code=500, detail="Gönderi oluşturuldu ancak okunamadı")
        return {"ok": True, "item": items[0]}
    finally:
        conn.close()


@router.get("/feed/posts/{post_id}", summary="Akış gönderisi detayı")
def get_feed_post(
    post_id: int,
    authorization: Optional[str] = Header(default=None),
):
    conn = db_conn()
    if not conn:
        raise HTTPException(status_code=500, detail="DB bağlantısı yok")
    try:
        viewer_account_id = _account_id_from_auth(conn, authorization)
        items = _fetch_feed_posts_by_ids(conn, [int(post_id)], int(viewer_account_id or 0))
        if not items:
            raise HTTPException(status_code=404, detail="Gönderi bulunamadı")
        return {"ok": True, "item": items[0]}
    finally:
        conn.close()


@router.get("/feed/media/{filename}", summary="Akış görseli")
def get_feed_media(filename: str):
    cleaned = re.sub(r"[^a-zA-Z0-9._-]+", "", filename)
    if not cleaned or cleaned != filename:
        raise HTTPException(status_code=400, detail="Geçersiz dosya adı")
    path = os.path.join(COMMUNITY_FEED_DIR, cleaned)
    if not os.path.isfile(path):
        raise HTTPException(status_code=404, detail="Dosya bulunamadı")
    return FileResponse(path, media_type="image/jpeg")


@router.post("/feed/posts/{post_id}/like", summary="Akış gönderisini beğen")
def like_feed_post(post_id: int, authorization: Optional[str] = Header(default=None)):
    conn = _db_conn()
    if not conn: # Changed _db_conn to db_conn
        raise HTTPException(status_code=500, detail="DB bağlantısı yok")
    try:
        account_id = _require_account_id(conn, authorization)
        item = _set_feed_post_like(conn, account_id, int(post_id), True)
        return {"ok": True, "item": item}
    finally:
        conn.close()


@router.post("/feed/posts/{post_id}/unlike", summary="Akış gönderisi beğenisini geri al")
def unlike_feed_post(post_id: int, authorization: Optional[str] = Header(default=None)):
    conn = _db_conn()
    if not conn: # Changed _db_conn to db_conn
        raise HTTPException(status_code=500, detail="DB bağlantısı yok")
    try:
        account_id = _require_account_id(conn, authorization)
        item = _set_feed_post_like(conn, account_id, int(post_id), False)
        return {"ok": True, "item": item}
    finally:
        conn.close()


@router.post("/feed/posts/{post_id}/replies", summary="Akış gönderisine yazılı yanıt ekle")
def create_feed_reply(
    post_id: int,
    payload: FeedReplyCreateRequest,
    authorization: Optional[str] = Header(default=None),
):
    conn = db_conn()
    if not conn:
        raise HTTPException(status_code=500, detail="DB bağlantısı yok")
    try:
        account_id = _require_account_id(conn, authorization)
        body = (payload.text or "").strip()
        if not body:
            raise HTTPException(status_code=400, detail="Yanıt metni gerekli")
        cur = conn.cursor()
        cur.execute("SELECT 1 FROM community_feed_posts WHERE id=%s LIMIT 1", (int(post_id),))
        if not cur.fetchone():
            raise HTTPException(status_code=404, detail="Gönderi bulunamadı")
        cur.execute(
            """
            INSERT INTO community_feed_replies (post_id, account_id, body)
            VALUES (%s, %s, %s)
            RETURNING id
            """,
            (int(post_id), int(account_id), body[:500]),
        )
        cur.fetchone()
        cur.execute(
            """
            UPDATE community_feed_posts
            SET reply_count = reply_count + 1, updated_at = NOW()
            WHERE id=%s
            """,
            (int(post_id),),
        )
        _notify_feed_post_owner(
            conn,
            actor_account_id=int(account_id),
            post_id=int(post_id),
            action="reply",
            reply_text=body[:500],
        )
        conn.commit()
        items = _fetch_feed_posts_by_ids(conn, [int(post_id)], int(account_id))
        if not items:
            raise HTTPException(status_code=404, detail="Gönderi bulunamadı")
        return {"ok": True, "item": items[0]}
    finally:
        conn.close()


@router.delete("/feed/posts/{post_id}", summary="Akış gönderisini sil")
def delete_feed_post(post_id: int, authorization: Optional[str] = Header(default=None)):
    conn = _db_conn()
    if not conn: # Changed _db_conn to db_conn
        raise HTTPException(status_code=500, detail="DB bağlantısı yok")
    try:
        requester_id = _require_account_id(conn, authorization)
        requester_role = _account_role(conn, requester_id)
        cur = conn.cursor()
        cur.execute(
            """
            SELECT account_id, image_filename
            FROM community_feed_posts
            WHERE id=%s
            LIMIT 1
            """,
            (int(post_id),),
        )
        row = cur.fetchone() or {}
        if not row:
            raise HTTPException(status_code=404, detail="Gönderi bulunamadı")
        owner_account_id = int(row.get("account_id") or 0)
        if requester_role != "super_admin" and owner_account_id != requester_id:
            raise HTTPException(status_code=403, detail="Sadece kendi gönderini silebilirsin")
        image_filename = re.sub(r"[^a-zA-Z0-9._-]+", "", (row.get("image_filename") or "").strip())
        cur.execute("DELETE FROM community_feed_posts WHERE id=%s", (int(post_id),))
        conn.commit()
        if image_filename:
            image_path = os.path.join(COMMUNITY_FEED_DIR, image_filename)
            try:
                if os.path.isfile(image_path):
                    os.remove(image_path)
            except Exception:
                pass
        return {"ok": True, "deleted": True, "post_id": int(post_id)}
    finally:
        conn.close()
