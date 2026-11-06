"""客户端版本登记：每个账号最近一次上报的 versionCode。

用途：给「更新提醒」提供定向依据——**只提醒版本落后的用户**，不骚扰已经
升级的人。数据来源是 `/api/version/latest` 的 `current_code`（每个客户端
冷启动都会调一次），比 `user_push_devices.app_version`（仅推送注册那一刻
写入）更准、覆盖也更大，包括拒绝了通知权限的用户。

隐私：只存整数版本号与时间，不含设备标识或任何用户内容。

背景（2026-09-22）：更新提示条这类「写在 App 里」的提醒，只有已经装了新版
的用户才看得到，而那些人恰恰不需要被提醒；真正卡在老版本的用户永远收不到。
所以提醒必须走服务端可触达的通道（推送/收件箱），并以这张表判断谁落后。
"""
from datetime import datetime

from sqlalchemy import DateTime, ForeignKey, Integer, UniqueConstraint, func
from sqlalchemy.orm import Mapped, mapped_column

from app.db.base import Base


class ClientVersion(Base):
    __tablename__ = "client_versions"

    id: Mapped[int] = mapped_column(primary_key=True)
    user_id: Mapped[int] = mapped_column(
        ForeignKey("users.id", ondelete="CASCADE"), index=True
    )
    current_code: Mapped[int] = mapped_column(Integer, index=True)
    updated_at: Mapped[datetime] = mapped_column(
        DateTime, server_default=func.now(), onupdate=func.now()
    )

    __table_args__ = (
        UniqueConstraint("user_id", name="uq_client_version_user"),
    )
