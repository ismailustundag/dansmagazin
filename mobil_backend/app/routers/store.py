import os
import re
import uuid
from decimal import Decimal, InvalidOperation, ROUND_HALF_UP
from io import BytesIO
from typing import Any, Dict, List, Optional

import psycopg2
from fastapi import APIRouter, File, Form, Header, HTTPException, Query, UploadFile
from pydantic import BaseModel, Field
from starlette.responses import FileResponse

from app.routers.profile import (
    _effective_is_verified,
    _require_account_id,
    _require_notification_sender_account_id,
)
from app.utils import get_db_connection, display_name

router = APIRouter(prefix="/store", tags=["Mağaza"])

BASE_DIR = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
MEDIA_DIR = os.path.join(BASE_DIR, "media")
STORE_PRODUCT_DIR = os.path.join(MEDIA_DIR, "store_products")
PUBLIC_API_BASE = os.getenv("PUBLIC_BASE_URL", "https://api2.dansmagazin.net").rstrip("/")
STORE_IMAGE_MAX_SIDE = 1600
ALLOWED_STORE_IMAGE_CONTENT_TYPES = {
    "image/jpeg",
    "image/jpg",
    "image/png",
    "image/webp",
    "image/heic",
    "image/heif",
    "image/heic-sequence",
    "image/heif-sequence",
}
ALLOWED_STORE_IMAGE_EXTENSIONS = {".jpg", ".jpeg", ".png", ".webp", ".heic", ".heif"}

db_conn = get_db_connection
_db_conn = db_conn
_display_name = display_name


def init_store_tables() -> None:
    conn = _db_conn()
    try:
        os.makedirs(STORE_PRODUCT_DIR, exist_ok=True)
        cur = conn.cursor()
        cur.execute(
            """
            CREATE TABLE IF NOT EXISTS mobile_store_products (
                id BIGSERIAL PRIMARY KEY,
                account_id INTEGER NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
                title TEXT NOT NULL,
                description TEXT NOT NULL DEFAULT '',
                image_filename TEXT NOT NULL DEFAULT '',
                price_value NUMERIC(12,2) NOT NULL DEFAULT 0,
                currency_code VARCHAR(8) NOT NULL DEFAULT 'TRY',
                is_active BOOLEAN NOT NULL DEFAULT TRUE,
                is_sold BOOLEAN NOT NULL DEFAULT FALSE,
                sold_at TIMESTAMP WITHOUT TIME ZONE,
                created_at TIMESTAMP WITHOUT TIME ZONE DEFAULT NOW(),
                updated_at TIMESTAMP WITHOUT TIME ZONE DEFAULT NOW()
            )
            """
        )
        cur.execute("ALTER TABLE mobile_store_products ADD COLUMN IF NOT EXISTS is_sold BOOLEAN NOT NULL DEFAULT FALSE")
        cur.execute("ALTER TABLE mobile_store_products ADD COLUMN IF NOT EXISTS sold_at TIMESTAMP WITHOUT TIME ZONE")
        cur.execute(
            "CREATE INDEX IF NOT EXISTS idx_mobile_store_products_account_active_created ON mobile_store_products(account_id, is_active, created_at DESC, id DESC)"
        )
        cur.execute(
            "CREATE INDEX IF NOT EXISTS idx_mobile_store_products_active_created ON mobile_store_products(is_active, created_at DESC, id DESC)"
        )
        cur.execute(
            "CREATE INDEX IF NOT EXISTS idx_mobile_store_products_account_status_created ON mobile_store_products(account_id, is_active, is_sold, created_at DESC, id DESC)"
        )
        cur.execute(
            "CREATE INDEX IF NOT EXISTS idx_mobile_store_products_public_created ON mobile_store_products(is_active, is_sold, created_at DESC, id DESC)"
        )
        cur.execute(
            """
            CREATE TABLE IF NOT EXISTS mobile_featured_store_sellers (
                slot SMALLINT PRIMARY KEY,
                account_id INTEGER NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
                updated_by_account_id INTEGER REFERENCES accounts(id) ON DELETE SET NULL,
                updated_at TIMESTAMP WITHOUT TIME ZONE DEFAULT NOW()
            )
            """
        )
        cur.execute(
            "CREATE UNIQUE INDEX IF NOT EXISTS idx_mobile_featured_store_sellers_account ON mobile_featured_store_sellers(account_id)"
        )
        cur.execute("ALTER TABLE mobile_profile_settings ADD COLUMN IF NOT EXISTS store_logo_filename TEXT")
        conn.commit()
    finally:
        conn.close()


class FeaturedStoreSellersUpdateRequest(BaseModel):
    account_ids: List[int] = Field(default_factory=list, max_length=3)


class StoreProductSoldUpdateRequest(BaseModel):
    is_sold: bool = False


class StoreSettingsUpdateRequest(BaseModel):
    store_title: str = ""


class _SellerSummary(Dict[str, Any]):
    pass


def _normalize_text(value: Any) -> str:
    return " ".join(str(value or "").split())


def _normalize_store_title(value: Any) -> str:
    return _normalize_text(value)


_PRICE_CLEAN_RE = re.compile(r"[^0-9,\.] +")


