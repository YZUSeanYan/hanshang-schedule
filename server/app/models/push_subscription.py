"""Per-device Web Push subscription; contains no app or education password."""
from datetime import datetime

from sqlalchemy import DateTime, ForeignKey, Index, Integer, String, Text, func
from sqlalchemy.orm import Mapped, mapped_column

from app.db.base import Base


class PushSubscription(Base):
    __tablename__ = "push_subscriptions"

    id: Mapped[int] = mapped_column(primary_key=True)
    user_id: Mapped[int] = mapped_column(
        ForeignKey("users.id", ondelete="CASCADE"), index=True
    )
    endpoint: Mapped[str] = mapped_column(Text, unique=True)
    section_times: Mapped[str] = mapped_column(Text, default="[]", server_default="[]")
    p256dh: Mapped[str] = mapped_column(String(256))
    auth: Mapped[str] = mapped_column(String(128))
    created_at: Mapped[datetime] = mapped_column(DateTime, server_default=func.now())
    last_success_at: Mapped[datetime | None] = mapped_column(DateTime, nullable=True)


class PushDelivery(Base):
    """Idempotency record for a specific class reminder on one device."""

    __tablename__ = "push_deliveries"

    id: Mapped[int] = mapped_column(primary_key=True)
    subscription_id: Mapped[int] = mapped_column(ForeignKey("push_subscriptions.id", ondelete="CASCADE"))
    schedule_uuid: Mapped[str] = mapped_column(String(64))
    class_date: Mapped[str] = mapped_column(String(10))
    reminder_minutes: Mapped[int] = mapped_column(Integer)
    sent_at: Mapped[datetime] = mapped_column(DateTime, server_default=func.now())

    __table_args__ = (
        Index(
            "ix_push_delivery_once",
            "subscription_id",
            "schedule_uuid",
            "class_date",
            "reminder_minutes",
            unique=True,
        ),
    )
