import os
import re
from datetime import datetime
from typing import Any, Dict, List

import httpx
import psycopg2
import psycopg2.extras
from fastapi import APIRouter, Query

router = APIRouter(prefix="/discover", tags=["Keşfet"])

WP_BASE = os.getenv("WP_BASE_URL", "https://www.dansmagazin.net").rstrip("/")
DATABASE_URL = os.getenv("DATABASE_URL", "").strip()
PUBLIC_MEDIA_BASE = os.getenv("PUBLIC_MEDIA_BASE", "https://foto.dansmagazin.net").rstrip("/")


def _strip_html(text: str) -> str:
    return re.sub(r"<[^>]*>", "", text or "").strip()


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


def _db_conn():
    if not DATABASE_URL:
        return None
    return psycopg2.connect(
        DATABASE_URL,
        connect_timeout=3,
        cursor_factory=psycopg2.extras.RealDictCursor,
    )


def _fetch_upcoming_events(limit: int = 12) -> List[Dict[str, Any]]:
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
            SELECT se.id, se.slug, se.name, se.created_at,
                   (
                     SELECT ep.file_path
                     FROM event_photos ep
                     WHERE ep.event_id = se.slug
                     ORDER BY ep.id DESC
                     LIMIT 1
                   ) AS cover_path
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
            cover_path = (r.get("cover_path") or "").lstrip("/")
            cover = f"{PUBLIC_MEDIA_BASE}/{cover_path}" if cover_path else ""
            out.append(
                {
                    "id": r.get("id"),
                    "slug": r.get("slug"),
                    "name": r.get("name"),
                    "date": r.get("created_at"),
                    "cover": cover,
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
            SELECT se.slug, se.name, ep.file_path, ep.created_at
            FROM event_photos ep
            JOIN saas_events se ON se.slug = ep.event_id
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
    events = _fetch_upcoming_events(limit=events_limit)
    albums = _fetch_latest_albums(limit=albums_limit)
    return {
        "section": "kesfet",
        "generated_at": datetime.utcnow().isoformat(timespec="seconds") + "Z",
        "news": news,
        "upcoming_events": events,
        "latest_albums": albums,
    }
