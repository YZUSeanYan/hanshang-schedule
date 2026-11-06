"""统一响应/错误格式（对应设计文档 5.3 的 {code, message} 约定）。"""
from typing import Generic, TypeVar

from pydantic import BaseModel

T = TypeVar("T")


class ApiResponse(BaseModel, Generic[T]):
    """统一成功响应：code 固定 0，data 为业务数据。"""

    code: int = 0
    message: str = "ok"
    data: T | None = None


class ApiError(BaseModel):
    """统一错误响应。"""

    code: int
    message: str
