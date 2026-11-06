"""用户端点。"""
from fastapi import APIRouter, Depends, File, HTTPException, UploadFile
from fastapi.responses import FileResponse
from sqlalchemy import select
from sqlalchemy.orm import Session

from app.api.deps import get_current_user
from app.core.ratelimit import RateLimiter
from app.db.session import get_db
from app.models.user import User
from app.schemas.user import ProfileUpdateIn, UserOut
from app.services.about_media import detect_extension, media_path, persist_media

router = APIRouter(prefix="/user", tags=["用户"])

# 资料修改属低频敏感操作：改名 10 次/天，头像 10 次/天（防刷与滥用）
_profile_limiter = RateLimiter(10, 24 * 60 * 60)
_avatar_limiter = RateLimiter(10, 24 * 60 * 60)

# 头像限制 2MB：头像只在个人页小圆图展示，无需更大
_MAX_AVATAR_BYTES = 2 * 1024 * 1024


@router.get("/profile", summary="获取个人信息（需登录）")
def profile(user: User = Depends(get_current_user)) -> dict:
    return {"code": 0, "message": "ok", "data": UserOut.model_validate(user).model_dump(mode="json")}


@router.patch("/profile", summary="修改用户名（昵称）")
def update_profile(
    data: ProfileUpdateIn,
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> dict:
    if not _profile_limiter.allow(f"profile:user:{user.id}"):
        raise HTTPException(
            status_code=429, detail={"code": 42960, "message": "资料修改过于频繁，请明天再试"}
        )
    username = data.username.strip()
    if username != user.username:
        conflict = db.scalar(select(User).where(User.username == username))
        if conflict is not None:
            raise HTTPException(
                status_code=409, detail={"code": 40960, "message": "该用户名已被占用"}
            )
        user.username = username
        db.commit()
    return {"code": 0, "message": "ok", "data": UserOut.model_validate(user).model_dump(mode="json")}


@router.post("/avatar", summary="上传头像（PNG/JPEG/WebP，≤2MB）")
async def upload_avatar(
    file: UploadFile = File(...),
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> dict:
    if not _avatar_limiter.allow(f"avatar:user:{user.id}"):
        raise HTTPException(
            status_code=429, detail={"code": 42961, "message": "头像更换过于频繁，请明天再试"}
        )
    raw = await file.read(_MAX_AVATAR_BYTES + 1)
    await file.close()
    if not raw:
        raise HTTPException(status_code=400, detail={"code": 40060, "message": "请选择图片"})
    if len(raw) > _MAX_AVATAR_BYTES:
        raise HTTPException(status_code=413, detail={"code": 41360, "message": "头像不能超过 2 MB"})
    # 只认真实图片魔数（PNG/JPEG/WebP），伪装文件在 detect_extension 处 415
    extension = detect_extension(raw)
    name = persist_media(raw, extension, subdir="avatars")
    old = user.avatar_media
    user.avatar_media = name
    db.commit()
    # 旧头像即时清理（已无引用）；失败不影响主流程
    if old:
        try:
            media_path(old, "avatars").unlink(missing_ok=True)
        except Exception:
            pass
    return {"code": 0, "message": "ok", "data": {"avatar_media": name}}


@router.get("/avatar/{name}", summary="头像图片（公开读取，随机名不可枚举）")
def get_avatar(name: str):
    path = media_path(name, "avatars")
    if not path.is_file():
        raise HTTPException(status_code=404, detail={"code": 40420, "message": "图片不存在"})
    return FileResponse(
        path,
        headers={
            "Cache-Control": "public, max-age=86400",
            "X-Content-Type-Options": "nosniff",
        },
    )
