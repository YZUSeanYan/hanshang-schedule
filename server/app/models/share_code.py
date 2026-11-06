"""One-time schedule-sharing codes.

The payload is a deliberately minimal timetable snapshot.  It never contains
the owner's account fields, authentication data, or education-system
credentials.
"""
from datetime import datetime, timezone

from sqlalchemy import Boolean, DateTime, ForeignKey, Index, Integer, String, Text
from sqlalchemy.orm import Mapped, mapped_column

from app.db.base import Base


class ShareCode(Base):
    __tablename__ = "share_codes"

    id: Mapped[int] = mapped_column(primary_key=True)
    code: Mapped[str] = mapped_column(String(6), unique=True, index=True)
    owner_user_id: Mapped[int] = mapped_column(ForeignKey("users.id"), index=True)
    semester_uuid: Mapped[str] = mapped_column(String(64))
    payload: Mapped[str] = mapped_column(Text)
    created_at: Mapped[datetime] = mapped_column(
        DateTime, default=lambda: datetime.now(timezone.utc).replace(tzinfo=None)
    )
    expires_at: Mapped[datetime] = mapped_column(DateTime, index=True)
    is_revoked: Mapped[bool] = mapped_column(Boolean, default=False)
    use_count: Mapped[int] = mapped_column(Integer, default=0)

    __table_args__ = (
        Index("ix_share_codes_owner_created", "owner_user_id", "created_at"),
    )
