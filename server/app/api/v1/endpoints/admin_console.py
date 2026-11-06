"""安全管理控制台 API：独立会话、CSRF、最小权限与审计。"""
import hashlib
import base64
import secrets
from pathlib import Path
from datetime import datetime, timedelta, timezone

from fastapi import APIRouter, Cookie, Depends, File, Header, HTTPException, Query, Request, Response, UploadFile
from sqlalchemy import delete, exists, func, inspect as sa_inspect, or_, select, text
from sqlalchemy.orm import Session

from app.core.config import get_settings
from app.core.ratelimit import RateLimiter, make_rate_limit_dependency
from app.core.security import verify_password
from app.db.session import get_db
from app.models.admin import AdminAuditLog, AdminSession, UserRestriction
from app.models.email_code import EmailCode
from app.models.push_subscription import PushDelivery, PushSubscription
from app.models.share_code import ShareCode
from app.models.sync_data import SyncCourse, SyncSchedule, SyncSemester
from app.models.token_session import RefreshTokenSession, UserTokenState
from app.models.daily_activity import DailyActivity
from app.models.import_event import ImportEvent
from app.models.reminder_status import ReminderStatus
from app.models.user import User
from app.models.about_content import AboutContent
from app.models.credential_vault import CredentialVault
from app.models.notification import UserNotification, UserPushDevice
from app.models.couple_schedule import CoupleMembership
from app.schemas.admin import (
    AdminConfirmIn,
    AdminLoginIn,
    AdminUserUpdateIn,
    AdminNotificationSendIn,
    AdminNotificationBatchIn,
    AdminVersionTargetIn,
)
from app.schemas.version import VersionPublishIn
from app.models.app_version import AppVersion
from app.models.release_target import AppVersionTarget
from app.services import version_release
from app.schemas.about import AdminAboutUpdateIn
from app.services.about_media import MAX_MEDIA_BYTES, detect_extension, persist_media
from app.services.hms_push import (
    HmsPushError,
    HmsPushUnavailable,
    send_harmony_notification,
)
from app.services.mobile_push import MobilePushUnavailable, send_account_notification
from app.services.web_push import WebPushUnavailable, send_web_push

router = APIRouter(prefix="/admin-console", tags=["管理控制台"])
settings = get_settings()
_COOKIE = "yzu_admin_session"
_login_limiter = RateLimiter(5, 60)
_login_limited = Depends(make_rate_limit_dependency(_login_limiter, "admin-login"))


def _hash(value: str) -> str:
    return hashlib.sha256(value.encode("utf-8")).hexdigest()


def _password_hash() -> str:
    if settings.admin_password_hash_b64:
        try:
            return base64.b64decode(settings.admin_password_hash_b64).decode("utf-8")
        except (ValueError, UnicodeDecodeError):
            return ""
    return settings.admin_password_hash


def _enabled() -> None:
    if not settings.admin_console_enabled:
        raise HTTPException(status_code=404, detail={"code": 40400, "message": "Not Found"})


def _session(
    request: Request,
    token: str | None = Cookie(default=None, alias=_COOKIE),
    db: Session = Depends(get_db),
) -> AdminSession:
    _enabled()
    if not token:
        raise HTTPException(status_code=401, detail={"code": 40110, "message": "管理会话已失效"})
    row = db.scalar(select(AdminSession).where(AdminSession.token_hash == _hash(token)))
    now = datetime.now(timezone.utc).replace(tzinfo=None)
    agent_hash = _hash(request.headers.get("user-agent", ""))
    if row is None or row.expires_at <= now or not secrets.compare_digest(row.user_agent_hash, agent_hash):
        if row is not None:
            db.delete(row)
            db.commit()
        raise HTTPException(status_code=401, detail={"code": 40110, "message": "管理会话已失效"})
    row.last_seen_at = now
    db.commit()
    return row


def _csrf(
    session: AdminSession = Depends(_session),
    csrf: str | None = Header(default=None, alias="X-CSRF-Token"),
) -> AdminSession:
    if not csrf or not secrets.compare_digest(session.csrf_hash, _hash(csrf)):
        raise HTTPException(status_code=403, detail={"code": 40310, "message": "安全校验失败，请刷新页面"})
    return session


def _audit(db: Session, action: str, user_id: int | None = None, detail: str = "") -> None:
    db.add(AdminAuditLog(action=action, target_user_id=user_id, detail=detail[:1000]))


def _user_or_404(db: Session, user_id: int) -> User:
    user = db.scalar(select(User).where(User.id == user_id))
    if user is None:
        raise HTTPException(status_code=404, detail={"code": 40401, "message": "用户不存在"})
    return user


def _utc_iso(value: datetime | None) -> str | None:
    """数据库时间列是无时区的 UTC，返回带 +00:00 的 ISO 字符串。

    否则前端 new Date() 会把无时区字符串按浏览器本地时间解析，
    在中国会显示成早 8 小时（管理中心时间与实况不符）。
    """
    if value is None:
        return None
    if value.tzinfo is None:
        value = value.replace(tzinfo=timezone.utc)
    return value.isoformat()


_WEB_PUSH_URL = "https://hanshang.seanyan.store/web/"


def _native_device_cutoff() -> datetime:
    return (
        datetime.now(timezone.utc).replace(tzinfo=None)
        - timedelta(days=settings.push_device_expire_days)
    )


def _deliver_android(
    *, title: str, body: str, notification_id: int,
    user_id: int, device_id: str | None = None,
) -> tuple[str, str, str]:
    """Send one account/device Android push; return (status, provider_id, error)."""
    try:
        provider_id = send_account_notification(
            user_id=user_id, title=title, body=body,
            notification_id=notification_id, device_id=device_id,
        )
        return "accepted", str(provider_id or ""), ""
    except MobilePushUnavailable as error:
        return "stored", "", str(error)[:500]
    except Exception as error:
        return "failed", "", type(error).__name__[:500]


def _deliver_harmony(
    db: Session, device: UserPushDevice, *, title: str, body: str,
    notification_id: int,
) -> tuple[str, str, str]:
    try:
        provider_id = send_harmony_notification(
            token=device.device_id, title=title, body=body,
            notification_id=notification_id,
        )
        return "accepted", str(provider_id or ""), ""
    except HmsPushUnavailable as error:
        return "stored", "", str(error)[:500]
    except HmsPushError as error:
        if error.stale_token:
            db.delete(device)
        return "failed", "", str(error)[:500]
    except Exception as error:
        return "failed", "", type(error).__name__[:500]


def _deliver_harmony_devices(
    db: Session, devices: list[UserPushDevice], *, title: str, body: str,
    notification_id: int,
) -> list[tuple[str, str, str]]:
    return [
        _deliver_harmony(
            db, device, title=title, body=body, notification_id=notification_id
        )
        for device in devices
    ]


def _deliver_web_push(
    subscription, title: str, body: str,
) -> bool:
    try:
        send_web_push(
            endpoint=subscription.endpoint,
            p256dh=subscription.p256dh,
            auth=subscription.auth,
            payload={"title": title, "body": body, "url": _WEB_PUSH_URL},
            private_key=settings.web_push_private_key,
            subject=settings.web_push_subject,
        )
        subscription.last_success_at = datetime.now(timezone.utc).replace(tzinfo=None)
        return True
    except Exception as error:
        print(
            f"[web_push] delivery failed sub_id={subscription.id} "
            f"user_id={subscription.user_id}: {type(error).__name__}: {error}",
            flush=True,
        )
        return False


def _about_row(db: Session) -> AboutContent:
    row = db.scalar(select(AboutContent).where(AboutContent.id == 1))
    if row is None:
        row = AboutContent(id=1, display_name="邗上课表")
        db.add(row)
        db.flush()
    return row


