"""Halk Ode hosted payment adapter for the static Dansmagazin checkout."""

import base64
import hashlib
import json
import os
import secrets
import uuid
from datetime import datetime, timezone
from typing import Any, Dict, List, Optional
from urllib.parse import urlencode, urlsplit, urlunsplit, parse_qsl

import httpx
from fastapi import APIRouter, Header, HTTPException, Query, Request
from fastapi.responses import HTMLResponse, RedirectResponse
from pydantic import BaseModel, Field

from app.utils import get_db_connection

router = APIRouter(prefix="/payments", tags=["Payments"])


def _cfg(name: str) -> str:
    return os.getenv(name, "").strip()


def _is_configured() -> bool:
    return all(_cfg(name) for name in ("HALKODE_APP_ID", "HALKODE_APP_SECRET", "HALKODE_MERCHANT_KEY"))


def _base_url() -> str:
    return "https://testapp.halkode.com.tr/ccpayment" if _cfg("HALKODE_ENVIRONMENT").lower() in {"test", "sandbox"} else "https://app.halkode.com.tr/ccpayment"


def _now() -> str:
    return datetime.now(timezone.utc).isoformat()


def _ensure_table() -> None:
    conn = get_db_connection()
    try:
        with conn.cursor() as cur:
            cur.execute(
                """
                CREATE TABLE IF NOT EXISTS static_payment_orders (
                    id BIGSERIAL PRIMARY KEY,
                    invoice_id TEXT UNIQUE NOT NULL,
                    amount NUMERIC(12,2) NOT NULL,
                    currency TEXT NOT NULL DEFAULT 'TRY',
                    status TEXT NOT NULL DEFAULT 'pending',
                    customer_email TEXT NOT NULL DEFAULT '',
                    payload JSONB NOT NULL DEFAULT '{}'::jsonb,
                    provider_status TEXT NOT NULL DEFAULT '',
                    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
                    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
                )
                """
            )
        conn.commit()
    finally:
        conn.close()


def _post_json(url: str, payload: Dict[str, Any], headers: Optional[Dict[str, str]] = None) -> Dict[str, Any]:
    try:
        response = httpx.post(url, json=payload, headers=headers or {}, timeout=30.0)
        response.raise_for_status()
        data = response.json()
    except (httpx.HTTPError, ValueError) as exc:
        raise HTTPException(status_code=502, detail="Halk Ode servisine ulasilamadi") from exc
    return data if isinstance(data, dict) else {}


def _token() -> str:
    data = _post_json(
        f"{_base_url()}/api/token",
        {"app_id": _cfg("HALKODE_APP_ID"), "app_secret": _cfg("HALKODE_APP_SECRET")},
    )
    token = str(((data.get("data") or {}).get("token") or "")).strip()
    if not token:
        raise HTTPException(status_code=502, detail="Halk Ode tokeni alinamadi")
    return token


def _hash_key(total: str, installments: int, invoice_id: str) -> str:
    """Match the PHP plugin's generateHashKey implementation exactly."""
    merchant_key = _cfg("HALKODE_MERCHANT_KEY")
    app_secret = _cfg("HALKODE_APP_SECRET")
    data = f"{total}|{installments}|TRY|{merchant_key}|{invoice_id}"
    iv_text = hashlib.sha1(secrets.token_bytes(32)).hexdigest()[:16]
    salt_text = hashlib.sha1(secrets.token_bytes(32)).hexdigest()[:4]
    password = hashlib.sha1(app_secret.encode()).hexdigest()
    # PHP passes the hexadecimal SHA-256 string to OpenSSL as the key.
    key = hashlib.sha256((password + salt_text).encode()).hexdigest().encode()[:32]
    from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
    from cryptography.hazmat.primitives import padding
    padder = padding.PKCS7(128).padder()
    padded = padder.update(data.encode()) + padder.finalize()
    encrypted = Cipher(algorithms.AES(key), modes.CBC(iv_text.encode())).encryptor()
    ciphertext = encrypted.update(padded) + encrypted.finalize()
    return f"{iv_text}:{salt_text}:{base64.b64encode(ciphertext).decode().replace('/', '__')}"


def _checkstatus_hash_key(invoice_id: str) -> str:
    """Match Halk Ode's checkstatus/refund hash: invoice_id|merchant_key."""
    merchant_key = _cfg("HALKODE_MERCHANT_KEY")
    app_secret = _cfg("HALKODE_APP_SECRET")
    data = f"{invoice_id}|{merchant_key}"
    iv_text = hashlib.sha1(secrets.token_bytes(32)).hexdigest()[:16]
    salt_text = hashlib.sha1(secrets.token_bytes(32)).hexdigest()[:4]
    password = hashlib.sha1(app_secret.encode()).hexdigest()
    key = hashlib.sha256((password + salt_text).encode()).hexdigest().encode()[:32]
    from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
    from cryptography.hazmat.primitives import padding
    padder = padding.PKCS7(128).padder()
    padded = padder.update(data.encode()) + padder.finalize()
    encrypted = Cipher(algorithms.AES(key), modes.CBC(iv_text.encode())).encryptor()
    ciphertext = encrypted.update(padded) + encrypted.finalize()
    return f"{iv_text}:{salt_text}:{base64.b64encode(ciphertext).decode().replace('/', '__')}"


def _payment_return_url() -> str:
    return _cfg("HALKODE_RETURN_URL") or "https://api2.dansmagazin.net/payments/halkode/return"


def _payment_cancel_url() -> str:
    return _cfg("HALKODE_CANCEL_URL") or _payment_return_url()


def _site_base_url() -> str:
    return (_cfg("PUBLIC_SITE_BASE_URL") or "https://dansmagazin.net").rstrip("/")


def _checkout_result_url(state: str, invoice_id: str = "") -> str:
    query = {"halkode_status": (state or "failed").strip().lower() or "failed"}
    if invoice_id:
        query["invoice_id"] = invoice_id
    return f"{_site_base_url()}/odeme/?{urlencode(query)}"


