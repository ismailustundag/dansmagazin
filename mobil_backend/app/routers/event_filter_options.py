from datetime import date, datetime
import hashlib

from fastapi import APIRouter

from app.utils import get_db_connection

router = APIRouter(prefix="/events", tags=["Etkinlikler"])


def _event_day(value):
    raw = str(value or "").strip()
    for fmt in ("%Y-%m-%d", "%d.%m.%Y", "%d/%m/%Y"):
        try:
            return datetime.strptime(raw[:10], fmt).date()
        except ValueError:
            continue
    return None


@router.get("/filter-options", summary="Güncel etkinliklerin şehir seçenekleri")
def event_filter_options(event_kind: str = "", dance_styles: str = ""):
    conn = get_db_connection()
    try:
        cur = conn.cursor()
        cur.execute(
            """
            SELECT mes.city, mes.event_date, mes.start_at, mes.end_at,
                   mes.event_kind, mes.dance_styles
            FROM mobile_event_submissions mes
            LEFT JOIN saas_events se ON se.slug = mes.approved_event_slug
            WHERE mes.status = 'approved' AND COALESCE(se.is_active, 1) = 1
            """
        )
        today = date.today()
        requested_kind = (event_kind or "").strip().lower()
        requested_styles = {
            item.strip().lower()
            for item in (dance_styles or "").split(",")
            if item.strip()
        }
        cities = {}
        for row in cur.fetchall():
            day = _event_day(row.get("end_at") or row.get("event_date") or row.get("start_at"))
            if day is not None and day < today:
                continue
            if requested_kind and requested_kind != "all" and str(row.get("event_kind") or "").lower() != requested_kind:
                continue
            if requested_styles:
                available = {item.strip().lower() for item in str(row.get("dance_styles") or "").split(",") if item.strip()}
                if not requested_styles.intersection(available):
                    continue
            city = str(row.get("city") or "").strip()
            if not city:
                continue
            city_id = "text:" + hashlib.md5(("\x1f" + city).encode()).hexdigest()
            cities[("", city_id)] = {"country_code": "", "city_id": city_id, "city": city}
        values = sorted(cities.values(), key=lambda item: item["city"].casefold())
        return {
            "countries": [{"code": "__unknown__", "name": "Ülkesi belirtilmemiş"}] if values else [],
            "cities": values,
        }
    finally:
        conn.close()
