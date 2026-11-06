from fastapi import APIRouter, Depends, HTTPException
from fastapi.responses import FileResponse
from sqlalchemy import select
from sqlalchemy.orm import Session

from app.db.session import get_db
from app.models.about_content import AboutContent
from app.services.about_media import media_path

router = APIRouter(prefix="/about", tags=["about"])


def serialize_about(row: AboutContent | None) -> dict:
    return {
        "display_name": row.display_name if row else "邗上课表",
        "icp_beian": row.icp_beian if row else "",
        "intro": row.intro if row else "",
        "website_url": row.website_url if row else "",
        "avatar_media": row.avatar_media if row else "",
        "payment_qr_media": row.payment_qr_media if row else "",
        "updated_at": row.updated_at.isoformat() if row and row.updated_at else None,
    }


@router.get("")
def get_about(db: Session = Depends(get_db)) -> dict:
    return {
        "code": 0,
        "message": "ok",
        "data": serialize_about(db.scalar(select(AboutContent).where(AboutContent.id == 1))),
    }


@router.get("/media/{name}")
def get_about_media(name: str):
    path = media_path(name)
    if not path.is_file():
        raise HTTPException(status_code=404, detail={"code": 40420, "message": "图片不存在"})
    return FileResponse(
        path,
        headers={
            "Cache-Control": "public, max-age=86400, immutable",
            "X-Content-Type-Options": "nosniff",
        },
    )