def _sync_adf_order_to_app(invoice_id: str, payload: Dict[str, Any], order_status: str) -> Dict[str, Any]:
    """Reuse the app's idempotent Woo order path for paid and terminal status changes."""
    items = payload.get("items") if isinstance(payload.get("items"), list) else []
    line_items: List[Dict[str, Any]] = []
    for index, item in enumerate(items):
        if not isinstance(item, dict):
            continue
        event_submission_id = item.get("event_submission_id")
        if (item.get("catalog_variation_id") or item.get("source_type") == "internal") and not event_submission_id:
            # Ordinary shop products produce commerce orders, not event tickets.
            continue
        ticket_product_id = str(item.get("ticket_product_id") or item.get("product_id") or "").strip()
        if not ticket_product_id and not event_submission_id:
            continue
        line_items.append({
            "id": f"{invoice_id}-{index + 1}",
            "product_id": ticket_product_id,
            **({"event_submission_id": int(event_submission_id)} if event_submission_id else {}),
            "variation_id": item.get("variation_id") or 0,
            "quantity": int(item.get("quantity") or 1),
            "name": str(item.get("name") or "").strip(),
        })
    if not line_items:
        return {"ok": True, "skipped": True, "reason": "no mapped product items"}
    sync_secret = _cfg("WOO_SYNC_SECRET")
    if not sync_secret:
        return {"ok": False, "error": "app sync secret is not configured"}
    order_payload = {
        "order_id": invoice_id,
        "status": (order_status or "").strip().lower() or "failed",
        "billing_email": str(payload.get("email") or "").strip().lower(),
        "billing_name": " ".join(filter(None, [str(payload.get("name") or "").strip(), str(payload.get("surname") or "").strip()])),
        "line_items": line_items,
    }
    if order_payload["status"] in {"processing", "completed"}:
        order_payload["date_paid"] = _now()
    try:
        response = httpx.post(
            "https://api2.dansmagazin.net/admin/events/woo/order-paid",
            json=order_payload,
            headers={"X-Woo-Sync-Secret": sync_secret},
            timeout=30.0,
        )
        data = response.json() if response.content else {}
        if response.status_code >= 400:
            return {"ok": False, "status_code": response.status_code, "response": data}
        return data if isinstance(data, dict) else {"ok": True}
    except (httpx.HTTPError, ValueError) as exc:
        return {"ok": False, "error": str(exc)}


def _adf_webhook_url() -> str:
    return _cfg("ADF_WEBHOOK_URL")


def _adf_webhook_key() -> str:
    return _cfg("ADF_WEBHOOK_KEY")


def _adf_order_payload(invoice_id: str, payload: Dict[str, Any], order_status: str = "processing") -> Optional[Dict[str, Any]]:
    items = payload.get("items") if isinstance(payload.get("items"), list) else []
    target_items = [item for item in items if isinstance(item, dict) and str(item.get("ticket_product_id") or item.get("product_id") or "").strip() == "3761"]
    if not target_items:
        return None
    line_items = []
    for index, item in enumerate(target_items):
        name = str(item.get("name") or "Ankara Dans Festivali FULLPASS").strip()
        parts = [part.strip() for part in name.split(" - ")]
        meta_data = [{"key": "Paket", "display_key": "Paket", "value": parts[0], "display_value": parts[0]}]
        if len(parts) > 1:
            meta_data.append({"key": "Gün Seçimi", "display_key": "Gün Seçimi", "value": parts[1], "display_value": parts[1]})
        if len(parts) > 2:
            meta_data.append({"key": "Oda Seçimi", "display_key": "Oda Seçimi", "value": parts[2], "display_value": parts[2]})
        quantity = max(1, int(item.get("quantity") or 1))
        price = float(item.get("price") or 0)
        line_items.append({
            "id": f"{invoice_id}-{index + 1}",
            "product_id": 3761,
            "variation_id": item.get("variation_id") or 0,
            "name": name,
            "quantity": quantity,
            "total": f"{price * quantity:.2f}",
            "meta_data": meta_data,
        })
    name = " ".join(filter(None, [str(payload.get("name") or "").strip(), str(payload.get("surname") or "").strip()])) or "DansMagazin müşterisi"
    first_name, _, last_name = name.partition(" ")
    normalized_status = (order_status or "processing").strip().lower()
    out = {
        "id": invoice_id,
        "status": normalized_status,
        "date_created": _now(),
        "transaction_id": invoice_id,
        "total": f"{sum(float(item.get('price') or 0) * max(1, int(item.get('quantity') or 1)) for item in target_items):.2f}",
        "billing": {
            "first_name": first_name,
            "last_name": last_name,
            "email": str(payload.get("email") or "").strip().lower(),
            "phone": str(payload.get("phone") or "").strip(),
        },
        "line_items": line_items,
    }
    if normalized_status in {"processing", "completed"}:
        out["date_paid"] = _now()
    return out


def _sync_adf_site_order(invoice_id: str, payload: Dict[str, Any], order_status: str = "processing") -> Dict[str, Any]:
    webhook_url = _adf_webhook_url()
    webhook_key = _adf_webhook_key()
    order = _adf_order_payload(invoice_id, payload, order_status=order_status)
    if order is None:
        return {"ok": True, "skipped": True, "reason": "not an Ankara festival product"}
    if not webhook_url or not webhook_key:
        return {"ok": False, "error": "ADF webhook ayarlari yapilandirilmamis"}
    parsed = urlsplit(webhook_url)
    query = dict(parse_qsl(parsed.query, keep_blank_values=True))
    query["key"] = webhook_key
    target_url = urlunsplit((parsed.scheme, parsed.netloc, parsed.path, urlencode(query), parsed.fragment))
    try:
        response = httpx.post(target_url, json=order, timeout=30.0)
        data = response.json() if response.content else {}
        if response.status_code >= 400 or not isinstance(data, dict) or not data.get("ok"):
            return {"ok": False, "status_code": response.status_code, "response": data}
        return {"ok": True, "imported": data.get("imported", 0), "updated": data.get("updated", False)}
    except (httpx.HTTPError, ValueError) as exc:
        return {"ok": False, "error": str(exc)}


