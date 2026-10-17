import importlib.util
from io import BytesIO
from tempfile import TemporaryDirectory
import unittest
from pathlib import Path
from unittest.mock import patch

from fastapi import HTTPException, UploadFile
from PIL import Image


SOURCE = Path(__file__).resolve().parents[1] / "app" / "routers" / "commerce.py"
spec = importlib.util.spec_from_file_location("commerce_candidate", SOURCE)
commerce = importlib.util.module_from_spec(spec)
spec.loader.exec_module(commerce)


class Cursor:
    def __init__(self, fail_at=None):
        self.calls = []
        self.fail_at = fail_at

    def execute(self, query, values=None):
        self.calls.append((query, values))
        if len(self.calls) == self.fail_at:
            raise RuntimeError("database failure")

    def fetchone(self):
        query = self.calls[-1][0] if self.calls else ""
        if "COUNT(*)::INT AS cnt FROM commerce_variations" in query:
            return {"cnt": 2}
        if "UPDATE commerce_products SET" in query:
            return {"id": 20, "name": "Test product", "is_active": True}
        return {"id": 20 if len(self.calls) == 1 else 30, "source_type": "internal", "is_active": False}


class Connection:
    def __init__(self, fail_at=None):
        self.cur = Cursor(fail_at)
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


class CommerceDraftCreationTests(unittest.TestCase):
    def setUp(self):
        self.auth = patch.object(commerce, "_require_admin")
        self.auth.start()
        self.addCleanup(self.auth.stop)
        self.payload = {
            "name": "Test product",
            "variations": [
                {"name": "Full Pass", "price": "100.00", "option_path": ["Full Pass"]},
                {"name": "Single", "price": "750.00", "option_path": ["Accommodation", "1 night", "Single"]},
            ],
        }

    def test_new_product_and_variations_commit_together_as_draft(self):
        conn = Connection()
        with patch.object(commerce, "get_db_connection", return_value=conn):
            result = commerce.create_product(self.payload, "admin-token")
        self.assertFalse(result["is_active"])
        self.assertEqual(result["variation_count"], 2)
        self.assertEqual(conn.commits, 1)
        self.assertEqual(conn.rollbacks, 0)
        self.assertIn("FALSE", conn.cur.calls[0][0])
        self.assertEqual(sum("INSERT INTO commerce_variations" in query for query, _ in conn.cur.calls), 2)

    def test_failed_variation_rolls_back_product(self):
        conn = Connection(fail_at=2)
        with patch.object(commerce, "get_db_connection", return_value=conn):
            with self.assertRaises(RuntimeError):
                commerce.create_product(self.payload, "admin-token")
        self.assertEqual(conn.commits, 0)
        self.assertEqual(conn.rollbacks, 1)

    def test_invalid_option_path_does_not_open_database(self):
        self.payload["variations"][0]["option_path"] = []
        with patch.object(commerce, "get_db_connection") as connect:
            with self.assertRaises(HTTPException) as error:
                commerce.create_product(self.payload, "admin-token")
        self.assertEqual(error.exception.status_code, 400)
        connect.assert_not_called()

    def test_internal_draft_can_be_published_when_it_has_active_variations(self):
        conn = Connection()
        with patch.object(commerce, "get_db_connection", return_value=conn):
            result = commerce.update_product(20, {"is_active": True}, "admin-token")
        self.assertTrue(result["ok"])
        self.assertEqual(conn.commits, 1)

    def test_product_without_active_variation_cannot_be_published(self):
        conn = Connection()
        original = conn.cur.fetchone
        conn.cur.fetchone = lambda: {"cnt": 0} if "COUNT(*)::INT AS cnt" in conn.cur.calls[-1][0] else original()
        with patch.object(commerce, "get_db_connection", return_value=conn):
            with self.assertRaises(HTTPException) as error:
                commerce.update_product(20, {"is_active": True}, "admin-token")
        self.assertEqual(error.exception.status_code, 409)
        self.assertEqual(conn.commits, 0)

    def test_already_active_internal_product_can_be_edited(self):
        conn = Connection()
        conn.cur.fetchone = lambda: {"id": 20, "source_type": "internal", "is_active": True}
        with patch.object(commerce, "get_db_connection", return_value=conn):
            commerce.update_product(20, {"name": "Updated", "is_active": True}, "admin-token")
        self.assertEqual(conn.commits, 1)

    def test_uploaded_image_is_optimized_and_publicly_readable(self):
        source = BytesIO()
        Image.new("RGB", (2000, 1000), "red").save(source, format="PNG")
        upload = UploadFile(filename="poster.png", file=BytesIO(source.getvalue()), headers={"content-type": "image/png"})
        with TemporaryDirectory() as directory, patch.object(commerce, "COMMERCE_IMAGE_DIR", Path(directory)):
            result = commerce.upload_product_image(upload, "admin-token")
            filename = result["url"].rsplit("/", 1)[-1]
            response = commerce.product_image(filename)
            self.assertEqual(response.media_type, "image/jpeg")
            with Image.open(Path(directory) / filename) as saved:
                self.assertLessEqual(saved.width, 1600)
                self.assertEqual(saved.format, "JPEG")


if __name__ == "__main__":
    unittest.main()
