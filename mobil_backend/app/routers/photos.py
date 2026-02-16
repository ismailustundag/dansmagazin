from fastapi import APIRouter

router = APIRouter(prefix="/photos", tags=["Fotoğraflar"])


@router.get("", summary="Fotoğraf akışı")
def list_photos():
    return {
        "section": "fotograflar",
        "items": [],
        "message": "Fotoğraf akışı burada dönecek.",
    }