def _persist_local_commerce_order(invoice_id: str, payload: Dict[str, Any], status: str) -> Dict[str, Any]:
    """Mirror a paid payment into the local commerce tables idempotently."""
    items = payload.get("items") if isinstance(payload.get("items"), list) else []
    if not items:
        return {"ok": False, "error": "payment has no items"}
    conn = get_db_connection()
    try:
        with conn.cursor() as cur:
            cur.execute("SELECT id FROM commerce_orders WHERE source_type=%s AND source_order_id=%s", ("halkode", invoice_id))
            existing = cur.fetchone()
            if existing:
                return {"ok": True, "existing": True, "order_id": int(existing["id"])}
            email = str(payload.get("email") or "").strip().lower()
            catalog_order = any(isinstance(item, dict) and item.get("catalog_variation_id") for item in items)
            if catalog_order:
                cur.execute(
                    "SELECT id FROM accounts WHERE id=%s AND LOWER(email)=LOWER(%s) AND COALESCE(is_active,1)=1 LIMIT 1",
                    (payload.get("verified_account_id"), email),
                )
            else:
                cur.execute("SELECT id FROM accounts WHERE LOWER(email)=LOWER(%s) LIMIT 1", (email,))
            account = cur.fetchone()
            total = sum(float(item.get("price") or 0) * max(1, int(item.get("quantity") or 1)) for item in items if isinstance(item, dict))
            cur.execute(
                """
                INSERT INTO commerce_orders
                    (public_order_no, account_id, source_type, source_order_id, status,
                     total_amount, currency, buyer_email, buyer_name, buyer_phone, metadata)
                VALUES (%s,%s,%s,%s,%s,%s,'TRY',%s,%s,%s,%s::jsonb)
                RETURNING id
                """,
                (
                    invoice_id,
                    account["id"] if account else None,
                    "halkode",
                    invoice_id,
                    "paid" if status == "paid" else status,
                    total,
                    email,
                    " ".join(filter(None, [str(payload.get("name") or "").strip(), str(payload.get("surname") or "").strip()])),
                    str(payload.get("phone") or "").strip(),
                    json.dumps({"provider": "halkode", "legacy_sync": "pending", "items": items}),
                ),
            )
            order_id = int(cur.fetchone()["id"])
            cur.execute(
                """
                INSERT INTO payment_transactions
                    (order_id, provider, provider_transaction_id, status, amount, currency, raw_reference)
                VALUES (%s,'halkode',%s,%s,%s,'TRY',%s)
                ON CONFLICT (provider, provider_transaction_id) DO UPDATE
                SET status=EXCLUDED.status, amount=EXCLUDED.amount, updated_at=NOW()
                """,
                (order_id, invoice_id, "paid" if status == "paid" else status, total, invoice_id),
            )
            cur.execute(
                """
                INSERT INTO payment_events
                    (transaction_id, provider, idempotency_key, event_type, payload, processed_at)
                SELECT id, 'halkode', %s, %s, %s::jsonb, NOW()
                FROM payment_transactions
                WHERE provider='halkode' AND provider_transaction_id=%s
                ON CONFLICT (idempotency_key) DO NOTHING
                """,
                (
                    f"halkode:{invoice_id}:{status}",
                    "payment.completed" if status == "paid" else f"payment.{status}",
                    json.dumps({"invoice_id": invoice_id, "order_id": order_id, "status": status}),
                    invoice_id,
                ),
            )
            for item in items:
                if not isinstance(item, dict):
                    continue
                internal_id = item.get("catalog_variation_id")
                source_variation_id = str(item.get("variation_id") or "").strip()
                if internal_id:
                    cur.execute(
                        """
                        SELECT v.id, v.product_id
                        FROM commerce_variations v
                        JOIN commerce_products p ON p.id=v.product_id
                        WHERE v.id=%s AND p.source_type IN ('internal','event') AND p.source_product_id=%s
                        """,
                        (internal_id, str(item.get("product_id") or "")),
                    )
                else:
                    cur.execute(
                        """
                        SELECT v.id, v.product_id, p.source_product_id
                        FROM commerce_variations v
                        JOIN commerce_products p ON p.id=v.product_id
                        WHERE v.source_variation_id=%s AND p.source_product_id=%s
                        """,
                        (source_variation_id, str(item.get("product_id") or "")),
                    )
                    variation = cur.fetchone()
                    if not variation:
                        cur.execute(
                            """
                            SELECT v.id, v.product_id, p.source_product_id
                            FROM commerce_variations v
                            JOIN commerce_products p ON p.id=v.product_id
                            JOIN mobile_event_submissions mes ON mes.id::text=p.source_product_id
                            JOIN saas_events se ON se.slug=mes.approved_event_slug
                            WHERE v.source_variation_id=%s AND se.external_event_id=%s
                              AND se.external_source='woo' AND p.source_type='event'
                            LIMIT 1
                            """,
                            (source_variation_id, str(item.get("product_id") or "")),
                        )
                        variation = cur.fetchone()
                if internal_id:
                    variation = cur.fetchone()
                if internal_id and not variation:
                    raise ValueError("Paid internal product could not be matched to the catalog")
                source_product_id = str(item.get("product_id") or "").strip()
                resolved_source_product_id = str((variation or {}).get("source_product_id") or source_product_id)
                event = None
                if internal_id and variation:
                    cur.execute(
                        "SELECT event_submission_id AS id FROM commerce_products WHERE id=%s",
                        (variation["product_id"],),
                    )
                    linked = cur.fetchone()
                    if linked and linked.get("id"):
                        event = linked
                elif not internal_id:
                    cur.execute(
                        """
                        SELECT id
                        FROM mobile_event_submissions
                        WHERE status='approved' AND (source_ref=%s OR id::text=%s)
                        ORDER BY CASE WHEN source_ref=%s THEN 0 ELSE 1 END, id DESC
                        LIMIT 1
                        """,
                        (resolved_source_product_id, resolved_source_product_id, resolved_source_product_id),
                    )
                    event = cur.fetchone()
                cur.execute(
                    """
                    INSERT INTO commerce_order_items
                        (order_id, product_id, variation_id, event_submission_id, quantity, unit_amount, metadata)
                    VALUES (%s,%s,%s,%s,%s,%s,%s::jsonb)
                    """,
                    (
                        order_id,
                        variation["product_id"] if variation else None,
                        variation["id"] if variation else None,
                        event["id"] if event else None,
                        max(1, int(item.get("quantity") or 1)),
                        float(item.get("price") or 0),
                        json.dumps({"source_product_id": source_product_id, "source_variation_id": source_variation_id,
                                    "resolved_source_product_id": resolved_source_product_id,
                                    "catalog_variation_id": internal_id}),
                    ),
                )
        conn.commit()
        return {"ok": True, "created": True, "order_id": order_id}
    except Exception as exc:
        conn.rollback()
        return {"ok": False, "error": str(exc)}
    finally:
        conn.close()


