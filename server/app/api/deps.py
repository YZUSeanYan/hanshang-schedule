"""API 公共依赖：当前用户解析（鉴权全覆盖从这里开始）、管理接口鉴权。

数据库会话依赖 get_db 定义在 app/db/session.py。
"""
import jwt
import secrets
from fastapi import Depends, Header, HTTPException, Request
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from sqlalchemy import select
from sqlalchemy.orm import Session

from app.core.config import get_settings
from app.core.security import decode_token
from app.core.token_sessions import current_token_version
from app.db.session import get_db
from app.models.user import User
from app.models.release_target import AppFeatureGrant
from app.services.activity import record_daily_activity

# auto_error=False：缺 token 时交给我们统一返回中文错误格式，而非默认 403
_bearer = HTTPBearer(auto_error=False)


def get_current_user_id(
    credentials: HTTPAuthorizationCredentials | None = Depends(_bearer),
    db: Session = Depends(get_db),
) -> int:
    """从 Authorization: Bearer <token> 解析当前用户 ID。"""
    if credentials is None:
        raise HTTPException(
            status_code=401, detail={"code": 40101, "message": "未登录或缺少访问令牌"}
        )
    try:
        payload = decode_token(credentials.credentials, expected_type="access")
        user_id = int(payload["sub"])
        claim_version = int(payload.get("ver", 0))
        if claim_version != current_token_version(db, user_id):
            raise jwt.InvalidTokenError("token 已被撤销")
        # 活跃打点：任意已认证请求即记当日活跃（当日首次才真正写库，
        # 详见 app/services/activity.py）。打点失败不影响主流程。
        record_daily_activity(db, user_id)
        return user_id
    except (jwt.PyJWTError, KeyError, TypeError, ValueError):
        raise HTTPException(
            status_code=401,
            detail={"code": 40102, "message": "登录状态无效或已过期，请重新登录"},
        )


def get_current_user(
    user_id: int = Depends(get_current_user_id),
    db: Session = Depends(get_db),
) -> User:
    """解析当前登录用户的完整模型（所有需登录接口统一使用本依赖）。"""
    user = db.scalar(select(User).where(User.id == user_id))
    if user is None:
        raise HTTPException(
            status_code=401, detail={"code": 40102, "message": "账号不存在或已被注销"}
        )
    return user


def get_optional_current_user(
    request: Request,
    db: Session = Depends(get_db),
) -> User | None:
    """Return the authenticated user when present; keep public endpoints public."""
    authorization = request.headers.get("authorization", "")
    scheme, _, token = authorization.partition(" ")
    if scheme.lower() != "bearer" or not token:
        return None
    try:
        payload = decode_token(token, expected_type="access")
        user_id = int(payload["sub"])
        if int(payload.get("ver", 0)) != current_token_version(db, user_id):
            return None
    except (jwt.PyJWTError, KeyError, TypeError, ValueError):
        return None
    return db.scalar(select(User).where(User.id == user_id))


def require_admin(x_admin_token: str | None = Header(default=None)) -> None:
    """管理接口鉴权：校验 X-Admin-Token 头（用于发布新版本等运维操作）。"""
    token = get_settings().admin_token
    if not token or not x_admin_token or not secrets.compare_digest(x_admin_token, token):
        raise HTTPException(
            status_code=403, detail={"code": 40300, "message": "无管理权限"}
        )


def require_module_user(module_id: str, *, require_grant: bool = True):
    """Authorize a module from either native app or hosted WebView.

    Hosted pages use the short-lived module cookie. Native pages use the
    normal access token. Targeted modules additionally require a per-user
    grant; generally available modules still authenticate every request but do
    not depend on rows that would omit newly registered users.
    """
    if not module_id or len(module_id) > 64:
        raise ValueError("invalid module id")

    def dependency(request: Request, db: Session = Depends(get_db)) -> User:
        cookie_token = request.cookies.get("__Host-hanshang_module", "")
        authorization = request.headers.get("authorization", "")
        scheme, _, bearer_token = authorization.partition(" ")
        token = cookie_token or (bearer_token if scheme.lower() == "bearer" else "")
        expected_type = f"module:{module_id}" if cookie_token else "access"
        try:
            payload = decode_token(token, expected_type=expected_type)
            user_id = int(payload["sub"])
            if int(payload.get("ver", 0)) != current_token_version(db, user_id):
                raise jwt.InvalidTokenError("token 已被撤销")
        except (jwt.PyJWTError, KeyError, TypeError, ValueError):
            raise HTTPException(
                status_code=401,
                detail={"code": 40130, "message": "功能会话无效或已过期"},
            )
        user = db.scalar(select(User).where(User.id == user_id))
        if user is None:
            raise HTTPException(
                status_code=401,
                detail={"code": 40130, "message": "功能会话无效或已过期"},
            )
        if require_grant:
            granted = db.scalar(
                select(AppFeatureGrant.id).where(
                    AppFeatureGrant.user_id == user.id,
                    AppFeatureGrant.feature_id == module_id,
                )
            )
            if granted is None:
                # Do not reveal that an account-targeted module exists.
                raise HTTPException(
                    status_code=404,
                    detail={"code": 40430, "message": "功能当前不可用"},
                )
        return user

    return dependency
