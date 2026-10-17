"""Internal commerce catalog API used during the WooCommerce transition.

The first version is deliberately local-only: it edits the internal catalog
and never writes to WooCommerce or creates tickets.
"""

import json
import os
from io import BytesIO
from pathlib import Path
from decimal import Decimal, InvalidOperation
from typing import Any, Dict, Optional
from uuid import uuid4

import httpx
from fastapi import APIRouter, File, Header, HTTPException, UploadFile
from fastapi.responses import FileResponse

from app.utils import get_db_connection


router = APIRouter(prefix="/admin/commerce", tags=["Admin Commerce"])
public_router = APIRouter(prefix="/commerce", tags=["Commerce"])
ADMIN_TOKEN = os.getenv("MOBILE_ADMIN_TOKEN", "").strip()
WOO_BASE_URL = os.getenv("WOO_BASE_URL", "").strip().rstrip("/")
WOO_CONSUMER_KEY = os.getenv("WOO_CONSUMER_KEY", "").strip()
WOO_CONSUMER_SECRET = os.getenv("WOO_CONSUMER_SECRET", "").strip()
COMMERCE_IMAGE_DIR = Path(os.getenv("COMMERCE_IMAGE_DIR", "/home/ubuntu/mobil_backend/media/commerce_products"))
COMMERCE_IMAGE_BASE = os.getenv("PUBLIC_API_BASE", "https://api2.dansmagazin.net").rstrip("/")


def _require_admin(token: Optional[str]) -> None:
    value = str(token or "").strip()
    if ADMIN_TOKEN and value == ADMIN_TOKEN:
        return
    if value.lower().startswith("bearer "):
        value = value.split(" ", 1)[1].strip()
    if not value:
        raise HTTPException(status_code=401, detail="Yönetici yetkisi gerekli")
    conn = get_db_connection()
    try:
        with conn.cursor() as cur:
            cur.execute(
                """
                SELECT COALESCE(a.role, 'customer') AS role
                FROM sessions s JOIN accounts a ON a.id=s.account_id
                WHERE s.session_token=%s AND COALESCE(a.is_active, 1)=1
                LIMIT 1
                """,
                (value,),
            )
            row = cur.fetchone()
        if str((row or {}).get("role") or "").lower() not in {"super_admin", "admin", "editor", "administrator"}:
            raise HTTPException(status_code=403, detail="Yönetici yetkisi gerekli")
    finally:
        conn.close()


def _money(value: Any) -> Decimal:
    try:
        amount = Decimal(str(value or "0")).quantize(Decimal("0.01"))
    except (InvalidOperation, ValueError):
        raise HTTPException(status_code=400, detail="Geçersiz fiyat")
    if amount < 0:
        raise HTTPException(status_code=400, detail="Fiyat negatif olamaz")
    return amount


@public_router.get("/images/{filename}", include_in_schema=False)
def product_image(filename: str):
    if not filename.endswith(".jpg") or len(filename) != 36 or not filename[:-4].isalnum():
        raise HTTPException(status_code=404, detail="Görsel bulunamadı")
    path = COMMERCE_IMAGE_DIR / filename
    if not path.is_file():
        raise HTTPException(status_code=404, detail="Görsel bulunamadı")
    return FileResponse(path, media_type="image/jpeg")


