"""Schemas for privacy-preserving schedule sharing."""
from datetime import datetime
from typing import Any

from pydantic import BaseModel, Field


class ShareCreateIn(BaseModel):
    semester_uuid: str = Field(min_length=1, max_length=64)


class ShareClaimIn(BaseModel):
    replace_existing: bool = False


class ShareCodeOut(BaseModel):
    code: str
    expires_at: datetime


class SharePreviewOut(BaseModel):
    code: str
    expires_at: datetime
    use_count: int
    payload: dict[str, Any]


class ShareClaimOut(BaseModel):
    semester_uuid: str
    course_count: int
