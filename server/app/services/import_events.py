"""导入漏斗事件写入：客户端上报端点与服务端顺带埋点共用。

埋点是观测性旁路：任何写入失败（含脏枚举）都只回滚、静默返回，
绝不影响主流程响应。隐私红线见 models/import_event.py 模块注释。
"""
from sqlalchemy.orm import Session

from app.models.import_event import ENTRY_STAGES, OUTCOMES, SOURCES, ImportEvent


def record_import_event(
    db: Session,
    *,
    user_id: int,
    entry: str,
    stage: str,
    outcome: str,
    error_code: str = "",
    detail: str = "",
    source: str = "client",
    client_version: str = "",
) -> None:
    try:
        if stage not in ENTRY_STAGES.get(entry, ()):
            return
        if outcome not in OUTCOMES or source not in SOURCES:
            return
        db.add(ImportEvent(
            user_id=user_id,
            entry=entry[:16],
            stage=stage[:16],
            outcome=outcome[:8],
            error_code=error_code[:16],
            detail=detail[:200],
            source=source[:8],
            client_version=client_version[:16],
        ))
        db.commit()
    except Exception:
        db.rollback()
