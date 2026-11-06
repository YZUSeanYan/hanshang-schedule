"""用户相关响应模式。"""
from datetime import datetime

from pydantic import BaseModel, Field


class UserOut(BaseModel):
    id: int
    username: str
    email: str
    created_at: datetime
    avatar_media: str = ""

    model_config = {"from_attributes": True}  # 支持直接从 SQLAlchemy 模型转换


# 用户名：2-32，中英文/数字/下划线/短横线；不允许纯空白与特殊符号（防注入式昵称）
_USERNAME_PATTERN = r"^[\w一-鿿\-]{2,32}$"


class ProfileUpdateIn(BaseModel):
    username: str = Field(min_length=2, max_length=32, pattern=_USERNAME_PATTERN)
