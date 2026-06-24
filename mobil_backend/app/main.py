import html
import json
import logging
import re
import threading
import time
from pathlib import Path
from urllib.parse import quote

from fastapi import FastAPI, Request
from fastapi.responses import FileResponse, HTMLResponse, RedirectResponse

from app.schemas import MobileMenuResponse
from app.routers.discover import init_news_reaction_table, router as discover_router
from app.routers.auth import (
    ensure_default_friendships_for_all_users,
    ensure_register_guard_tables,
    router as auth_router,
)
from app.routers.events import (
    admin_router as admin_events_router,
    init_event_submission_tables,
    router as events_router,
)
from app.routers.photos import init_photo_reaction_tables, router as photos_router
from app.routers.store import init_store_tables, router as store_router
from app.routers.news import (
    admin_router as admin_news_router,
    init_news_submission_tables,
    router as news_router,
)
from app.routers.messages import (
    init_message_extra_tables,
    init_message_read_state_table,
    init_message_typing_state_table,
    router as messages_router,
)
from app.routers.profile import (
    init_profile_search_indexes,
    init_profile_settings_table,
    router as profile_router,
    trigger_event_city_notifications_today,
    trigger_birthday_notifications_today,
)
from app.utils import get_db_connection

app = FastAPI(title="Mobil Backend")
logger = logging.getLogger("mobil_backend.main")
_birthday_worker_started = False
ANDROID_STORE_URL = "https://play.google.com/store/apps/details?id=net.dansmagazin.mobile"
IOS_STORE_URL = "https://apps.apple.com/tr/app/dansmagazin/id6760408150?l=tr"
APP_DOWNLOAD_URL = "https://api2.dansmagazin.net/app-download"
APP_DOWNLOAD_QR_PATH = Path("/home/ubuntu/mobil_backend/media/app_download_qr.png")
PUBLIC_API_BASE = "https://api2.dansmagazin.net"
_EVENT_SHARE_ROUTE_RE = re.compile(r"^/events/(\d+)$")


def _birthday_worker():
    while True:
        try:
            trigger_birthday_notifications_today(reason="scheduler")
        except Exception as exc:
            logger.warning("birthday scheduler error: %s", exc)
        try:
            trigger_event_city_notifications_today(reason="scheduler")
        except Exception as exc:
            logger.warning("event city scheduler error: %s", exc)
        time.sleep(60)


def _detect_store_target(user_agent: str) -> str:
    ua = (user_agent or "").lower()
    if "android" in ua:
        return "android"
    if any(token in ua for token in ("iphone", "ipad", "ipod")):
        return "ios"
    return "fallback"


def _share_route_deep_link(route: str) -> str:
    return f"dansmagazin://open?route={quote((route or "").strip(), safe='')}"


def _share_event_cover_url(raw_value: str) -> str:
    value = (raw_value or "").strip()
    if not value:
        return ""
    if value.startswith("http://") or value.startswith("https://"):
        return value
    return f"{PUBLIC_API_BASE}/events/submission-cover/{Path(value).name}"


def _load_event_share_meta(submission_id: int):
    conn = None
    try:
        conn = get_db_connection()
        cur = conn.cursor()
        cur.execute(
            """
            SELECT id,
                   COALESCE(event_name, '') AS event_name,
                   COALESCE(description, '') AS description,
                   COALESCE(program_text, '') AS program_text,
                   COALESCE(event_date, '') AS event_date,
                   COALESCE(start_at, '') AS start_at,
                   COALESCE(venue, '') AS venue,
                   COALESCE(organizer_name, '') AS organizer_name,
                   COALESCE(cover_path, '') AS cover_path
            FROM mobile_event_submissions
            WHERE id=%s
            LIMIT 1
            """,
            (int(submission_id),),
        )
        row = cur.fetchone()
        if not row:
            return None
        title = (row.get("event_name") or "").strip() or f"Etkinlik {int(submission_id)}"
        raw_description = (
            (row.get("description") or "").strip()
            or (row.get("program_text") or "").strip()
            or (row.get("organizer_name") or "").strip()
        )
        description = " ".join(raw_description.split())
        if len(description) > 220:
            description = f"{description[:220].rstrip()}..."
        meta_parts = []
        event_date = (row.get("event_date") or "").strip()
        if event_date:
            meta_parts.append(event_date)
        venue = (row.get("venue") or "").strip()
        if venue:
            meta_parts.append(venue)
        return {
            "title": title,
            "description": description or "Etkinlik detaylarını Dansmagazin uygulamasında görüntüle.",
            "image_url": _share_event_cover_url((row.get("cover_path") or "").strip()),
            "meta_line": " · ".join(meta_parts),
        }
    except Exception as exc:
        logger.warning("share_event_meta_failed submission_id=%s err=%s", int(submission_id), exc)
        return None
    finally:
        if conn is not None:
            conn.close()