@router.post("/images")
def upload_product_image(image: UploadFile = File(...), x_admin_token: Optional[str] = Header(default=None)):
    _require_admin(x_admin_token)
    if image.content_type not in {"image/jpeg", "image/png", "image/webp"}:
        raise HTTPException(status_code=400, detail="JPG, PNG veya WebP görsel seçin")
    raw = image.file.read(10 * 1024 * 1024 + 1)
    if len(raw) > 10 * 1024 * 1024:
        raise HTTPException(status_code=400, detail="Görsel 10 MB sınırını aşıyor")
    try:
        from PIL import Image, ImageOps, UnidentifiedImageError

        with Image.open(BytesIO(raw)) as source:
            source.verify()
        with Image.open(BytesIO(raw)) as source:
            if source.width * source.height > 25_000_000:
                raise HTTPException(status_code=400, detail="Görsel boyutu çok büyük")
            photo = ImageOps.exif_transpose(source)
            photo.thumbnail((1600, 1600), Image.Resampling.LANCZOS)
            if photo.mode != "RGB":
                background = Image.new("RGB", photo.size, "white")
                if "A" in photo.getbands():
                    background.paste(photo, mask=photo.getchannel("A"))
                else:
                    background.paste(photo.convert("RGB"))
                photo = background
            output = BytesIO()
            photo.save(output, format="JPEG", quality=82, optimize=True)
    except HTTPException:
        raise
    except (UnidentifiedImageError, OSError, ValueError):
        raise HTTPException(status_code=400, detail="Görsel okunamadı")
    COMMERCE_IMAGE_DIR.mkdir(parents=True, exist_ok=True)
    filename = f"{uuid4().hex}.jpg"
    temporary = COMMERCE_IMAGE_DIR / f".{filename}.tmp"
    temporary.write_bytes(output.getvalue())
    temporary.replace(COMMERCE_IMAGE_DIR / filename)
    return {"url": f"{COMMERCE_IMAGE_BASE}/commerce/images/{filename}"}


@router.post("/products", status_code=201)
def create_product(payload: Dict[str, Any], x_admin_token: Optional[str] = Header(default=None)):
    """Save a new internal catalog draft atomically; checkout is a separate gate."""
    _require_admin(x_admin_token)
    name = str(payload.get("name") or "").strip()
    rows = payload.get("variations")
    if not name or len(name) > 240:
        raise HTTPException(status_code=400, detail="Geçerli bir ürün adı gerekli")
    if not isinstance(rows, list) or not 1 <= len(rows) <= 200:
        raise HTTPException(status_code=400, detail="En az bir varyasyon gerekli")
    image_url = str(payload.get("image_url") or "").strip()
    event_submission_id = payload.get("event_submission_id")
    if event_submission_id in (None, ""):
        event_submission_id = None
    elif not str(event_submission_id).isdigit() or int(event_submission_id) <= 0:
        raise HTTPException(status_code=400, detail="Geçersiz etkinlik bağlantısı")
    else:
        event_submission_id = int(event_submission_id)
    if image_url and not image_url.startswith(f"{COMMERCE_IMAGE_BASE}/commerce/images/"):
        raise HTTPException(status_code=400, detail="Önce ürün görselini yükleyin")
    validated = []
    for item in rows:
        if not isinstance(item, dict):
            raise HTTPException(status_code=400, detail="Geçersiz varyasyon")
        variation_name = str(item.get("name") or "").strip()
        path = item.get("option_path")
        if not variation_name or len(variation_name) > 240 or not isinstance(path, list) or not 1 <= len(path) <= 3:
            raise HTTPException(status_code=400, detail="Varyasyon adı ve seçenek yolu gerekli")
        if any(not isinstance(part, str) or not part.strip() or len(part) > 120 for part in path):
            raise HTTPException(status_code=400, detail="Geçersiz seçenek yolu")
        price = _money(item.get("price"))
        variant_image = str(item.get("image_url") or image_url).strip()
        if variant_image and not variant_image.startswith(f"{COMMERCE_IMAGE_BASE}/commerce/images/"):
            raise HTTPException(status_code=400, detail="Önce varyasyon görselini yükleyin")
        validated.append((variation_name, price, [part.strip() for part in path], variant_image, bool(item.get("is_active", True))))
    conn = get_db_connection()
    try:
        cur = conn.cursor()
        if event_submission_id is not None:
            cur.execute(
                "SELECT id FROM mobile_event_submissions WHERE id=%s AND status='approved'",
                (event_submission_id,),
            )
            if not cur.fetchone():
                raise HTTPException(status_code=400, detail="Yalnızca onaylı bir etkinlik bağlanabilir")
        cur.execute(
            """
            INSERT INTO commerce_products
                (source_type, source_product_id, event_submission_id, name, description, image_url, is_active)
            VALUES ('internal', %s, %s, %s, %s, %s, FALSE) RETURNING id
            """,
            (uuid4().hex, event_submission_id, name, str(payload.get("description") or ""), image_url),
        )
        product_id = int(cur.fetchone()["id"])
        for variation_name, price, path, variant_image, is_active in validated:
            cur.execute(
                """
                INSERT INTO commerce_variations
                    (product_id, source_variation_id, name, price, currency, is_active, metadata)
                VALUES (%s, NULL, %s, %s, 'TRY', %s, %s::jsonb) RETURNING id
                """,
                (product_id, variation_name, price, is_active,
                 json.dumps({"option_path": path, "image_url": variant_image}, ensure_ascii=False)),
            )
            variation_id = int(cur.fetchone()["id"])
            cur.execute(
                "UPDATE commerce_variations SET source_variation_id=%s WHERE id=%s",
                (f"internal-{variation_id}", variation_id),
            )
        conn.commit()
        return {"ok": True, "id": product_id, "is_active": False, "variation_count": len(validated)}
    except Exception:
        conn.rollback()
        raise
    finally:
        conn.close()