def _status_for_invoice(invoice_id: str, amount: float) -> Dict[str, Any]:
    token = _token()
    return _post_json(
        f"{_base_url()}/api/checkstatus",
        {
            "invoice_id": invoice_id,
            "merchant_key": _cfg("HALKODE_MERCHANT_KEY"),
            "hash_key": _checkstatus_hash_key(invoice_id),
            "include_pending_status": "true",
        },
        {"Authorization": f"Bearer {token}"},
    )


class PaymentItem(BaseModel):
    name: str = Field(min_length=1, max_length=240)
    price: float = Field(gt=0)
    quantity: int = Field(default=1, ge=1, le=20)
    product_id: Optional[str] = Field(default=None, max_length=80)
    variation_id: Optional[int] = Field(default=None)
    catalog_variation_id: Optional[int] = Field(default=None, gt=0)


def _canonical_payment_items(items: List[PaymentItem]) -> List[Dict[str, Any]]:
    """Resolve checkout lines from the local catalog, never from browser prices."""
    conn = get_db_connection()
    try:
        canonical: List[Dict[str, Any]] = []
        with conn.cursor() as cur:
            for item in items:
                if item.catalog_variation_id:
                    if _cfg("ENABLE_INTERNAL_COMMERCE_PAYMENTS").lower() not in {"1", "true"}:
                        raise HTTPException(status_code=409, detail="Dahili ürün ödemeleri henüz açılmadı")
                    allowed_products = {value.strip() for value in _cfg("INTERNAL_COMMERCE_PAYMENT_PRODUCT_IDS").split(",") if value.strip()}
                    if "*" not in allowed_products and item.product_id not in allowed_products:
                        raise HTTPException(status_code=409, detail="Bu ürün için ödeme henüz açılmadı")
                    if item.variation_id or not item.product_id:
                        raise HTTPException(status_code=400, detail="Dahili ürün seçimi geçersiz")
                    cur.execute(
                        """
                        SELECT p.source_product_id, p.source_type, p.event_submission_id,
                               p.legacy_woo_product_id, v.id, v.name, v.price,
                               v.currency, v.stock_quantity
                        FROM commerce_variations v
                        JOIN commerce_products p ON p.id=v.product_id
                        WHERE v.id=%s AND p.source_product_id=%s
                          AND p.source_type IN ('internal','event')
                          AND v.is_active=TRUE AND p.is_active=TRUE
                        """,
                        (item.catalog_variation_id, item.product_id),
                    )
                    row = cur.fetchone()
                    if not row:
                        raise HTTPException(status_code=400, detail="Ürün seçimi artık satışta değil; lütfen sayfayı yenileyin")
                    if str(row["currency"] or "TRY").upper() != "TRY":
                        raise HTTPException(status_code=400, detail="Bu ürün için desteklenmeyen para birimi")
                    if row["stock_quantity"] is not None and item.quantity > row["stock_quantity"]:
                        raise HTTPException(status_code=400, detail="İstenen adet stokta yok")
                    canonical.append({
                        "name": str(row["name"]), "price": float(row["price"]),
                        "quantity": item.quantity, "product_id": str(row["source_product_id"]),
                        "variation_id": int(row["id"]), "catalog_variation_id": int(row["id"]),
                        "source_type": str(row["source_type"] or "internal"),
                        **({"event_submission_id": int(row["event_submission_id"])} if row.get("event_submission_id") else {}),
                        **({"ticket_product_id": str(row["legacy_woo_product_id"])} if row.get("legacy_woo_product_id") else {}),
                    })
                    continue
                if not item.variation_id:
                    raise HTTPException(status_code=400, detail="Ürün seçimi geçersiz; lütfen ürünü yeniden seçin")
                cur.execute(
                    """
                    SELECT p.source_product_id, p.source_type, v.source_variation_id, v.name, v.price, v.currency
                    FROM commerce_variations v
                    JOIN commerce_products p ON p.id=v.product_id
                    WHERE v.source_variation_id=%s AND p.source_product_id=%s
                      AND v.is_active=TRUE AND p.is_active=TRUE
                    """,
                    (str(item.variation_id), str(item.product_id or "")),
                )
                row = cur.fetchone()
                if not row:
                    cur.execute(
                        """
                        SELECT p.source_product_id, p.source_type, v.source_variation_id,
                               v.name, v.price, v.currency
                        FROM commerce_variations v
                        JOIN commerce_products p ON p.id=v.product_id
                        JOIN mobile_event_submissions mes ON mes.id::text=p.source_product_id
                        JOIN saas_events se ON se.slug=mes.approved_event_slug
                        WHERE v.source_variation_id=%s AND se.external_event_id=%s
                          AND se.external_source='woo' AND p.source_type='event'
                          AND v.is_active=TRUE AND p.is_active=TRUE
                        LIMIT 1
                        """,
                        (str(item.variation_id), str(item.product_id or "")),
                    )
                    row = cur.fetchone()
                if not row:
                    raise HTTPException(status_code=400, detail="Ürün seçimi artık satışta değil; lütfen sayfayı yenileyin")
                if str(row["currency"] or "TRY").upper() != "TRY":
                    raise HTTPException(status_code=400, detail="Bu ürün için desteklenmeyen para birimi")
                ticket_product_id = None
                if row.get("source_type") == "event":
                    cur.execute(
                        """
                        SELECT se.external_event_id
                        FROM mobile_event_submissions mes
                        JOIN saas_events se ON se.slug=mes.approved_event_slug
                        WHERE mes.id::text=%s AND se.external_source='woo'
                          AND NULLIF(se.external_event_id,'') IS NOT NULL
                        LIMIT 1
                        """,
                        (str(row["source_product_id"]),),
                    )
                    mapped = cur.fetchone()
                    if not mapped:
                        raise HTTPException(status_code=409, detail="Etkinlik bileti eşleştirmesi tamamlanmadı")
                    ticket_product_id = str(mapped["external_event_id"])
                canonical.append(
                    {
                        "name": str(row["name"]),
                        "price": float(row["price"]),
                        "quantity": item.quantity,
                        "product_id": str(row["source_product_id"] or ""),
                        "variation_id": int(item.variation_id),
                        **({"ticket_product_id": ticket_product_id} if ticket_product_id else {}),
                    }
                )
        return canonical
    finally:
        conn.close()


