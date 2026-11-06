"""系统端点：健康检查。"""
from fastapi import APIRouter

router = APIRouter(tags=["系统"])


@router.get("/health", summary="健康检查")
def health() -> dict:
    """供部署探活与监控使用，无需鉴权。"""
    return {"code": 0, "message": "ok", "data": {"status": "up"}}
