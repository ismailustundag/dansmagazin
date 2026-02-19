import os
import re
from datetime import datetime
from typing import Any, Dict, List

import httpx
import psycopg2
import psycopg2.extras
from fastapi import APIRouter, HTTPException, Query

router = APIRouter(prefix="/discover", tags=["Keşfet"])

WP_BASE = os.getenv("WP_BASE_URL", "https://www.dansmagazin.net").rstrip("/")
DATABASE_URL = os.getenv("DATABASE_URL", "").strip()
PUBLIC_MEDIA_BASE = os.getenv("PUBLIC_MEDIA_BASE", "https://foto.dansmagazin.net").rstrip("/")
PUBLIC_WEB_BASE = os.getenv("PUBLIC_WEB_BASE", "https://foto.dansmagazin.net").rstrip("/")
PUBLIC_API_BASE = os.getenv("PUBLIC_API_BASE", "https://api2.dansmagazin.net").rstrip("/")
MOBILE_UPLOAD_DIR = "/home/ubuntu/mobil_backend/media/submission_covers"
ALT_UPLOAD_DIR = "/home/ubuntu/etkinlik_fotograf_projesi/media/submission_covers"


def _strip_html(text: str) -> str:
    return re.sub(r"<[^>]*>", "", text or "").strip()


def _submission_cover_exists(path: str) -> bool:
    if not path:
        return False
    bn = os.path.basename(path)
    return os.path.exists(os.path.join(MOBILE_UPLOAD_DIR, bn)) or os.path.exists(os.path.join(ALT_UPLOAD_DIR, bn))


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


def _parse_wp_item(item: Dict[str, Any]) -> Dict[str, Any]:
    image_url = ""
    emb = item.get("_embedded") or {}
    media_arr = emb.get("wp:featuredmedia") or []
    if media_arr and isinstance(media_arr, list):
        media = media_arr[0] or {}
        image_url = (
            (media.get("media_details") or {}).get("sizes", {}).get("medium_large", {}).get("source_url")
            or (media.get("source_url") or "")
        )
    return {
        "id": item.get("id"),
        "title": ((item.get("title") or {}).get("rendered") or "").strip(),
        "excerpt": _strip_html((item.get("excerpt") or {}).get("rendered") or ""),
        "date": item.get("date"),
        "link": item.get("link"),
        "image": image_url,
    }


def _extract_wp_terms(item: Dict[str, Any]) -> List[str]:
    emb = item.get("_embedded") or {}
    term_groups = emb.get("wp:term") or []
    terms: List[str] = []
    for grp in term_groups:
        if not isinstance(grp, list):
            continue
        for t in grp:
            if not isinstance(t, dict):
                continue
            name = (t.get("name") or "").strip().lower()
            slug = (t.get("slug") or "").strip().lower()
            if name:
                terms.append(name)
            if slug:
                terms.append(slug)
    return terms


def _is_event_post(item: Dict[str, Any]) -> bool:
    keys = set(_extract_wp_terms(item))
    text = (
        ((item.get("title") or {}).get("rendered") or "")
        + " "
        + ((item.get("excerpt") or {}).get("rendered") or "")
    ).lower()
    for kw in ("event", "etkinlik", "festival", "workshop", "kamp", "congress"):
        if kw in text:
            return True
    for kw in ("event", "events", "etkinlik", "festival", "workshop", "kongre", "bilet"):
        if any(kw in v for v in keys):
            return True
    return False


async def _fetch_wp_news(limit: int = 24) -> List[Dict[str, Any]]:
    items: List[Dict[str, Any]] = []
    page = 1
    remaining = max(1, min(limit, 60))
    try:
        async with httpx.AsyncClient(timeout=8.0) as client:
            while remaining > 0:
                per_page = 20 if remaining > 20 else remaining
                url = f"{WP_BASE}/wp-json/wp/v2/posts"
                params = {"_embed": "1", "orderby": "date", "order": "desc", "page": page, "per_page": per_page}
                resp = await client.get(url, params=params)
                if resp.status_code != 200:
                    break
                arr = resp.json()
                if not arr:
                    break
                parsed = [_parse_wp_item(x) for x in arr]
                items.extend(parsed)
                remaining -= len(parsed)
                if len(arr) < per_page:
                    break
                page += 1
    except Exception:
        return items
    return items


async def _fetch_wp_post_detail(post_id: int) -> Dict[str, Any]:
    url = f"{WP_BASE}/wp-json/wp/v2/posts/{int(post_id)}"
    params = {"_embed": "1"}
    async with httpx.AsyncClient(timeout=10.0) as client:
        resp = await client.get(url, params=params)
    if resp.status_code == 404:
        raise HTTPException(status_code=404, detail="Haber bulunamadı")
    if resp.status_code != 200:
        raise HTTPException(status_code=502, detail=f"WordPress hata: {resp.status_code}")
    item = resp.json()
    base = _parse_wp_item(item)
    base["content_html"] = ((item.get("content") or {}).get("rendered") or "").strip()
    return base


