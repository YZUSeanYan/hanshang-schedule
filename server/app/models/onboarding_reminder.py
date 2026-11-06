"""新人导入提醒的发送记录：每个阶段对同一用户只发一次。"""
from datetime import datetime

from sqlalchemy import DateTime, ForeignKey, Index, Integer, String, func
from sqlalchemy.orm import Mapped, mapped_column

from app.db.base import Base


class OnboardingReminder(Base):
    __tablename__ = "onboarding_reminders"

    id: Mapped[int] = mapped_column(primary_key=True)
    user_id: Mapped[int] = mapped_column(
        ForeignKey("users.id", ondelete="CASCADE"), index=True
    )
    stage: Mapped[str] = mapped_column(String(16), comment="阶段标识：2h/12h/2d/5d/7d")
    notification_id: Mapped[int] = mapped_column(Integer, comment="关联的收件箱通知 id")
    sent_at: Mapped[datetime] = mapped_column(DateTime, server_default=func.now())

    __table_args__ = (
        Index("ix_onboarding_reminder_user_stage", "user_id", "stage", unique=True),
    )
