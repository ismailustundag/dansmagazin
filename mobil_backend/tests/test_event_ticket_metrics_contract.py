import ast
import unittest
from pathlib import Path


EVENTS_SOURCE = Path(__file__).resolve().parents[1] / "app" / "routers" / "events.py"


class EventTicketMetricsContractTests(unittest.TestCase):
    def test_ticket_summary_includes_historical_and_used_counts(self):
        source = EVENTS_SOURCE.read_text(encoding="utf-8")
        tree = ast.parse(source)
        helper = next(
            node
            for node in tree.body
            if isinstance(node, ast.FunctionDef) and node.name == "_build_active_ticket_control_map"
        )
        helper_source = ast.get_source_segment(source, helper) or ""

        self.assertIn("used_ticket_count", helper_source)
        self.assertIn("t.used_at IS NOT NULL", helper_source)
        self.assertIn("NOT IN ('cancelled','deleted','void')", helper_source)


if __name__ == "__main__":
    unittest.main()