class PaymentStartRequest(BaseModel):
    amount: float = Field(gt=0, le=1000000)
    currency: str = Field(default="TRY", min_length=3, max_length=3)
    email: str = Field(min_length=3, max_length=240)
    name: str = Field(default="Musteri", max_length=100)
    surname: str = Field(default="", max_length=100)
    items: List[PaymentItem] = Field(min_length=1, max_length=20)


def _verified_internal_buyer(authorization: Optional[str], email: str) -> int:
    if not isinstance(authorization, str) or not authorization.lower().startswith("bearer "):
        raise HTTPException(status_code=401, detail="Bu ürün için uygulama hesabınızla giriş yapın")
    token = authorization.split(" ", 1)[1].strip()
    if not token:
        raise HTTPException(status_code=401, detail="Bu ürün için uygulama hesabınızla giriş yapın")
    conn = get_db_connection()
    try:
        with conn.cursor() as cur:
            cur.execute(
                """
                SELECT s.account_id, a.email
                FROM sessions s JOIN accounts a ON a.id=s.account_id
                WHERE s.session_token=%s AND COALESCE(a.is_active,1)=1
                  AND s.expires_at::timestamptz > NOW()
                LIMIT 1
                """,
                (token,),
            )
            row = cur.fetchone()
        if not row:
            raise HTTPException(status_code=401, detail="Oturum süresi dolmuş; yeniden giriş yapın")
        if str(row["email"] or "").strip().lower() != email.strip().lower():
            raise HTTPException(status_code=403, detail="Ödeme e-postası giriş yaptığınız hesapla aynı olmalı")
        return int(row["account_id"])
    finally:
        conn.close()


@router.post("/halkode/start")
def start_halkode_payment(request: PaymentStartRequest, authorization: Optional[str] = Header(default=None)):
    if not _is_configured():
        raise HTTPException(status_code=503, detail="Halk Ode ayarlari henuz tanimli degil")
    if request.currency.upper() != "TRY":
        raise HTTPException(status_code=400, detail="Bu odeme akisi sadece TRY destekliyor")
    canonical_items = _canonical_payment_items(request.items)
    calculated = sum(item["price"] * item["quantity"] for item in canonical_items)
    if abs(calculated - request.amount) > 0.01:
        raise HTTPException(status_code=400, detail="Siparis tutari kalemlerle eslesmiyor")
    catalog_order = any(item.get("catalog_variation_id") for item in canonical_items)
    verified_account_id = _verified_internal_buyer(authorization, request.email) if catalog_order else None

    _ensure_table()
    invoice_id = f"DM-{uuid.uuid4().hex}"
    return_url = _payment_return_url()
    cancel_url = _payment_cancel_url()
    invoice = {
        "invoice_id": invoice_id,
        "invoice_description": "Dansmagazin siparisi",
        "total": f"{request.amount:.2f}",
        "return_url": return_url,
        "cancel_url": cancel_url,
        "items": canonical_items,
    }
    conn = get_db_connection()
    try:
        with conn.cursor() as cur:
            cur.execute(
                """
                INSERT INTO static_payment_orders
                    (invoice_id, amount, currency, customer_email, payload)
                VALUES (%s,%s,%s,%s,%s::jsonb)
                """,
                (invoice_id, calculated, "TRY", request.email.lower().strip(), json.dumps({**request.model_dump(), "amount": calculated, "items": canonical_items,
                                                                                           "verified_account_id": verified_account_id})),
            )
        conn.commit()
    finally:
        conn.close()
    return {"ok": True, "invoice_id": invoice_id, "status": "pending", "payment_mode": "paySmart3D"}


@router.post("/halkode/pay-smart-3d", response_class=HTMLResponse)
async def pay_smart_3d(request: Request):
    """Create the provider form without storing card data on our server."""
    if not _is_configured():
        raise HTTPException(status_code=503, detail="Halk Ode ayarlari henuz tanimli degil")
    form = await request.form()
    invoice_id = str(form.get("invoice_id") or "").strip()
    if not invoice_id or len(invoice_id) > 120:
        raise HTTPException(status_code=400, detail="Fatura bilgisi eksik")
    required = ("cc_holder_name", "cc_no", "expiry_month", "expiry_year", "cvv")
    if any(not str(form.get(key) or "").strip() for key in required):
        raise HTTPException(status_code=400, detail="Kart bilgileri eksik")

    conn = get_db_connection()
    try:
        with conn.cursor() as cur:
            cur.execute("SELECT amount, payload, status FROM static_payment_orders WHERE invoice_id=%s", (invoice_id,))
            row = cur.fetchone()
        if not row:
            raise HTTPException(status_code=404, detail="Odeme kaydi bulunamadi")
        if row["status"] in {"paid", "failed"}:
            raise HTTPException(status_code=409, detail="Bu odeme kaydi daha once sonuclandi")
        payload = row["payload"] if isinstance(row["payload"], dict) else json.loads(row["payload"] or "{}")
        request_data = PaymentStartRequest.model_validate(payload)
    finally:
        conn.close()

    total = f"{float(row['amount']):.2f}"
    first = request_data.name or "Musteri"
    last = request_data.surname or ""
    fields = {
        "cc_holder_name": str(form.get("cc_holder_name") or "").strip(),
        "cc_no": str(form.get("cc_no") or "").replace(" ", "").replace("-", ""),
        "expiry_month": str(form.get("expiry_month") or "").strip(),
        "expiry_year": str(form.get("expiry_year") or "").strip(),
        "cvv": str(form.get("cvv") or "").strip(),
        "currency_code": "TRY",
        "installments_number": "1",
        "invoice_id": invoice_id,
        "invoice_description": "Dansmagazin siparisi",
        "total": total,
        "items": json.dumps([
            {key: getattr(item, key) for key in ("name", "price", "quantity", "product_id", "variation_id")}
            for item in request_data.items
        ], ensure_ascii=False),
        "name": first,
        "surname": last,
        "merchant_key": _cfg("HALKODE_MERCHANT_KEY"),
        "hash_key": _hash_key(total, 1, invoice_id),
        "return_url": _payment_return_url(),
        "cancel_url": _payment_cancel_url(),
        "transaction_type": "Auth",
        "payment_completed_by": "app",
        "token": _token(),
    }
    action = f"{_base_url()}/api/paySmart3D"
    hidden = "".join(
        f'<input type="hidden" name="{_html_escape(key)}" value="{_html_escape(value)}">'
        for key, value in fields.items()
    )
    return HTMLResponse(
        "<!doctype html><html lang=\"tr\"><meta charset=\"utf-8\"><title>Güvenli ödeme</title>"
        "<body style=\"font-family:system-ui;text-align:center;padding:48px\">"
        "<p>Güvenli ödeme ekranına yönlendiriliyorsunuz...</p>"
        f"<form id=\"halkode-payment\" method=\"post\" action=\"{_html_escape(action)}\">{hidden}</form>"
        "<script>document.getElementById('halkode-payment').submit();</script></body></html>"
    )