def _about_data(row: AboutContent) -> dict:
    return {
        "display_name": row.display_name,
        "icp_beian": row.icp_beian,
        "intro": row.intro,
        "website_url": row.website_url,
        "avatar_media": row.avatar_media,
        "payment_qr_media": row.payment_qr_media,
        "updated_at": _utc_iso(row.updated_at),
    }


@router.post("/login", dependencies=[_login_limited])
def login(data: AdminLoginIn, request: Request, response: Response, db: Session = Depends(get_db)) -> dict:
    _enabled()
    valid_user = secrets.compare_digest(data.username, settings.admin_username)
    configured_hash = _password_hash()
    valid_password = bool(configured_hash) and verify_password(data.password, configured_hash)
    if not valid_user or not valid_password:
        raise HTTPException(status_code=401, detail={"code": 40111, "message": "账号或密码错误"})

    now = datetime.now(timezone.utc).replace(tzinfo=None)
    db.execute(delete(AdminSession).where(AdminSession.expires_at <= now))
    token = secrets.token_urlsafe(48)
    csrf = secrets.token_urlsafe(32)
    db.add(AdminSession(
        token_hash=_hash(token),
        csrf_hash=_hash(csrf),
        user_agent_hash=_hash(request.headers.get("user-agent", "")),
        expires_at=now + timedelta(hours=settings.admin_session_hours),
    ))
    _audit(db, "admin.login")
    db.commit()
    response.set_cookie(
        _COOKIE,
        token,
        max_age=settings.admin_session_hours * 3600,
        httponly=True,
        secure=settings.admin_cookie_secure,
        samesite="strict",
        path="/",
    )
    response.headers["Cache-Control"] = "no-store"
    return {"code": 0, "message": "ok", "data": {"csrf_token": csrf}}


@router.get("/session")
def session_info(
    session: AdminSession = Depends(_session),
    db: Session = Depends(get_db),
) -> dict:
    csrf = secrets.token_urlsafe(32)
    session.csrf_hash = _hash(csrf)
    db.commit()
    return {
        "code": 0,
        "message": "ok",
        "data": {"authenticated": True, "csrf_token": csrf},
    }


@router.post("/logout")
def logout(
    response: Response,
    session: AdminSession = Depends(_csrf),
    db: Session = Depends(get_db),
) -> dict:
    db.delete(session)
    _audit(db, "admin.logout")
    db.commit()
    response.delete_cookie(_COOKIE, path="/")
    return {"code": 0, "message": "ok", "data": {"logged_out": True}}


@router.get("/summary")
def summary(_: AdminSession = Depends(_session), db: Session = Depends(get_db)) -> dict:
    counts = {
        "users": db.scalar(select(func.count()).select_from(User)) or 0,
        "push_devices": db.scalar(select(func.count()).select_from(UserPushDevice)) or 0,
        "semesters": db.scalar(select(func.count()).select_from(SyncSemester).where(SyncSemester.deleted.is_(False))) or 0,
        "courses": db.scalar(select(func.count()).select_from(SyncCourse).where(SyncCourse.deleted.is_(False))) or 0,
        "schedules": db.scalar(select(func.count()).select_from(SyncSchedule).where(SyncSchedule.deleted.is_(False))) or 0,
    }
    return {"code": 0, "message": "ok", "data": counts}


@router.get("/users")
def users(
    q: str = Query(default="", max_length=100),
    page: int = Query(default=1, ge=1),
    page_size: int = Query(default=20, ge=1, le=100),
    _: AdminSession = Depends(_session),
    db: Session = Depends(get_db),
) -> dict:
    filters = []
    if q.strip():
        needle = q.strip()
        filters.append(or_(User.username.contains(needle, autoescape=True), User.email.contains(needle, autoescape=True)))
    total = db.scalar(select(func.count()).select_from(User).where(*filters)) or 0
    rows = db.scalars(
        select(User).where(*filters).order_by(User.id.desc()).offset((page - 1) * page_size).limit(page_size)
    ).all()
    # 每个用户的设备计数（Android + 网页端），一次查询避免 N+1
    from app.models.push_subscription import PushSubscription
    user_ids = [user.id for user in rows]
    android_counts = {}
    web_counts = {}
    course_counts = {}
    last_active = {}
    restricted_ids = set()
    if user_ids:
        for row in db.execute(
            select(UserPushDevice.user_id, func.count().label("cnt"))
            .where(UserPushDevice.user_id.in_(user_ids))
            .group_by(UserPushDevice.user_id)
        ):
            android_counts[row[0]] = row[1]
        for row in db.execute(
            select(PushSubscription.user_id, func.count().label("cnt"))
            .where(PushSubscription.user_id.in_(user_ids))
            .group_by(PushSubscription.user_id)
        ):
            web_counts[row[0]] = row[1]
        # 课表规模与最近活跃（管理后台 v3 用户管理列）
        for row in db.execute(
            select(SyncCourse.user_id, func.count().label("cnt"))
            .where(SyncCourse.user_id.in_(user_ids), SyncCourse.deleted.is_(False))
            .group_by(SyncCourse.user_id)
        ):
            course_counts[row[0]] = row[1]
        for row in db.execute(
            select(DailyActivity.user_id, func.max(DailyActivity.activity_date).label("last"))
            .where(DailyActivity.user_id.in_(user_ids))
            .group_by(DailyActivity.user_id)
        ):
            last_active[row[0]] = row[1].isoformat() if row[1] else None
        restricted_ids = set(db.scalars(
            select(UserRestriction.user_id).where(UserRestriction.user_id.in_(user_ids))
        ).all())
    data = [{
        "id": user.id,
        "username": user.username,
        "email": user.email,
        "created_at": _utc_iso(user.created_at),
        "android_count": android_counts.get(user.id, 0),
        "web_count": web_counts.get(user.id, 0),
        "course_count": course_counts.get(user.id, 0),
        "last_active": last_active.get(user.id),
        "restricted": user.id in restricted_ids,
    } for user in rows]
    return {"code": 0, "message": "ok", "data": {"items": data, "total": total, "page": page, "page_size": page_size}}


@router.get("/users/{user_id}")
def user_detail(user_id: int, _: AdminSession = Depends(_session), db: Session = Depends(get_db)) -> dict:
    user = _user_or_404(db, user_id)
    counts = {
        "semesters": db.scalar(select(func.count()).select_from(SyncSemester).where(SyncSemester.user_id == user_id, SyncSemester.deleted.is_(False))) or 0,
        "courses": db.scalar(select(func.count()).select_from(SyncCourse).where(SyncCourse.user_id == user_id, SyncCourse.deleted.is_(False))) or 0,
        "schedules": db.scalar(select(func.count()).select_from(SyncSchedule).where(SyncSchedule.user_id == user_id, SyncSchedule.deleted.is_(False))) or 0,
    }
    vault = db.scalar(select(CredentialVault).where(CredentialVault.user_id == user_id))
    notification_count = db.scalar(select(func.count()).select_from(UserNotification).where(UserNotification.user_id == user_id)) or 0
    # ---- 管理后台 v3：状态 / 最近活跃 / 设备清单 ----
    restriction = db.scalar(select(UserRestriction).where(UserRestriction.user_id == user_id))
    last_active = db.scalar(
        select(func.max(DailyActivity.activity_date)).where(DailyActivity.user_id == user_id)
    )
    devices = db.scalars(
        select(UserPushDevice).where(UserPushDevice.user_id == user_id)
        .order_by(UserPushDevice.last_seen_at.desc())
    ).all()
    web_count = db.scalar(
        select(func.count()).select_from(PushSubscription).where(PushSubscription.user_id == user_id)
    ) or 0
    return {"code": 0, "message": "ok", "data": {
        "id": user.id, "username": user.username, "email": user.email,
        "created_at": user.created_at.isoformat() if user.created_at else None,
        "counts": counts,
        "notification_count": notification_count,
        "credential_vault": {
            "exists": vault is not None,
            "student_id_hint": vault.student_id_hint if vault else "",
            "schema_version": vault.schema_version if vault else None,
            "updated_at": _utc_iso(vault.updated_at if vault else None),
            "last_verified_at": _utc_iso(vault.last_verified_at if vault else None),
        },
        "restricted": {
            "active": restriction is not None,
            "reason": restriction.reason if restriction else "",
            "disabled_at": _utc_iso(restriction.disabled_at if restriction else None),
        },
        "last_active": last_active.isoformat() if last_active else None,
        "devices": [{
            "platform": device.platform,
            "last_seen_at": _utc_iso(device.last_seen_at),
            "created_at": _utc_iso(device.created_at),
        } for device in devices],
        "web_count": web_count,
    }}


