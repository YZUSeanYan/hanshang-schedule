"""Editable public content shown on the App's About page."""
from datetime import datetime

from sqlalchemy import DateTime, Integer, String, Text, func
from sqlalchemy.orm import Mapped, mapped_column

from app.db.base import Base


class AboutContent(Base):
    __tablename__ = "about_content"

    id: Mapped[int] = mapped_column(Integer, primary_key=True, default=1)
    display_name: Mapped[str] = mapped_column(String(80), default="邗上课表")
    icp_beian: Mapped[str] = mapped_column(String(64), default="", comment="工信部备案号")
    intro: Mapped[str] = mapped_column(Text, default="")
    website_url: Mapped[str] = mapped_column(String(500), default="")
    avatar_media: Mapped[str] = mapped_column(String(80), default="")
    payment_qr_media: Mapped[str] = mapped_column(String(80), default="")
    updated_at: Mapped[datetime] = mapped_column(
        DateTime, server_default=func.now(), onupdate=func.now()
    )
