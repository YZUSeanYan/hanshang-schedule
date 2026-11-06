"""认证端点：注册、登录、刷新 token、忘记/重置密码。

安全说明：
- 密码一律 bcrypt 哈希落库；
- 登录/注册/重置接口均有限流（防爆破）；
- 忘记密码接口无论邮箱是否存在都返回成功，防止账号枚举。
"""
import secrets
from datetime import datetime, timedelta, timezone

from fastapi import APIRouter, Depends, HTTPException, Request, Response
from sqlalchemy import or_, select
from sqlalchemy.orm import Session

from app.api.deps import get_current_user
from app.core.config import get_settings
from app.core.mail import send_mail
from app.core.ratelimit import RateLimiter, make_rate_limit_dependency
from app.core.security import (
    create_access_token,
    create_refresh_token,
    decode_token,
    hash_password,
    hash_one_time_code,
    verify_password,
    verify_one_time_code,
)
from app.core.token_sessions import (
    consume_refresh_session,
    current_token_version,
    invalidate_user_tokens,
    register_refresh_session,
    revoke_refresh_session,
)
from app.db.session import get_db
from app.models.device_pair import DevicePairCode
from app.models.email_code import EmailCode
from app.models.user import User
from app.schemas.auth import (
    DevicePairClaimIn,
    ForgotPasswordIn,
    LoginIn,
    RefreshIn,
    RegisterIn,
    ResetPasswordIn,
    TokenOut,
)
from app.schemas.user import UserOut

router = APIRouter(prefix="/auth", tags=["认证"])

_settings = get_settings()
# 认证接口限流器：单 IP 每分钟 N 次（默认 10，可通过 AUTH_RATE_LIMIT_PER_MINUTE 配置）
_limiter = RateLimiter(_settings.auth_rate_limit_per_minute, 60)
_rate_limited = Depends(make_rate_limit_dependency(_limiter, "auth"))
_reset_attempt_limiter = RateLimiter(5, 10 * 60)

_CODE_TTL_MINUTES = 10  # 邮箱验证码有效期
_WEB_REFRESH_COOKIE = "__Host-hanshang_refresh"


def _is_trusted_web_request(request: Request) -> bool:
    origin = request.headers.get("origin", "").rstrip("/")
    return origin in _settings.parsed_web_allowed_origins


def _set_web_refresh_cookie(
    request: Request, response: Response, token: str, *, force: bool = False
) -> None:
    # force=True 用于 refresh 的 Cookie 写回：请求能携带 __Host- HttpOnly Cookie
    # 本身就证明是同站浏览器请求；iOS PWA 冷启动可能不带 Origin 头，
    # 若此时消费了旧会话却不发新 Cookie，用户下次必 401 被迫重新登录。
    if not force and not _is_trusted_web_request(request):
        return
    response.set_cookie(
        key=_WEB_REFRESH_COOKIE,
        value=token,
        max_age=_settings.refresh_token_expire_minutes * 60,
        secure=True,
        httponly=True,
        samesite="strict",
        path="/",
    )


def _clear_web_refresh_cookie(response: Response) -> None:
    response.delete_cookie(
        key=_WEB_REFRESH_COOKIE,
        secure=True,
        httponly=True,
        samesite="strict",
        path="/",
    )


def _issue_tokens(user: User, db: Session) -> dict:
    """签发一对新 token。"""
    token_version = current_token_version(db, user.id)
    refresh_jti = secrets.token_urlsafe(32)
    register_refresh_session(
        db,
        user_id=user.id,
        token_version=token_version,
        token_identifier=refresh_jti,
    )
    return TokenOut(
        access_token=create_access_token(user.id, token_version),
        refresh_token=create_refresh_token(
            user.id, token_version, jti=refresh_jti
        ),
        expires_in=_settings.access_token_expire_minutes * 60,
    ).model_dump()


def _ok(data) -> dict:
    return {"code": 0, "message": "ok", "data": data}


@router.post("/register", summary="注册（用户名/邮箱 + 密码），成功后自动登录", dependencies=[_rate_limited])
def register(
    data: RegisterIn,
    request: Request,
    response: Response,
    db: Session = Depends(get_db),
) -> dict:
    if db.scalar(select(User).where(User.username == data.username)):
        raise HTTPException(status_code=409, detail={"code": 40901, "message": "用户名已被占用"})
    if db.scalar(select(User).where(User.email == data.email)):
        raise HTTPException(status_code=409, detail={"code": 40902, "message": "该邮箱已注册"})

    user = User(
        username=data.username,
        email=data.email,
        password_hash=hash_password(data.password),
    )
    db.add(user)
    db.flush()
    tokens = _issue_tokens(user, db)
    db.commit()
    db.refresh(user)
    _set_web_refresh_cookie(request, response, tokens["refresh_token"])
    return _ok({"user": UserOut.model_validate(user).model_dump(mode="json"), **tokens})