@router.post("/users/{user_id}/notifications")
def send_user_notification(
    user_id: int,
    data: AdminNotificationSendIn,
    _: AdminSession = Depends(_csrf),
    db: Session = Depends(get_db),
) -> dict:
    user = _user_or_404(db, user_id)
    title, body = data.title.strip(), data.body.strip()
    if not title or not body:
        raise HTTPException(status_code=422, detail={"code": 42230, "message": "标题和内容不能为空"})
    web_sub = None
    device = None
    if data.device_id:
        if data.device_id.startswith("web:"):
            try:
                web_sub_id = int(data.device_id.removeprefix("web:"))
            except ValueError:
                raise HTTPException(
                    status_code=404,
                    detail={"code": 40432, "message": "指定设备不存在或不属于该账号"},
                )
            web_sub = db.scalar(select(PushSubscription).where(
                PushSubscription.id == web_sub_id,
                PushSubscription.user_id == user_id,
            ))
            if web_sub is None:
                raise HTTPException(
                    status_code=404,
                    detail={"code": 40432, "message": "指定设备不存在或不属于该账号"},
                )
        else:
            device = db.scalar(select(UserPushDevice).where(
                UserPushDevice.user_id == user_id,
                UserPushDevice.device_id == data.device_id,
                UserPushDevice.last_seen_at >= _native_device_cutoff(),
            ))
            if device is None:
                raise HTTPException(
                    status_code=404,
                    detail={"code": 40432, "message": "指定设备不存在或不属于该账号"},
                )
    row = UserNotification(
        user_id=user_id, title=title, body=body,
        target_type="DEVICE" if (device or web_sub) else "ACCOUNT",
        target_device_id=(
            device.device_id if device
            else (f"web:{web_sub.id}" if web_sub else None)
        ),
        target_label=(
            device.label if device
            else ("网页端（PWA）" if web_sub else "全部设备")
        ),
    )
    db.add(row)
    db.flush()
    if web_sub is not None:
        web_ok = _deliver_web_push(web_sub, title, body)
        row.provider = "web_push"
        row.delivery_status = "accepted" if web_ok else "failed"
        row.delivery_error = "" if web_ok else "WebPushError"
    elif device is not None and device.platform == "harmony":
        row.provider = "hms"
        row.delivery_status, row.provider_message_id, row.delivery_error = _deliver_harmony(
            db, device, title=title, body=body, notification_id=row.id,
        )
    else:
        row.delivery_status, row.provider_message_id, row.delivery_error = _deliver_android(
            title=title, body=body, notification_id=row.id,
            user_id=user_id, device_id=device.device_id if device else None,
        )
        if device is None:
            harmony_devices = db.scalars(select(UserPushDevice).where(
                UserPushDevice.user_id == user_id,
                UserPushDevice.platform == "harmony",
                UserPushDevice.last_seen_at >= _native_device_cutoff(),
            )).all()
            harmony_results = _deliver_harmony_devices(
                db, list(harmony_devices), title=title, body=body,
                notification_id=row.id,
            )
            accepted_harmony = next(
                (result for result in harmony_results if result[0] == "accepted"),
                None,
            )
            if row.delivery_status != "accepted" and accepted_harmony:
                row.provider = "hms"
                row.delivery_status = "accepted"
                row.provider_message_id = accepted_harmony[1]
                row.delivery_error = ""
            # 「全部设备」也要投递该账号的全部网页端（PWA/iOS）订阅；
            # 此前缺这一段导致 iOS PWA 收不到管理后台通知。
            if device is None:
                web_delivered = 0
                for sub in db.scalars(select(PushSubscription).where(
                    PushSubscription.user_id == user_id
                )).all():
                    if _deliver_web_push(sub, title, body):
                        web_delivered += 1
    _audit(db, "notification.send", user_id, f"notification_id={row.id},status={row.delivery_status}")
    db.commit()
    return {"code": 0, "message": "ok", "data": {
        "id": row.id, "status": row.delivery_status, "target_label": row.target_label,
        "provider_message_id": row.provider_message_id,
    }}


@router.post("/notifications/batch")
def send_batch_notification(
    data: AdminNotificationBatchIn,
    _: AdminSession = Depends(_csrf),
    db: Session = Depends(get_db),
) -> dict:
    """Send one notice to several selected accounts (Android + their web devices)."""
    title, body = data.title.strip(), data.body.strip()
    if not title or not body:
        raise HTTPException(status_code=422, detail={"code": 42230, "message": "标题和内容不能为空"})
    user_ids = list(dict.fromkeys(data.user_ids))
    users = db.scalars(select(User).where(User.id.in_(user_ids))).all()
    users_by_id = {user.id: user for user in users}
    missing_user_ids = [user_id for user_id in user_ids if user_id not in users_by_id]
    if missing_user_ids:
        raise HTTPException(
            status_code=422,
            detail={
                "code": 42231,
                "message": "批量通知包含不存在的账号",
                "missing_user_ids": missing_user_ids,
            },
        )
    users = [users_by_id[user_id] for user_id in user_ids]
    results = []
    for user in users:
        row = UserNotification(
            user_id=user.id, title=title, body=body,
            target_type="ACCOUNT", target_label="全部设备",
        )
        db.add(row)
        db.flush()
        row.delivery_status, row.provider_message_id, row.delivery_error = _deliver_android(
            title=title, body=body, notification_id=row.id, user_id=user.id,
        )
        harmony_devices = db.scalars(select(UserPushDevice).where(
            UserPushDevice.user_id == user.id,
            UserPushDevice.platform == "harmony",
            UserPushDevice.last_seen_at >= _native_device_cutoff(),
        )).all()
        harmony_results = _deliver_harmony_devices(
            db, list(harmony_devices), title=title, body=body,
            notification_id=row.id,
        )
        accepted_harmony = next(
            (result for result in harmony_results if result[0] == "accepted"),
            None,
        )
        if row.delivery_status != "accepted" and accepted_harmony:
            row.provider = "hms"
            row.delivery_status = "accepted"
            row.provider_message_id = accepted_harmony[1]
            row.delivery_error = ""
        web_delivered = 0
        for sub in db.scalars(select(PushSubscription).where(
            PushSubscription.user_id == user.id
        )).all():
            if _deliver_web_push(sub, title, body):
                web_delivered += 1
        results.append({
            "user_id": user.id,
            "status": row.delivery_status,
            "harmony_delivered": sum(
                status == "accepted" for status, _, _ in harmony_results
            ),
            "web_delivered": web_delivered,
        })
    _audit(db, "notification.batch", None, f"users={len(users)},title={title[:40]}")
    db.commit()
    return {"code": 0, "message": "ok", "data": {
        "targeted": len(results),
        "results": results,
    }}