def _html_escape(value: Any) -> str:
    import html
    return html.escape(str(value or ""), quote=True)


@router.api_route("/halkode/return", methods=["GET", "POST"])
async def halkode_return(request: Request, invoice_id: str = Query(default="")):
    callback = dict(request.query_params)
    if request.method == "POST":
        callback.update({key: str(value) for key, value in (await request.form()).items()})
    if not invoice_id:
        invoice_id = str(callback.get("invoice_id") or "").strip()
    if not invoice_id:
        return RedirectResponse(_checkout_result_url("failed"))
    conn = get_db_connection()
    try:
        with conn.cursor() as cur:
            cur.execute("SELECT amount, payload FROM static_payment_orders WHERE invoice_id=%s", (invoice_id,))
            row = cur.fetchone()
        if not row:
            return RedirectResponse(_checkout_result_url("failed"))
        callback_code = int(str(callback.get("status_code") or "0").strip() or 0)
        callback_payment = str(callback.get("payment_status") or "").strip().lower()
        callback_paid = callback_code == 100 and callback_payment in {"1", "true", "completed"}
        status = _status_for_invoice(invoice_id, float(row["amount"]))
        payload = row["payload"] if isinstance(row.get("payload"), dict) else json.loads(row.get("payload") or "{}")
        internal_order = any(item.get("catalog_variation_id") for item in payload.get("items", []))
        # Legacy Woo orders retain their existing callback fallback. New internal
        # orders require an independently verified provider status.
        status_code = int(status.get("status_code") or 0)
        if callback_paid and not internal_order and status_code not in {100, 69}:
            status = {
                "status_code": callback_code,
                "transaction_status": "completed",
                "amount": callback.get("total") or callback.get("amount"),
            }
        code = int(status.get("status_code") or 0)
        transaction_status = str(status.get("transaction_status") or "").lower()
        paid = code == 100 and transaction_status == "completed"
        pending = code == 69 or transaction_status == "pending"
        state = "paid" if paid else ("pending" if pending else "failed")
        if paid and status.get("amount") is not None and abs(float(status["amount"]) - float(row["amount"])) > 0.01:
            state = "failed"
        sync_status = "processing" if state == "paid" else ("failed" if state == "failed" else "")
        app_sync = _sync_adf_order_to_app(invoice_id, payload, sync_status) if sync_status else {"ok": True, "skipped": True}
        adf_sync = _sync_adf_site_order(invoice_id, payload, sync_status) if sync_status else {"ok": True, "skipped": True}
        local_sync = _persist_local_commerce_order(invoice_id, payload, state) if state == "paid" else {"ok": True, "skipped": True}
        with conn.cursor() as cur:
            provider_status = str(status.get("status_code") or "")
            if app_sync.get("created_tickets") is not None:
                provider_status += f"|tickets:{app_sync.get('created_tickets')}"
            elif app_sync.get("ok") is False:
                provider_status += "|app_sync_failed"
            if local_sync.get("ok") is True and not local_sync.get("skipped"):
                provider_status += "|local_order_ok"
            elif local_sync.get("ok") is False:
                provider_status += "|local_order_failed"
            if adf_sync.get("ok") is True and not adf_sync.get("skipped"):
                provider_status += "|adf_sync_ok"
            elif adf_sync.get("ok") is False:
                provider_status += "|adf_sync_failed"
            cur.execute("UPDATE static_payment_orders SET status=%s, provider_status=%s, updated_at=NOW() WHERE invoice_id=%s", (state, provider_status, invoice_id))
        conn.commit()
    finally:
        conn.close()
    return RedirectResponse(_checkout_result_url(state, invoice_id))


@router.get("/halkode/status")
def halkode_payment_status(invoice_id: str = Query(min_length=8, max_length=120)):
    if not _is_configured():
        raise HTTPException(status_code=503, detail="Halk Ode ayarlari henuz tanimli degil")
    _ensure_table()
    conn = get_db_connection()
    try:
        with conn.cursor() as cur:
            cur.execute("SELECT amount, status, payload FROM static_payment_orders WHERE invoice_id=%s", (invoice_id,))
            row = cur.fetchone()
        if not row:
            raise HTTPException(status_code=404, detail="Odeme kaydi bulunamadi")
        data = _post_json(
            f"{_base_url()}/api/checkstatus",
            {
                "invoice_id": invoice_id,
                "merchant_key": _cfg("HALKODE_MERCHANT_KEY"),
                "hash_key": _checkstatus_hash_key(invoice_id),
                "include_pending_status": "true",
            },
            {"Authorization": f"Bearer {_token()}"},
        )
        transaction_status = str(data.get("transaction_status") or "").lower()
        provider_status = str(data.get("status_code") or "")
        paid = int(data.get("status_code") or 0) == 100 and transaction_status == "completed"
        pending = int(data.get("status_code") or 0) == 69 or transaction_status == "pending"
        next_status = "paid" if paid else ("pending" if pending else "failed")
        if paid and data.get("amount") is not None and abs(float(data["amount"]) - float(row["amount"])) > 0.01:
            next_status = "failed"
        payload = row["payload"] if isinstance(row.get("payload"), dict) else json.loads(row.get("payload") or "{}")
        sync_status = "processing" if next_status == "paid" else ("failed" if next_status == "failed" else "")
        app_sync = _sync_adf_order_to_app(invoice_id, payload, sync_status) if sync_status else {"ok": True, "skipped": True}
        adf_sync = _sync_adf_site_order(invoice_id, payload, sync_status) if sync_status else {"ok": True, "skipped": True}
        local_sync = _persist_local_commerce_order(invoice_id, payload, next_status) if next_status == "paid" else {"ok": True, "skipped": True}
        if app_sync.get("created_tickets") is not None:
            provider_status += f"|tickets:{app_sync.get('created_tickets')}"
        elif app_sync.get("updated_tickets") is not None:
            provider_status += f"|tickets_updated:{app_sync.get('updated_tickets')}"
        elif app_sync.get("ok") is False:
            provider_status += "|app_sync_failed"
        if local_sync.get("ok") is True and not local_sync.get("skipped"):
            provider_status += "|local_order_ok"
        elif local_sync.get("ok") is False:
            provider_status += "|local_order_failed"
        if adf_sync.get("ok") is True and not adf_sync.get("skipped"):
            provider_status += "|adf_sync_ok"
        elif adf_sync.get("ok") is False:
            provider_status += "|adf_sync_failed"
        with conn.cursor() as cur:
            cur.execute(
                "UPDATE static_payment_orders SET status=%s, provider_status=%s, updated_at=NOW() WHERE invoice_id=%s",
                (next_status, provider_status, invoice_id),
            )
        conn.commit()
        return {"ok": True, "invoice_id": invoice_id, "status": next_status}
    finally:
        conn.close()


