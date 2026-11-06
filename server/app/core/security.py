"""安全工具：JWT 生成/校验、bcrypt 密码哈希。

安全红线：本模块只处理本系统账号，绝不接触教务系统凭证
（教务账号密码只存在于用户手机 WebView 进程内）。
"""
from datetime import datetime, timedelta, timezone
from typing import Any
import hashlib
import hmac
import secrets

import bcrypt
import jwt

from app.core.config import get_settings


# ---------- 密码哈希 ----------

def hash_password(plain_password: str) -> str:
    """bcrypt 哈希密码（自带随机盐）。"""
    return bcrypt.hashpw(plain_password.encode("utf-8"), bcrypt.gensalt()).decode("utf-8")


def verify_password(plain_password: str, password_hash: str) -> bool:
    """校验明文密码与哈希是否匹配。"""
    try:
        return bcrypt.checkpw(plain_password.encode("utf-8"), password_hash.encode("utf-8"))
    except ValueError:
        return False


# ---------- JWT ----------

def _create_token(
    subject: str | int,
    token_type: str,
    expires_minutes: int,
    *,
    token_version: int = 0,
    jti: str | None = None,
) -> str:
    """内部方法：生成带类型标记的 JWT。"""
    settings = get_settings()
    now = datetime.now(timezone.utc)
    payload: dict[str, Any] = {
        "sub": str(subject),   # 用户 ID
        "type": token_type,    # access / refresh，防止两种 token 混用
        "ver": token_version,  # 密码重置等高风险操作后整体失效
        "jti": jti or secrets.token_urlsafe(24),
        "iat": now,
        "exp": now + timedelta(minutes=expires_minutes),
    }
    return jwt.encode(payload, settings.jwt_secret_key, algorithm=settings.jwt_algorithm)


def create_access_token(subject: str | int, token_version: int = 0) -> str:
    """生成 access token（短有效期，用于接口鉴权）。"""
    return _create_token(
        subject,
        "access",
        get_settings().access_token_expire_minutes,
        token_version=token_version,
    )


def create_refresh_token(
    subject: str | int,
    token_version: int = 0,
    *,
    jti: str | None = None,
) -> str:
    """生成 refresh token（长有效期，仅用于换新 token）。"""
    return _create_token(
        subject,
        "refresh",
        get_settings().refresh_token_expire_minutes,
        token_version=token_version,
        jti=jti,
    )


def create_module_token(
    subject: str | int, module_id: str, token_version: int = 0
) -> str:
    """Create a 15-minute token scoped to one hosted app module."""
    if not module_id or len(module_id) > 64:
        raise ValueError("invalid module id")
    token = _create_token(
        subject,
        f"module:{module_id}",
        15,
        token_version=token_version,
    )
    return token


def hash_token_identifier(value: str) -> str:
    """数据库只保存刷新令牌标识的不可逆摘要。"""
    return hashlib.sha256(value.encode("utf-8")).hexdigest()


def hash_scoped_secret(purpose: str, value: str) -> str:
    """Store a full-width keyed digest for reusable one-time secrets."""
    message = f"{purpose}\0{value}".encode("utf-8")
    return hmac.new(
        get_settings().jwt_secret_key.encode("utf-8"), message, hashlib.sha256
    ).hexdigest()


def hash_one_time_code(email: str, purpose: str, code: str) -> str:
    """用服务端密钥生成短验证码摘要；8 个十六进制字符适配旧表宽度。"""
    message = f"{purpose}\0{email.strip().lower()}\0{code}".encode("utf-8")
    digest = hmac.new(
        get_settings().jwt_secret_key.encode("utf-8"), message, hashlib.sha256
    ).hexdigest()
    return digest[:8]


def verify_one_time_code(email: str, purpose: str, code: str, stored: str) -> bool:
    """兼容部署前尚未使用的六位明文记录，并校验新摘要。"""
    expected = stored
    candidate = code if len(stored) == 6 and stored.isdigit() else hash_one_time_code(
        email, purpose, code
    )
    return secrets.compare_digest(candidate, expected)


def decode_token(token: str, expected_type: str = "access") -> dict[str, Any]:
    """解码并校验 JWT。

    - 校验签名、过期时间、token 类型；
    - 校验失败抛出 jwt.PyJWTError 子类，由调用方转成统一错误格式。
    """
    settings = get_settings()
    payload: dict[str, Any] = jwt.decode(
        token, settings.jwt_secret_key, algorithms=[settings.jwt_algorithm]
    )
    if payload.get("type") != expected_type:
        raise jwt.InvalidTokenError(f"token 类型错误，期望 {expected_type}")
    return payload
