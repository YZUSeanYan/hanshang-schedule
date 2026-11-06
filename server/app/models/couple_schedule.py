"""Consent records for the couple timetable feature."""
from datetime import datetime

from sqlalchemy import DateTime, ForeignKey, Index, String
from sqlalchemy.orm import Mapped, mapped_column

from app.db.base import Base


class CoupleConnection(Base):
    __tablename__ = "couple_connections"

    id: Mapped[int] = mapped_column(primary_key=True)
    inviter_user_id: Mapped[int] = mapped_column(
        ForeignKey("users.id", ondelete="CASCADE"), index=True
    )
    partner_user_id: Mapped[int | None] = mapped_column(
        ForeignKey("users.id", ondelete="CASCADE"), nullable=True, index=True
    )
    invite_hash: Mapped[str] = mapped_column(String(64), unique=True)
    invite_expires_at: Mapped[datetime] = mapped_column(DateTime)
    accepted_at: Mapped[datetime | None] = mapped_column(DateTime, nullable=True)
    revoked_at: Mapped[datetime | None] = mapped_column(DateTime, nullable=True)
    created_at: Mapped[datetime] = mapped_column(DateTime)

    __table_args__ = (
        Index("ix_couple_inviter_active", "inviter_user_id", "revoked_at"),
        Index("ix_couple_partner_active", "partner_user_id", "revoked_at"),
    )


class CoupleMembership(Base):
    """One row per active participant; user_id uniqueness closes claim races."""
    __tablename__ = "couple_memberships"

    user_id: Mapped[int] = mapped_column(
        ForeignKey("users.id", ondelete="CASCADE"), primary_key=True
    )
    connection_id: Mapped[int] = mapped_column(
        ForeignKey("couple_connections.id", ondelete="CASCADE"), index=True
    )
    created_at: Mapped[datetime] = mapped_column(DateTime)
