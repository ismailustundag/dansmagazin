from fastapi import FastAPI

from app.schemas import MobileMenuResponse
from app.routers.discover import router as discover_router
from app.routers.events import (
    admin_router as admin_events_router,
    init_event_submission_tables,
    router as events_router,
)
from app.routers.photos import router as photos_router
from app.routers.messages import router as messages_router
from app.routers.profile import router as profile_router

app = FastAPI(title="Mobil Backend")


@app.on_event("startup")
def on_startup():
    init_event_submission_tables()


@app.get("/health")
def health():
    return {"ok": True}


@app.get("/menu", response_model=MobileMenuResponse, tags=["Menu"], summary="Mobil alt menü")
def mobile_menu():
    return {
        "items": [
            {"key": "discover", "title": "Keşfet", "icon": "compass", "route": "/discover"},
            {"key": "events", "title": "Etkinlikler", "icon": "calendar", "route": "/events"},
            {"key": "photos", "title": "Fotoğraflar", "icon": "image", "route": "/photos"},
            {"key": "messages", "title": "Mesajlar", "icon": "message-circle", "route": "/messages", "badge": 0},
            {"key": "profile", "title": "Profil", "icon": "user", "route": "/profile"},
        ]
    }


app.include_router(discover_router)
app.include_router(events_router)
app.include_router(admin_events_router)
app.include_router(photos_router)
app.include_router(messages_router)
app.include_router(profile_router)
