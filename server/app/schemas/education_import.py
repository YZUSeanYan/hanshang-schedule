"""Request/response contracts for short-lived education-system imports."""
from pydantic import BaseModel, Field, SecretStr


class WebVpnImportIn(BaseModel):
    student_id: str = Field(min_length=4, max_length=32, pattern=r"^[0-9A-Za-z_-]+$")
    password: SecretStr = Field(min_length=1, max_length=128)


class ImportedSlotOut(BaseModel):
    day_of_week: int = Field(ge=1, le=7)
    start_section: int = Field(ge=1, le=30)
    end_section: int = Field(ge=1, le=30)
    weeks_text: str = Field(max_length=256)
    location: str = Field(max_length=256)


class ImportedCourseOut(BaseModel):
    name: str = Field(max_length=256)
    teacher: str = Field(max_length=128)
    slots: list[ImportedSlotOut] = Field(max_length=100)


class WebVpnImportOut(BaseModel):
    courses: list[ImportedCourseOut] = Field(max_length=200)
