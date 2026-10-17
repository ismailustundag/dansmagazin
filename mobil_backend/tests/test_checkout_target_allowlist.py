import importlib

import pytest
from fastapi import HTTPException


def reload_auth(monkeypatch, extra_hosts=""):
    monkeypatch.setenv("WP_BASE_URL", "https://www.dansmagazin.net")
    monkeypatch.setenv("WOO_SSO_EXTRA_ALLOWED_HOSTS", extra_hosts)
    import mobil_backend.app.routers.auth as auth

    return importlib.reload(auth)


def test_checkout_target_accepts_wordpress_hosts(monkeypatch):
    auth = reload_auth(monkeypatch)

    assert auth._normalize_checkout_target("https://www.dansmagazin.net/urun/test") == (
        "https://www.dansmagazin.net/urun/test?app=1"
    )
    assert auth._normalize_checkout_target("https://dansmagazin.net/urun/test") == (
        "https://dansmagazin.net/urun/test?app=1"
    )


def test_checkout_target_rejects_unknown_host(monkeypatch):
    auth = reload_auth(monkeypatch)

    with pytest.raises(HTTPException) as exc:
        auth._normalize_checkout_target("https://example.com/urun/test")

    assert exc.value.status_code == 400


def test_checkout_target_accepts_configured_staging_host(monkeypatch):
    auth = reload_auth(monkeypatch, "test.dansmagazin.net, staging.dansmagazin.net")

    assert auth._normalize_checkout_target("https://test.dansmagazin.net/magaza/?product=woo-1") == (
        "https://test.dansmagazin.net/magaza/?product=woo-1&app=1"
    )