async def _fetch_wp_events(limit: int = 12) -> List[Dict[str, Any]]:
    out: List[Dict[str, Any]] = []
    page = 1
    max_scan = 60
    async with httpx.AsyncClient(timeout=8.0) as client:
        while len(out) < limit and max_scan > 0:
            per_page = 20
            url = f"{WP_BASE}/wp-json/wp/v2/posts"
            params = {"_embed": "1", "orderby": "date", "order": "desc", "page": page, "per_page": per_page}
            resp = await client.get(url, params=params)
            if resp.status_code != 200:
                break
            arr = resp.json()
            if not arr:
                break
            for item in arr:
                if _is_event_post(item):
                    parsed = _parse_wp_item(item)
                    out.append(
                        {
                            "id": parsed["id"],
                            "slug": str(parsed["id"]),
                            "name": parsed["title"],
                            "date": parsed["date"],
                            "cover": parsed["image"],
                            "link": parsed["link"],
                        }
                    )
                    if len(out) >= limit:
                        break
                max_scan -= 1
                if max_scan <= 0:
                    break
            if len(arr) < per_page:
                break
            page += 1
    return out[:limit]


def _db_conn():
    if not DATABASE_URL:
        return None
    return psycopg2.connect(
        DATABASE_URL,
        connect_timeout=3,
        cursor_factory=psycopg2.extras.RealDictCursor,
    )


def _fetch_upcoming_events_db(limit: int = 12) -> List[Dict[str, Any]]:
    try:
        conn = _db_conn()
    except Exception:
        return []
    if not conn:
        return []
    try:
        cur = conn.cursor()
        # Not: mevcut şemada etkinlik tarih alanı olmadığı için en yeni aktif etkinlikler listeleniyor.
        cur.execute(
            """
            SELECT se.id, se.slug, se.name, se.created_at, se.ticket_url,
                   (
                     SELECT ep.file_path
                     FROM event_photos ep
                     WHERE ep.event_id = se.slug
                     ORDER BY ep.id DESC
                     LIMIT 1
                   ) AS cover_path,
                   (
                     SELECT mes.cover_path
                     FROM mobile_event_submissions mes
                     WHERE mes.approved_event_slug = se.slug
                     ORDER BY mes.id DESC
                     LIMIT 1
                   ) AS submission_cover_path
            FROM saas_events se
            WHERE COALESCE(se.is_active, 1) = 1
            ORDER BY se.id DESC
            LIMIT %s
            """,
            (int(limit),),
        )
        rows = cur.fetchall() or []
        out = []
        for r in rows:
            photo_cover_path = _norm_media_path(r.get("cover_path") or "")
            submission_cover = (r.get("submission_cover_path") or "").strip()
            if submission_cover:
                # Mobil etkinlikte kapak kaynağı submission cover'dır; yanlış kapak göstermemek için
                # dosya yoksa boş bırakıyoruz.
                cover = (
                    f"{PUBLIC_API_BASE}/events/submission-cover/{os.path.basename(submission_cover)}"
                    if _submission_cover_exists(submission_cover)
                    else ""
                )
            else:
                cover = _media_url(photo_cover_path)
            ticket_url = (r.get("ticket_url") or "").strip()
            out.append(
                {
                    "id": 0,
                    "slug": r.get("slug"),
                    "name": r.get("name"),
                    "date": r.get("created_at"),
                    "cover": cover,
                    # Mobil keşfette sadece bilet linki gösterilir; fotoğraf kayıt sayfasına düşmesin.
                    "link": ticket_url,
                }
            )
        return out
    finally:
        conn.close()


def _fetch_latest_albums(limit: int = 6) -> List[Dict[str, Any]]:
    try:
        conn = _db_conn()
    except Exception:
        return []
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
            file_path = (r.get("file_path") or "").lstrip("/")
            cover = _media_url(file_path)
            out.append(
                {
                    "slug": r.get("slug"),
                    "name": r.get("name"),
                    "cover": cover,
                    "created_at": r.get("created_at"),
                    "photo_count": int(r.get("photo_count") or 0),
                    "link": f"{PUBLIC_WEB_BASE}/e/{r.get('slug')}/all" if r.get("slug") else "",
                }
            )
        return out
    finally:
        conn.close()


def _fetch_latest_albums_old(limit: int = 6) -> List[Dict[str, Any]]:
    """
    Legacy fallback; kept for quick rollback.
    """
    try:
        conn = _db_conn()
    except Exception:
        return []
    if not conn:
        return []
    try:
        cur = conn.cursor()
        cur.execute(
            """
            SELECT se.slug, se.name, ep.file_path, ep.created_at
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
            file_path = (r.get("file_path") or "").lstrip("/")
            cover = f"{PUBLIC_MEDIA_BASE}/{file_path}" if file_path else ""
            out.append(
                {
                    "slug": r.get("slug"),
                    "name": r.get("name"),
                    "cover": cover,
                    "created_at": r.get("created_at"),
                }
            )
        return out
    finally:
        conn.close()


@router.get("", summary="Keşfet ana içerikleri")
async def discover_home(
    news_limit: int = Query(default=24, ge=1, le=60),
    events_limit: int = Query(default=12, ge=1, le=30),
    albums_limit: int = Query(default=6, ge=1, le=12),
):
    news = await _fetch_wp_news(limit=news_limit)
    try:
        events = await _fetch_wp_events(limit=events_limit)
    except Exception:
        events = []
    if not events:
        events = _fetch_upcoming_events_db(limit=events_limit)
    albums = _fetch_latest_albums(limit=albums_limit)
    return {
        "section": "kesfet",
        "generated_at": datetime.utcnow().isoformat(timespec="seconds") + "Z",
        "news": news,
        "upcoming_events": events,
        "latest_albums": albums,
    }


@router.get("/news/{post_id}", summary="WordPress haber detayı")
async def discover_news_detail(post_id: int):
    return await _fetch_wp_post_detail(post_id)