def _parse_price(value: str) -> Decimal:
    raw = str(value or "").strip().replace("TL", "").replace("₺", "")
    raw = raw.replace(" ", "")
    if not raw:
        raise HTTPException(status_code=400, detail="Fiyat zorunlu")
    cleaned = re.sub(r"[^0-9,\.]", "", raw)
    if not cleaned:
        raise HTTPException(status_code=400, detail="Geçersiz fiyat")
    if "," in cleaned and "." in cleaned:
        cleaned = cleaned.replace(".", "").replace(",", ".")
    elif "," in cleaned:
        cleaned = cleaned.replace(",", ".")
    try:
        amount = Decimal(cleaned)
    except InvalidOperation as exc:
        raise HTTPException(status_code=400, detail="Geçersiz fiyat") from exc
    if amount < 0:
        raise HTTPException(status_code=400, detail="Fiyat negatif olamaz")
    return amount.quantize(Decimal("0.01"), rounding=ROUND_HALF_UP)



def _format_price(value: Any) -> str:
    try:
        amount = Decimal(str(value or "0")).quantize(Decimal("0.01"), rounding=ROUND_HALF_UP)
    except Exception:
        amount = Decimal("0.00")
    return f"{amount:.2f}"



def _image_url(filename: str) -> str:
    cleaned = (filename or "").strip().replace("\\", "/")
    if not cleaned:
        return ""
    return f"{PUBLIC_API_BASE}/store/media/{cleaned}"


def _effective_store_title(display_name: str, raw_store_title: Any) -> str:
    store_title = _normalize_store_title(raw_store_title)
    if store_title:
        return store_title
    clean_display_name = _normalize_text(display_name)
    if clean_display_name:
        return f"{clean_display_name} mağazası"
    return "Mağaza"


def _delete_store_image(filename: str) -> None:
    clean = os.path.basename((filename or "").strip())
    if not clean:
        return
    path = os.path.join(STORE_PRODUCT_DIR, clean)
    try:
        if os.path.isfile(path):
            os.remove(path)
    except Exception:
        pass



def _guess_extension(upload: UploadFile) -> str:
    name = (upload.filename or "").strip().lower()
    _, ext = os.path.splitext(name)
    if ext in ALLOWED_STORE_IMAGE_EXTENSIONS:
        return ext
    content_type = (upload.content_type or "").strip().lower()
    if content_type in {"image/png"}:
        return ".png"
    if content_type in {"image/webp"}:
        return ".webp"
    return ".jpg"



def _optimize_store_image(raw: bytes) -> bytes:
    try:
        from PIL import Image
        from PIL import ImageOps
    except Exception as exc:
        raise HTTPException(status_code=500, detail="Görsel işleme için Pillow gerekli") from exc

    if not raw:
        raise HTTPException(status_code=400, detail="Boş dosya yüklenemez")

    with Image.open(BytesIO(raw)) as img:
        img = ImageOps.exif_transpose(img)
        if img.mode not in ("RGB", "RGBA"):
            img = img.convert("RGBA" if "A" in img.getbands() else "RGB")
        if img.mode == "RGBA":
            bg = Image.new("RGB", img.size, (255, 255, 255))
            bg.paste(img, mask=img.split()[-1])
            img = bg
        else:
            img = img.convert("RGB")
        img.thumbnail((STORE_IMAGE_MAX_SIDE, STORE_IMAGE_MAX_SIDE), Image.Resampling.LANCZOS)
        out = BytesIO()
        img.save(out, format="JPEG", quality=84, optimize=True)
        return out.getvalue()



def _store_image_bytes(upload: UploadFile) -> str:
    content_type = (upload.content_type or "").strip().lower()
    ext = _guess_extension(upload)
    if content_type and content_type not in ALLOWED_STORE_IMAGE_CONTENT_TYPES and ext not in ALLOWED_STORE_IMAGE_EXTENSIONS:
        raise HTTPException(status_code=400, detail="Desteklenmeyen görsel türü")
    try:
        raw = upload.file.read()
    finally:
        try:
            upload.file.close()
        except Exception:
            pass
    optimized = _optimize_store_image(raw)
    filename = f"store_{uuid.uuid4().hex}.jpg"
    os.makedirs(STORE_PRODUCT_DIR, exist_ok=True)
    target = os.path.join(STORE_PRODUCT_DIR, filename)
    with open(target, "wb") as f:
        f.write(optimized)
    return filename



def _seller_row_to_json(row: Dict[str, Any]) -> Dict[str, Any]:
    display_name = _display_name(
        row.get("name") or "",
        row.get("email") or "",
        row.get("username") or "",
    )
    store_title = _effective_store_title(display_name, row.get("store_title") or "")
    return {
        "account_id": int(row.get("account_id") or 0),
        "slot": int(row.get("slot") or 0),
        "name": display_name,
        "store_title": store_title,
        "avatar_url": (row.get("avatar_url") or "").strip(),
        "is_verified": _effective_is_verified(row.get("is_verified"), row.get("role")),
        "product_count": int(row.get("product_count") or 0),
        "latest_product_at": str(row.get("latest_product_at") or ""),
        "store_logo_url": _image_url((row.get("store_logo_filename") or "").strip()),
        "cover_image_url": _image_url(((row.get("store_logo_filename") or row.get("cover_image_filename") or "")).strip()),
    }



def _store_product_status(row: Dict[str, Any]) -> str:
    if row.get("is_active") is False:
        return "deleted"
    if bool(row.get("is_sold")):
        return "sold"
    return "active"


