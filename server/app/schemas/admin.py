"""管理控制台输入模型。"""
from pydantic import BaseModel, EmailStr, Field


class AdminLoginIn(BaseModel):
    username: str = Field(min_length=1, max_length=64)
    password: str = Field(min_length=8, max_length=128)


class AdminUserUpdateIn(BaseModel):
    username: str = Field(min_length=2, max_length=32, pattern=r"^[A-Za-z0-9_\-\u4e00-\u9fff]+$")
    email: EmailStr


class AdminConfirmIn(BaseModel):
    confirm: str = Field(min_length=1, max_length=64)


class AdminVersionTargetIn(BaseModel):
    account: str = Field(min_length=1, max_length=255)
    notify: bool = False


class AdminNotificationSendIn(BaseModel):
    # 静默广播：只写收件箱（App 内红点可见），不触发任何系统推送——
    # 用于"欢迎更新"这类只需触达、无需打扰的公告
    silent: bool = False
    title: str = Field(min_length=1, max_length=64)
    body: str = Field(min_length=1, max_length=500)
    device_id: str | None = Field(default=None, min_length=4, max_length=192)
    platform: str | None = Field(default=None, description="按平台筛选：android/web/None(全部)")


class AdminNotificationBatchIn(BaseModel):
    title: str = Field(min_length=1, max_length=64)
    body: str = Field(min_length=1, max_length=500)
    user_ids: list[int] = Field(min_length=1, max_length=50)
