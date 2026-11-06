"""客户端埋点上报：导入漏斗事件（指标 1/2）。

只记枚举、错误码与元数据；隐私红线见 models/import_event.py。
"""
from fastapi import APIRouter, Depends, HTTPException, Request
from sqlalchemy.orm import Session

from app.api.deps import get_current_user
from app.core.ratelimit import RateLimiter
from app.db.session import get_db
from app.models.user import User
from app.schemas.telemetry import ImportEventIn
from app.services.import_events import record_import_event

router = APIRouter(prefix="/telemetry", tags=["埋点上报"])

# 按用户限流：正常一次导入全流程只有几条事件，60 次/天绰绰有余
_import_event_limiter = RateLimiter(60, 24 * 60 * 60)
_MAX_BODY_BYTES = 2048


@router.post("/import-event", response_model=None)
def report_import_event(
    data: ImportEventIn,
    request: Request,
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> dict:
    content_length = request.headers.get("content-length")
    if content_length and content_length.isdigit() and int(content_length) > _MAX_BODY_BYTES:
        raise HTTPException(
            status_code=413, detail={"code": 41330, "message": "上报内容过大"}
        )
    if not _import_event_limiter.allow(f"import-event:user:{user.id}"):
        raise HTTPException(
            status_code=429, detail={"code": 42940, "message": "上报过于频繁"}
        )
    record_import_event(
        db,
        user_id=user.id,
        entry=data.entry,
        stage=data.stage,
        outcome=data.outcome,
        error_code=data.error_code,
        detail=data.detail,
        source="client",
        client_version=data.client_version,
    )
    return {"code": 0, "message": "ok", "data": {"recorded": True}}