@router.post("/login", summary="登录（用户名或邮箱 + 密码）", dependencies=[_rate_limited])
def login(
    data: LoginIn,
    request: Request,
    response: Response,
    db: Session = Depends(get_db),
) -> dict:
    user = db.scalar(
        select(User).where(or_(User.username == data.account, User.email == data.account))
    )
    if user is None or not verify_password(data.password, user.password_hash):
        raise HTTPException(
            status_code=401, detail={"code": 40103, "message": "账号或密码错误"}
        )
    tokens = _issue_tokens(user, db)
    db.commit()
    _set_web_refresh_cookie(request, response, tokens["refresh_token"])
    return _ok({"user": UserOut.model_validate(user).model_dump(mode="json"), **tokens})


@router.post("/refresh", summary="刷新 token")
def refresh(
    request: Request,
    response: Response,
    data: RefreshIn | None = None,
    db: Session = Depends(get_db),
) -> dict:
    refresh_token = data.refresh_token if data is not None else request.cookies.get(_WEB_REFRESH_COOKIE, "")
    try:
        payload = decode_token(refresh_token, expected_type="refresh")
    except Exception:
        raise HTTPException(
            status_code=401,
            detail={"code": 40102, "message": "刷新令牌无效或已过期，请重新登录"},
        )
    user = db.scalar(select(User).where(User.id == int(payload["sub"])))
    if user is None:
        raise HTTPException(status_code=401, detail={"code": 40102, "message": "账号不存在"})
    token_version = int(payload.get("ver", 0))
    if token_version != current_token_version(db, user.id):
        raise HTTPException(
            status_code=401,
            detail={"code": 40102, "message": "刷新令牌已失效，请重新登录"},
        )
    jti = payload.get("jti")
    legacy = not isinstance(jti, str) or not jti
    token_identifier = refresh_token if legacy else jti
    if not consume_refresh_session(
        db,
        user_id=user.id,
        token_version=token_version,
        token_identifier=token_identifier,
        legacy=legacy,
    ):
        db.rollback()
        raise HTTPException(
            status_code=401,
            detail={"code": 40102, "message": "刷新令牌已失效，请重新登录"},
        )
    from app.models.daily_activity import DailyActivity
    from sqlalchemy import text as sa_text
    from datetime import date as dt_date
    try:
        db.execute(
            sa_text(
                "INSERT OR IGNORE INTO daily_activity (user_id, activity_date, created_at) "
                "VALUES (:uid, :d, datetime('now'))"
            ),
            {"uid": user.id, "d": str(dt_date.today())},
        )
        db.commit()
    except Exception:
        pass
    # 不再轮换：refresh token 在有效期内固定不变（滑动续期已在 consume 内
    # 完成），只签发新 access token。多浏览器/多设备各自持有独立会话，
    # 互不顶掉，尽可能保持登录状态。
    tokens = TokenOut(
        access_token=create_access_token(user.id, token_version),
        refresh_token=refresh_token,
        expires_in=_settings.access_token_expire_minutes * 60,
    ).model_dump()
    db.commit()
    # 凭据来自 Cookie 时无条件写回（force 跳过 Origin 门槛，原因见
    # _set_web_refresh_cookie）：Cookie 值不变，但 max_age 随之滑动续期；
    # JSON body 凭据（App/脚本）仍按 Origin 门槛处理。
    _set_web_refresh_cookie(request, response, refresh_token, force=data is None)
    # 与登录/注册响应一致带上 user：Web 启动只用一个往返即可恢复会话，
    # 不必再串行请求 /api/user/profile。
    return _ok({"user": UserOut.model_validate(user).model_dump(mode="json"), **tokens})


@router.post("/logout", summary="退出登录并撤销当前刷新会话")
def logout(
    request: Request,
    response: Response,
    data: RefreshIn | None = None,
    db: Session = Depends(get_db),
) -> dict:
    refresh_token = data.refresh_token if data is not None else request.cookies.get(_WEB_REFRESH_COOKIE, "")
    if refresh_token:
        try:
            payload = decode_token(refresh_token, expected_type="refresh")
            jti = payload.get("jti")
            # 登出是显式撤销：删除会话行而非标记 revoked_at，
            # 避免被轮换宽限窗当作并发重放放行。
            revoke_refresh_session(
                db,
                token_identifier=jti if isinstance(jti, str) and jti else refresh_token,
            )
            db.commit()
        except Exception:
            db.rollback()
    _clear_web_refresh_cookie(response)
    return _ok({"logged_out": True})


