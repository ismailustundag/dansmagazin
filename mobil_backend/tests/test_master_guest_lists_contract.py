import ast
import unittest
from pathlib import Path


BACKEND_ROOT = Path(__file__).resolve().parents[1]
PROFILE_SOURCE = BACKEND_ROOT / "app" / "routers" / "profile.py"
EVENTS_SOURCE = BACKEND_ROOT / "app" / "routers" / "events.py"
MOBILE_ROOT = BACKEND_ROOT.parents[0] / "mobile_app_preview" / "lib"


def _function_source(path: Path, name: str) -> str:
    source = path.read_text(encoding="utf-8")
    tree = ast.parse(source)
    for node in tree.body:
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)) and node.name == name:
            return ast.get_source_segment(source, node) or ""
    raise AssertionError(f"Function not found: {name}")


class MasterGuestListContractTests(unittest.TestCase):
    def test_schema_tracks_master_and_copy_source(self):
        source = _function_source(PROFILE_SOURCE, "init_profile_settings_table")
        self.assertIn("is_master BOOLEAN NOT NULL DEFAULT FALSE", source)
        self.assertIn("source_master_list_id BIGINT", source)
        self.assertIn("'ankara genel'", source)
        self.assertIn("'diğer davetli'", source)

    def test_designated_master_names_are_created_as_master_by_super_admin(self):
        source = _function_source(PROFILE_SOURCE, "create_guest_list")
        self.assertIn("_is_designated_master_guest_list(actor, name)", source)

    def test_managers_can_read_and_copy_master_lists(self):
        list_source = _function_source(PROFILE_SOURCE, "guest_lists")
        detail_source = _function_source(PROFILE_SOURCE, "_fetch_guest_list_detail")
        copy_source = _function_source(PROFILE_SOURCE, "copy_guest_list")

        self.assertIn("gl.is_master=TRUE", list_source)
        self.assertIn("gl.is_master=TRUE", detail_source)
        self.assertIn("owner_account_id=%s OR is_master=TRUE", copy_source)
        self.assertIn("VALUES (%s,%s,FALSE,%s,NOW(),NOW())", copy_source)

    def test_master_mutations_and_event_import_remain_owner_only(self):
        for name in (
            "update_guest_list",
            "delete_guest_list",
            "add_guest_list_member",
            "remove_guest_list_member",
        ):
            with self.subTest(name=name):
                self.assertIn(
                    "owner_account_id=%s",
                    _function_source(PROFILE_SOURCE, name),
                )

        import_source = _function_source(EVENTS_SOURCE, "import_guest_list_to_event")
        self.assertIn("owner_account_id=%s", import_source)

    def test_mobile_event_picker_only_shows_owned_lists(self):
        source = (
            MOBILE_ROOT / "screens" / "editor_event_management_screen.dart"
        ).read_text(encoding="utf-8")
        self.assertIn("allLists.where((list) => list.isOwned).toList()", source)


if __name__ == "__main__":
    unittest.main()
