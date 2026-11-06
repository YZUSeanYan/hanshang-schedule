"""版本更新相关模式。"""
from pydantic import BaseModel, Field, HttpUrl


class VersionPublishIn(BaseModel):
    """管理员发布新版本。"""

    version_name: str = Field(..., min_length=1, max_length=32, description="如 1.0.0")
    version_code: int = Field(..., gt=0, description="递增整数版本号，必须与 APK 的 versionCode 一致")
    apk_url: HttpUrl = Field(..., description="APK 下载直链")
    sha256: str = Field(
        min_length=64, max_length=64, pattern=r"^[0-9a-fA-F]{64}$",
        description="APK 的 SHA-256；发布记录必须提供完整校验值",
    )
    release_notes: str = Field(default="", max_length=10000)
    is_force_update: bool = False
    # 仅对特定旧版本强制更新（逗号分隔的 versionCode，如 "30"）；为空则不额外强制
    force_codes: str = Field(default="", max_length=128, pattern=r"^[0-9,]*$")
    target_accounts: list[str] = Field(
        default_factory=list,
        max_length=50,
        description="可选。仅这些用户名或邮箱能看到该测试版本；为空表示正式版本。",
    )
    notify_targets: bool = Field(
        default=False,
        description="发布后同时向白名单账号写入通知并尝试发送 Android 推送。",
    )


class VersionInfoOut(BaseModel):
    has_update: bool
    version_name: str | None = None
    version_code: int | None = None
    apk_url: str | None = None
    sha256: str | None = None
    release_notes: str | None = None
    is_force_update: bool = False
