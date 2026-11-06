"""用户表模型（对应设计文档 5.2 users）。"""
from datetime import datetime

from sqlalchemy import DateTime, String, func
from sqlalchemy.orm import Mapped, mapped_column

from app.db.base import Base


class User(Base):
    __tablename__ = "users"

    id: Mapped[int] = mapped_column(primary_key=True, index=True)
    username: Mapped[str] = mapped_column(String(32), unique=True, index=True, comment="用户名")
    email: Mapped[str] = mapped_column(String(255), unique=True, index=True, comment="邮箱")
    password_hash: Mapped[str] = mapped_column(String(255), comment="bcrypt 密码哈希")
    created_at: Mapped[datetime] = mapped_column(
        DateTime, server_default=func.now(), comment="注册时间"
    )
    avatar_media: Mapped[str] = mapped_column(
        String(64), default="", comment="头像文件名（uploads/avatars/ 下），空=首字母默认头像"
    )