def _annotate_ticket_product_ids(payload: Dict[str, Any], mapped_ids: Dict[str, str]) -> Dict[str, Any]:
    """Expose historical event mappings without changing the stored payment record."""
    return {
        **payload,
        "items": [
            {**item, **({"ticket_product_id": mapped_ids[str(item["product_id"])]}
             if not item.get("ticket_product_id") and str(item.get("product_id")) in mapped_ids else {})}
            if isinstance(item, dict) else item
            for item in payload.get("items", [])
        ],
    }


@router.get("/halkode/admin-orders")
def halkode_admin_orders(authorization: Optional[str] = Header(default=None)):
    """Return verified static checkout records to authenticated administrators."""
    if not authorization or not authorization.lower().startswith("bearer "):
        raise HTTPException(status_code=401, detail="Bearer token gerekli")
    token = authorization.split(" ", 1)[1].strip()
    conn = get_db_connection()
    try:
        with conn.cursor() as cur:
            cur.execute(
                """
                SELECT COALESCE(a.role, 'customer') AS role
                FROM sessions s
                JOIN accounts a ON a.id=s.account_id
                WHERE s.session_token=%s AND COALESCE(a.is_active,1)=1
                LIMIT 1
                """,
                (token,),
            )
            account = cur.fetchone()
            role = str((account or {}).get("role") or "customer").lower()
            if role not in {"super_admin", "admin", "editor"}:
                raise HTTPException(status_code=403, detail="Yönetici yetkisi gerekli")
            cur.execute(
                """
                SELECT invoice_id, amount, currency, status, customer_email, payload,
                       provider_status, created_at, updated_at
                FROM static_payment_orders
                ORDER BY created_at DESC
                LIMIT 500
                """
            )
            rows = cur.fetchall() or []
            cur.execute(
                """
                SELECT public_order_no, total_amount, currency, status, buyer_email,
                       metadata, created_at, updated_at
                FROM commerce_orders
                WHERE source_type='halkode'
                ORDER BY created_at DESC
                LIMIT 500
                """
            )
            local_rows = cur.fetchall() or []
            source_ids = sorted({
                str(item.get("product_id"))
                for row in rows
                for item in (row.get("payload") if isinstance(row.get("payload"), dict)
                             else json.loads(row.get("payload") or "{}")).get("items", [])
                if isinstance(item, dict) and item.get("product_id")
            })
            ticket_product_ids = {}
            if source_ids:
                cur.execute(
                    """
                    SELECT mes.id::text AS source_product_id, se.external_event_id
                    FROM mobile_event_submissions mes
                    JOIN saas_events se ON se.slug=mes.approved_event_slug
                    WHERE mes.id::text=ANY(%s::text[]) AND se.external_source='woo'
                      AND NULLIF(se.external_event_id,'') IS NOT NULL
                    """,
                    (source_ids,),
                )
                ticket_product_ids = {
                    str(item["source_product_id"]): str(item["external_event_id"])
                    for item in (cur.fetchall() or [])
                }
        result = []
        for row in rows:
            payload = row["payload"] if isinstance(row.get("payload"), dict) else json.loads(row.get("payload") or "{}")
            payload = _annotate_ticket_product_ids(payload, ticket_product_ids)
            result.append({
                "invoice_id": row["invoice_id"],
                "amount": float(row["amount"] or 0),
                "currency": row["currency"],
                "status": row["status"],
                "customer_email": row["customer_email"],
                "payload": payload,
                "provider_status": row["provider_status"],
                "created_at": row["created_at"].isoformat() if row.get("created_at") else None,
                "updated_at": row["updated_at"].isoformat() if row.get("updated_at") else None,
            })
        seen = {str(item["invoice_id"]) for item in result}
        for row in local_rows:
            invoice_id = str(row["public_order_no"])
            if invoice_id in seen:
                continue
            metadata = row["metadata"] if isinstance(row.get("metadata"), dict) else json.loads(row.get("metadata") or "{}")
            result.append({
                "invoice_id": invoice_id,
                "amount": float(row["total_amount"] or 0),
                "currency": row["currency"],
                "status": row["status"],
                "customer_email": row["buyer_email"],
                "payload": {"email": row["buyer_email"], "items": metadata.get("items", [])},
                "provider_status": "local_order",
                "created_at": row["created_at"].isoformat() if row.get("created_at") else None,
                "updated_at": row["updated_at"].isoformat() if row.get("updated_at") else None,
            })
        result.sort(key=lambda item: item.get("created_at") or "", reverse=True)
        return {"ok": True, "orders": result}
    finally:
        conn.close()