def _product_row_to_json(row: Dict[str, Any]) -> Dict[str, Any]:
    seller_name = _display_name(
        row.get("seller_name") or row.get("name") or "",
        row.get("seller_email") or row.get("email") or "",
        row.get("seller_username") or row.get("username") or "",
    )
    is_active = row.get("is_active")
    if is_active is None:
        is_active = True
    is_sold = bool(row.get("is_sold"))
    return {
        "id": int(row.get("id") or 0),
        "title": (row.get("title") or "").strip(),
        "description": (row.get("description") or "").strip(),
        "image_url": _image_url((row.get("image_filename") or "").strip()),
        "price": _format_price(row.get("price_value")),
        "currency_code": (row.get("currency_code") or "TRY").strip() or "TRY",
        "is_active": bool(is_active),
        "is_sold": is_sold,
        "status": _store_product_status({"is_active": bool(is_active), "is_sold": is_sold}),
        "sold_at": str(row.get("sold_at") or ""),
        "is_publicly_visible": bool(is_active) and not is_sold,
        "seller": {
            "account_id": int(row.get("account_id") or row.get("seller_account_id") or 0),
            "name": seller_name,
            "avatar_url": (row.get("seller_avatar_url") or row.get("avatar_url") or "").strip(),
            "is_verified": _effective_is_verified(row.get("seller_is_verified") or row.get("is_verified"), row.get("seller_role") or row.get("role")),
        },
        "created_at": str(row.get("created_at") or ""),
        "updated_at": str(row.get("updated_at") or ""),
    }



def _store_owner_meta(conn, account_id: int) -> Dict[str, Any]:
    cur = conn.cursor()
    cur.execute(
        """
        SELECT
            COALESCE(ps.is_verified, FALSE) AS is_verified,
            COALESCE(ps.store_enabled, FALSE) AS store_enabled,
            COALESCE(ps.store_title, '') AS store_title,
            COALESCE(ps.store_logo_filename, '') AS store_logo_filename,
            COALESCE(ps.username, '') AS username,
            COALESCE(a.name, '') AS name,
            COALESCE(a.email, '') AS email,
            COALESCE(a.role, '') AS role
        FROM accounts a
        LEFT JOIN mobile_profile_settings ps ON ps.account_id = a.id
        WHERE a.id=%s AND COALESCE(a.is_active,1)=1
        LIMIT 1
        """,
        (int(account_id),),
    )
    row = cur.fetchone() or {}
    if not row:
        raise HTTPException(status_code=404, detail="Kullanıcı bulunamadı")
    return row


def _require_verified_store_owner(conn, account_id: int, *, require_store_enabled: bool = True) -> None:
    row = _store_owner_meta(conn, account_id)
    if not _effective_is_verified(row.get("is_verified"), row.get("role")):
        raise HTTPException(status_code=403, detail="Sadece onaylı kullanıcılar mağaza açabilir")
    if require_store_enabled and not bool(row.get("store_enabled")):
        raise HTTPException(status_code=403, detail="Önce mağazanı açmalısın")


def _fetch_store_product_row(
    conn,
    *,
    product_id: int,
    owner_account_id: Optional[int] = None,
    include_inactive: bool = False,
) -> Dict[str, Any]:
    cur = conn.cursor()
    where_clauses = [
        "p.id=%s",
        "COALESCE(a.is_active,1)=1",
    ]
    values: List[Any] = [int(product_id)]
    if owner_account_id is not None:
        where_clauses.append("p.account_id=%s")
        values.append(int(owner_account_id))
    if not include_inactive:
        where_clauses.append("COALESCE(p.is_active, TRUE)=TRUE")
    cur.execute(
        f"""
        SELECT
            p.id,
            p.account_id,
            p.title,
            p.description,
            p.image_filename,
            p.price_value,
            p.currency_code,
            p.is_active,
            COALESCE(p.is_sold, FALSE) AS is_sold,
            p.sold_at,
            p.created_at,
            p.updated_at,
            COALESCE(a.name,'') AS seller_name,
            COALESCE(a.email,'') AS seller_email,
            COALESCE(a.role,'') AS seller_role,
            COALESCE(ps.username,'') AS seller_username,
            COALESCE(ps.avatar_url,'') AS seller_avatar_url,
            COALESCE(ps.is_verified, FALSE) AS seller_is_verified
        FROM mobile_store_products p
        JOIN accounts a ON a.id = p.account_id
        LEFT JOIN mobile_profile_settings ps ON ps.account_id = a.id
        WHERE {" AND ".join(where_clauses)}
        LIMIT 1
        """,
        tuple(values),
    )
    return cur.fetchone() or {}


