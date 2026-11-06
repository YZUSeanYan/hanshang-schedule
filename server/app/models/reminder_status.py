"""提醒链路客户端状态：App 每次重排本地提醒后按设备上报最近一次快照。

指标 4 的数据源：通知权限、精确闹钟授权、本地排程条数与最近排程时间。
(user_id, device_id) 唯一，重复上报覆盖旧值。
"""
from datetime import datetime

from sqlalchemy import Boolean, DateTime, ForeignKey, Integer, String, UniqueConstraint, func
from sqlalchemy.orm import Mapped, mapped_column

from app.db.base import Base


class ReminderStatus(Base):
    __tablename__ = "reminder_status"

    id: Mapped[int] = mapped_column(primary_key=True)
    user_id: Mapped[int] = mapped_column(
        ForeignKey("users.id", ondelete="CASCADE"), index=True
    )
    device_id: Mapped[str] = mapped_column(String(192))
    platform: Mapped[str] = mapped_column(String(24), default="android")
    notif_permission: Mapped[bool] = mapped_column(Boolean, default=False)
    exact_alarm: Mapped[bool | None] = mapped_column(Boolean, nullable=True)
    scheduled_count: Mapped[int] = mapped_column(Integer, default=0)
    last_schedule_at: Mapped[datetime | None] = mapped_column(DateTime, nullable=True)
    updated_at: Mapped[datetime] = mapped_column(
        DateTime, server_default=func.now(), onupdate=func.now()
    )

    __table_args__ = (
        UniqueConstraint("user_id", "device_id", name="uq_reminder_status_user_device"),
    )
