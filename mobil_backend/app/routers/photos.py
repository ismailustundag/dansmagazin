import os
from typing import Any, Dict, List, Optional

import psycopg2
import psycopg2.extras
from fastapi import APIRouter, Header, HTTPException, Query

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


def init_photo_reaction_tables():
    conn = _db_conn()
    if not conn:
        return
    try:
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
    cur = conn.cursor()
    cur.execute(
        "SELECT photo_id, like_count FROM photo_item_reactions WHERE photo_id = ANY(%s)",
        (clean,),
    )
    for r in cur.fetchall() or []:
        pid = int(r.get("photo_id") or 0)
        if pid <= 0:
            continue
        out.setdefault(pid, {"like_count": 0, "liked_by_me": False})
        out[pid]["like_count"] = int(r.get("like_count") or 0)
    if account_id:
        cur.execute(
            "SELECT photo_id FROM photo_item_user_likes WHERE account_id=%s AND photo_id = ANY(%s)",
            (int(account_id), clean),
        )
        for r in cur.fetchall() or []:
            pid = int(r.get("photo_id") or 0)
            if pid > 0:
                out.setdefault(pid, {"like_count": 0, "liked_by_me": False})
                out[pid]["liked_by_me"] = True
    return out


def _album_like_count(conn, slug: str) -> int:
    cur = conn.cursor()
    cur.execute("SELECT like_count FROM photo_album_reactions WHERE album_slug=%s", (slug,))
    row = cur.fetchone()
    return int((row or {}).get("like_count") or 0)


def _photo_like_count(conn, photo_id: int) -> int:
    cur = conn.cursor()
    cur.execute("SELECT like_count FROM photo_item_reactions WHERE photo_id=%s", (int(photo_id),))
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
    cur = conn.cursor()
    cur.execute(
        "INSERT INTO photo_item_reactions (photo_id, like_count) VALUES (%s, 0) ON CONFLICT (photo_id) DO NOTHING",
        (int(photo_id),),
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
            (int(account_id), int(photo_id)),
        )
        changed = bool(cur.fetchone())
        if changed:
            cur.execute(
                """
                UPDATE photo_item_reactions
                SET like_count = like_count + 1, updated_at = NOW()
                WHERE photo_id=%s
                """,
                (int(photo_id),),
            )
    else:
        cur.execute(
            "DELETE FROM photo_item_user_likes WHERE account_id=%s AND photo_id=%s RETURNING account_id",
            (int(account_id), int(photo_id)),
        )
        changed = bool(cur.fetchone())
        if changed:
            cur.execute(
                """
                UPDATE photo_item_reactions
                SET like_count = GREATEST(0, like_count - 1), updated_at = NOW()
                WHERE photo_id=%s
                """,
                (int(photo_id),),
            )
    conn.commit()
    return {"photo_id": int(photo_id), "like_count": _photo_like_count(conn, int(photo_id)), "liked_by_me": like if changed else like}


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
    authorization: Optional[str] = Header(default=None),
):
    albums = _albums(albums_limit)
    latest = _latest(latest_limit)
    conn = _db_conn()
    account_id = None
    if conn:
        try:
            account_id = _account_id_from_auth(conn, authorization)
            album_slugs = [str(a.get("slug") or "").strip() for a in albums]
            album_react = _album_reactions_for(conn, album_slugs, account_id)
            latest_ids = [int(p.get("id") or 0) for p in latest]
            photo_react = _photo_reactions_for(conn, latest_ids, account_id)
            for a in albums:
                slug = str(a.get("slug") or "").strip()
                rs = album_react.get(slug, {})
                a["like_count"] = int(rs.get("like_count") or 0)
                a["liked_by_me"] = bool(rs.get("liked_by_me") or False)
            for p in latest:
                pid = int(p.get("id") or 0)
                rs = photo_react.get(pid, {})
                p["like_count"] = int(rs.get("like_count") or 0)
                p["liked_by_me"] = bool(rs.get("liked_by_me") or False)
        finally:
            conn.close()
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
def album_photos(
    slug: str,
    limit: int = Query(default=200, ge=1, le=1000),
    authorization: Optional[str] = Header(default=None),
):
    items = _event_photos(slug, limit)
    conn = _db_conn()
    album_like_count = 0
    album_liked_by_me = False
    if conn:
        try:
            account_id = _account_id_from_auth(conn, authorization)
            ars = _album_reactions_for(conn, [slug], account_id).get(slug, {})
            album_like_count = int(ars.get("like_count") or 0)
            album_liked_by_me = bool(ars.get("liked_by_me") or False)
            photo_ids = [int(x.get("id") or 0) for x in items]
            photo_react = _photo_reactions_for(conn, photo_ids, account_id)
            for p in items:
                pid = int(p.get("id") or 0)
                prs = photo_react.get(pid, {})
                p["like_count"] = int(prs.get("like_count") or 0)
                p["liked_by_me"] = bool(prs.get("liked_by_me") or False)
        finally:
            conn.close()
    return {
        "slug": slug,
        "like_count": album_like_count,
        "liked_by_me": album_liked_by_me,
        "items": items,
    }


@router.get("/albums/{slug}/reactions", summary="Albüm beğeni bilgisi")
def album_reactions(slug: str, authorization: Optional[str] = Header(default=None)):
    conn = _db_conn()
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
    if not conn:
        raise HTTPException(status_code=500, detail="DB bağlantısı yok")
    try:
        account_id = _require_account_id(conn, authorization)
        return _set_album_like(conn, account_id, slug, True)
    finally:
        conn.close()


@router.post("/albums/{slug}/unlike", summary="Albüm beğeniyi geri al")
def album_unlike(slug: str, authorization: Optional[str] = Header(default=None)):
    conn = _db_conn()
    if not conn:
        raise HTTPException(status_code=500, detail="DB bağlantısı yok")
    try:
        account_id = _require_account_id(conn, authorization)
        return _set_album_like(conn, account_id, slug, False)
    finally:
        conn.close()


@router.get("/items/{photo_id}/reactions", summary="Fotoğraf beğeni bilgisi")
def photo_reactions(photo_id: int, authorization: Optional[str] = Header(default=None)):
    conn = _db_conn()
    if not conn:
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
    if not conn:
        raise HTTPException(status_code=500, detail="DB bağlantısı yok")
    try:
        account_id = _require_account_id(conn, authorization)
        return _set_photo_like(conn, account_id, int(photo_id), True)
    finally:
        conn.close()


@router.post("/items/{photo_id}/unlike", summary="Fotoğraf beğeniyi geri al")
def photo_unlike(photo_id: int, authorization: Optional[str] = Header(default=None)):
    conn = _db_conn()
    if not conn:
        raise HTTPException(status_code=500, detail="DB bağlantısı yok")
    try:
        account_id = _require_account_id(conn, authorization)
        return _set_photo_like(conn, account_id, int(photo_id), False)
    finally:
        conn.close()
