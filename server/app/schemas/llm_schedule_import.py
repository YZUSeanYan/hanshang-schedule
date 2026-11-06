"""Request/response contracts for the LLM fallback timetable import."""
from typing import Annotated, Literal

from pydantic import BaseModel, Field

from app.schemas.education_import import ImportedCourseOut


class LlmImportIn(BaseModel):
    """One captured timetable page.

    ``html`` is the rendered page the client gave up parsing locally; a real
    YZU capture is ~1.7 MB, so 2 MB is the hard ceiling (Nginx allows 2 MB per
    request).  ``captured`` carries sniffed API response bodies — they often
    hold the same timetable as clean JSON and let the server skip the LLM
    entirely.
    """

    html: str = Field(min_length=200, max_length=2_000_000)
    captured: list[Annotated[str, Field(max_length=200_000)]] = Field(
        default_factory=list, max_length=30
    )
    # Diagnostics only: which education-system page the capture came from.
    page_url: str = Field(default="", max_length=512)


class LlmImportOut(BaseModel):
    courses: list[ImportedCourseOut] = Field(max_length=200)
    source: Literal["json", "llm", "image_llm", "spreadsheet_llm"]
