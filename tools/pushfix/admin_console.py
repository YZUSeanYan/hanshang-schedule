"""安全管理控制台 API：独立会话、CSRF、最小权限与审计。"""
import hashlib
import base64
import secrets
from datetime import datetime, timedelta, timezone

from fastapi import APIRouter, Cookie, Depends, File, Header, HTTPException, Query, Request, Response, UploadFile
from sqlalchemy import delete, func, or_, select
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
from app.models.user import User
from app.models.about_content import AboutContent
from app.models.credential_vault import CredentialVault
from app.models.notification import UserNotification, UserPushDevice
from app.schemas.admin import (
    AdminConfirmIn,
    AdminLoginIn,
    AdminUserUpdateIn,
    AdminNotificationSendIn,
    AdminNotificationBatchIn,
)
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
    data = [{
        "id": user.id,
        "username": user.username,
        "email": user.email,
        "created_at": _utc_iso(user.created_at),
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
    users = db.scalars(select(User).order_by(User.id)).all()
    android_results = []
    harmony_results = []
    for user in users:
        row = UserNotification(
            user_id=user.id, title=title, body=body,
            target_type="ALL", target_label="全部账户",
        )
        db.add(row)
        db.flush()
        android_result = _deliver_android(
            title=title, body=body, notification_id=row.id, user_id=user.id,
        )
        android_results.append(android_result)
        row.delivery_status, row.provider_message_id, row.delivery_error = android_result

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
    web_delivered = 0
    for sub in db.scalars(select(PushSubscription)).all():
        if _deliver_web_push(sub, title, body):
            web_delivered += 1
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
        "created_at": _utc_iso(row.created_at),
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

    subscription_ids = select(PushSubscription.id).where(
        PushSubscription.user_id == user_id
    )
    deletion_steps = (
        (PushDelivery, PushDelivery.subscription_id.in_(subscription_ids), "push_deliveries"),
        (PushSubscription, PushSubscription.user_id == user_id, "push_subscriptions"),
        (ShareCode, ShareCode.owner_user_id == user_id, "share_codes"),
        (SyncSchedule, SyncSchedule.user_id == user_id, "schedules"),
        (SyncCourse, SyncCourse.user_id == user_id, "courses"),
        (SyncSemester, SyncSemester.user_id == user_id, "semesters"),
        (CredentialVault, CredentialVault.user_id == user_id, "credential_vaults"),
        (RefreshTokenSession, RefreshTokenSession.user_id == user_id, "refresh_sessions"),
        (UserTokenState, UserTokenState.user_id == user_id, "token_states"),
        (EmailCode, EmailCode.email == email, "email_codes"),
        (UserRestriction, UserRestriction.user_id == user_id, "restrictions"),
        (UserNotification, UserNotification.user_id == user_id, "notifications"),
        (UserPushDevice, UserPushDevice.user_id == user_id, "push_devices"),
    )
    for model, condition, name in deletion_steps:
        result = db.execute(delete(model).where(condition))
        counts[name] = result.rowcount or 0

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
    row.icp_beian = data.icp_beian
    row.intro = data.intro
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
