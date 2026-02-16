from fastapi import APIRouter

router = APIRouter(prefix="/events", tags=["Etkinlikler"])


@router.get("", summary="Etkinlik listesi")
def list_events():
    return {
        "section": "etkinlikler",
        "items": [],
        "message": "Etkinlik listesi burada dönecek.",
    }
