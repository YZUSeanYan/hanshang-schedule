"""设备配对码表（手表端免输账号密码登录，6 位数字码换令牌）。"""
from datetime import datetime, timezone

from sqlalchemy import Boolean, DateTime, Integer, String
from sqlalchemy.orm import Mapped, mapped_column

from app.db.base import Base


class DevicePairCode(Base):
    __tablename__ = "device_pair_codes"

    id: Mapped[int] = mapped_column(primary_key=True)
    user_id: Mapped[int] = mapped_column(Integer, index=True, comment="归属账号")
    code: Mapped[str] = mapped_column(String(8), comment="6 位数字配对码（HMAC 摘要）")
    expires_at: Mapped[datetime] = mapped_column(DateTime, comment="过期时间（UTC）")
    used: Mapped[bool] = mapped_column(Boolean, default=False, comment="是否已领取")
    device_name: Mapped[str] = mapped_column(String(64), default="", comment="领取时上报的设备名")
    created_at: Mapped[datetime] = mapped_column(
        DateTime, default=lambda: datetime.now(timezone.utc).replace(tzinfo=None)
    )
