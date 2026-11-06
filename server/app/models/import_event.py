"""导入漏斗事件表：指标 1（首次导入成功率）与指标 2（各入口失败率）共用数据源。

隐私红线（与隐私政策一致）：只记枚举、错误码与文件类型/大小档/耗时档等
元数据；禁止记录文件名、课表内容、日程标题、学号、姓名、邀请码原文。
"""
from datetime import datetime

from sqlalchemy import DateTime, ForeignKey, Index, String, func
from sqlalchemy.orm import Mapped, mapped_column

from app.db.base import Base

# 入口与阶段枚举（端点校验与埋点共用的唯一事实来源）
ENTRY_STAGES: dict[str, tuple[str, ...]] = {
    "screenshot": ("pick", "upload", "parse", "preview", "save"),
    "excel": ("pick", "upload", "parse", "preview", "save"),
    "school": ("webview", "login", "sniff", "parse", "preview", "save"),
    "sharecode": ("input", "preview", "apply"),
    "manual": ("edit", "save"),
}
OUTCOMES = ("success", "fail", "abandon")
SOURCES = ("client", "server")


class ImportEvent(Base):
    __tablename__ = "import_events"

    id: Mapped[int] = mapped_column(primary_key=True)
    user_id: Mapped[int] = mapped_column(
        ForeignKey("users.id", ondelete="CASCADE"), index=True
    )
    entry: Mapped[str] = mapped_column(String(16))
    stage: Mapped[str] = mapped_column(String(16))
    outcome: Mapped[str] = mapped_column(String(8))
    error_code: Mapped[str] = mapped_column(String(16), default="")
    detail: Mapped[str] = mapped_column(String(200), default="")
    source: Mapped[str] = mapped_column(String(8), default="client")
    client_version: Mapped[str] = mapped_column(String(16), default="")
    created_at: Mapped[datetime] = mapped_column(
        DateTime, server_default=func.now(), index=True
    )

    __table_args__ = (
        Index("ix_import_events_user_created", "user_id", "created_at"),
        Index("ix_import_events_entry_outcome_created", "entry", "outcome", "created_at"),
    )
