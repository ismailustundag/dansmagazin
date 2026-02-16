from fastapi import APIRouter

router = APIRouter(prefix="/profile", tags=["Profil"])


@router.get("", summary="Profil özeti")
def profile_summary():
    return {
        "section": "profil",
        "name": None,
        "email": None,
        "message": "Profil bilgileri burada dönecek.",
    }
