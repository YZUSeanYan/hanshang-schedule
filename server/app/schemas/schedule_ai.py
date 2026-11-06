"""AI 日程接口的出入参模型（AI 日程 2.0）。"""
from typing import Literal

from pydantic import BaseModel, Field, model_validator

from app.services.llm_event_parse import (
    MAX_AUDIO_BASE64_CHARS,
    MAX_CHAT_IMAGE_BASE64_CHARS,
    MAX_IMAGE_BASE64_CHARS,
)


class HolidayParseIn(BaseModel):
    """调休通知解析：文字或截图二选一。"""

    text: str = Field(default="", max_length=2000)
    image_base64: str = Field(default="", max_length=MAX_IMAGE_BASE64_CHARS)

    @model_validator(mode="after")
    def _require_some_input(self) -> "HolidayParseIn":
        if not self.text.strip() and not self.image_base64.strip():
            raise ValueError("text 或 image_base64 至少提供一个")
        return self


class ScheduleAiTranscribeIn(BaseModel):
    """录音进行中的分段转写（实时上屏）：仅返回文本，不落库。"""

    audio_base64: str = Field(min_length=1, max_length=MAX_AUDIO_BASE64_CHARS)


class ScheduleAiParseIn(BaseModel):
    """text 与 audio_base64 二选一；都给了以音频为准（与端点行为一致）。"""

    text: str = Field(default="", max_length=500)
    audio_base64: str = Field(default="", max_length=MAX_AUDIO_BASE64_CHARS)
    image_base64: str = Field(default="", max_length=MAX_IMAGE_BASE64_CHARS)

    @model_validator(mode="after")
    def _require_some_input(self) -> "ScheduleAiParseIn":
        if not self.text.strip() and not self.audio_base64.strip() and not self.image_base64.strip():
            raise ValueError("text、audio_base64 或 image_base64 至少提供一个")
        return self


class ChatTurnIn(BaseModel):
    """对话历史中的一轮（客户端自带，至多 10 条）。"""

    role: Literal["user", "assistant"]
    content: str = Field(min_length=1, max_length=2000)


class ScheduleAiChatIn(BaseModel):
    """「墨程」AI 助手对话：message 必填（≤2000 字），图片与历史可选。"""

    message: str = Field(min_length=1, max_length=2000)
    image_base64: str = Field(default="", max_length=MAX_CHAT_IMAGE_BASE64_CHARS)
    history: list[ChatTurnIn] = Field(default_factory=list, max_length=10)


class ScheduleAiGoalPlanIn(BaseModel):
    """「墨程」AI 目标规划：title 必填，其余可空；target_date 未指定由 AI 兜底。"""

    title: str = Field(min_length=1, max_length=200)
    detail: str = Field(default="", max_length=4000)
    target_date: str | None = None
    daily_minutes: int = Field(default=60, ge=10, le=720)
    image_base64: str = Field(default="", max_length=MAX_CHAT_IMAGE_BASE64_CHARS)

    @model_validator(mode="after")
    def _validate_target_date(self) -> "ScheduleAiGoalPlanIn":
        if self.target_date is not None:
            value = self.target_date.strip()
            if not value:
                self.target_date = None
                return self
            try:
                from datetime import date

                date.fromisoformat(value)
            except ValueError:
                raise ValueError("target_date 必须是 YYYY-MM-DD") from None
            self.target_date = value
        return self
