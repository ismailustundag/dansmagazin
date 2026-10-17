"""Backward-compatible commerce schema for the WooCommerce transition.

This module only creates empty local tables. It does not import, alter, or
cancel existing WooCommerce orders and it does not create tickets.
"""

from app.utils import get_db_connection


def init_commerce_schema() -> None:
    conn = get_db_connection()
    try:
        cur = conn.cursor()
        cur.execute(
            """
            CREATE TABLE IF NOT EXISTS commerce_products (
                id BIGSERIAL PRIMARY KEY,
                source_type TEXT NOT NULL DEFAULT 'internal',
                source_product_id TEXT,
                event_submission_id INTEGER,
                legacy_woo_product_id TEXT,
                legacy_woo_is_active BOOLEAN NOT NULL DEFAULT TRUE,
                name TEXT NOT NULL,
                description TEXT NOT NULL DEFAULT '',
                image_url TEXT NOT NULL DEFAULT '',
                is_active BOOLEAN NOT NULL DEFAULT TRUE,
                created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
                updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
                UNIQUE (source_type, source_product_id)
            )
            """
        )
        cur.execute("ALTER TABLE commerce_products ADD COLUMN IF NOT EXISTS event_submission_id INTEGER")
        cur.execute("ALTER TABLE commerce_products ADD COLUMN IF NOT EXISTS legacy_woo_product_id TEXT")
        cur.execute("ALTER TABLE commerce_products ADD COLUMN IF NOT EXISTS legacy_woo_is_active BOOLEAN NOT NULL DEFAULT TRUE")
        cur.execute(
            "CREATE INDEX IF NOT EXISTS idx_commerce_products_event_submission "
            "ON commerce_products(event_submission_id)"
        )
        cur.execute(
            """
            UPDATE commerce_products p
            SET event_submission_id=mes.id,
                legacy_woo_product_id=COALESCE(
                    NULLIF(p.legacy_woo_product_id, ''),
                    NULLIF(se.external_event_id, '')
                )
            FROM mobile_event_submissions mes
            LEFT JOIN saas_events se ON se.slug=mes.approved_event_slug
            WHERE p.source_type='event'
              AND p.event_submission_id IS NULL
              AND (
                    p.source_product_id=mes.id::text
                 OR p.source_product_id=COALESCE(mes.source_ref, '')
                 OR p.source_product_id=COALESCE(se.external_event_id, '')
              )
            """
        )
        cur.execute(
            """
            CREATE TABLE IF NOT EXISTS commerce_variations (
                id BIGSERIAL PRIMARY KEY,
                product_id BIGINT NOT NULL REFERENCES commerce_products(id) ON DELETE CASCADE,
                source_variation_id TEXT,
                name TEXT NOT NULL,
                price NUMERIC(12,2) NOT NULL DEFAULT 0,
                currency TEXT NOT NULL DEFAULT 'TRY',
                stock_quantity INTEGER,
                is_active BOOLEAN NOT NULL DEFAULT TRUE,
                metadata JSONB NOT NULL DEFAULT '{}'::jsonb,
                created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
                updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
                UNIQUE (product_id, source_variation_id)
            )
            """
        )
        cur.execute(
            """
            CREATE TABLE IF NOT EXISTS commerce_orders (
                id BIGSERIAL PRIMARY KEY,
                public_order_no TEXT NOT NULL UNIQUE,
                account_id INTEGER REFERENCES accounts(id) ON DELETE SET NULL,
                source_type TEXT NOT NULL DEFAULT 'internal',
                source_order_id TEXT,
                status TEXT NOT NULL DEFAULT 'created',
                total_amount NUMERIC(12,2) NOT NULL DEFAULT 0,
                currency TEXT NOT NULL DEFAULT 'TRY',
                buyer_email TEXT NOT NULL DEFAULT '',
                buyer_name TEXT NOT NULL DEFAULT '',
                buyer_phone TEXT NOT NULL DEFAULT '',
                metadata JSONB NOT NULL DEFAULT '{}'::jsonb,
                created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
                updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
                UNIQUE (source_type, source_order_id)
            )
            """
        )
        cur.execute(
            """
            CREATE TABLE IF NOT EXISTS commerce_order_items (
                id BIGSERIAL PRIMARY KEY,
                order_id BIGINT NOT NULL REFERENCES commerce_orders(id) ON DELETE CASCADE,
                product_id BIGINT REFERENCES commerce_products(id) ON DELETE SET NULL,
                variation_id BIGINT REFERENCES commerce_variations(id) ON DELETE SET NULL,
                event_submission_id INTEGER REFERENCES mobile_event_submissions(id) ON DELETE SET NULL,
                quantity INTEGER NOT NULL DEFAULT 1 CHECK (quantity > 0),
                unit_amount NUMERIC(12,2) NOT NULL DEFAULT 0,
                metadata JSONB NOT NULL DEFAULT '{}'::jsonb
            )
            """
        )
        cur.execute(
            """
            CREATE TABLE IF NOT EXISTS payment_transactions (
                id BIGSERIAL PRIMARY KEY,
                order_id BIGINT NOT NULL REFERENCES commerce_orders(id) ON DELETE CASCADE,
                provider TEXT NOT NULL,
                provider_transaction_id TEXT,
                status TEXT NOT NULL DEFAULT 'created',
                amount NUMERIC(12,2) NOT NULL DEFAULT 0,
                currency TEXT NOT NULL DEFAULT 'TRY',
                raw_reference TEXT,
                created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
                updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
                UNIQUE (provider, provider_transaction_id)
            )
            """
        )
        cur.execute(
            """
            CREATE TABLE IF NOT EXISTS payment_events (
                id BIGSERIAL PRIMARY KEY,
                transaction_id BIGINT REFERENCES payment_transactions(id) ON DELETE SET NULL,
                provider TEXT NOT NULL,
                idempotency_key TEXT NOT NULL UNIQUE,
                event_type TEXT NOT NULL,
                payload JSONB NOT NULL DEFAULT '{}'::jsonb,
                processed_at TIMESTAMPTZ,
                created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
            )
            """
        )
        cur.execute(
            """
            CREATE TABLE IF NOT EXISTS event_change_log (
                id BIGSERIAL PRIMARY KEY,
                submission_id INTEGER NOT NULL REFERENCES mobile_event_submissions(id) ON DELETE CASCADE,
                account_id INTEGER REFERENCES accounts(id) ON DELETE SET NULL,
                action TEXT NOT NULL,
                before_data JSONB NOT NULL DEFAULT '{}'::jsonb,
                after_data JSONB NOT NULL DEFAULT '{}'::jsonb,
                created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
            )
            """
        )
        cur.execute("CREATE INDEX IF NOT EXISTS idx_commerce_orders_account ON commerce_orders(account_id, created_at DESC)")
        cur.execute("CREATE INDEX IF NOT EXISTS idx_commerce_orders_status ON commerce_orders(status, created_at DESC)")
        cur.execute("CREATE INDEX IF NOT EXISTS idx_order_items_event ON commerce_order_items(event_submission_id)")
        cur.execute("CREATE INDEX IF NOT EXISTS idx_payment_events_created ON payment_events(created_at DESC)")
        cur.execute("CREATE INDEX IF NOT EXISTS idx_event_change_log_submission ON event_change_log(submission_id, created_at DESC)")
        conn.commit()
    except Exception:
        conn.rollback()
        raise
    finally:
        conn.close()