@public_router.get("/products")
def public_products():
    """Read-only active local catalog for the web and mobile clients."""
    conn = get_db_connection()
    try:
        cur = conn.cursor()
        cur.execute(
            """
            SELECT p.id, p.source_type, p.source_product_id,
                   p.event_submission_id, p.legacy_woo_product_id, p.name,
                   p.description, p.image_url,
                   COALESCE(json_agg(json_build_object(
                       'id', v.id,
                       'source_variation_id', v.source_variation_id,
                       'name', v.name,
                       'price', v.price,
                       'currency', v.currency,
                       'stock_quantity', v.stock_quantity,
                       'metadata', v.metadata,
                       'is_active', v.is_active
                   ) ORDER BY v.id) FILTER (WHERE v.id IS NOT NULL), '[]') AS variations
            FROM commerce_products p
            LEFT JOIN commerce_variations v ON v.product_id=p.id AND v.is_active=TRUE
            WHERE p.is_active=TRUE
            GROUP BY p.id
            ORDER BY p.updated_at DESC, p.id DESC
            """
        )
        return {"items": cur.fetchall() or []}
    finally:
        conn.close()


@public_router.get("/legacy-visibility")
def public_legacy_visibility():
    """Expose only storefront visibility, never Woo credentials or order data."""
    conn = get_db_connection()
    try:
        cur = conn.cursor()
        cur.execute(
            """
            SELECT legacy_woo_product_id, BOOL_OR(legacy_woo_is_active) AS is_active
            FROM commerce_products
            WHERE NULLIF(legacy_woo_product_id, '') IS NOT NULL
            GROUP BY legacy_woo_product_id
            """
        )
        return {
            "items": [
                {"product_id": str(row["legacy_woo_product_id"]), "is_active": bool(row["is_active"])}
                for row in (cur.fetchall() or [])
            ]
        }
    finally:
        conn.close()


@public_router.get("/products/source/{source_product_id}")
def public_product_by_source(source_product_id: str):
    """Read one active catalog product by its stable external/source ID."""
    source_id = str(source_product_id or "").strip()
    if not source_id or len(source_id) > 80:
        raise HTTPException(status_code=400, detail="Geçersiz ürün kaynağı")
    conn = get_db_connection()
    try:
        cur = conn.cursor()
        cur.execute(
            """
            SELECT p.id, p.source_type, p.source_product_id,
                   p.event_submission_id, p.legacy_woo_product_id, p.name,
                   p.description, p.image_url,
                   COALESCE(json_agg(json_build_object(
                       'id', v.id,
                       'source_variation_id', v.source_variation_id,
                       'name', v.name,
                       'price', v.price,
                       'currency', v.currency,
                       'stock_quantity', v.stock_quantity,
                       'metadata', v.metadata,
                       'is_active', v.is_active
                   ) ORDER BY v.id) FILTER (WHERE v.id IS NOT NULL), '[]') AS variations
            FROM commerce_products p
            LEFT JOIN commerce_variations v ON v.product_id=p.id AND v.is_active=TRUE
            WHERE p.is_active=TRUE AND p.source_product_id=%s
            GROUP BY p.id
            LIMIT 1
            """,
            (source_id,),
        )
        row = cur.fetchone()
        if not row:
            raise HTTPException(status_code=404, detail="Ürün bulunamadı")
        return row
    finally:
        conn.close()