def _render_share_landing_page(
    request: Request,
    *,
    route: str,
    page_title: str,
    description: str,
    canonical_url: str,
    image_url: str = "",
    meta_line: str = "",
    action_label: str = "Uygulamada Ac",
):
    app_url = _share_route_deep_link(route)
    fallback_url = APP_DOWNLOAD_URL
    auto_open = _detect_store_target(request.headers.get("user-agent", "")) in {"android", "ios"}
    safe_page_title = html.escape(page_title or "Dansmagazin")
    safe_description = html.escape(description or "Dansmagazin uygulamasinda goruntule.")
    safe_canonical_url = html.escape(canonical_url or APP_DOWNLOAD_URL)
    safe_meta_line = html.escape(meta_line or "")
    safe_app_url = html.escape(app_url)
    safe_fallback_url = html.escape(fallback_url)
    image_meta = ""
    image_card = ""
    if image_url:
        safe_image_url = html.escape(image_url)
        image_meta = (
            f'<meta property="og:image" content="{safe_image_url}" />\n'
            f'    <meta name="twitter:image" content="{safe_image_url}" />'
        )
        image_card = (
            '<div class="hero">'
            f'<img src="{safe_image_url}" alt="{safe_page_title}" />'
            '</div>'
        )

    return HTMLResponse(
        f"""
<!doctype html>
<html lang="tr">
  <head>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1" />
    <title>{safe_page_title}</title>
    <meta name="description" content="{safe_description}" />
    <meta property="og:title" content="{safe_page_title}" />
    <meta property="og:description" content="{safe_description}" />
    <meta property="og:type" content="website" />
    <meta property="og:url" content="{safe_canonical_url}" />
    <meta name="twitter:card" content="summary_large_image" />
    {image_meta}
    <style>
      body {{
        margin: 0;
        min-height: 100vh;
        background: radial-gradient(circle at top, #fff7ed 0%, #ffedd5 36%, #fff 100%);
        color: #111827;
        font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
      }}
      .wrap {{
        min-height: 100vh;
        display: flex;
        align-items: center;
        justify-content: center;
        padding: 24px;
      }}
      .card {{
        width: min(680px, 100%);
        background: rgba(255, 255, 255, 0.96);
        border-radius: 28px;
        box-shadow: 0 24px 70px rgba(15, 23, 42, 0.14);
        padding: 28px;
      }}
      .badge {{
        display: inline-flex;
        align-items: center;
        justify-content: center;
        border-radius: 999px;
        padding: 7px 14px;
        background: #ffedd5;
        color: #c2410c;
        font-size: 13px;
        font-weight: 800;
        letter-spacing: .02em;
      }}
      .hero {{
        margin-top: 18px;
        border-radius: 22px;
        overflow: hidden;
        background: #fff7ed;
        box-shadow: inset 0 0 0 1px rgba(194, 65, 12, 0.08);
      }}
      .hero img {{
        display: block;
        width: 100%;
        height: auto;
        max-height: 420px;
        object-fit: cover;
      }}
      h1 {{
        margin: 20px 0 10px;
        font-size: 34px;
        line-height: 1.08;
      }}
      .meta {{
        margin: 0 0 10px;
        color: #c2410c;
        font-size: 15px;
        font-weight: 700;
      }}
      p {{
        margin: 0;
        color: #4b5563;
        line-height: 1.65;
      }}
      .actions {{
        display: flex;
        flex-wrap: wrap;
        gap: 12px;
        margin-top: 24px;
      }}
      .btn {{
        flex: 1 1 220px;
        min-height: 52px;
        display: inline-flex;
        align-items: center;
        justify-content: center;
        border-radius: 16px;
        text-decoration: none;
        font-weight: 800;
        padding: 0 18px;
      }}
      .btn.primary {{
        background: #111827;
        color: #fff;
      }}
      .btn.secondary {{
        background: #ea580c;
        color: #fff;
      }}
      .hint {{
        margin-top: 16px;
        font-size: 14px;
        color: #6b7280;
      }}
      code {{
        background: #fff7ed;
        color: #9a3412;
        padding: 3px 6px;
        border-radius: 8px;
      }}
    </style>
  </head>
  <body>
    <div class="wrap">
      <div class="card">
        <div class="badge">Dansmagazin</div>
        {image_card}
        <h1>{safe_page_title}</h1>
        {'<div class="meta">' + safe_meta_line + '</div>' if safe_meta_line else ''}
        <p>{safe_description}</p>
        <div class="actions">
          <a class="btn primary" href="{safe_app_url}">{html.escape(action_label)}</a>
          <a class="btn secondary" href="{safe_fallback_url}">Uygulamayi Indir</a>
        </div>
        <p class="hint">
          Uygulama yüklüyse otomatik acilmaya calisir. Acilmazsa buradan devam edebilirsin:
          <code>{safe_canonical_url}</code>
        </p>
      </div>
    </div>
    <script>
      const appUrl = {json.dumps(app_url)};
      const fallbackUrl = {json.dumps(fallback_url)};
      const autoOpen = {json.dumps(auto_open)};
      let pageHidden = false;
      document.addEventListener('visibilitychange', () => {{
        if (document.hidden) {{
          pageHidden = true;
        }}
      }});
      function openApp() {{
        window.location.href = appUrl;
        window.setTimeout(() => {{
          if (!pageHidden) {{
            window.location.href = fallbackUrl;
          }}
        }}, 1600);
      }}
      if (autoOpen) {{
        window.setTimeout(openApp, 180);
      }}
    </script>
  </body>
</html>
"""
    )


