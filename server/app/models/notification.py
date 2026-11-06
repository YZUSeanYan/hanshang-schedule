"""Persistent account notifications and provider delivery status."""
from datetime import datetime

from sqlalchemy import DateTime, ForeignKey, Index, String, Text, func
from sqlalchemy.orm import Mapped, mapped_column

from app.db.base import Base


class UserNotification(Base):
    __tablename__ = "user_notifications"

    id: Mapped[int] = mapped_column(primary_key=True)
    user_id: Mapped[int] = mapped_column(
        ForeignKey("users.id", ondelete="CASCADE"), index=True
    )
    title: Mapped[str] = mapped_column(String(64))
    body: Mapped[str] = mapped_column(Text)
    data_json: Mapped[str] = mapped_column(Text, default="{}")
    provider: Mapped[str] = mapped_column(String(24), default="aliyun")
    delivery_status: Mapped[str] = mapped_column(String(24), default="pending", index=True)
    provider_message_id: Mapped[str] = mapped_column(String(128), default="")
    delivery_error: Mapped[str] = mapped_column(String(500), default="")
    target_type: Mapped[str] = mapped_column(String(16), default="ACCOUNT")
    target_device_id: Mapped[str | None] = mapped_column(String(192), nullable=True)
    target_label: Mapped[str] = mapped_column(String(160), default="全部设备")
    created_at: Mapped[datetime] = mapped_column(
        DateTime, server_default=func.now(), index=True
    )
    read_at: Mapped[datetime | None] = mapped_column(DateTime, nullable=True)

    __table_args__ = (
        Index("ix_user_notification_user_created", "user_id", "created_at"),
    )


class UserPushDevice(Base):
    __tablename__ = "user_push_devices"

    id: Mapped[int] = mapped_column(primary_key=True)
    user_id: Mapped[int] = mapped_column(
        ForeignKey("users.id", ondelete="CASCADE"), index=True
    )
    device_id: Mapped[str] = mapped_column(String(192), unique=True, index=True)
    label: Mapped[str] = mapped_column(String(160), default="Android 设备")
    platform: Mapped[str] = mapped_column(String(24), default="android")
    app_version: Mapped[str] = mapped_column(String(32), default="")
    created_at: Mapped[datetime] = mapped_column(DateTime, server_default=func.now())
    last_seen_at: Mapped[datetime] = mapped_column(
        DateTime, server_default=func.now(), index=True
    )

    __table_args__ = (
        Index("ix_user_push_device_user_seen", "user_id", "last_seen_at"),
    )