@router.post("/notifications/broadcast")
def send_broadcast_notification_api(
    data: AdminNotificationSendIn,
    _: AdminSession = Depends(_csrf),
    db: Session = Depends(get_db),
) -> dict:
    """Persist and synchronously deliver one notice per account."""
    title, body = data.title.strip(), data.body.strip()
    if not title or not body:
        raise HTTPException(status_code=422, detail={"code": 42230, "message": "标题和内容不能为空"})
    platform = (data.platform or "").strip().lower() or None
    silent = bool(data.silent)
    users = db.scalars(select(User).order_by(User.id)).all()
    android_results = []
    harmony_results = []
    web_delivered = 0
    for user in users:
        row = UserNotification(
            user_id=user.id, title=title, body=body,
            target_type="ALL",
            target_label=(
                "静默公告（仅收件箱）" if silent
                else f"全部账户{f'（仅{platform}）' if platform else ''}"
            ),
        )
        db.add(row)
        db.flush()
        if silent:
            # 静默：只落收件箱，跳过全部外部推送
            row.provider = "inbox"
            row.delivery_status = "stored"
            row.delivery_error = ""
            continue
        if platform != "web":
            android_result = _deliver_android(
                title=title, body=body, notification_id=row.id, user_id=user.id,
            )
            android_results.append(android_result)
            row.delivery_status, row.provider_message_id, row.delivery_error = android_result
        if platform != "android":
            # 走到这里却没回写状态的话，行会永远停在默认值 pending——线上就有
            # 182 条「仅网页版」广播因此被统计成「待投递」，看着像积压。
            own_subs = db.scalars(
                select(PushSubscription).where(PushSubscription.user_id == user.id)
            ).all()
            web_ok = 0
            for sub in own_subs:
                if _deliver_web_push(sub, title, body):
                    web_ok += 1
            web_delivered += web_ok
            if platform == "web":
                row.provider = "web_push"
                row.delivery_status = "accepted" if web_ok else "stored"
                row.delivery_error = ""

        harmony_devices = db.scalars(select(UserPushDevice).where(
            UserPushDevice.user_id == user.id,
            UserPushDevice.platform == "harmony",
            UserPushDevice.last_seen_at >= _native_device_cutoff(),
        )).all()
        account_harmony_results = _deliver_harmony_devices(
            db, list(harmony_devices), title=title, body=body,
            notification_id=row.id,
        )
        harmony_results.extend(account_harmony_results)
        accepted_harmony = next(
            (result for result in account_harmony_results if result[0] == "accepted"),
            None,
        )
        if row.delivery_status != "accepted" and accepted_harmony:
            row.provider = "hms"
            row.delivery_status = "accepted"
            row.provider_message_id = accepted_harmony[1]
            row.delivery_error = ""

    if silent:
        web_total = db.scalar(select(func.count()).select_from(PushSubscription)) or 0
        _audit(db, "notification.broadcast", None,
               f"silent=1,users={len(users)},title={title[:40]}")
        db.commit()
        return {"code": 0, "message": "ok", "data": {
            "users": len(users),
            "silent": True,
            "android_status": "skipped",
            "harmony_delivered": 0,
            "harmony_total": 0,
            "web_delivered": 0,
            "web_total": web_total,
            "provider_message_id": "",
            "android_error": "",
        }}

    accepted_android = next(
        (result for result in android_results if result[0] == "accepted"), None
    )
    if accepted_android:
        android_status, provider_id, android_error = "accepted", accepted_android[1], ""
    elif android_results and all(result[0] == "stored" for result in android_results):
        android_status, provider_id = "stored", ""
        android_error = next((result[2] for result in android_results if result[2]), "")
    elif android_results:
        android_status, provider_id = "failed", ""
        android_error = next((result[2] for result in android_results if result[2]), "")
    else:
        android_status, provider_id, android_error = "stored", "", "无用户"

    harmony_delivered = sum(
        status == "accepted" for status, _, _ in harmony_results
    )
    web_total = db.scalar(select(func.count()).select_from(PushSubscription)) or 0
    _audit(db, "notification.broadcast", None, f"users={len(users)},title={title[:40]}")
    db.commit()
    return {"code": 0, "message": "ok", "data": {
        "users": len(users),
        "android_status": android_status,
        "harmony_delivered": harmony_delivered,
        "harmony_total": len(harmony_results),
        "web_delivered": web_delivered,
        "web_total": web_total,
        "provider_message_id": provider_id,
        "android_error": android_error,
    }}


@router.get("/users/{user_id}/notifications")
def user_notifications(
    user_id: int,
    limit: int = Query(default=20, ge=1, le=100),
    _: AdminSession = Depends(_session),
    db: Session = Depends(get_db),
) -> dict:
    _user_or_404(db, user_id)
    rows = db.scalars(select(UserNotification).where(
        UserNotification.user_id == user_id
    ).order_by(UserNotification.id.desc()).limit(limit)).all()
    return {"code": 0, "message": "ok", "data": [{
        "id": row.id, "title": row.title, "body": row.body,
        "status": row.delivery_status,
        "target_type": row.target_type, "target_label": row.target_label,
        "published_at": _utc_iso(row.published_at),
        "read_at": _utc_iso(row.read_at),
    } for row in rows]}


@router.get("/users/{user_id}/devices")
def user_push_devices(
    user_id: int,
    _: AdminSession = Depends(_session),
    db: Session = Depends(get_db),
) -> dict:
    _user_or_404(db, user_id)
    rows = db.scalars(select(UserPushDevice).where(
        UserPushDevice.user_id == user_id,
        UserPushDevice.last_seen_at >= _native_device_cutoff(),
    ).order_by(UserPushDevice.last_seen_at.desc(), UserPushDevice.id.desc())).all()
    devices = [{
        "device_id": row.device_id,
        "label": row.label,
        "platform": row.platform,
        "app_version": row.app_version,
        "last_seen_at": _utc_iso(row.last_seen_at),
    } for row in rows]
    subs = db.scalars(select(PushSubscription).where(
        PushSubscription.user_id == user_id
    ).order_by(PushSubscription.id.desc())).all()
    for sub in subs:
        seen = sub.last_success_at or sub.created_at
        devices.append({
            "device_id": f"web:{sub.id}",
            "label": "网页端（PWA · iPhone/浏览器）",
            "platform": "web",
            "app_version": None,
            "last_seen_at": _utc_iso(seen),
        })
    return {"code": 0, "message": "ok", "data": devices}


@router.patch("/users/{user_id}")
def update_user(
    user_id: int,
    data: AdminUserUpdateIn,
    _: AdminSession = Depends(_csrf),
    db: Session = Depends(get_db),
) -> dict:
    user = _user_or_404(db, user_id)
    conflict = db.scalar(select(User).where(User.id != user_id, or_(User.username == data.username, User.email == str(data.email))))
    if conflict:
        raise HTTPException(status_code=409, detail={"code": 40910, "message": "用户名或邮箱已被占用"})
    before = f"username={user.username},email={user.email}"
    user.username = data.username
    user.email = str(data.email)
    _audit(db, "user.update", user_id, before)
    db.commit()
    return {"code": 0, "message": "ok", "data": {"updated": True}}


@router.delete("/users/{user_id}/sync-data")
def clear_sync_data(
    user_id: int,
    data: AdminConfirmIn,
    _: AdminSession = Depends(_csrf),
    db: Session = Depends(get_db),
) -> dict:
    user = _user_or_404(db, user_id)
    if not secrets.compare_digest(data.confirm, user.username):
        raise HTTPException(status_code=400, detail={"code": 40010, "message": "确认文字与用户名不一致"})
    counts = {}
    for model, name in ((SyncSchedule, "schedules"), (SyncCourse, "courses"), (SyncSemester, "semesters")):
        result = db.execute(delete(model).where(model.user_id == user_id))
        counts[name] = result.rowcount or 0
    _audit(db, "user.sync_data.clear", user_id, str(counts))
    db.commit()
    return {"code": 0, "message": "ok", "data": counts}


