import re
from pydantic import BaseModel, Field, HttpUrl, field_validator


class PushKeysIn(BaseModel):
    p256dh: str = Field(min_length=32, max_length=256, pattern=r"^[A-Za-z0-9_-]+={0,2}$")
    auth: str = Field(min_length=8, max_length=128, pattern=r"^[A-Za-z0-9_-]+={0,2}$")


class PushSubscriptionIn(BaseModel):
    endpoint: HttpUrl
    keys: PushKeysIn
    section_times: list[tuple[str, str]] | None = Field(default=None, min_length=12, max_length=12)

    @field_validator("section_times")
    @classmethod
    def valid_times(cls, value):
        if value is None:
            return value
        previous = -1
        for start, end in value:
            if not all(re.fullmatch(r"(?:[01]\d|2[0-3]):[0-5]\d", t) for t in (start, end)):
                raise ValueError("时间格式不正确")
            a, b = (int(t[:2]) * 60 + int(t[3:]) for t in (start, end))
            if b <= a or a < previous:
                raise ValueError("上下课时间反向或重叠")
            previous = b
        return value

    @field_validator("endpoint")
    @classmethod
    def endpoint_must_be_https(cls, value: HttpUrl) -> HttpUrl:
        if value.scheme != "https":
            raise ValueError("Push endpoint 必须使用 HTTPS")
        return value


class PushUnsubscribeIn(BaseModel):
    endpoint: HttpUrl

    @field_validator("endpoint")
    @classmethod
    def endpoint_must_be_https(cls, value: HttpUrl) -> HttpUrl:
        if value.scheme != "https":
            raise ValueError("Push endpoint 必须使用 HTTPS")
        return value
