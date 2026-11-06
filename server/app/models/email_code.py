"""邮箱验证码表（忘记密码等场景使用）。"""
from datetime import datetime, timezone

from sqlalchemy import Boolean, DateTime, String
from sqlalchemy.orm import Mapped, mapped_column

from app.db.base import Base


class EmailCode(Base):
    __tablename__ = "email_codes"

    id: Mapped[int] = mapped_column(primary_key=True)
    email: Mapped[str] = mapped_column(String(255), index=True)
    code: Mapped[str] = mapped_column(String(8), comment="6 位数字验证码")
    purpose: Mapped[str] = mapped_column(String(32), default="reset_password", comment="用途标记")
    expires_at: Mapped[datetime] = mapped_column(DateTime, comment="过期时间（UTC）")
    used: Mapped[bool] = mapped_column(Boolean, default=False, comment="是否已使用")
    created_at: Mapped[datetime] = mapped_column(
        DateTime, default=lambda: datetime.now(timezone.utc).replace(tzinfo=None)
    )