@router.delete("/users/{user_id}/credential-vault")
def clear_credential_vault(
    user_id: int,
    data: AdminConfirmIn,
    _: AdminSession = Depends(_csrf),
    db: Session = Depends(get_db),
) -> dict:
    user = _user_or_404(db, user_id)
    if not secrets.compare_digest(data.confirm, user.username):
        raise HTTPException(status_code=400, detail={"code": 40010, "message": "确认文字与用户名不一致"})
    row = db.scalar(select(CredentialVault).where(CredentialVault.user_id == user_id))
    if row is not None:
        db.delete(row)
    _audit(db, "user.credential_vault.clear", user_id, "client-encrypted blob deleted")
    db.commit()
    return {"code": 0, "message": "ok", "data": {"deleted": row is not None}}


@router.delete("/users/{user_id}")
def delete_user_permanently(
    user_id: int,
    data: AdminConfirmIn,
    _: AdminSession = Depends(_csrf),
    db: Session = Depends(get_db),
) -> dict:
    """Permanently remove one account and all owned data after exact confirmation."""
    user = _user_or_404(db, user_id)
    if not secrets.compare_digest(data.confirm, user.username):
        raise HTTPException(
            status_code=400,
            detail={"code": 40010, "message": "确认文字与用户名不一致"},
        )

    username = user.username
    email = user.email
    counts: dict[str, int] = {}

    # push_deliveries 以订阅为键，必须先于订阅清理按子查询删除
    subscription_ids = select(PushSubscription.id).where(
        PushSubscription.user_id == user_id
    )
    delivery = db.execute(
        delete(PushDelivery).where(
            PushDelivery.subscription_id.in_(subscription_ids)
        )
    )
    counts["push_deliveries"] = delivery.rowcount or 0

    # 通用 sweep：凡带 user_id / owner_user_id / email 的表一律清掉该账号的行。
    # 不再逐表登记——2026-11-01 曾因固定清单没跟上新增表（client_versions、
    # import_events、daily_activity、onboarding_reminders 等）导致「注销」后
    # 数据仍残留、账号仍能被找回密码流程命中。
    inspector = sa_inspect(db.connection())
    for table_name in inspector.get_table_names():
        if table_name in {"users", "admin_audit_logs"}:
            continue
        columns = {
            column["name"] for column in inspector.get_columns(table_name)
        }
        if "user_id" in columns:
            key, value = "user_id", user_id
        elif "owner_user_id" in columns:
            key, value = "owner_user_id", user_id
        elif "email" in columns:
            key, value = "email", email
        else:
            continue
        result = db.execute(
            text(f"DELETE FROM {table_name} WHERE {key} = :v"), {"v": value}
        )
        if result.rowcount:
            counts[table_name] = result.rowcount

    # SQLite deployments may not enforce ON DELETE SET NULL. Preserve older
    # audit rows explicitly, then create a deletion audit without an FK target.
    prior_audits = db.scalars(
        select(AdminAuditLog).where(AdminAuditLog.target_user_id == user_id)
    ).all()
    for audit_row in prior_audits:
        audit_row.target_user_id = None
    db.delete(user)
    _audit(
        db,
        "user.delete",
        detail=f"deleted_user_id={user_id},username={username},counts={counts}",
    )
    db.commit()
    return {"code": 0, "message": "ok", "data": {"deleted": True, "counts": counts}}


@router.get("/about")
def admin_get_about(
    _: AdminSession = Depends(_session),
    db: Session = Depends(get_db),
) -> dict:
    row = _about_row(db)
    db.commit()
    db.refresh(row)
    return {"code": 0, "message": "ok", "data": _about_data(row)}


@router.patch("/about")
def admin_update_about(
    data: AdminAboutUpdateIn,
    _: AdminSession = Depends(_csrf),
    db: Session = Depends(get_db),
) -> dict:
    row = _about_row(db)
    row.display_name = data.display_name
    # 仅在请求显式携带字段时覆盖，防止旧版前端不带字段把已展示内容静默清空
    if "icp_beian" in data.model_fields_set:
        row.icp_beian = data.icp_beian
    if "intro" in data.model_fields_set:
        row.intro = data.intro
    if "website_url" in data.model_fields_set:
        row.website_url = data.website_url
    _audit(db, "about.update", detail=f"display_name={data.display_name}")
    db.commit()
    db.refresh(row)
    return {"code": 0, "message": "ok", "data": _about_data(row)}


@router.post("/about/media/{kind}")
async def admin_upload_about_media(
    kind: str,
    upload: UploadFile = File(...),
    _: AdminSession = Depends(_csrf),
    db: Session = Depends(get_db),
) -> dict:
    if kind not in {"avatar", "payment_qr"}:
        raise HTTPException(status_code=404, detail={"code": 40421, "message": "图片类型不存在"})
    data = await upload.read(MAX_MEDIA_BYTES + 1)
    if not data:
        raise HTTPException(status_code=400, detail={"code": 40021, "message": "请选择图片"})
    if len(data) > MAX_MEDIA_BYTES:
        raise HTTPException(status_code=413, detail={"code": 41320, "message": "图片不能超过 5MB"})
    extension = detect_extension(data)
    name = persist_media(data, extension)
    row = _about_row(db)
    if kind == "avatar":
        row.avatar_media = name
    else:
        row.payment_qr_media = name
    _audit(db, "about.media.update", detail=f"kind={kind},name={name}")
    db.commit()
    db.refresh(row)
    return {"code": 0, "message": "ok", "data": _about_data(row)}


@router.get("/audit")
def audit(
    limit: int = Query(default=50, ge=1, le=200),
    _: AdminSession = Depends(_session),
    db: Session = Depends(get_db),
) -> dict:
    rows = db.scalars(select(AdminAuditLog).order_by(AdminAuditLog.id.desc()).limit(limit)).all()
    return {"code": 0, "message": "ok", "data": [{
        "id": row.id, "action": row.action, "target_user_id": row.target_user_id,
        "detail": row.detail, "created_at": _utc_iso(row.created_at),
    } for row in rows]}

@router.get("/stats/overview")
def stats_overview(
    _: AdminSession = Depends(_session),
    db: Session = Depends(get_db),
) -> dict:
    from datetime import date, timedelta
    from sqlalchemy import func as sqla_func
    from app.models.daily_activity import DailyActivity

    today = date.today()
    yesterday = today - timedelta(days=1)
    week_ago = today - timedelta(days=6)
    month_ago = today - timedelta(days=29)

    def dau_of(d) -> int:
        return db.scalar(
            select(sqla_func.count(sqla_func.distinct(DailyActivity.user_id)))
            .where(DailyActivity.activity_date == d)
        ) or 0

    def range_count(from_date, to_date) -> int:
        return db.scalar(
            select(sqla_func.count(sqla_func.distinct(DailyActivity.user_id)))
            .where(DailyActivity.activity_date >= from_date, DailyActivity.activity_date <= to_date)
        ) or 0

    return {"code": 0, "message": "ok", "data": {
        "today_dau": dau_of(today),
        "yesterday_dau": dau_of(yesterday),
        "wau": range_count(week_ago, today),
        "mau": range_count(month_ago, today),
        "total_users": db.scalar(select(sqla_func.count()).select_from(User)) or 0,
        # ---- 增长与规模（管理后台 v3 数据看板扩展） ----
        "today_new_users": db.scalar(
            select(sqla_func.count()).select_from(User).where(sqla_func.date(User.created_at) == today.isoformat())
        ) or 0,
        "week_new_users": db.scalar(
            select(sqla_func.count()).select_from(User).where(sqla_func.date(User.created_at) >= week_ago.isoformat())
        ) or 0,
        "total_semesters": db.scalar(select(sqla_func.count()).select_from(SyncSemester).where(SyncSemester.deleted.is_(False))) or 0,
        "total_courses": db.scalar(select(sqla_func.count()).select_from(SyncCourse).where(SyncCourse.deleted.is_(False))) or 0,
        "total_schedules": db.scalar(select(sqla_func.count()).select_from(SyncSchedule).where(SyncSchedule.deleted.is_(False))) or 0,
        "native_devices": db.scalar(select(sqla_func.count()).select_from(UserPushDevice)) or 0,
        "web_subscriptions": db.scalar(select(sqla_func.count()).select_from(PushSubscription)) or 0,
        "total_notifications": db.scalar(select(sqla_func.count()).select_from(UserNotification)) or 0,
        "today_notifications": db.scalar(
            select(sqla_func.count()).select_from(UserNotification).where(sqla_func.date(UserNotification.created_at) == today.isoformat())
        ) or 0,
        "couple_memberships": db.scalar(select(sqla_func.count()).select_from(CoupleMembership)) or 0,
    }}