@app.on_event("startup")
def on_startup():
    global _birthday_worker_started
    ensure_register_guard_tables()
    init_profile_settings_table()
    init_profile_search_indexes()
    init_event_submission_tables()
    init_news_submission_tables()
    init_news_reaction_table()
    init_photo_reaction_tables()
    init_store_tables()
    init_message_read_state_table()
    init_message_typing_state_table()
    init_message_extra_tables()
    ensure_default_friendships_for_all_users()
    if not _birthday_worker_started:
        t = threading.Thread(target=_birthday_worker, name="birthday-worker", daemon=True)
        t.start()
        _birthday_worker_started = True


@app.get("/health")
def health():
    return {"ok": True}


@app.head("/health")
def health_head():
    return {}


@app.get("/app-download", include_in_schema=False)
def app_download_redirect(request: Request):
    target = _detect_store_target(request.headers.get("user-agent", ""))
    if target == "android":
        return RedirectResponse(ANDROID_STORE_URL, status_code=307)
    if target == "ios":
        return RedirectResponse(IOS_STORE_URL, status_code=307)
    return HTMLResponse(
        f"""
<!doctype html>
<html lang="tr">
  <head>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1" />
    <title>Dansmagazin Uygulamasını İndir</title>
    <style>
      body {{
        margin: 0;
        background: linear-gradient(180deg, #f8fafc 0%, #e2e8f0 100%);
        color: #0f172a;
        font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
      }}
      .wrap {{
        min-height: 100vh;
        display: flex;
        align-items: center;
        justify-content: center;
        padding: 24px;
      }}
      .card {{
        width: min(560px, 100%);
        background: rgba(255, 255, 255, 0.96);
        border-radius: 24px;
        box-shadow: 0 24px 60px rgba(15, 23, 42, 0.12);
        padding: 32px;
      }}
      .badge {{
        display: inline-block;
        padding: 6px 12px;
        border-radius: 999px;
        background: #dbeafe;
        color: #1d4ed8;
        font-size: 13px;
        font-weight: 700;
        letter-spacing: 0.02em;
      }}
      h1 {{
        margin: 16px 0 10px;
        font-size: 32px;
        line-height: 1.1;
      }}
      p {{
        margin: 0;
        color: #475569;
        line-height: 1.6;
      }}
      .actions {{
        display: flex;
        flex-wrap: wrap;
        gap: 12px;
        margin-top: 24px;
      }}
      .btn {{
        flex: 1 1 220px;
        display: inline-flex;
        justify-content: center;
        align-items: center;
        min-height: 52px;
        padding: 0 18px;
        border-radius: 14px;
        text-decoration: none;
        font-weight: 700;
      }}
      .btn.primary {{
        background: #111827;
        color: #fff;
      }}
      .btn.secondary {{
        background: #16a34a;
        color: #fff;
      }}
      .hint {{
        margin-top: 18px;
        font-size: 14px;
      }}
      code {{
        background: #eef2ff;
        padding: 3px 6px;
        border-radius: 8px;
      }}
    </style>
  </head>
  <body>
    <div class="wrap">
      <div class="card">
        <div class="badge">Dansmagazin</div>
        <h1>Uygulamayı İndir</h1>
        <p>
          Telefonunda bu linki açtığında uygun mağazaya otomatik yönlenirsin.
          Masaüstünde görüntülüyorsan aşağıdan mağazanı seçebilirsin.
        </p>
        <div class="actions">
          <a class="btn primary" href="{IOS_STORE_URL}">App Store'da Aç</a>
          <a class="btn secondary" href="{ANDROID_STORE_URL}">Google Play'de Aç</a>
        </div>
        <p class="hint">
          Tek link: <code>{APP_DOWNLOAD_URL}</code>
        </p>
      </div>
    </div>
  </body>
</html>
"""
    )