def _fetch_featured_store_sellers(conn) -> List[Dict[str, Any]]:
    cur = conn.cursor()
    cur.execute(
        """
        SELECT
            mfss.slot,
            seller.account_id,
            seller.name,
            seller.email,
            seller.role,
            seller.username,
            seller.avatar_url,
            seller.is_verified,
            seller.product_count,
            seller.latest_product_at,
            seller.cover_image_filename
        FROM mobile_featured_store_sellers mfss
        JOIN (
            SELECT
                p.account_id,
                COALESCE(a.name,'') AS name,
                COALESCE(a.email,'') AS email,
                COALESCE(a.role,'') AS role,
                COALESCE(ps.username,'') AS username,
                COALESCE(ps.store_title,'') AS store_title,
                COALESCE(ps.store_logo_filename,'') AS store_logo_filename,
                COALESCE(ps.avatar_url,'') AS avatar_url,
                COALESCE(ps.is_verified, FALSE) AS is_verified,
                COUNT(*)::int AS product_count,
                MAX(p.created_at) AS latest_product_at,
                (
                    SELECT p2.image_filename
                    FROM mobile_store_products p2
                    WHERE p2.account_id = p.account_id
                      AND COALESCE(p2.is_active, TRUE)=TRUE
                      AND COALESCE(p2.is_sold, FALSE)=FALSE
                    ORDER BY p2.created_at DESC, p2.id DESC
                    LIMIT 1
                ) AS cover_image_filename
            FROM mobile_store_products p
            JOIN accounts a ON a.id = p.account_id
            LEFT JOIN mobile_profile_settings ps ON ps.account_id = a.id
            WHERE COALESCE(p.is_active, TRUE)=TRUE
              AND COALESCE(p.is_sold, FALSE)=FALSE
              AND COALESCE(a.is_active,1)=1
              AND COALESCE(ps.store_enabled, FALSE)=TRUE
            GROUP BY p.account_id, a.name, a.email, a.role, ps.username, ps.store_title, ps.store_logo_filename, ps.avatar_url, ps.is_verified
        ) seller ON seller.account_id = mfss.account_id
        ORDER BY mfss.slot ASC
        """
    )
    rows = cur.fetchall() or []
    return [_seller_row_to_json(row) for row in rows if _effective_is_verified(row.get("is_verified"), row.get("role"))]


@router.get("/sellers", summary="Mağaza sahipleri")
def list_store_sellers(limit: int = Query(default=100, ge=1, le=300)):
    conn = _db_conn()
    try:
        cur = conn.cursor()
        cur.execute(
            """
            SELECT
                p.account_id,
                COALESCE(a.name,'') AS name,
                COALESCE(a.email,'') AS email,
                COALESCE(a.role,'') AS role,
                COALESCE(ps.username,'') AS username,
                COALESCE(ps.store_title,'') AS store_title,
                COALESCE(ps.store_logo_filename,'') AS store_logo_filename,
                COALESCE(ps.avatar_url,'') AS avatar_url,
                COALESCE(ps.is_verified, FALSE) AS is_verified,
                COUNT(*)::int AS product_count,
                MAX(p.created_at) AS latest_product_at,
                (
                    SELECT p2.image_filename
                    FROM mobile_store_products p2
                    WHERE p2.account_id = p.account_id
                      AND COALESCE(p2.is_active, TRUE)=TRUE
                      AND COALESCE(p2.is_sold, FALSE)=FALSE
                    ORDER BY p2.created_at DESC, p2.id DESC
                    LIMIT 1
                ) AS cover_image_filename
            FROM mobile_store_products p
            JOIN accounts a ON a.id = p.account_id
            LEFT JOIN mobile_profile_settings ps ON ps.account_id = a.id
            WHERE COALESCE(p.is_active, TRUE)=TRUE
              AND COALESCE(p.is_sold, FALSE)=FALSE
              AND COALESCE(a.is_active,1)=1
              AND COALESCE(ps.store_enabled, FALSE)=TRUE
            GROUP BY p.account_id, a.name, a.email, a.role, ps.username, ps.store_title, ps.store_logo_filename, ps.avatar_url, ps.is_verified
            ORDER BY MAX(p.created_at) DESC, p.account_id DESC
            LIMIT %s
            """,
            (int(limit),),
        )
        rows = cur.fetchall() or []
        items = [_seller_row_to_json(row) for row in rows if _effective_is_verified(row.get("is_verified"), row.get("role"))]
        return {"items": items}
    finally:
        conn.close()


@router.get("/featured", summary="Öne çıkan mağazalar")
def list_featured_store_sellers():
    conn = _db_conn()
    try:
        return {"ok": True, "items": _fetch_featured_store_sellers(conn)}
    finally:
        conn.close()


@router.get("/sellers/{seller_account_id}", summary="Bir mağazanın ürünleri")
def get_seller_store(seller_account_id: int):
    conn = _db_conn()
    try:
        seller_id = int(seller_account_id)
        cur = conn.cursor()
        cur.execute(
            """
            SELECT
                a.id AS account_id,
                COALESCE(a.name,'') AS name,
                COALESCE(a.email,'') AS email,
                COALESCE(a.role,'') AS role,
                COALESCE(ps.username,'') AS username,
                COALESCE(ps.store_title,'') AS store_title,
                COALESCE(ps.store_logo_filename,'') AS store_logo_filename,
                COALESCE(ps.avatar_url,'') AS avatar_url,
                COALESCE(ps.is_verified, FALSE) AS is_verified,
                COALESCE(ps.store_enabled, FALSE) AS store_enabled
            FROM accounts a
            LEFT JOIN mobile_profile_settings ps ON ps.account_id = a.id
            WHERE a.id=%s AND COALESCE(a.is_active,1)=1
            LIMIT 1
            """,
            (seller_id,),
        )
        seller = cur.fetchone() or {}
        if not seller:
            raise HTTPException(status_code=404, detail="Mağaza bulunamadı")
        if not _effective_is_verified(seller.get("is_verified"), seller.get("role")) or not bool(seller.get("store_enabled")):
            raise HTTPException(status_code=404, detail="Mağaza bulunamadı")
        cur.execute(
            """
            SELECT
                p.id,
                p.account_id,
                p.title,
                p.description,
                p.image_filename,
                p.price_value,
                p.currency_code,
                p.is_active,
                COALESCE(p.is_sold, FALSE) AS is_sold,
                p.sold_at,
                p.created_at,
                p.updated_at,
                COALESCE(a.name,'') AS seller_name,
                COALESCE(a.email,'') AS seller_email,
                COALESCE(a.role,'') AS seller_role,
                COALESCE(ps.username,'') AS seller_username,
                COALESCE(ps.avatar_url,'') AS seller_avatar_url,
                COALESCE(ps.is_verified, FALSE) AS seller_is_verified
            FROM mobile_store_products p
            JOIN accounts a ON a.id = p.account_id
            LEFT JOIN mobile_profile_settings ps ON ps.account_id = a.id
            WHERE p.account_id=%s
              AND COALESCE(p.is_active, TRUE)=TRUE
              AND COALESCE(p.is_sold, FALSE)=FALSE
            ORDER BY p.created_at DESC, p.id DESC
            """,
            (seller_id,),
        )
        rows = cur.fetchall() or []
        return {
            "seller": _seller_row_to_json({
                **seller,
                "product_count": len(rows),
                "latest_product_at": rows[0].get("created_at") if rows else "",
                "cover_image_filename": rows[0].get("image_filename") if rows else "",
            }),
            "products": [_product_row_to_json(row) for row in rows],
        }
    finally:
        conn.close()