@public_router.get("/products/event/{submission_id}")
def public_product_by_event(submission_id: int):
    """Read the active local product linked to a mobile event submission."""
    if submission_id <= 0:
        raise HTTPException(status_code=400, detail="Geçersiz etkinlik")
    conn = get_db_connection()
    try:
        cur = conn.cursor()
        cur.execute(
            """
            SELECT p.id, p.source_type, p.source_product_id,
                   p.event_submission_id, p.legacy_woo_product_id, p.name,
                   p.description, p.image_url,
                   COALESCE(json_agg(json_build_object(
                       'id', v.id,
                       'source_variation_id', v.source_variation_id,
                       'name', v.name,
                       'price', v.price,
                       'currency', v.currency,
                       'stock_quantity', v.stock_quantity,
                       'metadata', v.metadata,
                       'is_active', v.is_active
                   ) ORDER BY v.id) FILTER (WHERE v.id IS NOT NULL), '[]') AS variations
            FROM commerce_products p
            JOIN mobile_event_submissions e
              ON e.id=p.event_submission_id
            LEFT JOIN commerce_variations v
              ON v.product_id=p.id AND v.is_active=TRUE
            WHERE p.is_active=TRUE AND e.id=%s
            GROUP BY p.id
            LIMIT 1
            """,
            (submission_id,),
        )
        row = cur.fetchone()
        if not row:
            raise HTTPException(status_code=404, detail="Etkinliğe bağlı ürün bulunamadı")
        return row
    finally:
        conn.close()


@router.get("/woo/preview")
def preview_woo_products(
    x_admin_token: Optional[str] = Header(default=None),
    page: int = 1,
    per_page: int = 100,
):
    """Read-only Woo catalog preview; it never writes to Woo or local tables."""
    _require_admin(x_admin_token)
    if not WOO_BASE_URL or not WOO_CONSUMER_KEY or not WOO_CONSUMER_SECRET:
        raise HTTPException(status_code=503, detail="WooCommerce bağlantısı yapılandırılmamış")
    page = max(1, min(int(page), 100))
    per_page = max(1, min(int(per_page), 100))
    try:
        response = httpx.get(
            f"{WOO_BASE_URL}/wp-json/wc/v3/products",
            params={"status": "any", "page": page, "per_page": per_page},
            auth=(WOO_CONSUMER_KEY, WOO_CONSUMER_SECRET),
            timeout=20.0,
        )
        response.raise_for_status()
        try:
            rows = response.json() if response.content else []
        except ValueError:
            content_type = response.headers.get("content-type", "").split(";", 1)[0].strip()
            raise HTTPException(
                status_code=502,
                detail=f"WooCommerce JSON yerine geçersiz yanıt döndürdü ({content_type or 'bilinmeyen içerik'})",
            )
        if not isinstance(rows, list):
            raise HTTPException(status_code=502, detail="WooCommerce ürün yanıtı geçersiz")
        return {
            "read_only": True,
            "page": page,
            "per_page": per_page,
            "items": [
                {
                    "source_product_id": str(row.get("id") or ""),
                    "name": str(row.get("name") or "").strip(),
                    "description": str(row.get("description") or ""),
                    "short_description": str(row.get("short_description") or ""),
                    "price": str(row.get("price") or ""),
                    "type": str(row.get("type") or ""),
                    "status": str(row.get("status") or ""),
                    "variations_count": len(row.get("variations") or []),
                    "permalink": str(row.get("permalink") or ""),
                }
                for row in rows
            ],
        }
    except httpx.HTTPError as exc:
        raise HTTPException(status_code=502, detail=f"WooCommerce kataloğu okunamadı: {exc}")