@app.head("/app-download", include_in_schema=False)
def app_download_redirect_head(request: Request):
    return app_download_redirect(request)


def _normalize_share_route(raw_route: str) -> str:
    route = (raw_route or "").strip()
    if not route.startswith("/"):
        return ""
    if _EVENT_SHARE_ROUTE_RE.match(route):
        return route
    return ""


@app.get("/open", include_in_schema=False)
def open_app_route(request: Request, route: str = ""):
    normalized_route = _normalize_share_route(route)
    if not normalized_route:
        return RedirectResponse(APP_DOWNLOAD_URL, status_code=307)
    submission_match = _EVENT_SHARE_ROUTE_RE.match(normalized_route)
    meta = None
    page_title = "Dansmagazin"
    description = "Icerigi Dansmagazin uygulamasinda goruntule."
    meta_line = ""
    if submission_match:
        submission_id = int(submission_match.group(1))
        meta = _load_event_share_meta(submission_id)
    if meta:
        page_title = meta.get("title") or page_title
        description = meta.get("description") or description
        meta_line = meta.get("meta_line") or ""
    return _render_share_landing_page(
        request,
        route=normalized_route,
        page_title=page_title,
        description=description,
        canonical_url=f"{PUBLIC_API_BASE}/open?route={quote(normalized_route, safe='/')}",
        image_url=(meta or {}).get("image_url", ""),
        meta_line=meta_line,
        action_label="Uygulamada Ac",
    )


@app.head("/open", include_in_schema=False)
def open_app_route_head(request: Request, route: str = ""):
    return open_app_route(request, route)