@router.get("/products", summary="Mağaza ürünleri")
def list_store_products(limit: int = Query(default=300, ge=1, le=500)):
    conn = _db_conn()
    try:
        cur = conn.cursor()
        cur.execute(
            """
            SELECT
                p.id,
                p.account_id,
                p.title,
                p.description,
                p.image_filename,
                p.price_value,
                p.currency_code,
                p.is_active,
                COALESCE(p.is_sold, FALSE) AS is_sold,
                p.sold_at,
                p.created_at,
                p.updated_at,
                COALESCE(a.name,'') AS seller_name,
                COALESCE(a.email,'') AS seller_email,
                COALESCE(a.role,'') AS seller_role,
                COALESCE(ps.username,'') AS seller_username,
                COALESCE(ps.avatar_url,'') AS seller_avatar_url,
                COALESCE(ps.is_verified, FALSE) AS seller_is_verified
            FROM mobile_store_products p
            JOIN accounts a ON a.id = p.account_id
            LEFT JOIN mobile_profile_settings ps ON ps.account_id = a.id
            WHERE COALESCE(p.is_active, TRUE)=TRUE
              AND COALESCE(p.is_sold, FALSE)=FALSE
              AND COALESCE(a.is_active,1)=1
              AND COALESCE(ps.store_enabled, FALSE)=TRUE
            ORDER BY p.created_at DESC, p.id DESC
            LIMIT %s
            """,
            (int(limit),),
        )
        rows = cur.fetchall() or []
        items = []
        for row in rows:
            if not _effective_is_verified(row.get("seller_is_verified"), row.get("seller_role")):
                continue
            items.append(_product_row_to_json(row))
        return {"items": items}
    finally:
        conn.close()


@router.get("/products/{product_id}", summary="Ürün detayı")
def get_store_product(product_id: int, authorization: Optional[str] = Header(default=None)):
    conn = _db_conn()
    try:
        row = _fetch_store_product_row(conn, product_id=int(product_id))
        if not row:
            raise HTTPException(status_code=404, detail="Ürün bulunamadı")
        if bool(row.get("is_sold")):
            if not authorization:
                raise HTTPException(status_code=404, detail="Ürün bulunamadı")
            account_id = _require_account_id(conn, authorization)
            if int(row.get("account_id") or 0) != int(account_id):
                raise HTTPException(status_code=404, detail="Ürün bulunamadı")
        return _product_row_to_json(row)
    finally:
        conn.close()


@router.get("/me/settings", summary="Kendi mağaza ayarlarım")
def get_my_store_settings(authorization: Optional[str] = Header(default=None)):
    conn = _db_conn()
    try:
        account_id = _require_account_id(conn, authorization)
        owner = _store_owner_meta(conn, account_id)
        _require_verified_store_owner(conn, account_id, require_store_enabled=False)
        display_name = _display_name(
            owner.get("name") or "",
            owner.get("email") or "",
            owner.get("username") or "",
        )
        return {
            "ok": True,
            "store_enabled": bool(owner.get("store_enabled")),
            "store_title": _normalize_store_title(owner.get("store_title") or ""),
            "effective_store_title": _effective_store_title(display_name, owner.get("store_title") or ""),
            "store_logo_url": _image_url((owner.get("store_logo_filename") or "").strip()),
        }
    finally:
        conn.close()


@router.get("/my/products", summary="Kendi ürünlerim")
def list_my_store_products(authorization: Optional[str] = Header(default=None)):
    conn = _db_conn()
    try:
        account_id = _require_account_id(conn, authorization)
        _require_verified_store_owner(conn, account_id)
        cur = conn.cursor()
        cur.execute(
            """
            SELECT
                p.id,
                p.account_id,
                p.title,
                p.description,
                p.image_filename,
                p.price_value,
                p.currency_code,
                p.is_active,
                COALESCE(p.is_sold, FALSE) AS is_sold,
                p.sold_at,
                p.created_at,
                p.updated_at,
                COALESCE(a.name,'') AS seller_name,
                COALESCE(a.email,'') AS seller_email,
                COALESCE(a.role,'') AS seller_role,
                COALESCE(ps.username,'') AS seller_username,
                COALESCE(ps.avatar_url,'') AS seller_avatar_url,
                COALESCE(ps.is_verified, FALSE) AS seller_is_verified
            FROM mobile_store_products p
            JOIN accounts a ON a.id = p.account_id
            LEFT JOIN mobile_profile_settings ps ON ps.account_id = a.id
            WHERE p.account_id=%s
              AND COALESCE(p.is_active, TRUE)=TRUE
            ORDER BY COALESCE(p.is_sold, FALSE) ASC, p.created_at DESC, p.id DESC
            """,
            (int(account_id),),
        )
        rows = cur.fetchall() or []
        return {"items": [_product_row_to_json(row) for row in rows]}
    finally:
        conn.close()


