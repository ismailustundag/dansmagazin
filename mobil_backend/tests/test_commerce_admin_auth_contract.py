import ast
import unittest
from pathlib import Path


COMMERCE_SOURCE = Path(__file__).resolve().parents[1] / "app" / "routers" / "commerce.py"


class CommerceAdminAuthContractTests(unittest.TestCase):
    def test_session_auth_uses_integer_account_active_flag(self):
        tree = ast.parse(COMMERCE_SOURCE.read_text(encoding="utf-8"))
        auth = next(
            node for node in tree.body
            if isinstance(node, ast.FunctionDef) and node.name == "_require_admin"
        )
        queries = [node.value for node in ast.walk(auth) if isinstance(node, ast.Constant) and isinstance(node.value, str)]

        self.assertTrue(any("COALESCE(a.is_active, 1)=1" in query for query in queries))
        self.assertFalse(any("COALESCE(a.is_active, TRUE)" in query for query in queries))


if __name__ == "__main__":
    unittest.main()