@app.get("/share/events/{submission_id}", include_in_schema=False)
def share_event_route(request: Request, submission_id: int):
    meta = _load_event_share_meta(int(submission_id)) or {}
    route = f"/events/{int(submission_id)}"
    return _render_share_landing_page(
        request,
        route=route,
        page_title=(meta.get("title") or f"Etkinlik {int(submission_id)}"),
        description=(
            meta.get("description")
            or "Etkinlik detaylarini Dansmagazin uygulamasinda goruntule."
        ),
        canonical_url=f"{PUBLIC_API_BASE}/share/events/{int(submission_id)}",
        image_url=(meta.get("image_url") or ""),
        meta_line=(meta.get("meta_line") or ""),
        action_label="Etkinligi Uygulamada Ac",
    )


@app.head("/share/events/{submission_id}", include_in_schema=False)
def share_event_route_head(request: Request, submission_id: int):
    return share_event_route(request, submission_id)


@app.get("/app-download/qr", include_in_schema=False)
def app_download_qr_preview():
    return HTMLResponse(
        """
<!doctype html>
<html lang="tr">
  <head>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1" />
    <title>Dansmagazin QR Kod</title>
    <style>
      body {
        margin: 0;
        background: linear-gradient(180deg, #fff7ed 0%, #ffedd5 100%);
        color: #111827;
        font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
      }
      .wrap {
        min-height: 100vh;
        display: flex;
        align-items: center;
        justify-content: center;
        padding: 24px;
      }
      .card {
        width: min(560px, 100%);
        background: rgba(255, 255, 255, 0.96);
        border-radius: 28px;
        box-shadow: 0 24px 60px rgba(17, 24, 39, 0.12);
        padding: 28px;
        text-align: center;
      }
      .badge {
        display: inline-block;
        padding: 6px 12px;
        border-radius: 999px;
        background: #ffedd5;
        color: #c2410c;
        font-size: 13px;
        font-weight: 700;
      }
      h1 {
        margin: 14px 0 10px;
        font-size: 32px;
      }
      p {
        margin: 0 auto;
        max-width: 420px;
        color: #4b5563;
        line-height: 1.6;
      }
      img {
        width: min(320px, 100%);
        height: auto;
        margin-top: 22px;
        border-radius: 18px;
        background: #fff;
        padding: 14px;
        box-shadow: inset 0 0 0 1px rgba(17, 24, 39, 0.08);
      }
      .actions {
        margin-top: 22px;
        display: flex;
        flex-wrap: wrap;
        justify-content: center;
        gap: 12px;
      }
      .btn {
        display: inline-flex;
        align-items: center;
        justify-content: center;
        min-height: 50px;
        padding: 0 18px;
        border-radius: 14px;
        text-decoration: none;
        font-weight: 700;
      }
      .btn.dark {
        background: #111827;
        color: #fff;
      }
      .btn.light {
        background: #ea580c;
        color: #fff;
      }
      .hint {
        margin-top: 18px;
        font-size: 14px;
      }
      code {
        background: #fff7ed;
        color: #9a3412;
        padding: 3px 6px;
        border-radius: 8px;
      }
    </style>
  </head>
  <body>
    <div class="wrap">
      <div class="card">
        <div class="badge">Dansmagazin</div>
        <h1>App İndirme QR Kodu</h1>
        <p>
          Bu QR okutulduğunda cihaz tipine göre App Store veya Google Play'e gider.
        </p>
        <img src="/app-download/qr.png" alt="Dansmagazin app download QR code" />
        <div class="actions">
          <a class="btn dark" href="/app-download/qr-download">PNG İndir</a>
          <a class="btn light" href="/app-download">İndirme Linkini Aç</a>
        </div>
        <p class="hint">
          Tek link: <code>https://api2.dansmagazin.net/app-download</code>
        </p>
      </div>
    </div>
  </body>
</html>
"""
    )