@router.get("/stats/dau-series")
def stats_dau_series(
    days: int = Query(30, ge=7, le=90),
    _: AdminSession = Depends(_session),
    db: Session = Depends(get_db),
) -> dict:
    from datetime import date, timedelta
    from app.models.daily_activity import DailyActivity
    from sqlalchemy import func as sqla_func

    today = date.today()
    start = today - timedelta(days=days - 1)
    rows = db.execute(
        select(
            DailyActivity.activity_date,
            sqla_func.count(sqla_func.distinct(DailyActivity.user_id)).label("dau"),
        )
        .where(DailyActivity.activity_date >= start)
        .group_by(DailyActivity.activity_date)
        .order_by(DailyActivity.activity_date)
    ).all()
    counts = {row[0].isoformat(): row[1] for row in rows}
    series = []
    for i in range(days):
        d = start + timedelta(days=i)
        series.append({"date": d.isoformat(), "dau": counts.get(d.isoformat(), 0)})
    return {"code": 0, "message": "ok", "data": series}


@router.get("/stats/growth-series")
def stats_growth_series(
    days: int = Query(30, ge=7, le=90),
    _: AdminSession = Depends(_session),
    db: Session = Depends(get_db),
) -> dict:
    """每日新增注册（管理后台 v3 数据看板）。"""
    from datetime import date, timedelta
    today = date.today()
    start = today - timedelta(days=days - 1)
    rows = db.execute(
        select(func.date(User.created_at).label("d"), func.count().label("cnt"))
        .where(func.date(User.created_at) >= start.isoformat())
        .group_by(func.date(User.created_at))
        .order_by(func.date(User.created_at))
    ).all()
    counts = {str(row[0]): row[1] for row in rows}
    series = []
    for i in range(days):
        d = start + timedelta(days=i)
        series.append({"date": d.isoformat(), "count": counts.get(d.isoformat(), 0)})
    return {"code": 0, "message": "ok", "data": series}


@router.get("/stats/platforms")
def stats_platforms(
    _: AdminSession = Depends(_session),
    db: Session = Depends(get_db),
) -> dict:
    """设备平台分布 + 通知投递状态分布 + 新人引导提醒发送量。"""
    devices = {row[0]: row[1] for row in db.execute(
        select(UserPushDevice.platform, func.count()).group_by(UserPushDevice.platform)
    ).all()}
    status = {row[0]: row[1] for row in db.execute(
        select(UserNotification.delivery_status, func.count()).group_by(UserNotification.delivery_status)
    ).all()}
    from app.models.onboarding_reminder import OnboardingReminder
    return {"code": 0, "message": "ok", "data": {
        "devices": devices,
        "web_subscriptions": db.scalar(select(func.count()).select_from(PushSubscription)) or 0,
        "notification_status": status,
        "onboarding_reminders": db.scalar(select(func.count()).select_from(OnboardingReminder)) or 0,
    }}


@router.get("/stats/import-funnel")
def stats_import_funnel(
    days: int = Query(30, ge=7, le=180),
    _: AdminSession = Depends(_session),
    db: Session = Depends(get_db),
) -> dict:
    """指标 1：首次导入成功率（注册后 7 天内产出首份有效课表视为成功）。

    成功判定（满足任一）：
    a) import_events 出现 outcome=success 且 stage=save/apply 的事件（客户端归因）；
    b) 兜底：sync_courses 首次出现 ≥1 门未删除课程（覆盖手动建课与旧客户端）。
    归因入口 = 该用户首个成功事件的 entry；b 类归因记为 manual。
    """
    now = datetime.now(timezone.utc).replace(tzinfo=None)
    cutoff = now - timedelta(days=days)
    new_users = db.scalars(select(User).where(User.created_at >= cutoff)).all()
    deadlines = {u.id: (u.created_at or now) + timedelta(days=7) for u in new_users}
    user_ids = list(deadlines)
    attribution: dict[str, int] = {}
    success_ids: set[int] = set()
    attempted = 0
    if user_ids:
        # 口径必须与下面的成功判定一致（成功那条用了 import_events + sync_courses
        # 兜底）。这里若只数 import_events，埋点刚上线时会得到「成功 67 > 有导入
        # 行为 6」这种自相矛盾的漏斗。
        attempted_ids = set(db.scalars(
            select(ImportEvent.user_id).where(
                ImportEvent.user_id.in_(user_ids),
                ImportEvent.created_at >= cutoff,
            )
        ))
        attempted_ids |= set(db.scalars(
            select(SyncCourse.user_id).where(
                SyncCourse.user_id.in_(user_ids), SyncCourse.deleted.is_(False),
            )
        ))
        attempted = len(attempted_ids)
        # 每用户首个 save/apply 成功事件（按时间升序取第一条）
        event_rows = db.execute(
            select(ImportEvent.user_id, ImportEvent.entry, ImportEvent.created_at)
            .where(
                ImportEvent.user_id.in_(user_ids),
                ImportEvent.outcome == "success",
                ImportEvent.stage.in_(("save", "apply")),
            )
            .order_by(ImportEvent.user_id, ImportEvent.created_at)
        ).all()
        for uid, entry, created in event_rows:
            if uid in success_ids:
                continue
            if created is not None and created <= deadlines[uid]:
                success_ids.add(uid)
                attribution[entry] = attribution.get(entry, 0) + 1
        # 兜底口径：sync_courses 首门未删除课程的入库时间
        course_rows = db.execute(
            select(SyncCourse.user_id, func.min(SyncCourse.synced_at))
            .where(SyncCourse.user_id.in_(user_ids), SyncCourse.deleted.is_(False))
            .group_by(SyncCourse.user_id)
        ).all()
        for uid, first_ns in course_rows:
            if uid in success_ids or not first_ns:
                continue
            first_at = datetime.fromtimestamp(first_ns / 1e9)
            if first_at <= deadlines[uid]:
                success_ids.add(uid)
                attribution["manual"] = attribution.get("manual", 0) + 1
    total = len(user_ids)
    partial = sum(1 for u in new_users if now < (u.created_at or now) + timedelta(days=7))
    return {"code": 0, "message": "ok", "data": {
        "days": days,
        "window_days": 7,
        "new_users": total,
        "partial_users": partial,
        "attempted_users": attempted,
        "success_users": len(success_ids),
        "success_rate": round(len(success_ids) / total, 4) if total else 0,
        "attribution": attribution,
    }}