@router.put("/me/settings", summary="Kendi mağaza ayarlarımı güncelle")
def update_my_store_settings(
    payload: StoreSettingsUpdateRequest,
    authorization: Optional[str] = Header(default=None),
):
    conn = _db_conn()
    try:
        account_id = _require_account_id(conn, authorization)
        owner = _store_owner_meta(conn, account_id)
        _require_verified_store_owner(conn, account_id, require_store_enabled=False)
        store_title = _normalize_store_title(payload.store_title or "")
        if store_title and (len(store_title) < 2 or len(store_title) > 80):
            raise HTTPException(status_code=400, detail="Mağaza adı 2-80 karakter olmalı")
        cur = conn.cursor()
        cur.execute(
            """
            INSERT INTO mobile_profile_settings (account_id, store_title, updated_at)
            VALUES (%s, NULLIF(%s,''), NOW())
            ON CONFLICT (account_id) DO UPDATE
            SET store_title = NULLIF(EXCLUDED.store_title, ''),
                updated_at = NOW()
            """,
            (int(account_id), store_title),
        )
        conn.commit()
        display_name = _display_name(
            owner.get("name") or "",
            owner.get("email") or "",
            owner.get("username") or "",
        )
        return {
            "ok": True,
            "store_enabled": bool(owner.get("store_enabled")),
            "store_title": store_title,
            "effective_store_title": _effective_store_title(display_name, store_title),
            "store_logo_url": _image_url((owner.get("store_logo_filename") or "").strip()),
        }
    except HTTPException:
        conn.rollback()
        raise
    except Exception as exc:
        conn.rollback()
        raise HTTPException(status_code=500, detail=f"Mağaza ayarları güncellenemedi: {exc}") from exc
    finally:
        conn.close()


@router.post("/me/logo", summary="Kendi mağaza logosunu yükle")
def upload_my_store_logo(
    image: UploadFile = File(...),
    authorization: Optional[str] = Header(default=None),
):
    conn = _db_conn()
    new_filename = ""
    try:
        account_id = _require_account_id(conn, authorization)
        owner = _store_owner_meta(conn, account_id)
        _require_verified_store_owner(conn, account_id, require_store_enabled=False)
        old_filename = (owner.get("store_logo_filename") or "").strip()
        new_filename = _store_image_bytes(image)
        cur = conn.cursor()
        cur.execute(
            """
            INSERT INTO mobile_profile_settings (account_id, store_logo_filename, updated_at)
            VALUES (%s, %s, NOW())
            ON CONFLICT (account_id) DO UPDATE
            SET store_logo_filename = EXCLUDED.store_logo_filename,
                updated_at = NOW()
            """,
            (int(account_id), new_filename),
        )
        conn.commit()
        if old_filename and old_filename != new_filename:
            _delete_store_image(old_filename)
        store_title = _normalize_store_title(owner.get("store_title") or "")
        display_name = _display_name(
            owner.get("name") or "",
            owner.get("email") or "",
            owner.get("username") or "",
        )
        return {
            "ok": True,
            "store_enabled": bool(owner.get("store_enabled")),
            "store_title": store_title,
            "effective_store_title": _effective_store_title(display_name, store_title),
            "store_logo_url": _image_url(new_filename),
        }
    except HTTPException:
        conn.rollback()
        if new_filename:
            _delete_store_image(new_filename)
        raise
    except Exception as exc:
        conn.rollback()
        if new_filename:
            _delete_store_image(new_filename)
        raise HTTPException(status_code=500, detail=f"Mağaza logosu yüklenemedi: {exc}") from exc
    finally:
        conn.close()


@router.post("/products", summary="Ürün oluştur")
def create_store_product(
    title: str = Form(...),
    description: str = Form(""),
    price: str = Form(...),
    image: UploadFile = File(...),
    authorization: Optional[str] = Header(default=None),
):
    conn = _db_conn()
    image_filename = ""
    try:
        account_id = _require_account_id(conn, authorization)
        _require_verified_store_owner(conn, account_id)
        title_text = _normalize_text(title)
        if len(title_text) < 2:
            raise HTTPException(status_code=400, detail="Ürün adı çok kısa")
        description_text = str(description or "").strip()
        if len(description_text) < 3:
            raise HTTPException(status_code=400, detail="Ürün açıklaması çok kısa")
        amount = _parse_price(price)
        image_filename = _store_image_bytes(image)
        cur = conn.cursor()
        cur.execute(
            """
            INSERT INTO mobile_store_products
                (account_id, title, description, image_filename, price_value, currency_code, is_active, is_sold, sold_at, created_at, updated_at)
            VALUES (%s, %s, %s, %s, %s, 'TRY', TRUE, FALSE, NULL, NOW(), NOW())
            RETURNING id
            """,
            (int(account_id), title_text, description_text, image_filename, amount),
        )
        row = cur.fetchone() or {}
        conn.commit()
        return {"ok": True, "product_id": int(row.get("id") or 0)}
    except HTTPException:
        conn.rollback()
        if image_filename:
            _delete_store_image(image_filename)
        raise
    except Exception as exc:
        conn.rollback()
        if image_filename:
            _delete_store_image(image_filename)
        raise HTTPException(status_code=500, detail=f"Ürün oluşturulamadı: {exc}") from exc
    finally:
        conn.close()