@app.head("/app-download/qr", include_in_schema=False)
def app_download_qr_preview_head():
    return app_download_qr_preview()


@app.get("/app-download/qr.png", include_in_schema=False)
def app_download_qr():
    if not APP_DOWNLOAD_QR_PATH.exists():
        return HTMLResponse("QR dosyasi henuz uretilmedi.", status_code=404)
    return FileResponse(
        APP_DOWNLOAD_QR_PATH,
        media_type="image/png",
        filename="dansmagazin-app-qr.png",
        content_disposition_type="inline",
    )


@app.head("/app-download/qr.png", include_in_schema=False)
def app_download_qr_head():
    return app_download_qr()


@app.get("/app-download/qr-download", include_in_schema=False)
def app_download_qr_download():
    if not APP_DOWNLOAD_QR_PATH.exists():
        return HTMLResponse("QR dosyasi henuz uretilmedi.", status_code=404)
    return FileResponse(
        APP_DOWNLOAD_QR_PATH,
        media_type="image/png",
        filename="dansmagazin-app-qr.png",
        content_disposition_type="attachment",
    )


@app.head("/app-download/qr-download", include_in_schema=False)
def app_download_qr_download_head():
    return app_download_qr_download()


@app.get("/account-deletion", response_class=HTMLResponse, include_in_schema=False)
def account_deletion_info():
    return """
<!doctype html>
<html lang="tr">
  <head>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1" />
    <title>Dansmagazin Hesap Silme</title>
    <style>
      body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; line-height: 1.6; margin: 0; background: #f6f7fb; color: #171717; }
      .wrap { max-width: 820px; margin: 0 auto; padding: 40px 20px 72px; }
      .card { background: #fff; border-radius: 18px; padding: 28px; box-shadow: 0 10px 30px rgba(0,0,0,.06); }
      h1, h2 { margin-top: 0; }
      ul, ol { padding-left: 20px; }
      .muted { color: #5f6470; }
      .badge { display: inline-block; padding: 6px 10px; border-radius: 999px; background: #eef2ff; color: #2a4bdb; font-weight: 600; font-size: 14px; }
      code { background: #f3f4f6; padding: 2px 6px; border-radius: 6px; }
    </style>
  </head>
  <body>
    <div class="wrap">
      <div class="card">
        <div class="badge">Dansmagazin</div>
        <h1>Hesap silme ve veri kaldırma</h1>
        <p class="muted">
          Bu sayfa, Google Play gereklilikleri kapsamında Dansmagazin uygulamasındaki hesap silme akışını açıklar.
        </p>

        <h2>Hesabınızı uygulama içinden nasıl silebilirsiniz?</h2>
        <ol>
          <li>Dansmagazin uygulamasında hesabınıza giriş yapın.</li>
          <li><strong>Profil &gt; Ayarlar</strong> ekranını açın.</li>
          <li><strong>Hesabımı Sil</strong> seçeneğine dokunun.</li>
          <li>Onay verdiğinizde hesabınız pasife alınır ve cihazdaki oturumunuz kapatılır.</li>
        </ol>

        <h2>Silinen veriler</h2>
        <ul>
          <li>Aktif oturumlar sonlandırılır.</li>
          <li>Push bildirim kayıtları pasif hale getirilir.</li>
          <li>Hesap e-posta adresi ve görünen ad, silinmiş hesap statüsüne alınır.</li>
        </ul>

        <h2>Saklanabilecek veriler</h2>
        <ul>
          <li>Yasal yükümlülükler, güvenlik kayıtları ve finansal/işlemsel zorunluluklar nedeniyle bazı kayıtlar sınırlı süreyle saklanabilir.</li>
          <li>Uygulama içi geçmiş kayıtlar, teknik ve idari gereklilikler doğrultusunda sistem loglarında sınırlı süre tutulabilir.</li>
        </ul>

        <h2>Destek</h2>
        <p>
          Hesap silme konusunda ek destek için: <a href="mailto:ustundag@boyutmedya.com">ustundag@boyutmedya.com</a>
        </p>
      </div>
    </div>
  </body>
</html>
"""