@router.get("/stats/import-failures")
def stats_import_failures(
    days: int = Query(30, ge=1, le=180),
    entry: str = Query("", max_length=16),
    _: AdminSession = Depends(_session),
    db: Session = Depends(get_db),
) -> dict:
    """指标 2：近 N 天 入口 × 阶段 × 错误码 的失败/放弃事件分布。"""
    now = datetime.now(timezone.utc).replace(tzinfo=None)
    cutoff = now - timedelta(days=days)
    base_filter = (
        ImportEvent.created_at >= cutoff,
        ImportEvent.outcome.in_(("fail", "abandon")),
    )
    totals = {
        row[0]: row[1]
        for row in db.execute(
            select(ImportEvent.entry, func.count()).where(*base_filter).group_by(ImportEvent.entry)
        ).all()
    }
    stmt = (
        select(
            ImportEvent.entry, ImportEvent.stage, ImportEvent.error_code,
            ImportEvent.outcome, func.count(),
            # 带上时间：否则昨天的旧记录和刚才的新记录在面板上长得一模一样，
            # 会被当成「又出现新失败了」（实际发生过一次误判）。
            func.min(ImportEvent.created_at), func.max(ImportEvent.created_at),
        )
        .where(*base_filter)
        .group_by(ImportEvent.entry, ImportEvent.stage, ImportEvent.error_code, ImportEvent.outcome)
        .order_by(func.count().desc())
    )
    if entry:
        stmt = stmt.where(ImportEvent.entry == entry)
    rows = [
        {
            "entry": r[0], "stage": r[1], "error_code": r[2], "outcome": r[3],
            "count": r[4], "first_at": _utc_iso(r[5]), "last_at": _utc_iso(r[6]),
        }
        for r in db.execute(stmt).all()
    ]
    return {"code": 0, "message": "ok", "data": {
        "days": days,
        "entry": entry,
        "totals_by_entry": totals,
        "rows": rows,
    }}


@router.get("/stats/retention-cohorts")
def stats_retention_cohorts(
    weeks: int = Query(8, ge=2, le=26),
    _: AdminSession = Depends(_session),
    db: Session = Depends(get_db),
) -> dict:
    """指标 3：按 ISO 周建队列的次周回访率。

    W 周注册的用户，W+1 周内 daily_activity 有 ≥1 天记录记为留存。
    W+1 尚未走完的队列标记 partial。周界用 UTC（与 users.created_at 一致）；
    daily_activity.activity_date 为服务器本地日期，边界上最多差一天，可接受。
    """
    from datetime import date as dt_date

    today = dt_date.today()
    this_monday = today - timedelta(days=today.weekday())
    earliest = this_monday - timedelta(weeks=weeks - 1)
    earliest_dt = datetime.combine(earliest, datetime.min.time())
    users = db.scalars(select(User).where(User.created_at >= earliest_dt)).all()
    cohort_of: dict[int, str] = {}
    for user in users:
        if user.created_at is None:
            continue
        d = user.created_at.date()
        monday = d - timedelta(days=d.weekday())
        cohort_of[user.id] = monday.isoformat()
    activity_rows = db.execute(
        select(DailyActivity.user_id, DailyActivity.activity_date)
        .where(DailyActivity.user_id.in_(list(cohort_of) or [0]))
    ).all()
    active_dates: dict[int, set] = {}
    for uid, adate in activity_rows:
        active_dates.setdefault(uid, set()).add(adate)

    cohorts = []
    for i in range(weeks):
        week_start = earliest + timedelta(weeks=i)
        week_end = week_start + timedelta(days=7)
        next_end = week_start + timedelta(days=14)
        members = [uid for uid, ws in cohort_of.items() if ws == week_start.isoformat()]
        retained = 0
        for uid in members:
            days_active = active_dates.get(uid, set())
            if any(week_end <= d < next_end for d in days_active):
                retained += 1
        cohorts.append({
            "week_start": week_start.isoformat(),
            "new_users": len(members),
            "retained_w1": retained,
            "rate_w1": round(retained / len(members), 4) if members else 0,
            "partial": today < next_end,
        })
    return {"code": 0, "message": "ok", "data": cohorts}


@router.get("/stats/reminder-health")
def stats_reminder_health(
    days: int = Query(30, ge=7, le=180),
    _: AdminSession = Depends(_session),
    db: Session = Depends(get_db),
) -> dict:
    """指标 4：提醒链路状态（客户端权限/排程上报）+ 账户通知送达分布。

    送达口径：accepted=阿里云网关受理；阿里云不回调真实到设备送达，
    统计到此为止，不虚构「已送达」。
    """
    now = datetime.now(timezone.utc).replace(tzinfo=None)
    cutoff = now - timedelta(days=days)
    rows = db.scalars(select(ReminderStatus)).all()
    total = len(rows)
    notif_on = sum(1 for r in rows if r.notif_permission)
    exact_known = [r for r in rows if r.exact_alarm is not None]
    exact_on = sum(1 for r in exact_known if r.exact_alarm)
    count_buckets = {"0": 0, "1_10": 0, "11_50": 0, "gt50": 0}
    recency = {"lt1d": 0, "d1_7": 0, "gt7d": 0}
    for r in rows:
        n = r.scheduled_count or 0
        count_buckets["0" if n == 0 else "1_10" if n <= 10 else "11_50" if n <= 50 else "gt50"] += 1
        age = now - r.updated_at if r.updated_at else timedelta(days=9999)
        recency["lt1d" if age < timedelta(days=1) else "d1_7" if age < timedelta(days=7) else "gt7d"] += 1

    delivery = {
        row[0]: row[1]
        for row in db.execute(
            select(UserNotification.delivery_status, func.count())
            .where(UserNotification.created_at >= cutoff)
            .group_by(UserNotification.delivery_status)
        ).all()
    }
    trend_rows = db.execute(
        select(func.date(UserNotification.created_at), UserNotification.delivery_status, func.count())
        .where(UserNotification.created_at >= cutoff)
        .group_by(func.date(UserNotification.created_at), UserNotification.delivery_status)
        .order_by(func.date(UserNotification.created_at))
    ).all()
    trend: dict[str, dict[str, int]] = {}
    for d, status, cnt in trend_rows:
        day = trend.setdefault(str(d), {"accepted": 0, "stored": 0, "failed": 0, "pending": 0})
        day[str(status)] = day.get(str(status), 0) + cnt
    return {"code": 0, "message": "ok", "data": {
        "days": days,
        "reported_devices": total,
        "notif_permission_on": notif_on,
        "notif_permission_rate": round(notif_on / total, 4) if total else 0,
        "exact_alarm_known": len(exact_known),
        "exact_alarm_on": exact_on,
        "exact_alarm_rate": round(exact_on / len(exact_known), 4) if exact_known else 0,
        "scheduled_count_buckets": count_buckets,
        "report_recency": recency,
        "delivery_status": delivery,
        "delivery_trend": [{"date": d, **counts} for d, counts in trend.items()],
    }}


@router.get("/stats/system")
def stats_system(_: AdminSession = Depends(_session)) -> dict:
    import os
    db_size_mb = 0
    try:
        db_size_mb = round(Path("/data/yzu_schedule.db").stat().st_size / 1024 / 1024, 1)
    except Exception:
        pass
    mem_total = mem_avail = 0
    try:
        for line in Path("/proc/meminfo").read_text().splitlines():
            if line.startswith("MemTotal:"):
                mem_total = int(line.split()[1]) // 1024
            elif line.startswith("MemAvailable:"):
                mem_avail = int(line.split()[1]) // 1024
    except Exception:
        pass
    load = [0.0, 0.0, 0.0]
    try:
        load = [float(x) for x in Path("/proc/loadavg").read_text().split()[:3]]
    except Exception:
        pass
    disk_total = disk_used = 0
    try:
        st = os.statvfs("/")
        disk_total = st.f_blocks * st.f_frsize // (1024 ** 3)
        disk_used = (st.f_blocks - st.f_bfree) * st.f_frsize // (1024 ** 3)
    except Exception:
        pass
    return {"code": 0, "message": "ok", "data": {
        "mem_total_mb": mem_total,
        "mem_used_mb": mem_total - mem_avail,
        "load_avg": load,
        "disk_total_gb": disk_total,
        "disk_used_gb": disk_used,
        "db_size_mb": db_size_mb,
    }}

