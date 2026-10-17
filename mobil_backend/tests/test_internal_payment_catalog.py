import json
import asyncio
import unittest
from unittest.mock import patch

from fastapi import HTTPException

from app.routers import payments


class Cursor:
    def __init__(self, rows):
        self.rows = list(rows)
        self.queries = []

    def __enter__(self):
        return self

    def __exit__(self, *args):
        return False

    def execute(self, query, values=None):
        self.queries.append((query, values))

    def fetchone(self):
        return self.rows.pop(0)


class Connection:
    def __init__(self, rows):
        self.cur = Cursor(rows)
        self.commits = 0
        self.rollbacks = 0

    def cursor(self):
        return self.cur

    def commit(self):
        self.commits += 1

    def rollback(self):
        self.rollbacks += 1

    def close(self):
        pass


class InternalPaymentCatalogTests(unittest.TestCase):
    def setUp(self):
        flag = patch.dict("os.environ", {"ENABLE_INTERNAL_COMMERCE_PAYMENTS": "1", "INTERNAL_COMMERCE_PAYMENT_PRODUCT_IDS": "codex-test-1tl-20261013,test-product,right,wrong"})
        flag.start()
        self.addCleanup(flag.stop)

    def test_internal_payment_is_closed_by_default(self):
        item = payments.PaymentItem(name="test", price=1, product_id="test", catalog_variation_id=25)
        with patch.dict("os.environ", {"ENABLE_INTERNAL_COMMERCE_PAYMENTS": ""}), \
             patch.object(payments, "get_db_connection", return_value=Connection([])):
            with self.assertRaises(HTTPException) as error:
                payments._canonical_payment_items([item])
        self.assertEqual(error.exception.status_code, 409)

    def test_internal_product_uses_database_id_and_database_price(self):
        conn = Connection([{
            "id": 25, "source_product_id": "codex-test-1tl-20261013",
            "source_type": "internal", "event_submission_id": None, "legacy_woo_product_id": None,
            "name": "Standart - Test", "price": 1, "currency": "TRY", "stock_quantity": None,
        }])
        item = payments.PaymentItem(name="browser name", price=900, quantity=1,
                                    product_id="codex-test-1tl-20261013", catalog_variation_id=25)
        with patch.object(payments, "get_db_connection", return_value=conn):
            result = payments._canonical_payment_items([item])
        self.assertEqual(result[0]["price"], 1)
        self.assertEqual(result[0]["catalog_variation_id"], 25)
        self.assertEqual(result[0]["source_type"], "internal")
        self.assertIn("p.source_type IN ('internal','event')", conn.cur.queries[0][0])
        self.assertEqual(conn.cur.queries[0][1], (25, "codex-test-1tl-20261013"))

    def test_event_linked_catalog_product_keeps_direct_ticket_mapping(self):
        conn = Connection([{
            "id": 91, "source_product_id": "3900", "source_type": "event",
            "event_submission_id": 348, "legacy_woo_product_id": "3900",
            "name": "Jack & Jill", "price": 500, "currency": "TRY", "stock_quantity": None,
        }])
        item = payments.PaymentItem(name="browser", price=999, quantity=1,
                                    product_id="3900", catalog_variation_id=91)
        with patch.dict("os.environ", {"INTERNAL_COMMERCE_PAYMENT_PRODUCT_IDS": "3900"}), \
             patch.object(payments, "get_db_connection", return_value=conn):
            result = payments._canonical_payment_items([item])
        self.assertEqual(result[0]["price"], 500)
        self.assertEqual(result[0]["event_submission_id"], 348)
        self.assertEqual(result[0]["ticket_product_id"], "3900")

    def test_event_linked_catalog_product_enters_ticket_sync_by_event_id(self):
        payload = {"email": "buyer@example.com", "items": [{
            "source_type": "event", "product_id": "3900", "catalog_variation_id": 91,
            "event_submission_id": 348, "variation_id": 91, "price": 500, "quantity": 1,
        }]}
        with patch.dict("os.environ", {"WOO_SYNC_SECRET": "test-secret"}), \
             patch.object(payments.httpx, "post") as post:
            post.return_value.status_code = 200
            post.return_value.content = b'{"ok":true,"created_tickets":1}'
            post.return_value.json.return_value = {"ok": True, "created_tickets": 1}
            result = payments._sync_adf_order_to_app("DM-event", payload, "processing")
        self.assertEqual(result["created_tickets"], 1)
        line = post.call_args.kwargs["json"]["line_items"][0]
        self.assertEqual(line["event_submission_id"], 348)
        self.assertEqual(line["product_id"], "3900")

    def test_internal_product_rejects_wrong_source_and_stock(self):
        item = payments.PaymentItem(name="test", price=1, product_id="wrong", catalog_variation_id=25)
        with patch.object(payments, "get_db_connection", return_value=Connection([None])):
            with self.assertRaises(HTTPException) as error:
                payments._canonical_payment_items([item])
        self.assertEqual(error.exception.status_code, 400)

        conn = Connection([{"source_product_id": "right", "source_type": "internal",
                            "event_submission_id": None, "legacy_woo_product_id": None,
                            "id": 25, "name": "test",
                            "price": 1, "currency": "TRY", "stock_quantity": 0}])
        item.product_id = "right"
        with patch.object(payments, "get_db_connection", return_value=conn):
            with self.assertRaises(HTTPException) as error:
                payments._canonical_payment_items([item])
        self.assertEqual(error.exception.status_code, 400)

    def test_internal_product_requires_explicit_canary_allowlist(self):
        item = payments.PaymentItem(name="test", price=1, product_id="other-product", catalog_variation_id=26)
        with patch.object(payments, "get_db_connection", return_value=Connection([])):
            with self.assertRaises(HTTPException) as error:
                payments._canonical_payment_items([item])
        self.assertEqual(error.exception.status_code, 409)

    def test_internal_callback_cannot_claim_paid_when_provider_disagrees(self):
        payload = {"items": [{"source_type": "internal", "product_id": "codex-test-1tl-20261013", "catalog_variation_id": 25}]}
        conn = Connection([{"amount": 1, "payload": payload}])
        request = type("Request", (), {"query_params": {"invoice_id": "DM-test", "status_code": "100", "payment_status": "completed"}, "method": "GET"})()
        with patch.object(payments, "get_db_connection", return_value=conn), \
             patch.object(payments, "_status_for_invoice", return_value={"status_code": 0}), \
             patch.object(payments, "_sync_adf_order_to_app", return_value={"ok": True, "skipped": True}), \
             patch.object(payments, "_sync_adf_site_order", return_value={"ok": True, "skipped": True}), \
             patch.object(payments, "_persist_local_commerce_order") as persist:
            response = asyncio.run(payments.halkode_return(request, ""))
        self.assertIn("halkode_status=failed", response.headers["location"])
        persist.assert_not_called()

    def test_woo_product_keeps_legacy_source_lookup(self):
        conn = Connection([{"source_product_id": "3761", "source_variation_id": "3768",
                            "name": "Fullpass", "price": 5500, "currency": "TRY"}])
        item = payments.PaymentItem(name="Fullpass", price=5500, product_id="3761", variation_id=3768)
        with patch.object(payments, "get_db_connection", return_value=conn):
            result = payments._canonical_payment_items([item])
        self.assertEqual(result[0]["variation_id"], 3768)
        self.assertNotIn("catalog_variation_id", result[0])
        self.assertIn("v.source_variation_id=%s", conn.cur.queries[0][0])
        self.assertIn("p.source_product_id=%s", conn.cur.queries[0][0])
        self.assertEqual(conn.cur.queries[0][1], ("3768", "3761"))

    def test_event_catalog_id_maps_to_ticket_product_without_losing_order_source(self):
        conn = Connection([
            {"source_product_id": "205", "source_type": "event", "source_variation_id": "3768",
             "name": "Fullpass", "price": 5500, "currency": "TRY"},
            {"external_event_id": "3761"},
        ])
        item = payments.PaymentItem(name="Fullpass", price=5500, product_id="205", variation_id=3768)
        with patch.object(payments, "get_db_connection", return_value=conn):
            result = payments._canonical_payment_items([item])
        self.assertEqual(result[0]["product_id"], "205")
        self.assertEqual(result[0]["ticket_product_id"], "3761")
        self.assertEqual(conn.cur.queries[0][1], ("3768", "205"))
        self.assertEqual(conn.cur.queries[1][1], ("205",))

    def test_legacy_woo_id_resolves_only_through_matching_event_and_variation(self):
        conn = Connection([
            None,
            {"source_product_id": "205", "source_type": "event", "source_variation_id": "3768",
             "name": "Fullpass", "price": 5500, "currency": "TRY"},
            {"external_event_id": "3761"},
        ])
        item = payments.PaymentItem(name="Fullpass", price=5500, product_id="3761", variation_id=3768)
        with patch.object(payments, "get_db_connection", return_value=conn):
            result = payments._canonical_payment_items([item])
        self.assertEqual(result[0]["product_id"], "205")
        self.assertEqual(result[0]["ticket_product_id"], "3761")
        self.assertIn("se.external_event_id=%s", conn.cur.queries[1][0])
        self.assertEqual(conn.cur.queries[1][1], ("3768", "3761"))

    def test_adf_sync_uses_ticket_product_id(self):
        payload = {"email": "buyer@example.com", "items": [{
            "name": "Fullpass", "price": 5500, "quantity": 1,
            "product_id": "205", "variation_id": 3768, "ticket_product_id": "3761",
        }]}
        with patch.dict("os.environ", {"WOO_SYNC_SECRET": "test-secret"}), \
             patch.object(payments.httpx, "post") as post:
            post.return_value.status_code = 200
            post.return_value.content = b'{"ok":true,"created_tickets":1}'
            post.return_value.json.return_value = {"ok": True, "created_tickets": 1}
            result = payments._sync_adf_order_to_app("DM-test", payload, "processing")
        self.assertEqual(result["created_tickets"], 1)
        self.assertEqual(post.call_args.kwargs["json"]["line_items"][0]["product_id"], "3761")
        self.assertIsNotNone(payments._adf_order_payload("DM-test", payload))

    def test_historical_event_order_is_annotated_without_mutating_payment_payload(self):
        payload = {"items": [{"product_id": "205", "variation_id": 3768}, {"product_id": "other"}]}
        result = payments._annotate_ticket_product_ids(payload, {"205": "3761"})
        self.assertEqual(result["items"][0]["ticket_product_id"], "3761")
        self.assertNotIn("ticket_product_id", payload["items"][0])
        self.assertNotIn("ticket_product_id", result["items"][1])

    def test_browser_amount_cannot_override_catalog_price(self):
        request = payments.PaymentStartRequest(
            amount=900, email="test@example.com", items=[payments.PaymentItem(
                name="browser name", price=900, product_id="test-product", catalog_variation_id=25,
            )],
        )
        canonical = [{"name": "Actual", "price": 1, "quantity": 1,
                      "product_id": "test-product", "catalog_variation_id": 25}]
        with patch.object(payments, "_is_configured", return_value=True), \
             patch.object(payments, "_canonical_payment_items", return_value=canonical), \
             patch.object(payments, "_ensure_table") as ensure:
            with self.assertRaises(HTTPException) as error:
                payments.start_halkode_payment(request)
        self.assertEqual(error.exception.status_code, 400)
        ensure.assert_not_called()

    def test_internal_buyer_must_have_matching_verified_session(self):
        with self.assertRaises(HTTPException) as error:
            payments._verified_internal_buyer(None, "test@example.com")
        self.assertEqual(error.exception.status_code, 401)

        conn = Connection([{"account_id": 42, "email": "owner@example.com"}])
        with patch.object(payments, "get_db_connection", return_value=conn):
            with self.assertRaises(HTTPException) as error:
                payments._verified_internal_buyer("Bearer valid-token", "other@example.com")
        self.assertEqual(error.exception.status_code, 403)
        self.assertIn("s.expires_at::timestamptz > NOW()", conn.cur.queries[0][0])

        conn = Connection([{"account_id": 42, "email": "owner@example.com"}])
        with patch.object(payments, "get_db_connection", return_value=conn):
            self.assertEqual(payments._verified_internal_buyer("Bearer valid-token", "owner@example.com"), 42)

    def test_payment_start_stores_verified_account_from_server(self):
        request = payments.PaymentStartRequest(
            amount=1, email="owner@example.com", items=[payments.PaymentItem(
                name="Test", price=1, product_id="test-product", catalog_variation_id=25,
            )],
        )
        canonical = [{"name": "Test", "price": 1, "quantity": 1,
                      "product_id": "test-product", "variation_id": 25,
                      "catalog_variation_id": 25, "source_type": "internal"}]
        conn = Connection([])
        with patch.object(payments, "_is_configured", return_value=True), \
             patch.object(payments, "_canonical_payment_items", return_value=canonical), \
             patch.object(payments, "_verified_internal_buyer", return_value=42) as verify, \
             patch.object(payments, "_ensure_table"), \
             patch.object(payments, "get_db_connection", return_value=conn):
            result = payments.start_halkode_payment(request, "Bearer valid-token")
        verify.assert_called_once_with("Bearer valid-token", "owner@example.com")
        self.assertTrue(result["invoice_id"].startswith("DM-"))
        saved = json.loads(conn.cur.queries[0][1][4])
        self.assertEqual(saved["verified_account_id"], 42)
        self.assertEqual(saved["items"], canonical)
        self.assertEqual(conn.commits, 1)

    def test_internal_product_does_not_enter_woo_ticket_sync(self):
        payload = {"items": [{"source_type": "internal", "product_id": "codex-test-1tl-20261013",
                              "variation_id": 25, "price": 1, "quantity": 1}]}
        with patch.object(payments.httpx, "post") as post:
            result = payments._sync_adf_order_to_app("DM-test", payload, "processing")
        self.assertTrue(result["skipped"])
        post.assert_not_called()

    def test_paid_internal_order_links_to_exact_catalog_variation_without_ticket(self):
        conn = Connection([None, {"id": 42}, {"id": 7}, {"id": 25, "product_id": 3}, None])
        payload = {"email": "test@example.com", "name": "Test", "verified_account_id": 42, "items": [{
            "source_type": "internal", "product_id": "codex-test-1tl-20261013",
            "variation_id": 25, "catalog_variation_id": 25, "price": 1, "quantity": 1,
        }]}
        with patch.object(payments, "get_db_connection", return_value=conn):
            result = payments._persist_local_commerce_order("DM-test", payload, "paid")
        self.assertTrue(result["ok"])
        self.assertEqual(conn.commits, 1)
        lookup = next((query, args) for query, args in conn.cur.queries if "WHERE v.id=%s AND p.source_type IN ('internal','event')" in query)
        self.assertEqual(lookup[1], (25, "codex-test-1tl-20261013"))
        account_lookup = next(args for query, args in conn.cur.queries if "SELECT id FROM accounts WHERE id=%s" in query)
        self.assertEqual(account_lookup, (42, "test@example.com"))
        insert = next(args for query, args in conn.cur.queries if "INSERT INTO commerce_order_items" in query)
        self.assertEqual(insert[1:4], (3, 25, None))

    def test_paid_event_order_links_legacy_and_catalog_ids_to_same_event(self):
        conn = Connection([
            None, {"id": 674}, {"id": 9}, None,
            {"id": 12, "product_id": 1, "source_product_id": "205"}, {"id": 205},
        ])
        payload = {"email": "buyer@example.com", "items": [{
            "product_id": "3761", "ticket_product_id": "3761",
            "variation_id": 3768, "price": 5500, "quantity": 1,
        }]}
        with patch.object(payments, "get_db_connection", return_value=conn):
            result = payments._persist_local_commerce_order("DM-event", payload, "paid")
        self.assertTrue(result["ok"])
        fallback = next((query, args) for query, args in conn.cur.queries if "se.external_event_id=%s" in query)
        self.assertEqual(fallback[1], ("3768", "3761"))
        event_lookup = next(args for query, args in conn.cur.queries if "FROM mobile_event_submissions" in query)
        self.assertEqual(event_lookup, ("205", "205", "205"))
        insert = next(args for query, args in conn.cur.queries if "INSERT INTO commerce_order_items" in query)
        self.assertEqual(insert[1:4], (1, 12, 205))


if __name__ == "__main__":
    unittest.main()