@app.get("/child-safety", response_class=HTMLResponse, include_in_schema=False)
def child_safety_info():
    return """
<!doctype html>
<html lang="tr">
  <head>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1" />
    <title>Dansmagazin Çocuk Güvenliği Standartları</title>
    <style>
      body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; line-height: 1.6; margin: 0; background: #f6f7fb; color: #171717; }
      .wrap { max-width: 860px; margin: 0 auto; padding: 40px 20px 72px; }
      .card { background: #fff; border-radius: 18px; padding: 28px; box-shadow: 0 10px 30px rgba(0,0,0,.06); }
      h1, h2 { margin-top: 0; }
      ul, ol { padding-left: 20px; }
      .muted { color: #5f6470; }
      .badge { display: inline-block; padding: 6px 10px; border-radius: 999px; background: #eef2ff; color: #2a4bdb; font-weight: 600; font-size: 14px; }
      a { color: #2349d7; }
    </style>
  </head>
  <body>
    <div class="wrap">
      <div class="card">
        <div class="badge">Dansmagazin</div>
        <h1>Çocuk Güvenliği Standartları</h1>
        <p class="muted">
          Dansmagazin, çocukların cinsel istismarı ve çocuk istismarına yönelik her türlü içeriğe, teşvike ve suistimale sıfır tolerans uygular.
        </p>

        <h2>Standartlarımız</h2>
        <ul>
          <li>Çocukların cinsel istismarı niteliğindeki materyallerin (CSAM) paylaşımı, talebi, dağıtımı veya teşviki yasaktır.</li>
          <li>Çocukların cinsel sömürüsünü kolaylaştıran, normalleştiren veya teşvik eden davranışlara izin verilmez.</li>
          <li>Reşit olmayanlara yönelik cinsel içerikli iletişim, yönlendirme veya uygunsuz temas girişimleri yasaktır.</li>
          <li>Kullanıcılar, uygulama içindeki destek/iletişim kanalları üzerinden güvenlik endişelerini bildirebilir.</li>
          <li>Gerekli durumlarda ilgili yasal yükümlülükler doğrultusunda yetkili kurumlarla iş birliği yapılır.</li>
        </ul>

        <h2>Nasıl bildirilir?</h2>
        <ol>
          <li>Dansmagazin uygulamasında hesabınıza giriş yapın.</li>
          <li><strong>Profil &gt; Ayarlar &gt; Destek</strong> yolunu açın.</li>
          <li>Destek hesabına mesaj göndererek çocuk güvenliğiyle ilgili endişenizi iletin.</li>
        </ol>

        <h2>İletişim</h2>
        <p>
          Çocuk güvenliği politikaları ve uygunluk süreçleri için ilgili kişi: <a href="mailto:ism.ustundag@gmail.com">ism.ustundag@gmail.com</a>
        </p>
      </div>
    </div>
  </body>
</html>
"""


@app.get("/menu", response_model=MobileMenuResponse, tags=["Menu"], summary="Mobil alt menü")
def mobile_menu():
    return {
        "items": [
            {"key": "discover", "title": "Haberler", "icon": "newspaper", "route": "/discover"},
            {"key": "events", "title": "Etkinlikler", "icon": "calendar", "route": "/events"},
            {"key": "photos", "title": "Fotoğraflar", "icon": "image", "route": "/photos"},
            {"key": "messages", "title": "Mesajlar", "icon": "message-circle", "route": "/messages", "badge": 0},
            {"key": "profile", "title": "Profil", "icon": "user", "route": "/profile"},
        ]
    }


app.include_router(auth_router)
app.include_router(discover_router)
app.include_router(events_router)
app.include_router(admin_events_router)
app.include_router(news_router)
app.include_router(admin_news_router)
app.include_router(photos_router)
app.include_router(store_router)
app.include_router(messages_router)
app.include_router(profile_router)
