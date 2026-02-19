import os
from typing import Any, Dict, List

import psycopg2
import psycopg2.extras
from fastapi import APIRouter, Query

router = APIRouter(prefix="/photos", tags=["Fotoğraflar"])

DATABASE_URL = os.getenv("DATABASE_URL", "").strip()
PUBLIC_MEDIA_BASE = os.getenv("PUBLIC_MEDIA_BASE", "https://foto.dansmagazin.net").rstrip("/")
PUBLIC_WEB_BASE = os.getenv("PUBLIC_WEB_BASE", "https://foto.dansmagazin.net").rstrip("/")


def _db_conn():
    if not DATABASE_URL:
        return None
    return psycopg2.connect(
        DATABASE_URL,
        connect_timeout=3,
        cursor_factory=psycopg2.extras.RealDictCursor,
    )


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


def _albums(limit: int) -> List[Dict[str, Any]]:
    conn = _db_conn()
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
                    "photo_count": int(r.get("photo_count") or 0),
                    "created_at": r.get("created_at"),
                    "link": f"{PUBLIC_WEB_BASE}/e/{r.get('slug')}/all" if r.get("slug") else "",
                }
            )
        return out
    except Exception:
        return []
    finally:
        conn.close()


def _latest(limit: int) -> List[Dict[str, Any]]:
    conn = _db_conn()
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
                    "created_at": r.get("created_at"),
                }
            )
        return out
    except Exception:
        return []
    finally:
        conn.close()


def _event_photos(slug: str, limit: int) -> List[Dict[str, Any]]:
    conn = _db_conn()
    if not conn:
        return []
    try:
        cur = conn.cursor()
        cur.execute(
            """
            SELECT id, file_path, created_at
            FROM event_photos
            WHERE event_id=%s
            ORDER BY id DESC
            LIMIT %s
            """,
            (slug, int(limit)),
        )
        rows = cur.fetchall() or []
        out = []
        for r in rows:
            fp = r.get("file_path") or ""
            out.append(
                {
                    "id": int(r.get("id") or 0),
                    "image": _media_url(fp),
                    "created_at": r.get("created_at"),
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
    latest_limit: int = Query(default=60, ge=1, le=200),
):
    albums = _albums(albums_limit)
    latest = _latest(latest_limit)
    return {
        "section": "fotograflar",
        "albums": albums,
        "latest": latest,
        "favorites": [],
        "stats": {
            "albums": len(albums),
            "latest": len(latest),
            "favorites": 0,
        },
    }


@router.get("/albums/{slug}", summary="Albüm fotoğrafları")
def album_photos(slug: str, limit: int = Query(default=200, ge=1, le=1000)):
    return {
        "slug": slug,
        "items": _event_photos(slug, limit),
    }