@router.get("/halkode/admin-users")
def halkode_admin_users(authorization: Optional[str] = Header(default=None)):
    """Return account summaries to authenticated administrators."""
    if not authorization or not authorization.lower().startswith("bearer "):
        raise HTTPException(status_code=401, detail="Bearer token gerekli")
    token = authorization.split(" ", 1)[1].strip()
    conn = get_db_connection()
    try:
        with conn.cursor() as cur:
            cur.execute(
                """
                SELECT COALESCE(a.role, 'customer') AS role
                FROM sessions s
                JOIN accounts a ON a.id=s.account_id
                WHERE s.session_token=%s AND COALESCE(a.is_active,1)=1
                LIMIT 1
                """,
                (token,),
            )
            account = cur.fetchone()
            role = str((account or {}).get("role") or "customer").lower()
            if role not in {"super_admin", "admin", "editor"}:
                raise HTTPException(status_code=403, detail="Yönetici yetkisi gerekli")
            cur.execute(
                """
                CREATE TABLE IF NOT EXISTS password_reset_requests (
                    id BIGSERIAL PRIMARY KEY,
                    account_id INTEGER REFERENCES accounts(id) ON DELETE CASCADE,
                    email TEXT NOT NULL DEFAULT '',
                    status TEXT NOT NULL DEFAULT 'pending',
                    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
                    resolved_at TIMESTAMPTZ
                )
                """
            )
            cur.execute(
                """
                SELECT id, email, role, is_active, name, phone, avatar_path, created_at,
                       can_create_mobile_event, is_mobile_event_reviewer,
                       pr.password_reset_requested_at
                FROM accounts a
                LEFT JOIN (
                    SELECT account_id, MAX(created_at) AS password_reset_requested_at
                    FROM password_reset_requests
                    WHERE status='pending'
                    GROUP BY account_id
                ) pr ON pr.account_id=a.id
                ORDER BY COALESCE(NULLIF(name,''), email) ASC
                LIMIT 1000
                """
            )
            rows = cur.fetchall() or []

        def normalize_role(raw: str) -> str:
            value = str(raw or "").lower()
            if value in {"super_admin", "administrator"}:
                return "superadmin"
            if value in {"admin", "editor", "shop_manager"}:
                return "admin"
            return value or "customer"

        users = []
        summary: Dict[str, int] = {}
        for row in rows:
            public_role = normalize_role(row.get("role"))
            summary[public_role] = summary.get(public_role, 0) + 1
            email = row.get("email") or ""
            users.append({
                "id": row.get("id"),
                "email": email,
                "username": email,
                "name": row.get("name") or email,
                "phone": row.get("phone") or "",
                "role": public_role,
                "appRole": public_role,
                "isActive": bool(row.get("is_active")),
                "avatarPath": row.get("avatar_path") or "",
                "createdAt": row.get("created_at") or "",
                "passwordResetRequestedAt": row.get("password_reset_requested_at").isoformat() if row.get("password_reset_requested_at") else "",
                "canCreateMobileEvent": bool(row.get("can_create_mobile_event")),
                "isMobileEventReviewer": bool(row.get("is_mobile_event_reviewer")),
            })
        app_role_summary = [{"role": key, "count": value} for key, value in sorted(summary.items())]
        return {
            "ok": True,
            "source": "dansmagazin-backend-accounts",
            "users": users,
            "appAccounts": users,
            "identityMap": [],
            "appRoleSummary": app_role_summary,
        }
    finally:
        conn.close()


@router.get("/halkode/my-orders")
def halkode_my_orders(authorization: Optional[str] = Header(default=None)):
    """Return the signed-in user's static checkout records."""
    if not authorization or not authorization.lower().startswith("bearer "):
        raise HTTPException(status_code=401, detail="Bearer token gerekli")
    token = authorization.split(" ", 1)[1].strip()
    conn = get_db_connection()
    try:
        with conn.cursor() as cur:
            cur.execute(
                """
                SELECT LOWER(a.email) AS email
                FROM sessions s
                JOIN accounts a ON a.id=s.account_id
                WHERE s.session_token=%s AND COALESCE(a.is_active,1)=1
                LIMIT 1
                """,
                (token,),
            )
            account = cur.fetchone()
            email = str((account or {}).get("email") or "").strip().lower()
            if not email:
                raise HTTPException(status_code=401, detail="Geçersiz oturum")
            cur.execute(
                """
                SELECT invoice_id, amount, currency, status, customer_email, payload,
                       provider_status, created_at, updated_at
                FROM static_payment_orders
                WHERE LOWER(customer_email)=LOWER(%s)
                ORDER BY created_at DESC
                LIMIT 100
                """,
                (email,),
            )
            rows = cur.fetchall() or []
            cur.execute(
                """
                SELECT public_order_no, total_amount, currency, status, buyer_email,
                       metadata, created_at, updated_at
                FROM commerce_orders
                WHERE source_type='halkode' AND LOWER(buyer_email)=LOWER(%s)
                ORDER BY created_at DESC
                LIMIT 100
                """,
                (email,),
            )
            local_rows = cur.fetchall() or []
        result = []
        for row in rows:
            payload = row["payload"] if isinstance(row.get("payload"), dict) else json.loads(row.get("payload") or "{}")
            result.append({
                "invoice_id": row["invoice_id"],
                "amount": float(row["amount"] or 0),
                "currency": row["currency"],
                "status": row["status"],
                "customer_email": row["customer_email"],
                "payload": payload,
                "provider_status": row["provider_status"],
                "created_at": row["created_at"].isoformat() if row.get("created_at") else None,
                "updated_at": row["updated_at"].isoformat() if row.get("updated_at") else None,
            })
        seen = {str(item["invoice_id"]) for item in result}
        for row in local_rows:
            invoice_id = str(row["public_order_no"])
            if invoice_id in seen:
                continue
            metadata = row["metadata"] if isinstance(row.get("metadata"), dict) else json.loads(row.get("metadata") or "{}")
            result.append({
                "invoice_id": invoice_id,
                "amount": float(row["total_amount"] or 0),
                "currency": row["currency"],
                "status": row["status"],
                "customer_email": row["buyer_email"],
                "payload": {"email": row["buyer_email"], "items": metadata.get("items", [])},
                "provider_status": "local_order",
                "created_at": row["created_at"].isoformat() if row.get("created_at") else None,
                "updated_at": row["updated_at"].isoformat() if row.get("updated_at") else None,
            })
        result.sort(key=lambda item: item.get("created_at") or "", reverse=True)
        return {"ok": True, "orders": result}
    finally:
        conn.close()
