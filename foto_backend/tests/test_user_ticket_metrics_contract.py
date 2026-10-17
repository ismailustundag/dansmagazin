import ast
import unittest
from pathlib import Path


SOURCE = Path(__file__).resolve().parents[1] / "admin_v2.py"


class UserTicketMetricsContractTests(unittest.TestCase):
    def test_user_queries_include_non_cancelled_and_used_ticket_counts(self):
        source = SOURCE.read_text(encoding="utf-8")
        tree = ast.parse(source)
        functions = {
            node.name: ast.get_source_segment(source, node) or ""
            for node in ast.walk(tree)
            if isinstance(node, ast.FunctionDef)
        }

        for function_name in ("paged_users", "user_item"):
            function_source = functions[function_name]
            self.assertIn("assigned_ticket_count", function_source)
            self.assertIn("purchased_ticket_count", function_source)
            self.assertIn("used_ticket_count", function_source)
            self.assertIn("NOT IN ('cancelled','deleted','void')", function_source)
            self.assertIn("t.used_at IS NOT NULL", function_source)


if __name__ == "__main__":
    unittest.main()