@router.patch("/woo/products/{product_id}")
def update_woo_product_state(
    product_id: int,
    payload: Dict[str, Any],
    x_admin_token: Optional[str] = Header(default=None),
):
    """Publish or unpublish a legacy Woo product without deleting order history."""
    _require_admin(x_admin_token)
    if product_id <= 0:
        raise HTTPException(status_code=400, detail="Geçersiz WooCommerce ürünü")
    active = payload.get("is_active")
    if not isinstance(active, bool):
        raise HTTPException(status_code=400, detail="Geçersiz satış durumu")
    if not WOO_BASE_URL or not WOO_CONSUMER_KEY or not WOO_CONSUMER_SECRET:
        raise HTTPException(status_code=503, detail="WooCommerce bağlantısı yapılandırılmamış")
    try:
        response = httpx.put(
            f"{WOO_BASE_URL}/wp-json/wc/v3/products/{int(product_id)}",
            json={"status": "publish" if active else "draft"},
            auth=(WOO_CONSUMER_KEY, WOO_CONSUMER_SECRET),
            timeout=20.0,
        )
        response.raise_for_status()
        row = response.json() if response.content else {}
        woo_is_active = str(row.get("status") or "") == "publish"
        conn = get_db_connection()
        try:
            cur = conn.cursor()
            cur.execute(
                "UPDATE commerce_products SET legacy_woo_is_active=%s, updated_at=NOW() WHERE legacy_woo_product_id=%s",
                (woo_is_active, str(product_id)),
            )
            conn.commit()
        except Exception:
            conn.rollback()
            raise
        finally:
            conn.close()
        return {
            "ok": True,
            "product_id": str(row.get("id") or product_id),
            "status": str(row.get("status") or ("publish" if active else "draft")),
            "is_active": woo_is_active,
        }
    except (httpx.HTTPError, ValueError) as exc:
        raise HTTPException(status_code=502, detail=f"WooCommerce ürün durumu güncellenemedi: {exc}")


@router.get("/products")
def list_products(x_admin_token: Optional[str] = Header(default=None)):
    _require_admin(x_admin_token)
    conn = get_db_connection()
    try:
        cur = conn.cursor()
        cur.execute(
            """
            SELECT p.id, p.source_type, p.source_product_id,
                   p.event_submission_id, p.legacy_woo_product_id, p.name,
                   p.description, p.image_url, p.is_active,
                   p.created_at, p.updated_at,
                   COALESCE(json_agg(json_build_object(
                       'id', v.id,
                       'source_variation_id', v.source_variation_id,
                       'name', v.name,
                       'price', v.price,
                       'currency', v.currency,
                       'stock_quantity', v.stock_quantity,
                       'metadata', v.metadata,
                       'is_active', v.is_active
                   ) ORDER BY v.id) FILTER (WHERE v.id IS NOT NULL), '[]') AS variations
            FROM commerce_products p
            LEFT JOIN commerce_variations v ON v.product_id=p.id
            GROUP BY p.id
            ORDER BY p.updated_at DESC, p.id DESC
            """
        )
        return {"items": cur.fetchall() or []}
    finally:
        conn.close()


@router.post("/import-event-products")
def import_event_products(x_admin_token: Optional[str] = Header(default=None)):
    """Create local product records from approved event submissions only.

    This is intentionally one-way and does not touch WooCommerce, tickets, or
    the source event rows. Existing local products are updated only for the
    descriptive fields of the same source event.
    """
    _require_admin(x_admin_token)
    conn = get_db_connection()
    try:
        cur = conn.cursor()
        cur.execute(
            """
            SELECT mes.id, COALESCE(mes.source_ref, '') AS source_ref,
                   COALESCE(event_name, '') AS event_name,
                   COALESCE(description, '') AS description,
                   COALESCE(cover_path, '') AS cover_path,
                   COALESCE(ticket_sales_enabled, TRUE) AS ticket_sales_enabled,
                   COALESCE(se.external_event_id, '') AS legacy_woo_product_id
            FROM mobile_event_submissions mes
            LEFT JOIN saas_events se ON se.slug=mes.approved_event_slug
            WHERE mes.status='approved' AND COALESCE(ticket_sales_enabled, TRUE)=TRUE
            ORDER BY mes.id
            """
        )
        imported = []
        for row in cur.fetchall() or []:
            source_id = str(row.get("source_ref") or row.get("id") or "").strip()
            if not source_id:
                continue
            cur.execute(
                """
                INSERT INTO commerce_products
                    (source_type, source_product_id, event_submission_id, legacy_woo_product_id,
                     name, description, image_url, is_active)
                VALUES ('event', %s, %s, %s, %s, %s, %s, %s)
                ON CONFLICT (source_type, source_product_id) DO UPDATE
                SET event_submission_id=EXCLUDED.event_submission_id,
                    legacy_woo_product_id=EXCLUDED.legacy_woo_product_id,
                    name=EXCLUDED.name,
                    description=EXCLUDED.description,
                    image_url=EXCLUDED.image_url,
                    is_active=EXCLUDED.is_active,
                    updated_at=NOW()
                RETURNING id
                """,
                (
                    source_id,
                    int(row["id"]),
                    str(row.get("legacy_woo_product_id") or "").strip() or None,
                    str(row.get("event_name") or "").strip() or f"Etkinlik #{row['id']}",
                    str(row.get("description") or ""),
                    str(row.get("cover_path") or ""),
                    bool(row.get("ticket_sales_enabled")),
                ),
            )
            product_id = int(cur.fetchone()["id"])
            imported.append({"event_submission_id": int(row["id"]), "product_id": product_id, "source_id": source_id})
        conn.commit()
        return {"ok": True, "imported": imported, "count": len(imported), "read_only_source": True}
    except Exception:
        conn.rollback()
        raise
    finally:
        conn.close()


