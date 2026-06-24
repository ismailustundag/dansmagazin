import sys
from pathlib import Path

from fastapi.testclient import TestClient
from dotenv import load_dotenv

ROOT_DIR = Path(__file__).resolve().parents[1]
if str(ROOT_DIR) not in sys.path:
    sys.path.insert(0, str(ROOT_DIR))

load_dotenv(ROOT_DIR / ".env")

from app.main import app


def main() -> int:
    with TestClient(app) as client:
        health = client.get("/health")
        assert health.status_code == 200, f"/health failed: {health.status_code} {health.text}"
        assert health.json() == {"ok": True}, f"/health payload unexpected: {health.text}"

        health_head = client.head("/health")
        assert health_head.status_code == 200, f"HEAD /health failed: {health_head.status_code}"

        menu = client.get("/menu")
        assert menu.status_code == 200, f"/menu failed: {menu.status_code} {menu.text}"
        menu_json = menu.json()
        assert isinstance(menu_json.get("items"), list), f"/menu payload unexpected: {menu.text}"
        assert any(item.get("key") == "messages" for item in menu_json["items"]), "/menu missing messages item"

    print("SMOKE_OK")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
