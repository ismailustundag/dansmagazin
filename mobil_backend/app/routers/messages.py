from fastapi import APIRouter

router = APIRouter(prefix="/messages", tags=["Mesajlar"])


@router.get("", summary="Mesaj kutusu")
def list_messages():
    return {
        "section": "mesajlar",
        "items": [],
        "unread_count": 0,
        "message": "Mesajlar burada dönecek.",
    }