@router.patch("/products/{product_id}")
def update_product(
    product_id: int,
    payload: Dict[str, Any],
    x_admin_token: Optional[str] = Header(default=None),
):
    _require_admin(x_admin_token)
    allowed = {"name", "description", "image_url", "is_active", "event_submission_id"}
    fields = {key: payload[key] for key in allowed if key in payload}
    if not fields:
        raise HTTPException(status_code=400, detail="Güncellenecek alan yok")
    if "name" in fields and not str(fields["name"]).strip():
        raise HTTPException(status_code=400, detail="Ürün adı boş olamaz")
    if "is_active" in fields and not isinstance(fields["is_active"], bool):
        raise HTTPException(status_code=400, detail="Geçersiz satış durumu")
    if "event_submission_id" in fields:
        value = fields["event_submission_id"]
        if value in (None, ""):
            fields["event_submission_id"] = None
        elif not str(value).isdigit() or int(value) <= 0:
            raise HTTPException(status_code=400, detail="Geçersiz etkinlik bağlantısı")
        else:
            fields["event_submission_id"] = int(value)
    conn = get_db_connection()
    try:
        cur = conn.cursor()
        cur.execute("SELECT source_type, is_active FROM commerce_products WHERE id=%s", (int(product_id),))
        existing = cur.fetchone()
        if not existing:
            raise HTTPException(status_code=404, detail="Ürün bulunamadı")
        if fields.get("is_active") is True and not bool(existing.get("is_active")):
            cur.execute(
                "SELECT COUNT(*)::INT AS cnt FROM commerce_variations WHERE product_id=%s AND is_active=TRUE",
                (int(product_id),),
            )
            if int((cur.fetchone() or {}).get("cnt") or 0) <= 0:
                raise HTTPException(status_code=409, detail="Satışa açmak için en az bir aktif fiyat seçeneği gerekli")
        if fields.get("event_submission_id") is not None:
            cur.execute(
                "SELECT id FROM mobile_event_submissions WHERE id=%s AND status='approved'",
                (fields["event_submission_id"],),
            )
            if not cur.fetchone():
                raise HTTPException(status_code=400, detail="Yalnızca onaylı bir etkinlik bağlanabilir")
        assignments = []
        values = []
        for key, value in fields.items():
            assignments.append(f"{key}=%s")
            values.append(value if key != "name" else str(value).strip())
        assignments.append("updated_at=NOW()")
        values.append(int(product_id))
        cur.execute(
            f"UPDATE commerce_products SET {', '.join(assignments)} WHERE id=%s "
            "RETURNING id, name, description, image_url, is_active, event_submission_id, updated_at",
            tuple(values),
        )
        row = cur.fetchone()
        if not row:
            raise HTTPException(status_code=404, detail="Ürün bulunamadı")
        conn.commit()
        return {"ok": True, "product": row}
    except HTTPException:
        conn.rollback()
        raise
    except Exception:
        conn.rollback()
        raise
    finally:
        conn.close()


