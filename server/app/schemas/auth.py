"""认证相关的请求/响应模式（pydantic 参数校验）。"""
import re

from pydantic import BaseModel, EmailStr, Field, field_validator

# 用户名：2-32 位，字母/数字/下划线/中文
_USERNAME_RE = re.compile(r"^[A-Za-z0-9_一-龥]{2,32}$")


class RegisterIn(BaseModel):
    username: str = Field(..., description="用户名，2-32 位字母/数字/下划线/中文")
    email: EmailStr
    password: str = Field(..., min_length=8, max_length=64, description="至少 8 位")

    @field_validator("username")
    @classmethod
    def _check_username(cls, v: str) -> str:
        if not _USERNAME_RE.match(v):
            raise ValueError("用户名仅限 2-32 位字母、数字、下划线或中文")
        return v


class LoginIn(BaseModel):
    account: str = Field(..., min_length=1, description="用户名或邮箱")
    password: str = Field(..., min_length=1)


class RefreshIn(BaseModel):
    refresh_token: str


class ForgotPasswordIn(BaseModel):
    email: EmailStr


class ResetPasswordIn(BaseModel):
    email: EmailStr
    code: str = Field(..., min_length=6, max_length=6, pattern=r"^\d{6}$", description="6 位数字验证码")
    new_password: str = Field(..., min_length=8, max_length=64)


class TokenOut(BaseModel):
    access_token: str
    refresh_token: str
    token_type: str = "bearer"
    expires_in: int = Field(..., description="access token 有效期（秒）")


class DevicePairClaimIn(BaseModel):
    code: str = Field(..., min_length=6, max_length=6, pattern=r"^\d{6}$", description="6 位数字配对码")
    device_name: str = Field("", max_length=64, description="设备名（仅记录）")
