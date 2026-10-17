from __future__ import annotations

import os
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime
from pathlib import Path
from typing import Any, Callable, Dict, Optional
from urllib.parse import urlparse

from fastapi import APIRouter, File, Form, HTTPException, Query, Request, UploadFile
from fastapi.responses import FileResponse, RedirectResponse


BackendCall = Callable[..., Dict[str, Any]]
AccountGuard = Callable[[Request], Any]
DbFactory = Callable[[], Any]
PasswordHasher = Callable[[str], str]


def build_admin_v2_router(
    *,
    require_super_admin: AccountGuard,
    db_conn: DbFactory,
    bearer_call: BackendCall,
    bearer_form_call: BackendCall,
    bearer_multipart_call: BackendCall,
    admin_call: BackendCall,
    hash_password: PasswordHasher,
    session_cookie: str,
) -> APIRouter:
    router = APIRouter()
    dist_dir = Path(__file__).resolve().parent / "admin_v2_dist"

    def require_account(request: Request) -> Dict[str, Any]:
        row = require_super_admin(request)
        return dict(row)

    def session_token(request: Request) -> str:
        token = (request.cookies.get(session_cookie) or "").strip()
        if not token:
            raise HTTPException(status_code=401, detail="Oturum tokeni bulunamadi")
        return token

    def require_same_origin(request: Request) -> None:
        if request.headers.get("x-dmz-request") != "admin-v2":
            raise HTTPException(status_code=403, detail="Gecersiz istek kaynagi")
        origin = (request.headers.get("origin") or "").strip()
        if origin and urlparse(origin).netloc != request.url.netloc:
            raise HTTPException(status_code=403, detail="Farkli kaynaktan istek reddedildi")

    def unwrap(result: Dict[str, Any], fallback: str) -> Any:
        if not result.get("ok"):
            raise HTTPException(status_code=502, detail=str(result.get("error") or fallback))
        return result.get("data") or {}

    def bearer(request: Request, path: str, method: str = "GET", payload: Optional[Dict[str, Any]] = None) -> Any:
        return unwrap(
            bearer_call(path, session_token(request), method=method, json_data=payload),
            "Mobil backend yanit vermedi",
        )

    def query_scalar(sql: str, params: tuple[Any, ...] = ()) -> int:
        conn = db_conn()
        try:
            cur = conn.cursor()
            cur.execute(sql, params)
            row = cur.fetchone()
            return int(row[0] if row else 0)
        finally:
            conn.close()

    def paged_users(q: str, role: str, page: int, page_size: int) -> Dict[str, Any]:
        where = []
        params: list[Any] = []
        if role != "all":
            where.append("LOWER(COALESCE(a.role,''))=?")
            params.append(role)
        if q:
            like = f"%{q.lower()}%"
            where.append(
                "(LOWER(COALESCE(a.email,'')) LIKE ? OR LOWER(COALESCE(a.name,'')) LIKE ? "
                "OR LOWER(COALESCE(mps.username,'')) LIKE ? OR CAST(a.id AS TEXT) LIKE ?)"
            )
            params.extend([like, like, like, like])
        where_sql = f" WHERE {' AND '.join(where)}" if where else ""
        offset = (page - 1) * page_size
        conn = db_conn()
        try:
            cur = conn.cursor()
            cur.execute(
                f"""
                SELECT COUNT(*)
                FROM accounts a
                LEFT JOIN mobile_profile_settings mps ON mps.account_id=a.id
                {where_sql}
                """,
                tuple(params),
            )
            total_row = cur.fetchone()
            total = int(total_row[0] if total_row else 0)
            cur.execute(
                f"""
                SELECT
                    a.id, COALESCE(a.name,'') AS name, a.email,
                    COALESCE(a.role,'customer') AS role,
                    COALESCE(a.is_active,0) AS is_active,
                    COALESCE(a.can_create_mobile_event,0) AS can_create_mobile_event,
                    COALESCE(mps.username,'') AS username,
                    CASE
                        WHEN LOWER(COALESCE(a.role,'')) IN ('super_admin','editor') THEN TRUE
                        ELSE COALESCE(mps.is_verified,FALSE)
                    END AS is_verified,
                    a.created_at,
                    COALESCE(ticket_stats.assigned_ticket_count,0) AS assigned_ticket_count,
                    COALESCE(ticket_stats.purchased_ticket_count,0) AS purchased_ticket_count,
                    COALESCE(ticket_stats.used_ticket_count,0) AS used_ticket_count
                FROM accounts a
                LEFT JOIN mobile_profile_settings mps ON mps.account_id=a.id
                LEFT JOIN (
                    SELECT
                        t.account_id,
                        COUNT(*) FILTER (
                            WHERE COALESCE(t.status,'active') NOT IN ('cancelled','deleted','void')
                        ) AS assigned_ticket_count,
                        COUNT(*) FILTER (
                            WHERE COALESCE(t.status,'active') NOT IN ('cancelled','deleted','void')
                              AND COALESCE(t.ticket_type,'paid')='paid'
                        ) AS purchased_ticket_count,
                        COUNT(*) FILTER (
                            WHERE COALESCE(t.status,'active') NOT IN ('cancelled','deleted','void')
                              AND t.used_at IS NOT NULL
                        ) AS used_ticket_count
                    FROM mobile_tickets t
                    GROUP BY t.account_id
                ) ticket_stats ON ticket_stats.account_id=a.id
                {where_sql}
                ORDER BY a.id DESC
                LIMIT ? OFFSET ?
                """,
                tuple(params + [page_size, offset]),
            )
            items = [dict(row) for row in (cur.fetchall() or [])]
            return {"items": items, "total": total, "page": page, "page_size": page_size}
        finally:
            conn.close()

    def event_item(item_id: int) -> Dict[str, Any]:
        data = unwrap(admin_call("/admin/events/items?limit=1000", method="GET"), "Etkinlikler alinamadi")
        for item in data.get("items") or []:
            if int(item.get("id") or item.get("submission_id") or 0) == int(item_id):
                return normalize_event(item)
        raise HTTPException(status_code=404, detail="Etkinlik bulunamadi")

    def normalize_event(item: Dict[str, Any]) -> Dict[str, Any]:
        normalized = dict(item)
        normalized["id"] = int(item.get("id") or item.get("submission_id") or 0)
        normalized["event_name"] = str(item.get("event_name") or item.get("name") or "").strip()
        return normalized

    def event_sort_value(item: Dict[str, Any]) -> Optional[datetime]:
        raw_value = str(item.get("start_at") or item.get("event_date") or "").strip()
        if not raw_value:
            return None
        normalized = raw_value.replace(" ", "T", 1)
        if normalized.endswith("Z"):
            normalized = f"{normalized[:-1]}+00:00"
        try:
            parsed = datetime.fromisoformat(normalized)
        except ValueError:
            try:
                parsed = datetime.strptime(raw_value[:10], "%Y-%m-%d")
            except ValueError:
                return None
        return parsed.replace(tzinfo=None) if parsed.tzinfo is not None else parsed

    def sort_events(items: list[Dict[str, Any]], *, descending: bool = False) -> list[Dict[str, Any]]:
        dated: list[tuple[datetime, int, Dict[str, Any]]] = []
        undated: list[Dict[str, Any]] = []
        for item in items:
            sort_value = event_sort_value(item)
            if sort_value is None:
                undated.append(item)
                continue
            dated.append((sort_value, int(item.get("id") or 0), item))
        dated.sort(key=lambda row: (row[0], row[1]), reverse=descending)
        undated.sort(key=lambda item: int(item.get("id") or 0), reverse=True)
        return [row[2] for row in dated] + undated

    def user_item(user_id: int) -> Dict[str, Any]:
        conn = db_conn()
        try:
            cur = conn.cursor()
            cur.execute(
                """
                SELECT
                    a.id, COALESCE(a.name,'') AS name, a.email,
                    COALESCE(a.role,'customer') AS role,
                    COALESCE(a.is_active,0) AS is_active,
                    COALESCE(a.can_create_mobile_event,0) AS can_create_mobile_event,
                    COALESCE(mps.username,'') AS username,
                    CASE
                        WHEN LOWER(COALESCE(a.role,'')) IN ('super_admin','editor') THEN TRUE
                        ELSE COALESCE(mps.is_verified,FALSE)
                    END AS is_verified,
                    a.created_at,
                    COALESCE(ticket_stats.assigned_ticket_count,0) AS assigned_ticket_count,
                    COALESCE(ticket_stats.purchased_ticket_count,0) AS purchased_ticket_count,
                    COALESCE(ticket_stats.used_ticket_count,0) AS used_ticket_count,
                    (SELECT COUNT(*) FROM community_feed_posts p WHERE p.account_id=a.id) AS feed_post_count
                FROM accounts a
                LEFT JOIN mobile_profile_settings mps ON mps.account_id=a.id
                LEFT JOIN (
                    SELECT
                        t.account_id,
                        COUNT(*) FILTER (
                            WHERE COALESCE(t.status,'active') NOT IN ('cancelled','deleted','void')
                        ) AS assigned_ticket_count,
                        COUNT(*) FILTER (
                            WHERE COALESCE(t.status,'active') NOT IN ('cancelled','deleted','void')
                              AND COALESCE(t.ticket_type,'paid')='paid'
                        ) AS purchased_ticket_count,
                        COUNT(*) FILTER (
                            WHERE COALESCE(t.status,'active') NOT IN ('cancelled','deleted','void')
                              AND t.used_at IS NOT NULL
                        ) AS used_ticket_count
                    FROM mobile_tickets t
                    WHERE t.account_id=?
                    GROUP BY t.account_id
                ) ticket_stats ON ticket_stats.account_id=a.id
                WHERE a.id=?
                LIMIT 1
                """,
                (int(user_id), int(user_id)),
            )
            row = cur.fetchone()
            if not row:
                raise HTTPException(status_code=404, detail="Kullanici bulunamadi")
            return dict(row)
        finally:
            conn.close()

    def event_editor_candidates() -> list[Dict[str, Any]]:
        conn = db_conn()
        try:
            cur = conn.cursor()
            cur.execute(
                """
                SELECT
                    a.id,
                    COALESCE(a.name,'') AS name,
                    COALESCE(a.email,'') AS email,
                    COALESCE(a.role,'customer') AS role,
                    COALESCE(mps.username,'') AS username
                FROM accounts a
                LEFT JOIN mobile_profile_settings mps ON mps.account_id=a.id
                WHERE COALESCE(a.is_active,1)=1
                  AND (
                    LOWER(COALESCE(a.role,'')) IN ('editor','super_admin')
                    OR COALESCE(a.can_create_mobile_event,0)=1
                  )
                ORDER BY COALESCE(NULLIF(a.name,''), NULLIF(mps.username,''), a.email), a.id
                LIMIT 300
                """
            )
            return [dict(row) for row in (cur.fetchall() or [])]
        finally:
            conn.close()

    def event_ticket_usage(item_id: int) -> Dict[int, str]:
        conn = db_conn()
        try:
            cur = conn.cursor()
            cur.execute(
                """
                SELECT ei.account_id, COALESCE(t.used_at,'') AS used_at
                FROM mobile_event_invitees ei
                LEFT JOIN mobile_tickets t ON t.id=ei.ticket_id
                WHERE ei.submission_id=?
                """,
                (int(item_id),),
            )
            return {
                int(row["account_id"]): str(row.get("used_at") or "").strip()
                for row in (cur.fetchall() or [])
            }
        finally:
            conn.close()

    @router.get("/admin-v2", include_in_schema=False)
    @router.get("/admin-v2/{path:path}", include_in_schema=False)
    def admin_v2_app(request: Request, path: str = ""):
        try:
            require_account(request)
        except HTTPException as exc:
            if exc.status_code == 401:
                return RedirectResponse(f"/login?next=/admin-v2/{path}", status_code=303)
            raise
        index_file = dist_dir / "index.html"
        if not index_file.is_file():
            raise HTTPException(status_code=503, detail="Admin V2 henuz derlenmedi")
        return FileResponse(
            index_file,
            media_type="text/html",
            headers={"Cache-Control": "no-cache, no-store, must-revalidate"},
        )

    @router.get("/admin-v2-assets/{asset_path:path}", include_in_schema=False)
    def admin_v2_asset(asset_path: str):
        target = (dist_dir / asset_path).resolve()
        if dist_dir.resolve() not in target.parents or not target.is_file():
            raise HTTPException(status_code=404, detail="Dosya bulunamadi")
        return FileResponse(target)

    @router.get("/admin/api/v2/me")
    def me(request: Request):
        account = require_account(request)
        return {
            "id": int(account.get("id") or 0),
            "name": str(account.get("name") or ""),
            "email": str(account.get("email") or ""),
            "role": str(account.get("role") or ""),
        }

    @router.get("/admin/api/v2/overview")
    def overview(request: Request):
        require_account(request)
        token = session_token(request)

        def get_events():
            return unwrap(admin_call("/admin/events/items?limit=300", method="GET"), "Etkinlikler alinamadi")

        def get_guests():
            return unwrap(bearer_call("/profile/guest-lists", token, method="GET"), "Davetli listeleri alinamadi")

        def get_notifications():
            return unwrap(
                bearer_call("/profile/notifications/sent?limit=20", token, method="GET"),
                "Bildirim gecmisi alinamadi",
            )

        with ThreadPoolExecutor(max_workers=3) as pool:
            event_future = pool.submit(get_events)
            guest_future = pool.submit(get_guests)
            notification_future = pool.submit(get_notifications)
            events_data = event_future.result()
            guests_data = guest_future.result()
            notifications_data = notification_future.result()

        event_items = [normalize_event(item) for item in (events_data.get("items") or [])]
        upcoming_events = sort_events(
            [
                item
                for item in event_items
                if str(item.get("status") or "").lower() == "approved"
                and bool(item.get("event_is_active", True))
            ]
        )
        return {
            "metrics": {
                "users": query_scalar("SELECT COUNT(*) FROM accounts WHERE COALESCE(is_active,0)=1"),
                "active_events": sum(
                    1
                    for item in event_items
                    if str(item.get("status") or "").lower() == "approved"
                    and bool(item.get("event_is_active", True))
                ),
                "guest_lists": len(guests_data.get("items") or []),
                "pending_news": query_scalar(
                    "SELECT COUNT(*) FROM mobile_news_submissions WHERE COALESCE(status,'pending')='pending'"
                ),
                "push_tokens": query_scalar(
                    "SELECT COUNT(*) FROM mobile_push_tokens WHERE COALESCE(is_active,TRUE)=TRUE "
                    "AND COALESCE(notifications_enabled,TRUE)=TRUE"
                ),
            },
            "recent_events": upcoming_events[:6],
            "recent_notifications": (notifications_data.get("items") or [])[:6],
            "photo_retirement": {
                "face_matching_enabled": False,
                "event_photo_rows": query_scalar("SELECT COUNT(*) FROM event_photos"),
                "face_match_rows": query_scalar("SELECT COUNT(*) FROM photo_matches"),
            },
        }

    @router.get("/admin/api/v2/events")
    def events(request: Request, q: str = "", status: str = "all"):
        require_account(request)
        data = unwrap(admin_call("/admin/events/items?limit=300", method="GET"), "Etkinlikler alinamadi")
        items = [normalize_event(item) for item in (data.get("items") or [])]
        needle = q.strip().lower()
        normalized_status = status.strip().lower()
        if normalized_status != "all":
            if normalized_status == "active":
                items = [
                    item
                    for item in items
                    if str(item.get("status") or "").lower() == "approved"
                    and bool(item.get("event_is_active", True))
                ]
            elif normalized_status == "inactive":
                items = [
                    item
                    for item in items
                    if str(item.get("status") or "").lower() == "approved"
                    and not bool(item.get("event_is_active", True))
                ]
            else:
                items = [item for item in items if str(item.get("status") or "").lower() == normalized_status]
        if needle:
            items = [
                item
                for item in items
                if needle in str(item.get("event_name") or "").lower()
                or needle in str(item.get("city") or "").lower()
                or needle in str(item.get("organizer_name") or "").lower()
                or needle == str(item.get("id") or "")
            ]
        items = sort_events(items, descending=normalized_status == "expired")
        return {"items": items, "total": len(items)}

    @router.get("/admin/api/v2/events/{item_id}")
    def event_detail(request: Request, item_id: int):
        require_account(request)
        return event_item(item_id)

    @router.get("/admin/api/v2/events/{item_id}/operations")
    def event_operations(request: Request, item_id: int):
        require_account(request)
        token = session_token(request)
        event = event_item(item_id)

        def get_guest_lists():
            return unwrap(
                bearer_call("/profile/guest-lists", token, method="GET"),
                "Davetli listeleri alinamadi",
            )

        def get_invitees():
            if str(event.get("status") or "").lower() not in {"approved", "expired"}:
                return {"items": [], "total": 0}
            return unwrap(
                bearer_call(f"/events/manage/items/{int(item_id)}/invitees", token, method="GET"),
                "Etkinlik davetlileri alinamadi",
            )

        def get_scan_permissions():
            return unwrap(
                admin_call(f"/admin/events/{int(item_id)}/scan-permissions", method="GET"),
                "Bilet kontrol yetkileri alinamadi",
            )

        with ThreadPoolExecutor(max_workers=5) as pool:
            guest_future = pool.submit(get_guest_lists)
            invitee_future = pool.submit(get_invitees)
            permission_future = pool.submit(get_scan_permissions)
            candidate_future = pool.submit(event_editor_candidates)
            usage_future = pool.submit(event_ticket_usage, item_id)
            guest_data = guest_future.result()
            invitee_data = invitee_future.result()
            permission_data = permission_future.result()
            candidates = candidate_future.result()
            ticket_usage = usage_future.result()

        invitees = invitee_data.get("items") or []
        for invitee in invitees:
            used_at = ticket_usage.get(int(invitee.get("account_id") or 0), "")
            invitee["ticket_used_at"] = used_at
            invitee["ticket_used"] = bool(used_at)

        return {
            "event": event,
            "read_only": str(event.get("status") or "").lower() == "expired",
            "guest_lists": guest_data.get("items") or [],
            "invitees": invitees,
            "scan_permissions": permission_data.get("items") or [],
            "editor_candidates": candidates,
        }

    @router.post("/admin/api/v2/events")
    async def create_event(
        request: Request,
        event_name: str = Form(...),
        description: str = Form(""),
        default_language: str = Form("tr"),
        translations_json: str = Form(""),
        event_date: str = Form(""),
        start_at: str = Form(""),
        end_at: str = Form(""),
        venue: str = Form(""),
        venue_map_url: str = Form(""),
        city: str = Form(...),
        country_code: str = Form(""),
        city_id: str = Form(""),
        event_kind: str = Form("dance_night"),
        dance_styles: str = Form(""),
        ticket_sales_enabled: str = Form("0"),
        repeat_weekly: str = Form("0"),
        repeat_weekday: str = Form(""),
        organizer_name: str = Form(""),
        program_text: str = Form(""),
        entry_fee: str = Form("0"),
        cover_image: Optional[UploadFile] = File(None),
    ):
        account = require_account(request)
        require_same_origin(request)
        fields = {
            "submitter_name": str(account.get("name") or account.get("email") or "super-admin"),
            "submitter_email": str(account.get("email") or ""),
            "event_name": event_name.strip(),
            "description": description.strip(),
            "default_language": default_language.strip(),
            "translations_json": translations_json.strip(),
            "event_date": event_date.strip(),
            "start_at": start_at.strip(),
            "end_at": end_at.strip(),
            "venue": venue.strip(),
            "venue_map_url": venue_map_url.strip(),
            "city": city.strip(),
            "country_code": country_code.strip().upper(),
            "city_id": city_id.strip(),
            "event_kind": event_kind.strip() or "dance_night",
            "dance_styles": dance_styles.strip(),
            "ticket_sales_enabled": ticket_sales_enabled,
            "create_photo_album": "0",
            "repeat_mode": "weekly_fixed" if repeat_weekly.strip().lower() in {"1", "true", "yes", "on"} else "none",
            "repeat_weekly": repeat_weekly,
            "repeat_weekday": repeat_weekday,
            "organizer_name": organizer_name.strip(),
            "program_text": program_text.strip(),
            "entry_fee": entry_fee.strip() or "0",
        }
        if cover_image and cover_image.filename:
            result = bearer_multipart_call(
                "/events/submissions",
                session_token(request),
                fields=fields,
                files=[
                    {
                        "field": "cover_image",
                        "filename": cover_image.filename,
                        "content_type": cover_image.content_type or "application/octet-stream",
                        "content": await cover_image.read(),
                    }
                ],
            )
        else:
            result = bearer_form_call(
                "/events/submissions",
                session_token(request),
                method="POST",
                data=fields,
            )
        return unwrap(result, "Etkinlik olusturulamadi")

    @router.post("/admin/api/v2/events/{item_id}")
    async def update_event(
        request: Request,
        item_id: int,
        event_name: str = Form(...),
        description: str = Form(""),
        default_language: str = Form("tr"),
        translations_json: str = Form(""),
        event_date: str = Form(""),
        start_at: str = Form(""),
        end_at: str = Form(""),
        venue: str = Form(""),
        venue_map_url: str = Form(""),
        city: str = Form(...),
        country_code: Optional[str] = Form(None),
        city_id: Optional[str] = Form(None),
        event_kind: str = Form("dance_night"),
        dance_styles: str = Form(""),
        ticket_sales_enabled: str = Form("0"),
        repeat_weekly: str = Form("0"),
        repeat_weekday: str = Form(""),
        organizer_name: str = Form(""),
        program_text: str = Form(""),
        entry_fee: str = Form("0"),
        cover_image: Optional[UploadFile] = File(None),
    ):
        require_account(request)
        require_same_origin(request)
        fields = {
            "event_name": event_name.strip(),
            "description": description.strip(),
            "default_language": default_language.strip(),
            "translations_json": translations_json.strip(),
            "event_date": event_date.strip(),
            "start_at": start_at.strip(),
            "end_at": end_at.strip(),
            "venue": venue.strip(),
            "venue_map_url": venue_map_url.strip(),
            "city": city.strip(),
            "event_kind": event_kind.strip() or "dance_night",
            "dance_styles": dance_styles.strip(),
            "ticket_sales_enabled": ticket_sales_enabled,
            "repeat_weekly": repeat_weekly,
            "repeat_weekday": repeat_weekday,
            "organizer_name": organizer_name.strip(),
            "program_text": program_text.strip(),
            "entry_fee": entry_fee.strip() or "0",
        }
        if country_code is not None:
            fields["country_code"] = country_code.strip().upper()
        if city_id is not None:
            fields["city_id"] = city_id.strip()
        if cover_image and cover_image.filename:
            result = bearer_multipart_call(
                f"/events/manage/items/{int(item_id)}/update",
                session_token(request),
                fields=fields,
                files=[
                    {
                        "field": "cover_image",
                        "filename": cover_image.filename,
                        "content_type": cover_image.content_type or "application/octet-stream",
                        "content": await cover_image.read(),
                    }
                ],
            )
            unwrap(result, "Etkinlik gorseli guncellenemedi")
        else:
            result = bearer_form_call(
                f"/events/manage/items/{int(item_id)}/update",
                session_token(request),
                method="POST",
                data=fields,
            )
            unwrap(result, "Etkinlik guncellenemedi")
        name_result = admin_call(
            f"/admin/events/items/{int(item_id)}/update",
            method="POST",
            data={
                "event_name": event_name.strip(),
                "description": description.strip(),
                "program_text": program_text.strip(),
                "default_language": default_language.strip(),
                "translations_json": translations_json.strip(),
            },
        )
        return unwrap(name_result, "Etkinlik adi guncellenemedi")

    @router.get("/admin/api/v2/guest-lists")
    def guest_lists(request: Request):
        require_account(request)
        return bearer(request, "/profile/guest-lists")

    @router.get("/admin/api/v2/guest-lists/{guest_list_id}")
    def guest_list_detail(request: Request, guest_list_id: int):
        require_account(request)
        return bearer(request, f"/profile/guest-lists/{guest_list_id}")

    @router.get("/admin/api/v2/users/{user_id}")
    def user_detail(request: Request, user_id: int):
        require_account(request)
        return user_item(user_id)

    @router.get("/admin/api/v2/users")
    def users(
        request: Request,
        q: str = "",
        role: str = "all",
        page: int = Query(default=1, ge=1),
        page_size: int = Query(default=30, ge=10, le=100),
    ):
        require_account(request)
        normalized_role = role if role in {"all", "super_admin", "editor", "customer"} else "all"
        return paged_users(q.strip(), normalized_role, page, page_size)

    @router.get("/admin/api/v2/feed")
    def feed(request: Request, limit: int = Query(default=50, ge=1, le=100)):
        require_account(request)
        return bearer(request, f"/photos/feed?limit={limit}&offset=0")

    @router.get("/admin/api/v2/news")
    def news(request: Request):
        require_account(request)
        return bearer(request, "/news/manage/items")

    @router.get("/admin/api/v2/news/{item_id}")
    def news_detail(request: Request, item_id: int):
        require_account(request)
        data = bearer(request, "/news/manage/items")
        for item in data.get("items") or []:
            if int(item.get("submission_id") or item.get("id") or 0) == int(item_id):
                return item
        raise HTTPException(status_code=404, detail="Haber bulunamadi")

    @router.post("/admin/api/v2/news")
    async def create_news(
        request: Request,
        title: str = Form(...),
        body_text: str = Form(...),
        default_language: str = Form("tr"),
        translations_json: str = Form(""),
        source_link: str = Form(""),
        cover_image: Optional[UploadFile] = File(None),
    ):
        require_account(request)
        require_same_origin(request)
        fields = {
            "title": title.strip(),
            "body_text": body_text.strip(),
            "default_language": default_language.strip(),
            "translations_json": translations_json.strip(),
            "source_link": source_link.strip(),
        }
        if cover_image and cover_image.filename:
            result = bearer_multipart_call(
                "/news/submissions",
                session_token(request),
                fields=fields,
                files=[
                    {
                        "field": "cover_image",
                        "filename": cover_image.filename,
                        "content_type": cover_image.content_type or "application/octet-stream",
                        "content": await cover_image.read(),
                    }
                ],
            )
        else:
            result = bearer_form_call(
                "/news/submissions",
                session_token(request),
                method="POST",
                data=fields,
            )
        return unwrap(result, "Haber olusturulamadi")

    @router.post("/admin/api/v2/news/{item_id}")
    async def update_news(
        request: Request,
        item_id: int,
        title: str = Form(...),
        body_text: str = Form(...),
        default_language: str = Form("tr"),
        translations_json: str = Form(""),
        source_link: str = Form(""),
        cover_image: Optional[UploadFile] = File(None),
    ):
        require_account(request)
        require_same_origin(request)
        fields = {
            "title": title.strip(),
            "body_text": body_text.strip(),
            "default_language": default_language.strip(),
            "translations_json": translations_json.strip(),
            "source_link": source_link.strip(),
        }
        if cover_image and cover_image.filename:
            result = bearer_multipart_call(
                f"/news/manage/items/{int(item_id)}/update",
                session_token(request),
                fields=fields,
                files=[
                    {
                        "field": "cover_image",
                        "filename": cover_image.filename,
                        "content_type": cover_image.content_type or "application/octet-stream",
                        "content": await cover_image.read(),
                    }
                ],
            )
        else:
            result = bearer_form_call(
                f"/news/manage/items/{int(item_id)}/update",
                session_token(request),
                method="POST",
                data=fields,
            )
        return unwrap(result, "Haber guncellenemedi")

    @router.get("/admin/api/v2/store")
    def store(request: Request):
        require_account(request)
        token = session_token(request)
        with ThreadPoolExecutor(max_workers=2) as pool:
            sellers_future = pool.submit(bearer_call, "/store/sellers?limit=300", token, "GET")
            products_future = pool.submit(bearer_call, "/store/products?limit=300", token, "GET")
            sellers = unwrap(sellers_future.result(), "Magazalar alinamadi")
            products = unwrap(products_future.result(), "Urunler alinamadi")
        event_products = []
        try:
            event_data = unwrap(admin_call("/admin/events/items?limit=1000", method="GET"), "Etkinlikler alinamadi")
            for item in event_data.get("items") or []:
                if not isinstance(item, dict):
                    continue
                product_id = str(item.get("woo_product_id") or item.get("external_event_id") or "").strip()
                ticket_url = str(item.get("ticket_url") or "").strip()
                ticket_sales_enabled = item.get("ticket_sales_enabled", True)
                if not product_id and not ticket_url:
                    continue
                if str(item.get("status") or "").strip().lower() not in {"approved", "expired"}:
                    continue
                event_products.append(
                    {
                        "event_id": int(item.get("id") or item.get("submission_id") or 0),
                        "event_name": str(item.get("event_name") or item.get("name") or "").strip(),
                        "description": str(item.get("description") or "").strip(),
                        "event_date": str(item.get("event_date") or item.get("start_at") or "").strip(),
                        "status": str(item.get("status") or "").strip(),
                        "ticket_sales_enabled": bool(ticket_sales_enabled),
                        "woo_product_id": product_id,
                        "ticket_url": ticket_url,
                    }
                )
        except Exception:
            # Mağaza sayfası, Woo/etkinlik hedefleri geçici olarak okunamasa da açılabilsin.
            event_products = []
        return {
            "sellers": sellers.get("items") or [],
            "products": products.get("items") or [],
            "event_products": event_products,
        }

    @router.get("/admin/api/v2/polls")
    def polls(request: Request):
        require_account(request)
        return bearer(request, "/photos/polls?limit=100&include_inactive=true")

    @router.get("/admin/api/v2/notifications")
    def notifications(request: Request):
        require_account(request)
        token = session_token(request)

        def optional_bearer(path: str) -> Dict[str, Any]:
            result = bearer_call(path, token, method="GET")
            return result.get("data") or {} if result.get("ok") else {}

        def optional_admin(path: str) -> Dict[str, Any]:
            result = admin_call(path, method="GET")
            return result.get("data") or {} if result.get("ok") else {}

        with ThreadPoolExecutor(max_workers=6) as pool:
            sent_future = pool.submit(optional_bearer, "/profile/notifications/sent?limit=200")
            events_future = pool.submit(optional_admin, "/admin/events/items?limit=300")
            news_future = pool.submit(optional_bearer, "/news/manage/items")
            sellers_future = pool.submit(optional_bearer, "/store/sellers?limit=300")
            products_future = pool.submit(optional_bearer, "/store/products?limit=300")
            polls_future = pool.submit(optional_bearer, "/photos/polls?limit=100&include_inactive=true")
            sent_data = sent_future.result()
            event_items = [normalize_event(item) for item in (events_future.result().get("items") or [])]
            news_items = news_future.result().get("items") or []
            seller_items = sellers_future.result().get("items") or []
            product_items = products_future.result().get("items") or []
            poll_items = polls_future.result().get("items") or []

        def target(route: str, label: str) -> Dict[str, str]:
            return {"route": route, "label": label}

        return {
            "items": sent_data.get("items") or [],
            "targets": {
                "events": [
                    target(f"/events/{item['id']}", f"{item.get('event_name') or 'Etkinlik'} · #{item['id']}")
                    for item in event_items
                    if item["id"] > 0
                    and str(item.get("status") or "").lower() == "approved"
                    and bool(item.get("event_is_active", True))
                ],
                "news": [
                    target(
                        f"/news/{int(item.get('submission_id') or item.get('id') or 0)}",
                        str(item.get("title") or "Haber").strip(),
                    )
                    for item in news_items
                    if int(item.get("submission_id") or item.get("id") or 0) > 0
                    and str(item.get("status") or "").lower() == "approved"
                ],
                "stores": [
                    target(
                        f"/store/sellers/{int(item.get('account_id') or 0)}",
                        str(item.get("store_title") or item.get("name") or "Magaza").strip(),
                    )
                    for item in seller_items
                    if int(item.get("account_id") or 0) > 0
                ],
                "products": [
                    target(
                        f"/store/products/{int(item.get('id') or 0)}",
                        str(item.get("title") or "Urun").strip(),
                    )
                    for item in product_items
                    if int(item.get("id") or 0) > 0
                ],
                "polls": [
                    target(
                        f"/photos/polls/{int(item.get('id') or 0)}",
                        str(item.get("title") or item.get("question") or "Anket").strip(),
                    )
                    for item in poll_items
                    if int(item.get("id") or 0) > 0 and bool(item.get("is_active", True))
                ],
            },
        }

    @router.get("/admin/api/v2/reports")
    def reports(request: Request):
        require_account(request)
        return {
            "accounts": {
                "total": query_scalar("SELECT COUNT(*) FROM accounts"),
                "active": query_scalar("SELECT COUNT(*) FROM accounts WHERE COALESCE(is_active,0)=1"),
                "editors": query_scalar(
                    "SELECT COUNT(*) FROM accounts WHERE role IN ('editor','super_admin')"
                ),
            },
            "events": {
                "total": query_scalar("SELECT COUNT(*) FROM mobile_event_submissions"),
                "approved": query_scalar(
                    "SELECT COUNT(*) FROM mobile_event_submissions WHERE status='approved'"
                ),
                "invitees": query_scalar("SELECT COUNT(*) FROM mobile_event_invitees"),
                "tickets": query_scalar("SELECT COUNT(*) FROM mobile_tickets"),
            },
            "engagement": {
                "feed_posts": query_scalar("SELECT COUNT(*) FROM community_feed_posts"),
                "messages": query_scalar("SELECT COUNT(*) FROM mobile_direct_messages"),
                "notifications": query_scalar("SELECT COUNT(*) FROM mobile_user_notifications"),
            },
        }

    @router.get("/admin/api/v2/settings")
    def settings(request: Request):
        require_account(request)
        return {
            "panel_version": "2.0.0",
            "legacy_panel_available": True,
            "photo_system": {
                "face_matching_enabled": False,
                "album_creation_enabled": False,
                "event_photos": query_scalar("SELECT COUNT(*) FROM event_photos"),
                "photo_matches": query_scalar("SELECT COUNT(*) FROM photo_matches"),
                "selfie_embeddings": query_scalar("SELECT COUNT(*) FROM selfie_embeddings"),
                "photo_face_embeddings": query_scalar("SELECT COUNT(*) FROM photo_face_embeddings"),
            },
        }

    @router.post("/admin/api/v2/actions/{action}")
    async def action(request: Request, action: str):
        require_account(request)
        require_same_origin(request)
        payload = await request.json()
        token = session_token(request)
        item_id = int(payload.get("id") or 0)

        if action == "event-active":
            result = bearer_call(
                f"/events/manage/items/{item_id}/active",
                token,
                method="POST",
                json_data={"is_active": bool(payload.get("active"))},
            )
        elif action in {"event-approve", "event-reject"}:
            verb = "approve" if action == "event-approve" else "reject"
            result = admin_call(
                f"/admin/events/submissions/{item_id}/{verb}",
                method="POST",
                data={"admin_note": str(payload.get("admin_note") or "").strip()},
            )
        elif action == "event-copy":
            result = bearer_call(f"/events/manage/items/{item_id}/copy", token, method="POST", json_data={})
        elif action == "event-delete":
            result = bearer_call(f"/events/manage/items/{item_id}", token, method="DELETE")
        elif action == "event-guest-import":
            result = bearer_call(
                f"/events/manage/items/{item_id}/invitees/import-guest-list",
                token,
                method="POST",
                json_data={"guest_list_id": int(payload.get("guest_list_id") or 0)},
            )
        elif action == "event-invitee-remove":
            result = bearer_call(
                f"/events/manage/items/{item_id}/invitees/{int(payload.get('account_id') or 0)}",
                token,
                method="DELETE",
            )
        elif action in {"event-scan-grant", "event-scan-revoke"}:
            verb = "grant" if action == "event-scan-grant" else "revoke"
            result = admin_call(
                f"/admin/events/{item_id}/scan-permissions/{verb}",
                method="POST",
                data={"account_id": int(payload.get("account_id") or 0)},
            )
        elif action == "guest-create":
            result = bearer_call(
                "/profile/guest-lists",
                token,
                method="POST",
                json_data={"name": str(payload.get("name") or "").strip()},
            )
        elif action == "guest-copy":
            result = bearer_call(
                f"/profile/guest-lists/{item_id}/copy",
                token,
                method="POST",
                json_data={"name": str(payload.get("name") or "").strip()},
            )
        elif action == "guest-rename":
            result = bearer_call(
                f"/profile/guest-lists/{item_id}",
                token,
                method="PATCH",
                json_data={"name": str(payload.get("name") or "").strip()},
            )
        elif action == "guest-delete":
            result = bearer_call(f"/profile/guest-lists/{item_id}", token, method="DELETE")
        elif action == "guest-member-add":
            result = bearer_call(
                f"/profile/guest-lists/{item_id}/members",
                token,
                method="POST",
                json_data={"account_id": int(payload.get("account_id") or 0)},
            )
        elif action == "guest-member-remove":
            result = bearer_call(
                f"/profile/guest-lists/{item_id}/members/{int(payload.get('account_id') or 0)}",
                token,
                method="DELETE",
            )
        elif action in {"news-approve", "news-reject"}:
            verb = "approve" if action == "news-approve" else "reject"
            result = bearer_form_call(
                f"/news/manage/items/{item_id}/{verb}",
                token,
                method="POST",
                data={"admin_note": str(payload.get("admin_note") or "").strip()},
            )
        elif action == "news-delete":
            result = bearer_call(f"/news/manage/items/{item_id}/delete", token, method="POST", json_data={})
        elif action == "poll-state":
            result = bearer_call(
                f"/photos/polls/{item_id}/state",
                token,
                method="POST",
                json_data={"active": bool(payload.get("active"))},
            )
        elif action == "poll-delete":
            result = bearer_call(f"/photos/polls/{item_id}", token, method="DELETE")
        elif action == "poll-create":
            result = bearer_call(
                "/photos/polls/admin",
                token,
                method="POST",
                json_data={
                    "title": str(payload.get("title") or "").strip(),
                    "show_results_after_vote": bool(payload.get("show_results_after_vote", True)),
                    "questions": payload.get("questions") or [],
                },
            )
        elif action == "feed-delete":
            result = bearer_call(f"/photos/feed/posts/{item_id}", token, method="DELETE")
        elif action == "notification-send":
            route = str(payload.get("route") or "").strip()
            if not route.startswith("/"):
                raise HTTPException(status_code=400, detail="Yönlendirme hedefi seçilmelidir")
            result = bearer_call(
                "/profile/notifications/send",
                token,
                method="POST",
                json_data={
                    "title": str(payload.get("title") or "").strip(),
                    "body": str(payload.get("body") or "").strip(),
                    "send_to_all": True,
                    "target_account_ids": [],
                    "target_route": route,
                },
            )
        elif action.startswith("user-"):
            user = user_item(item_id)
            if str(user.get("role") or "").lower() == "super_admin":
                raise HTTPException(status_code=409, detail="Super admin hesabi bu islemle degistirilemez")
            conn = db_conn()
            try:
                cur = conn.cursor()
                if action == "user-active":
                    cur.execute(
                        "UPDATE accounts SET is_active=? WHERE id=?",
                        (1 if bool(payload.get("active")) else 0, item_id),
                    )
                elif action == "user-event-permission":
                    cur.execute(
                        "UPDATE accounts SET can_create_mobile_event=? WHERE id=?",
                        (1 if bool(payload.get("enabled")) else 0, item_id),
                    )
                elif action == "user-verified":
                    cur.execute(
                        """
                        INSERT INTO mobile_profile_settings (account_id, is_verified, updated_at)
                        VALUES (?, ?, NOW())
                        ON CONFLICT (account_id) DO UPDATE
                        SET is_verified=EXCLUDED.is_verified, updated_at=NOW()
                        """,
                        (item_id, bool(payload.get("verified"))),
                    )
                elif action == "user-username":
                    username = " ".join(str(payload.get("username") or "").split()).strip()
                    if len(username) < 3 or len(username) > 40:
                        raise HTTPException(status_code=400, detail="Kullanici adi 3-40 karakter olmali")
                    cur.execute(
                        """
                        INSERT INTO mobile_profile_settings (account_id, username, updated_at)
                        VALUES (?, ?, NOW())
                        ON CONFLICT (account_id) DO UPDATE
                        SET username=EXCLUDED.username, updated_at=NOW()
                        """,
                        (item_id, username),
                    )
                elif action == "user-password":
                    password = str(payload.get("password") or "")
                    if len(password) < 6:
                        raise HTTPException(status_code=400, detail="Parola en az 6 karakter olmali")
                    cur.execute(
                        "UPDATE accounts SET password_hash=? WHERE id=?",
                        (hash_password(password), item_id),
                    )
                else:
                    raise HTTPException(status_code=404, detail="Kullanici islemi bulunamadi")
                conn.commit()
                return user_item(item_id)
            except HTTPException:
                conn.rollback()
                raise
            finally:
                conn.close()
        else:
            raise HTTPException(status_code=404, detail="Yonetim islemi bulunamadi")

        return unwrap(result, "Yonetim islemi tamamlanamadi")

    return router