@router.post("/products/{product_id}/import-variations")
def import_variations(
    product_id: int,
    payload: Dict[str, Any],
    x_admin_token: Optional[str] = Header(default=None),
):
    """Import a verified static variation snapshot into the local catalog."""
    _require_admin(x_admin_token)
    rows = payload.get("variations") if isinstance(payload, dict) else None
    if not isinstance(rows, list) or not rows:
        raise HTTPException(status_code=400, detail="Varyasyon listesi gerekli")
    if len(rows) > 200:
        raise HTTPException(status_code=400, detail="Çok fazla varyasyon")
    conn = get_db_connection()
    try:
        cur = conn.cursor()
        cur.execute("SELECT id FROM commerce_products WHERE id=%s", (int(product_id),))
        if not cur.fetchone():
            raise HTTPException(status_code=404, detail="Ürün bulunamadı")
        imported = []
        for item in rows:
            if not isinstance(item, dict):
                raise HTTPException(status_code=400, detail="Geçersiz varyasyon")
            source_id = str(item.get("source_variation_id") or item.get("id") or "").strip()
            name = str(item.get("name") or item.get("label") or "").strip()
            if not source_id or not name:
                raise HTTPException(status_code=400, detail="Varyasyon ID ve adı gerekli")
            cur.execute(
                """
                INSERT INTO commerce_variations
                    (product_id, source_variation_id, name, price, currency, is_active, metadata)
                VALUES (%s, %s, %s, %s, %s, %s, %s::jsonb)
                ON CONFLICT (product_id, source_variation_id) DO UPDATE
                SET name=EXCLUDED.name,
                    price=EXCLUDED.price,
                    currency=EXCLUDED.currency,
                    is_active=EXCLUDED.is_active,
                    metadata=EXCLUDED.metadata,
                    updated_at=NOW()
                RETURNING id
                """,
                (
                    int(product_id), source_id, name, _money(item.get("price")),
                    str(item.get("currency") or "TRY").upper()[:3],
                    bool(item.get("is_active", True)),
                    json.dumps(item.get("metadata") if isinstance(item.get("metadata"), dict) else {}, ensure_ascii=False),
                ),
            )
            imported.append({"source_variation_id": source_id, "variation_id": int(cur.fetchone()["id"])})
        conn.commit()
        return {"ok": True, "count": len(imported), "items": imported}
    except HTTPException:
        conn.rollback()
        raise
    except Exception:
        conn.rollback()
        raise
    finally:
        conn.close()


@router.patch("/variations/{variation_id}")
def update_variation(
    variation_id: int,
    payload: Dict[str, Any],
    x_admin_token: Optional[str] = Header(default=None),
):
    _require_admin(x_admin_token)
    allowed = {"name", "price", "currency", "stock_quantity", "is_active", "metadata"}
    fields = {key: payload[key] for key in allowed if key in payload}
    if "price" in fields:
        fields["price"] = _money(fields["price"])
    if "metadata" in fields and not isinstance(fields["metadata"], dict):
        raise HTTPException(status_code=400, detail="Geçersiz varyasyon bilgisi")
    if not fields:
        raise HTTPException(status_code=400, detail="Güncellenecek alan yok")
    conn = get_db_connection()
    try:
        cur = conn.cursor()
        assignments = []
        values = []
        for key, value in fields.items():
            if key == "metadata":
                assignments.append("metadata=%s::jsonb")
                values.append(json.dumps(value, ensure_ascii=False))
            else:
                assignments.append(f"{key}=%s")
                values.append(value)
        assignments.append("updated_at=NOW()")
        values.append(int(variation_id))
        cur.execute(
            f"UPDATE commerce_variations SET {', '.join(assignments)} WHERE id=%s RETURNING id, name, price, currency, stock_quantity, metadata, is_active, updated_at",
            tuple(values),
        )
        row = cur.fetchone()
        if not row:
            raise HTTPException(status_code=404, detail="Varyasyon bulunamadı")
        conn.commit()
        return {"ok": True, "variation": row}
    except HTTPException:
        conn.rollback()
        raise
    finally:
        conn.close()