# ==================== 版本发布管理（统一标准：定向测试=有目标账号，正式=无） ====================


@router.get("/stats/client-versions")
def stats_client_versions(
    _: AdminSession = Depends(_session),
    db: Session = Depends(get_db),
) -> dict:
    """客户端版本分布 + 落后用户名单（含邮箱，供人工催更）。

    版本来源与 [outdated_user_ids][app.services.version_release.outdated_user_ids]
    完全一致，保证「看板里看到的」就是「催更会发到的」同一批人。
    """
    from app.models.client_version import ClientVersion
    from app.services.version_release import (
        _parse_app_version_code,
        outdated_user_ids,
    )

    latest = db.scalar(
        select(AppVersion)
        .where(~exists(
            select(AppVersionTarget.id).where(AppVersionTarget.version_id == AppVersion.id)
        ))
        .order_by(AppVersion.version_code.desc())
    )
    latest_code = latest.version_code if latest else 0

    # 每账号取两处来源的最大值；同时记下来源，便于排查数据可信度
    codes: dict[int, int] = {}
    sources: dict[int, str] = {}
    for user_id, code in db.execute(
        select(ClientVersion.user_id, ClientVersion.current_code)
    ).all():
        code = int(code)
        if code > codes.get(user_id, 0):
            codes[user_id] = code
            sources[user_id] = 'version/latest'
    for user_id, raw in db.execute(
        select(UserPushDevice.user_id, UserPushDevice.app_version)
    ).all():
        code = _parse_app_version_code(raw)
        if code > codes.get(user_id, 0):
            codes[user_id] = code
            sources[user_id] = 'push_device'

    total_users = db.scalar(select(func.count()).select_from(User)) or 0
    distribution: dict[str, int] = {}
    for code in codes.values():
        key = str(code)
        distribution[key] = distribution.get(key, 0) + 1

    outdated_ids = outdated_user_ids(db, latest_code) if latest_code else []
    outdated: list[dict] = []
    for user_id in outdated_ids:
        user = db.get(User, user_id)
        if user is None:
            continue
        outdated.append({
            'user_id': user_id,
            'username': user.username,
            'email': user.email,
            'current_code': codes.get(user_id, 0),
            'source': sources.get(user_id, ''),
        })
    outdated.sort(key=lambda item: item['current_code'])

    return {"code": 0, "message": "ok", "data": {
        'latest': {
            'id': latest.id if latest else 0,
            'version_name': latest.version_name if latest else '',
            'version_code': latest_code,
        },
        'total_users': total_users,
        'tracked_users': len(codes),
        'untracked_users': max(total_users - len(codes), 0),
        'distribution': dict(sorted(distribution.items(), key=lambda kv: int(kv[0]))),
        'outdated_count': len(outdated),
        'outdated': outdated,
    }}


@router.post("/versions/{version_id}/notify-outdated")
def admin_notify_outdated(
    version_id: int,
    _: AdminSession = Depends(_csrf),
    db: Session = Depends(get_db),
) -> dict:
    """一键只给「版本落后」的账号发更新提醒（不含内测名单）。"""
    from app.services.version_release import notify_outdated_users

    version = db.get(AppVersion, version_id)
    if version is None:
        raise HTTPException(status_code=404, detail={"code": 40410, "message": "版本不存在"})
    statuses = notify_outdated_users(db, version)
    return {"code": 0, "message": "ok", "data": {
        'version_name': version.version_name,
        'version_code': version.version_code,
        'sent': statuses,
    }}


@router.get("/versions")
def admin_versions(
    limit: int = Query(default=20, ge=1, le=100),
    _: AdminSession = Depends(_session),
    db: Session = Depends(get_db),
) -> dict:
    """版本列表（新→旧），含每个版本的定向账号。"""
    rows = db.scalars(
        select(AppVersion).order_by(AppVersion.id.desc()).limit(limit)
    ).all()
    targets = db.execute(
        select(AppVersionTarget.version_id, AppVersionTarget.user_id, User.username)
        .join(User, User.id == AppVersionTarget.user_id)
        .where(AppVersionTarget.version_id.in_([r.id for r in rows] or [0]))
    ).all()
    by_version: dict[int, list[dict]] = {}
    for vid, uid, username in targets:
        by_version.setdefault(vid, []).append({"user_id": uid, "username": username})
    data = [{
        "id": row.id,
        "version_name": row.version_name,
        "version_code": row.version_code,
        "apk_url": row.apk_url,
        "sha256": row.sha256,
        "release_notes": row.release_notes,
        "is_force_update": row.is_force_update,
        "force_codes": row.force_codes or "",
        "published_at": _utc_iso(row.published_at),
        "channel": "targeted_test" if by_version.get(row.id) else "stable",
        "targets": by_version.get(row.id, []),
    } for row in rows]
    return {"code": 0, "message": "ok", "data": data}


@router.post("/versions")
def admin_publish_version(
    data: VersionPublishIn,
    _: AdminSession = Depends(_csrf),
    db: Session = Depends(get_db),
) -> dict:
    """发布新版本（与 X-Admin-Token 的 /api/admin/versions 同一套逻辑）。"""
    result = version_release.publish_version(db, data)
    _audit(db, "version.publish", None,
           f"code={data.version_code},channel={result['release_channel']},targets={result['target_user_ids']}")
    db.commit()
    return {"code": 0, "message": "ok", "data": result}


@router.post("/versions/{version_id}/targets")
def admin_add_version_target(
    version_id: int,
    data: AdminVersionTargetIn,
    _: AdminSession = Depends(_csrf),
    db: Session = Depends(get_db),
) -> dict:
    """给既有版本补定向账号（可选发送测试邀请通知）。"""
    version = db.get(AppVersion, version_id)
    if version is None:
        raise HTTPException(status_code=404, detail={"code": 40450, "message": "版本不存在"})
    users, missing = version_release._resolve_accounts(db, [data.account.strip()])
    if missing:
        raise HTTPException(
            status_code=422,
            detail={"code": 42241, "message": "测试账号不存在", "accounts": missing},
        )
    added = version_release.add_targets(db, version, users)
    statuses = (
        version_release.notify_users_of_version(db, version, added)
        if data.notify and added
        else []
    )
    _audit(db, "version.target.add", users[0].id,
           f"version_id={version_id},added={len(added)},notify={data.notify}")
    db.commit()
    return {"code": 0, "message": "ok", "data": {
        "added": [u.id for u in added],
        "already": [u.id for u in users if u not in added],
        "notifications": statuses,
    }}


@router.delete("/versions/{version_id}/targets/{user_id}")
def admin_remove_version_target(
    version_id: int,
    user_id: int,
    _: AdminSession = Depends(_csrf),
    db: Session = Depends(get_db),
) -> dict:
    """把账号移出某版本的定向名单（移出后该用户不再看到此版本）。"""
    removed = version_release.remove_target(db, version_id, user_id)
    if removed:
        _audit(db, "version.target.remove", user_id, f"version_id={version_id}")
        db.commit()
    return {"code": 0, "message": "ok", "data": {"removed": removed}}
