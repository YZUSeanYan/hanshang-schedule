from typing import Literal

from pydantic import BaseModel, Field, field_validator


class AdminNotificationSendIn(BaseModel):
    title: str = Field(min_length=1, max_length=64)
    body: str = Field(min_length=1, max_length=500)


class PushDeviceRegistrationIn(BaseModel):
    device_id: str = Field(min_length=8, max_length=192)
    label: str = Field(default="Android 设备", min_length=1, max_length=160)
    platform: Literal["android", "harmony"] = "android"
    app_version: str = Field(default="", max_length=32)

    @field_validator("platform", mode="before")
    @classmethod
    def normalize_platform(cls, value: object) -> object:
        return value.strip().lower() if isinstance(value, str) else value