@router.post("/forgot-password", summary="发送重置密码验证码到邮箱", dependencies=[_rate_limited])
def forgot_password(data: ForgotPasswordIn, db: Session = Depends(get_db)) -> dict:
    user = db.scalar(select(User).where(User.email == data.email))
    if user is not None:
        # 作废旧验证码，生成新验证码（10 分钟有效）
        for old in db.scalars(
            select(EmailCode).where(EmailCode.email == data.email, EmailCode.used.is_(False))
        ):
            old.used = True
        code = f"{secrets.randbelow(1000000):06d}"
        db.add(EmailCode(
            email=data.email,
            code=hash_one_time_code(data.email, "reset_password", code),
            purpose="reset_password",
            expires_at=datetime.now(timezone.utc).replace(tzinfo=None)
            + timedelta(minutes=_CODE_TTL_MINUTES),
        ))
        db.commit()
        send_mail(
            to=data.email,
            subject="【邗上课表】重置密码验证码",
            text=f"你的验证码是：{code}，{_CODE_TTL_MINUTES} 分钟内有效。\n"
                 f"若非本人操作，请忽略本邮件并尽快修改密码。",
        )
    # 无论邮箱是否存在都返回成功，防止账号枚举
    return _ok({"sent": True, "expires_minutes": _CODE_TTL_MINUTES})


@router.post("/reset-password", summary="凭邮箱验证码重置密码", dependencies=[_rate_limited])
def reset_password(
    data: ResetPasswordIn,
    request: Request,
    db: Session = Depends(get_db),
) -> dict:
    client_ip = request.client.host if request.client else "unknown"
    if not _reset_attempt_limiter.allow(f"{data.email.lower()}:{client_ip}"):
        raise HTTPException(
            status_code=429,
            detail={"code": 42901, "message": "验证码尝试次数过多，请稍后重新获取"},
        )
    record = db.scalar(
        select(EmailCode)
        .where(
            EmailCode.email == data.email,
            EmailCode.purpose == "reset_password",
            EmailCode.used.is_(False),
        )
        .order_by(EmailCode.id.desc())
    )
    now = datetime.now(timezone.utc).replace(tzinfo=None)
    if (
        record is None
        or record.expires_at < now
        or not verify_one_time_code(
            data.email, "reset_password", data.code, record.code
        )
    ):
        raise HTTPException(
            status_code=400, detail={"code": 40001, "message": "验证码错误或已过期"}
        )
    user = db.scalar(select(User).where(User.email == data.email))
    if user is None:
        raise HTTPException(status_code=400, detail={"code": 40001, "message": "验证码错误或已过期"})

    user.password_hash = hash_password(data.new_password)
    invalidate_user_tokens(db, user.id)
    record.used = True
    db.commit()
    return _ok({"reset": True})


# ---------- 设备配对码（手表端免输账号密码登录） ----------
# 手机端登录后生成 6 位数字码，手表输码换取令牌。
# 安全：码只存 HMAC 摘要、10 分钟一次性、生成/领取均按 IP 限流。
_PAIR_TTL_MINUTES = 10
_pair_create_limiter = RateLimiter(10, 60)
_pair_claim_limiter = RateLimiter(10, 60)
_pair_create_rate_limited = Depends(make_rate_limit_dependency(_pair_create_limiter, "device-pair-create"))
_pair_claim_rate_limited = Depends(make_rate_limit_dependency(_pair_claim_limiter, "device-pair-claim"))


def _pair_now() -> datetime:
    return datetime.now(timezone.utc).replace(tzinfo=None)


@router.post("/device-pair", summary="生成 6 位设备配对码（需登录，手机端调用）", dependencies=[_pair_create_rate_limited])
def create_device_pair(
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> dict:
    # 作废旧码再生成新码，保证任意时刻只有一枚有效码
    for old in db.scalars(
        select(DevicePairCode).where(
            DevicePairCode.user_id == user.id, DevicePairCode.used.is_(False)
        )
    ):
        old.used = True
    code = f"{secrets.randbelow(1000000):06d}"
    db.add(DevicePairCode(
        user_id=user.id,
        code=hash_one_time_code("device", "device_pair", code),
        expires_at=_pair_now() + timedelta(minutes=_PAIR_TTL_MINUTES),
    ))
    db.commit()
    return _ok({"code": code, "expires_minutes": _PAIR_TTL_MINUTES})


@router.post("/device-pair/claim", summary="手表输码换取登录令牌（免登录）", dependencies=[_pair_claim_rate_limited])
def claim_device_pair(
    data: DevicePairClaimIn,
    db: Session = Depends(get_db),
) -> dict:
    code_hash = hash_one_time_code("device", "device_pair", data.code)
    record = db.scalar(
        select(DevicePairCode).where(
            DevicePairCode.code == code_hash,
            DevicePairCode.used.is_(False),
        )
    )
    if record is None or record.expires_at < _pair_now():
        raise HTTPException(
            status_code=400,
            detail={"code": 40020, "message": "配对码无效或已过期，请重新生成"},
        )
    user = db.get(User, record.user_id)
    if user is None:
        raise HTTPException(
            status_code=400,
            detail={"code": 40020, "message": "配对码无效或已过期，请重新生成"},
        )
    record.used = True
    if data.device_name:
        record.device_name = data.device_name[:64]
    tokens = _issue_tokens(user, db)
    db.commit()
    return _ok({"user": UserOut.model_validate(user).model_dump(mode="json"), **tokens})
