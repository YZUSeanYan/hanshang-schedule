"""埋点上报入参：枚举白名单校验，非法枚举直接 422，不打点脏数据。"""
from pydantic import BaseModel, Field, model_validator

from app.models.import_event import ENTRY_STAGES, OUTCOMES


class ImportEventIn(BaseModel):
    entry: str = Field(min_length=1, max_length=16)
    stage: str = Field(min_length=1, max_length=16)
    outcome: str = Field(min_length=1, max_length=8)
    error_code: str = Field(default="", max_length=16)
    # 只承载文件类型/大小档/耗时档等元数据；超 200 字由服务端截断（不 422）
    detail: str = Field(default="", max_length=2000)
    client_version: str = Field(default="", max_length=16)

    @model_validator(mode="after")
    def _check_enums(self) -> "ImportEventIn":
        if self.stage not in ENTRY_STAGES.get(self.entry, ()):
            raise ValueError("unknown entry/stage")
        if self.outcome not in OUTCOMES:
            raise ValueError("unknown outcome")
        return self


class ReminderStatusIn(BaseModel):
    device_id: str = Field(min_length=1, max_length=192)
    platform: str = Field(default="android", max_length=24)
    notif_permission: bool
    exact_alarm: bool | None = None
    scheduled_count: int = Field(ge=0, le=100000)
    last_schedule_at: int | None = Field(default=None, ge=0, le=4102444800)
