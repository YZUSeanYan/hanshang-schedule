"""App 版本表（对应设计文档 5.2 app_versions，另补 sha256 校验字段）。"""
from datetime import datetime

from sqlalchemy import Boolean, DateTime, Integer, String, Text, func
from sqlalchemy.orm import Mapped, mapped_column

from app.db.base import Base


class AppVersion(Base):
    __tablename__ = "app_versions"

    id: Mapped[int] = mapped_column(primary_key=True)
    version_name: Mapped[str] = mapped_column(String(32), comment="如 1.0.0")
    version_code: Mapped[int] = mapped_column(Integer, unique=True, comment="递增整数版本号")
    apk_url: Mapped[str] = mapped_column(String(512), comment="APK 直链（Nginx 静态托管）")
    sha256: Mapped[str] = mapped_column(String(64), default="", comment="APK 文件 SHA-256，用于下载后校验")
    release_notes: Mapped[str] = mapped_column(Text, default="", comment="更新说明")
    is_force_update: Mapped[bool] = mapped_column(Boolean, default=False, comment="是否强制更新")
    force_codes: Mapped[str] = mapped_column(
        String(128), default="", comment="仅对这些 versionCode 强制更新（逗号分隔，如 30,31）；is_force_update 为 true 时全量强制"
    )
    published_at: Mapped[datetime] = mapped_column(DateTime, server_default=func.now())