@router.put("/products/{product_id}", summary="Ürün güncelle")
def update_store_product(
    product_id: int,
    title: str = Form(...),
    description: str = Form(""),
    price: str = Form(...),
    image: Optional[UploadFile] = File(default=None),
    authorization: Optional[str] = Header(default=None),
):
    conn = _db_conn()
    new_image_filename = ""
    old_image_filename = ""
    try:
        account_id = _require_account_id(conn, authorization)
        _require_verified_store_owner(conn, account_id)
        existing = _fetch_store_product_row(conn, product_id=int(product_id), owner_account_id=account_id)
        if not existing:
            raise HTTPException(status_code=404, detail="Ürün bulunamadı")

        title_text = _normalize_text(title)
        if len(title_text) < 2:
            raise HTTPException(status_code=400, detail="Ürün adı çok kısa")
        description_text = str(description or "").strip()
        if len(description_text) < 3:
            raise HTTPException(status_code=400, detail="Ürün açıklaması çok kısa")
        amount = _parse_price(price)

        old_image_filename = (existing.get("image_filename") or "").strip()
        final_image_filename = old_image_filename
        if image is not None:
            new_image_filename = _store_image_bytes(image)
            final_image_filename = new_image_filename

        cur = conn.cursor()
        cur.execute(
            """
            UPDATE mobile_store_products
            SET title=%s,
                description=%s,
                image_filename=%s,
                price_value=%s,
                updated_at=NOW()
            WHERE id=%s
              AND account_id=%s
              AND COALESCE(is_active, TRUE)=TRUE
            RETURNING id
            """,
            (
                title_text,
                description_text,
                final_image_filename,
                amount,
                int(product_id),
                int(account_id),
            ),
        )
        row = cur.fetchone() or {}
        if not row:
            raise HTTPException(status_code=404, detail="Ürün bulunamadı")
        updated = _fetch_store_product_row(conn, product_id=int(product_id), owner_account_id=account_id)
        conn.commit()
        if new_image_filename and old_image_filename and old_image_filename != new_image_filename:
            _delete_store_image(old_image_filename)
        return {"ok": True, "product_id": int(row.get("id") or 0), "item": _product_row_to_json(updated)}
    except HTTPException:
        conn.rollback()
        if new_image_filename:
            _delete_store_image(new_image_filename)
        raise
    except Exception as exc:
        conn.rollback()
        if new_image_filename:
            _delete_store_image(new_image_filename)
        raise HTTPException(status_code=500, detail=f"Ürün güncellenemedi: {exc}") from exc
    finally:
        conn.close()


@router.put("/products/{product_id}/sold", summary="Ürün satıldı durumunu güncelle")
def update_store_product_sold_status(
    product_id: int,
    payload: StoreProductSoldUpdateRequest,
    authorization: Optional[str] = Header(default=None),
):
    conn = _db_conn()
    try:
        account_id = _require_account_id(conn, authorization)
        _require_verified_store_owner(conn, account_id)
        existing = _fetch_store_product_row(conn, product_id=int(product_id), owner_account_id=account_id)
        if not existing:
            raise HTTPException(status_code=404, detail="Ürün bulunamadı")

        is_sold = bool(payload.is_sold)
        cur = conn.cursor()
        cur.execute(
            """
            UPDATE mobile_store_products
            SET is_sold=%s,
                sold_at=CASE WHEN %s THEN COALESCE(sold_at, NOW()) ELSE NULL END,
                updated_at=NOW()
            WHERE id=%s
              AND account_id=%s
              AND COALESCE(is_active, TRUE)=TRUE
            RETURNING id
            """,
            (is_sold, is_sold, int(product_id), int(account_id)),
        )
        row = cur.fetchone() or {}
        if not row:
            raise HTTPException(status_code=404, detail="Ürün bulunamadı")
        updated = _fetch_store_product_row(conn, product_id=int(product_id), owner_account_id=account_id)
        conn.commit()
        return {"ok": True, "product_id": int(row.get("id") or 0), "item": _product_row_to_json(updated)}
    except HTTPException:
        conn.rollback()
        raise
    except Exception as exc:
        conn.rollback()
        raise HTTPException(status_code=500, detail=f"Ürün durumu güncellenemedi: {exc}") from exc
    finally:
        conn.close()


