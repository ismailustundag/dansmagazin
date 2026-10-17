import unittest
from pathlib import Path

from fastapi import FastAPI, HTTPException
from fastapi.testclient import TestClient

from admin_v2 import build_admin_v2_router


class AdminV2RouterTest(unittest.TestCase):
    def setUp(self):
        self.calls = []
        self.admin_items = []
        self.bearer_responses = {}
        self.admin_responses = {}

        class FakeCursor:
            def __init__(self):
                self.sql = ""

            def execute(self, sql, params=()):
                self.sql = sql

            def fetchall(self):
                if "FROM accounts a" in self.sql and "can_create_mobile_event" in self.sql:
                    return [{"id": 9, "name": "Editor", "email": "editor@example.com", "role": "editor", "username": "editor"}]
                if "FROM mobile_event_invitees ei" in self.sql:
                    return [{"account_id": 12, "used_at": "2026-08-04T20:00:00"}]
                return []

        class FakeConnection:
            def cursor(self):
                return FakeCursor()

            def close(self):
                return None

        def guard(request):
            if request.cookies.get("session_token") != "valid-session":
                raise HTTPException(status_code=401, detail="Giris gerekli")
            return {
                "id": 1,
                "name": "Admin",
                "email": "admin@example.com",
                "role": "super_admin",
            }

        def bearer(path, token, method="GET", json_data=None):
            self.calls.append(
                {
                    "kind": "bearer",
                    "path": path,
                    "token": token,
                    "method": method,
                    "data": json_data,
                }
            )
            return {"ok": True, "data": self.bearer_responses.get(path, {"ok": True})}

        def bearer_form(path, token, method="POST", data=None):
            self.calls.append(
                {
                    "kind": "form",
                    "path": path,
                    "token": token,
                    "method": method,
                    "data": data,
                }
            )
            return {"ok": True, "data": {"ok": True}}

        def bearer_multipart(path, token, fields=None, files=None):
            self.calls.append(
                {
                    "kind": "multipart",
                    "path": path,
                    "token": token,
                    "fields": fields,
                    "files": files,
                }
            )
            return {"ok": True, "data": {"ok": True}}

        def admin(path, method="GET", data=None):
            self.calls.append({"kind": "admin", "path": path, "method": method, "data": data})
            if path in self.admin_responses:
                return {"ok": True, "data": self.admin_responses[path]}
            return {"ok": True, "data": {"items": self.admin_items}}

        app = FastAPI()
        app.include_router(
            build_admin_v2_router(
                require_super_admin=guard,
                db_conn=FakeConnection,
                bearer_call=bearer,
                bearer_form_call=bearer_form,
                bearer_multipart_call=bearer_multipart,
                admin_call=admin,
                hash_password=lambda value: f"hashed:{value}",
                session_cookie="session_token",
            )
        )
        self.client = TestClient(app)
        self.client.cookies.set("session_token", "valid-session")

    def test_me_returns_current_super_admin(self):
        response = self.client.get("/admin/api/v2/me")
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json()["role"], "super_admin")

    def test_mutation_requires_same_origin_header(self):
        response = self.client.post(
            "/admin/api/v2/actions/event-active",
            json={"id": 42, "active": False},
        )
        self.assertEqual(response.status_code, 403)
        self.assertEqual(self.calls, [])

    def test_event_active_payload_is_translated(self):
        response = self.client.post(
            "/admin/api/v2/actions/event-active",
            json={"id": 42, "active": False},
            headers={"X-DMZ-Request": "admin-v2"},
        )
        self.assertEqual(response.status_code, 200)
        self.assertEqual(
            self.calls[-1],
            {
                "kind": "bearer",
                "path": "/events/manage/items/42/active",
                "token": "valid-session",
                "method": "POST",
                "data": {"is_active": False},
            },
        )

    def test_event_copy_uses_manage_item_contract(self):
        response = self.client.post(
            "/admin/api/v2/actions/event-copy",
            json={"id": 42},
            headers={"X-DMZ-Request": "admin-v2"},
        )
        self.assertEqual(response.status_code, 200)
        self.assertEqual(
            self.calls[-1],
            {
                "kind": "bearer",
                "path": "/events/manage/items/42/copy",
                "token": "valid-session",
                "method": "POST",
                "data": {},
            },
        )

    def test_event_delete_uses_manage_item_contract(self):
        response = self.client.post(
            "/admin/api/v2/actions/event-delete",
            json={"id": 42},
            headers={"X-DMZ-Request": "admin-v2"},
        )
        self.assertEqual(response.status_code, 200)
        self.assertEqual(self.calls[-1]["path"], "/events/manage/items/42")
        self.assertEqual(self.calls[-1]["method"], "DELETE")

    def test_event_guest_and_scan_actions_use_existing_contracts(self):
        cases = [
            (
                "event-guest-import",
                {"id": 42, "guest_list_id": 7},
                "bearer",
                "/events/manage/items/42/invitees/import-guest-list",
                "POST",
                {"guest_list_id": 7},
            ),
            (
                "event-invitee-remove",
                {"id": 42, "account_id": 9},
                "bearer",
                "/events/manage/items/42/invitees/9",
                "DELETE",
                None,
            ),
            (
                "event-scan-grant",
                {"id": 42, "account_id": 9},
                "admin",
                "/admin/events/42/scan-permissions/grant",
                "POST",
                {"account_id": 9},
            ),
            (
                "event-scan-revoke",
                {"id": 42, "account_id": 9},
                "admin",
                "/admin/events/42/scan-permissions/revoke",
                "POST",
                {"account_id": 9},
            ),
        ]
        for action, payload, kind, path, method, data in cases:
            with self.subTest(action=action):
                response = self.client.post(
                    f"/admin/api/v2/actions/{action}",
                    json=payload,
                    headers={"X-DMZ-Request": "admin-v2"},
                )
                self.assertEqual(response.status_code, 200)
                self.assertEqual(self.calls[-1]["kind"], kind)
                self.assertEqual(self.calls[-1]["path"], path)
                self.assertEqual(self.calls[-1]["method"], method)
                self.assertEqual(self.calls[-1]["data"], data)

    def test_event_operations_collects_guest_scan_and_qr_state(self):
        self.admin_items = [
            {
                "submission_id": 42,
                "name": "Vişnelik",
                "status": "approved",
                "active_ticket_count": 3,
            }
        ]
        self.bearer_responses = {
            "/profile/guest-lists": {"items": [{"guest_list_id": 7, "name": "Ankara"}]},
            "/events/manage/items/42/invitees": {
                "items": [{"account_id": 12, "name": "Davetli", "ticket_id": 81}]
            },
        }
        self.admin_responses = {
            "/admin/events/42/scan-permissions": {
                "items": [{"permission_id": 2, "account_id": 9, "name": "Editor"}]
            }
        }

        response = self.client.get("/admin/api/v2/events/42/operations")

        self.assertEqual(response.status_code, 200)
        data = response.json()
        self.assertEqual(data["event"]["active_ticket_count"], 3)
        self.assertEqual(data["guest_lists"][0]["guest_list_id"], 7)
        self.assertTrue(data["invitees"][0]["ticket_used"])
        self.assertEqual(data["scan_permissions"][0]["account_id"], 9)
        self.assertEqual(data["editor_candidates"][0]["id"], 9)

    def test_expired_event_operations_are_read_only_and_include_invitees(self):
        self.admin_items = [
            {
                "submission_id": 43,
                "name": "Geçmiş Gece",
                "status": "expired",
                "used_ticket_count": 5,
            }
        ]
        self.bearer_responses = {
            "/profile/guest-lists": {"items": []},
            "/events/manage/items/43/invitees": {
                "items": [{"account_id": 12, "name": "Davetli", "ticket_id": 81}]
            },
        }
        self.admin_responses = {
            "/admin/events/43/scan-permissions": {"items": []},
        }

        response = self.client.get("/admin/api/v2/events/43/operations")

        self.assertEqual(response.status_code, 200)
        data = response.json()
        self.assertTrue(data["read_only"])
        self.assertEqual(data["event"]["used_ticket_count"], 5)
        self.assertEqual(data["invitees"][0]["account_id"], 12)

    def test_guest_list_actions_use_profile_contracts(self):
        cases = [
            ("guest-create", {"name": "Yeni Liste"}, "/profile/guest-lists", "POST"),
            ("guest-copy", {"id": 7, "name": "Kopya"}, "/profile/guest-lists/7/copy", "POST"),
            ("guest-rename", {"id": 7, "name": "Yeni Ad"}, "/profile/guest-lists/7", "PATCH"),
            ("guest-delete", {"id": 7}, "/profile/guest-lists/7", "DELETE"),
            ("guest-member-add", {"id": 7, "account_id": 9}, "/profile/guest-lists/7/members", "POST"),
            ("guest-member-remove", {"id": 7, "account_id": 9}, "/profile/guest-lists/7/members/9", "DELETE"),
        ]
        for action, payload, path, method in cases:
            with self.subTest(action=action):
                response = self.client.post(
                    f"/admin/api/v2/actions/{action}",
                    json=payload,
                    headers={"X-DMZ-Request": "admin-v2"},
                )
                self.assertEqual(response.status_code, 200)
                self.assertEqual(self.calls[-1]["path"], path)
                self.assertEqual(self.calls[-1]["method"], method)

    def test_content_actions_use_existing_mobile_contracts(self):
        cases = [
            ("news-reject", {"id": 11}, "form", "/news/manage/items/11/reject", "POST"),
            ("news-delete", {"id": 11}, "bearer", "/news/manage/items/11/delete", "POST"),
            ("poll-state", {"id": 12, "active": False}, "bearer", "/photos/polls/12/state", "POST"),
            ("poll-delete", {"id": 12}, "bearer", "/photos/polls/12", "DELETE"),
            ("feed-delete", {"id": 13}, "bearer", "/photos/feed/posts/13", "DELETE"),
        ]
        for action, payload, kind, path, method in cases:
            with self.subTest(action=action):
                response = self.client.post(
                    f"/admin/api/v2/actions/{action}",
                    json=payload,
                    headers={"X-DMZ-Request": "admin-v2"},
                )
                self.assertEqual(response.status_code, 200)
                self.assertEqual(self.calls[-1]["kind"], kind)
                self.assertEqual(self.calls[-1]["path"], path)
                self.assertEqual(self.calls[-1]["method"], method)

    def test_pending_event_approval_uses_admin_submission_contract(self):
        response = self.client.post(
            "/admin/api/v2/actions/event-approve",
            json={"id": 52},
            headers={"X-DMZ-Request": "admin-v2"},
        )
        self.assertEqual(response.status_code, 200)
        self.assertEqual(
            self.calls[-1],
            {
                "kind": "admin",
                "path": "/admin/events/submissions/52/approve",
                "method": "POST",
                "data": {"admin_note": ""},
            },
        )

    def test_pending_event_rejection_forwards_admin_note(self):
        response = self.client.post(
            "/admin/api/v2/actions/event-reject",
            json={"id": 52, "admin_note": "Tarih eksik"},
            headers={"X-DMZ-Request": "admin-v2"},
        )
        self.assertEqual(response.status_code, 200)
        self.assertEqual(self.calls[-1]["path"], "/admin/events/submissions/52/reject")
        self.assertEqual(self.calls[-1]["data"], {"admin_note": "Tarih eksik"})

    def test_event_list_normalizes_mobile_backend_field_names(self):
        self.admin_items = [
            {
                "submission_id": 42,
                "name": "Vişnelik Dans Gecesi",
                "status": "approved",
                "event_is_active": True,
            }
        ]
        response = self.client.get("/admin/api/v2/events?status=active")
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json()["items"][0]["id"], 42)
        self.assertEqual(response.json()["items"][0]["event_name"], "Vişnelik Dans Gecesi")

    def test_event_list_is_sorted_by_nearest_date_with_undated_items_last(self):
        self.admin_items = [
            {"submission_id": 3, "name": "Uzak", "status": "approved", "event_is_active": True, "start_at": "2026-08-20T20:00:00"},
            {"submission_id": 1, "name": "Tarihsiz", "status": "approved", "event_is_active": True, "start_at": ""},
            {"submission_id": 2, "name": "Yakın", "status": "approved", "event_is_active": True, "event_date": "2026-08-04"},
        ]
        response = self.client.get("/admin/api/v2/events?status=active")
        self.assertEqual(response.status_code, 200)
        self.assertEqual([item["id"] for item in response.json()["items"]], [2, 3, 1])

    def test_expired_event_list_is_sorted_newest_first(self):
        self.admin_items = [
            {"submission_id": 4, "name": "Eski", "status": "expired", "start_at": "2026-06-01T20:00:00"},
            {"submission_id": 5, "name": "Yeni", "status": "expired", "start_at": "2026-07-30T20:00:00"},
        ]
        response = self.client.get("/admin/api/v2/events?status=expired")
        self.assertEqual(response.status_code, 200)
        self.assertEqual([item["id"] for item in response.json()["items"]], [5, 4])

    def test_news_approval_uses_form_contract(self):
        response = self.client.post(
            "/admin/api/v2/actions/news-approve",
            json={"id": 9, "admin_note": "Uygun"},
            headers={"X-DMZ-Request": "admin-v2"},
        )
        self.assertEqual(response.status_code, 200)
        self.assertEqual(self.calls[-1]["kind"], "form")
        self.assertEqual(self.calls[-1]["data"], {"admin_note": "Uygun"})

    def test_notification_contract_always_has_explicit_target(self):
        response = self.client.post(
            "/admin/api/v2/actions/notification-send",
            json={"title": "Test", "body": "Mesaj", "route": "/events/242"},
            headers={"X-DMZ-Request": "admin-v2"},
        )
        self.assertEqual(response.status_code, 200)
        self.assertEqual(
            self.calls[-1]["data"],
            {
                "title": "Test",
                "body": "Mesaj",
                "send_to_all": True,
                "target_account_ids": [],
                "target_route": "/events/242",
            },
        )

    def test_event_create_uses_form_contract_without_photo_album(self):
        response = self.client.post(
            "/admin/api/v2/events",
            data={
                "event_name": "Yeni Gece",
                "city": "Ankara",
                "start_at": "2026-08-01T20:00",
                "ticket_sales_enabled": "1",
            },
            headers={"X-DMZ-Request": "admin-v2"},
        )
        self.assertEqual(response.status_code, 200)
        self.assertEqual(self.calls[-1]["kind"], "form")
        self.assertEqual(self.calls[-1]["path"], "/events/submissions")
        self.assertEqual(self.calls[-1]["data"]["create_photo_album"], "0")

    def test_event_update_forwards_weekly_repeat_contract(self):
        response = self.client.post(
            "/admin/api/v2/events/246",
            data={
                "event_name": "GREAT ANKARA DANS GECESİ",
                "city": "Ankara",
                "event_date": "2026-08-07T20:00",
                "start_at": "2026-08-07T20:00",
                "end_at": "2026-08-08T00:30",
                "repeat_weekly": "1",
                "repeat_weekday": "4",
            },
            headers={"X-DMZ-Request": "admin-v2"},
        )
        self.assertEqual(response.status_code, 200)
        manage_call = next(call for call in self.calls if call["kind"] == "form")
        self.assertEqual(manage_call["path"], "/events/manage/items/246/update")
        self.assertEqual(manage_call["data"]["repeat_weekly"], "1")
        self.assertEqual(manage_call["data"]["repeat_weekday"], "4")

    def test_poll_create_uses_admin_poll_contract(self):
        response = self.client.post(
            "/admin/api/v2/actions/poll-create",
            json={
                "title": "Bu gece nasildi?",
                "show_results_after_vote": True,
                "questions": [{"question": "Muzik nasildi?", "options": ["Iyi", "Orta"]}],
            },
            headers={"X-DMZ-Request": "admin-v2"},
        )
        self.assertEqual(response.status_code, 200)
        self.assertEqual(self.calls[-1]["path"], "/photos/polls/admin")
        self.assertEqual(self.calls[-1]["data"]["questions"][0]["options"], ["Iyi", "Orta"])

    def test_built_asset_is_served_without_duplicate_assets_directory(self):
        dist_dir = Path(__file__).resolve().parents[1] / "admin_v2_dist" / "assets"
        css_file = next(dist_dir.glob("*.css"))
        response = self.client.get(f"/admin-v2-assets/assets/{css_file.name}")
        self.assertEqual(response.status_code, 200)
        self.assertIn("text/css", response.headers.get("content-type", ""))

    def test_admin_shell_is_not_cached_across_frontend_deploys(self):
        response = self.client.get("/admin-v2/events")

        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.headers.get("cache-control"), "no-cache, no-store, must-revalidate")

    def test_asset_path_cannot_escape_distribution_directory(self):
        response = self.client.get("/admin-v2-assets/%2e%2e/admin_v2.py")
        self.assertEqual(response.status_code, 404)


if __name__ == "__main__":
    unittest.main()
