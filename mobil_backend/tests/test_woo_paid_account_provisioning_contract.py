import ast
import unittest
from pathlib import Path


EVENTS_SOURCE = Path(__file__).resolve().parents[1] / "app" / "routers" / "events.py"


class WooPaidAccountProvisioningContractTests(unittest.TestCase):
    def test_only_paid_orders_provision_missing_app_accounts(self):
        source = EVENTS_SOURCE.read_text(encoding="utf-8")
        tree = ast.parse(source)
        functions = {
            node.name: node
            for node in tree.body
            if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef))
        }

        handler_source = ast.get_source_segment(source, functions["admin_woo_order_paid"]) or ""
        helper_source = ast.get_source_segment(
            source,
            functions["_provision_account_for_paid_woo_order"],
        ) or ""

        self.assertIn('order_status in {"processing", "completed"}', handler_source)
        self.assertIn("_woo_order_has_ticket_product", handler_source)
        self.assertIn("_provision_account_for_paid_woo_order", handler_source)
        self.assertIn("_upsert_local_account", helper_source)
        self.assertIn("_upsert_identity_map", helper_source)
        self.assertIn('"woo_paid_order"', helper_source)

        eligibility_source = ast.get_source_segment(
            source,
            functions["_woo_order_has_ticket_product"],
        ) or ""
        self.assertIn("_find_or_create_submission_for_woo_product", eligibility_source)


if __name__ == "__main__":
    unittest.main()