@router.delete("/products/{product_id}", summary="Ürün sil")
def delete_store_product(product_id: int, authorization: Optional[str] = Header(default=None)):
    conn = _db_conn()
    image_filename = ""
    try:
        account_id = _require_account_id(conn, authorization)
        _require_verified_store_owner(conn, account_id)
        existing = _fetch_store_product_row(conn, product_id=int(product_id), owner_account_id=account_id)
        if not existing:
            raise HTTPException(status_code=404, detail="Ürün bulunamadı")

        image_filename = (existing.get("image_filename") or "").strip()
        cur = conn.cursor()
        cur.execute(
            """
            UPDATE mobile_store_products
            SET is_active=FALSE,
                updated_at=NOW()
            WHERE id=%s
              AND account_id=%s
              AND COALESCE(is_active, TRUE)=TRUE
            RETURNING id
            """,
            (int(product_id), int(account_id)),
        )
        row = cur.fetchone() or {}
        if not row:
            raise HTTPException(status_code=404, detail="Ürün bulunamadı")
        conn.commit()
        if image_filename:
            _delete_store_image(image_filename)
        return {"ok": True, "product_id": int(row.get("id") or 0), "deleted": True}
    except HTTPException:
        conn.rollback()
        raise
    except Exception as exc:
        conn.rollback()
        raise HTTPException(status_code=500, detail=f"Ürün silinemedi: {exc}") from exc
    finally:
        conn.close()


@router.post("/me/open", summary="Mağazayı aktifleştir")
def open_my_store(authorization: Optional[str] = Header(default=None)):
    conn = _db_conn()
    try:
        account_id = _require_account_id(conn, authorization)
        _require_verified_store_owner(conn, account_id, require_store_enabled=False)
        cur = conn.cursor()
        cur.execute(
            """
            INSERT INTO mobile_profile_settings
                (account_id, store_enabled, updated_at)
            VALUES (%s, TRUE, NOW())
            ON CONFLICT (account_id) DO UPDATE
            SET store_enabled=TRUE,
                updated_at=NOW()
            """,
            (int(account_id),),
        )
        conn.commit()
        return {"ok": True, "account_id": int(account_id), "store_enabled": True}
    except HTTPException:
        conn.rollback()
        raise
    except Exception as exc:
        conn.rollback()
        raise HTTPException(status_code=500, detail=f"Mağaza açılamadı: {exc}") from exc
    finally:
        conn.close()


@router.put("/featured/admin", summary="Super admin öne çıkan mağazaları kaydet")
def admin_featured_store_sellers_upsert(
    payload: FeaturedStoreSellersUpdateRequest,
    authorization: Optional[str] = Header(default=None),
):
    conn = _db_conn()
    try:
        sender_account_id = _require_notification_sender_account_id(conn, authorization)
        raw_ids = [int(x) for x in (payload.account_ids or []) if int(x) > 0]
        account_ids: List[int] = []
        seen = set()
        for account_id in raw_ids:
            if account_id in seen:
                continue
            seen.add(account_id)
            account_ids.append(account_id)
        if len(account_ids) > 3:
            raise HTTPException(status_code=400, detail="En fazla 3 mağaza seçebilirsiniz")

        cur = conn.cursor()
        if account_ids:
            placeholders = ",".join(["%s"] * len(account_ids))
            cur.execute(
                f"""
                SELECT DISTINCT p.account_id
                FROM mobile_store_products p
                JOIN accounts a ON a.id = p.account_id
                LEFT JOIN mobile_profile_settings ps ON ps.account_id = a.id
                WHERE p.account_id IN ({placeholders})
                  AND COALESCE(p.is_active, TRUE)=TRUE
                  AND COALESCE(p.is_sold, FALSE)=FALSE
                  AND COALESCE(a.is_active,1)=1
                  AND COALESCE(ps.store_enabled, FALSE)=TRUE
                """,
                tuple(account_ids),
            )
            valid_ids = {int(row["account_id"]) for row in (cur.fetchall() or [])}
            missing = [account_id for account_id in account_ids if account_id not in valid_ids]
            if missing:
                raise HTTPException(status_code=400, detail="Seçilen mağazalardan bazıları artık aktif değil")
            for account_id in account_ids:
                cur.execute(
                    """
                    SELECT
                        COALESCE(ps.is_verified, FALSE) AS is_verified,
                        COALESCE(a.role, '') AS role
                    FROM accounts a
                    LEFT JOIN mobile_profile_settings ps ON ps.account_id = a.id
                    WHERE a.id=%s
                    LIMIT 1
                    """,
                    (int(account_id),),
                )
                row = cur.fetchone() or {}
                if not _effective_is_verified(row.get("is_verified"), row.get("role")):
                    raise HTTPException(status_code=400, detail="Seçilen mağazalardan bazıları onaylı kullanıcıya ait değil")

        cur.execute("DELETE FROM mobile_featured_store_sellers")
        for index, account_id in enumerate(account_ids, start=1):
            cur.execute(
                """
                INSERT INTO mobile_featured_store_sellers (slot, account_id, updated_by_account_id, updated_at)
                VALUES (%s, %s, %s, NOW())
                """,
                (index, int(account_id), int(sender_account_id)),
            )
        conn.commit()
        return {
            "ok": True,
            "updated_by_account_id": int(sender_account_id),
            "items": _fetch_featured_store_sellers(conn),
        }
    except HTTPException:
        conn.rollback()
        raise
    except Exception as exc:
        conn.rollback()
        raise HTTPException(status_code=500, detail=f"Öne çıkan mağazalar kaydedilemedi: {exc}") from exc
    finally:
        conn.close()


@router.get("/media/{filename}", summary="Mağaza ürün görseli")
def get_store_media(filename: str):
    clean = os.path.basename((filename or "").strip())
    path = os.path.join(STORE_PRODUCT_DIR, clean)
    if not clean or not os.path.isfile(path):
        raise HTTPException(status_code=404, detail="Görsel bulunamadı")
    return FileResponse(path)
