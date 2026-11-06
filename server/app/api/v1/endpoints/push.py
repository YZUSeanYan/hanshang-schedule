"""Authenticated PWA Web Push subscription and explicit test notification."""
import json
from datetime import date, datetime, time, timedelta, timezone

from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy import select
from sqlalchemy.orm import Session
from starlette.concurrency import run_in_threadpool

from app.api.deps import get_current_user, require_admin
from app.core.config import get_settings
from app.core.ratelimit import RateLimiter
from app.db.session import get_db
from app.models.push_subscription import PushDelivery, PushSubscription
from app.models.reminder_status import ReminderStatus
from app.models.sync_data import SyncCourse, SyncSchedule, SyncSemester
from app.models.personal_event import SyncOverride
from app.models.user import User
from app.schemas.push import PushSubscriptionIn, PushUnsubscribeIn
from app.schemas.telemetry import ReminderStatusIn
from app.services.onboarding_reminder import dispatch_onboarding_reminders
from app.services.web_push import WebPushUnavailable, send_web_push

router = APIRouter(prefix="/push", tags=["PWA 通知"])
settings = get_settings()
# 提醒状态按用户限流：App 每次重排本地提醒后上报一次，30 次/天足够
_reminder_status_limiter = RateLimiter(30, 24 * 60 * 60)
_REMINDER_MINUTES = 15
_DISPATCH_WINDOW_MINUTES = 5
_HONG_KONG_TZ = timezone(timedelta(hours=8))
_SPRING_SUMMER_STARTS = ("08:00", "08:55", "09:55", "10:50", "11:45", "14:30", "15:25", "16:20", "17:15", "18:10", "19:30", "20:25")
_AUTUMN_WINTER_STARTS = ("08:00", "08:55", "09:55", "10:50", "11:45", "14:00", "14:55", "15:50", "16:45", "17:40", "19:00", "19:55")


@router.get("/public-key")
def public_key(_: User = Depends(get_current_user)) -> dict:
    if not settings.web_push_public_key:
        raise HTTPException(503, detail={"code": 50340, "message": "课程通知服务尚未配置"})
    return {"code": 0, "message": "ok", "data": {"public_key": settings.web_push_public_key}}


@router.post("/subscribe")
def subscribe(
    data: PushSubscriptionIn,
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> dict:
    endpoint = str(data.endpoint)
    record = db.scalar(select(PushSubscription).where(PushSubscription.endpoint == endpoint))
    if record is not None and record.user_id != user.id:
        raise HTTPException(409, detail={"code": 40940, "message": "该设备通知已绑定其他账号，请先在原账号关闭通知"})
    if record is None:
        record = PushSubscription(user_id=user.id, endpoint=endpoint, p256dh=data.keys.p256dh, auth=data.keys.auth)
        db.add(record)
    else:
        record.p256dh = data.keys.p256dh
        record.auth = data.keys.auth
    if "section_times" in data.model_fields_set:
        record.section_times = json.dumps(data.section_times or [])
    db.commit()
    return {"code": 0, "message": "ok", "data": {"subscribed": True}}


@router.delete("/subscribe")
def unsubscribe(
    data: PushUnsubscribeIn,
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> dict:
    record = db.scalar(
        select(PushSubscription).where(
            PushSubscription.user_id == user.id,
            PushSubscription.endpoint == str(data.endpoint),
        )
    )
    if record is not None:
        db.delete(record)
        db.commit()
    return {"code": 0, "message": "ok", "data": {"subscribed": False}}


@router.post("/test")
async def test_notification(
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> dict:
    record = db.scalar(
        select(PushSubscription)
        .where(PushSubscription.user_id == user.id)
        .order_by(PushSubscription.id.desc())
    )
    if record is None:
        raise HTTPException(404, detail={"code": 40440, "message": "当前账号还没有通知订阅"})
    try:
        await run_in_threadpool(
            send_web_push,
            endpoint=record.endpoint,
            p256dh=record.p256dh,
            auth=record.auth,
            payload={"title": "邗上课表通知已开启", "body": "系统推送通道测试成功。", "url": "/web/"},
            private_key=settings.web_push_private_key,
            subject=settings.web_push_subject,
        )
    except WebPushUnavailable as exc:
        raise HTTPException(503, detail={"code": 50340, "message": str(exc)}) from None
    except Exception:
        raise HTTPException(502, detail={"code": 50240, "message": "通知发送失败，请重新开启通知"}) from None
    record.last_success_at = datetime.now(timezone.utc).replace(tzinfo=None)
    db.commit()
    return {"code": 0, "message": "ok", "data": {"sent": True}}


def _now_hk() -> datetime:
    # Hong Kong has used UTC+08:00 year-round since 1979; fixed offset also
    # avoids depending on host tzdata inside minimal containers and Windows CI.
    return datetime.now(_HONG_KONG_TZ)


def _week_is_active(weeks_type: int, custom_weeks: str, week: int) -> bool:
    if weeks_type == 0:
        return True
    if weeks_type == 1:
        return week % 2 == 1
    if weeks_type == 2:
        return week % 2 == 0
    values: set[int] = set()
    for piece in custom_weeks.split(","):
        piece = piece.strip()
        if not piece:
            continue
        if "-" in piece:
            start, _, end = piece.partition("-")
            if start.isdigit() and end.isdigit():
                values.update(range(int(start), int(end) + 1))
        elif piece.isdigit():
            values.add(int(piece))
    return week in values


def _class_start(day: date, section: int, custom: str = "[]") -> datetime | None:
    starts = _SPRING_SUMMER_STARTS if 5 <= day.month <= 9 else _AUTUMN_WINTER_STARTS
    try:
        times = json.loads(custom)
        if times:
            PushSubscriptionIn.valid_times(times)
            if len(times) == 12:
                starts = tuple(pair[0] for pair in times)
    except (ValueError, TypeError, IndexError):
        pass
    if not 1 <= section <= len(starts):
        return None
    hour, minute = (int(value) for value in starts[section - 1].split(":"))
    return datetime.combine(day, time(hour, minute), tzinfo=_HONG_KONG_TZ)


async def _dispatch_due(db: Session, now: datetime) -> int:
    window_start = now - timedelta(minutes=_DISPATCH_WINDOW_MINUTES)
    sent = 0
    subscriptions = db.scalars(select(PushSubscription)).all()
    for subscription in subscriptions:
        # 调休覆盖：放假（off）当天不提醒任何课程；补课（makeup）按指定星期的课表提醒。
        # 语义与 App 端 effectiveWeekday() 一致（override_repository.dart）。
        today_iso = now.date().isoformat()
        overrides = db.scalars(
            select(SyncOverride).where(
                SyncOverride.user_id == subscription.user_id,
                SyncOverride.date == today_iso,
                SyncOverride.deleted.is_(False),
            )
        ).all()
        if any(row.kind == "off" for row in overrides):
            continue
        makeup_weekday = next(
            (row.weekday for row in overrides if row.kind == "makeup" and 1 <= row.weekday <= 7),
            0,
        )
        effective_weekday = makeup_weekday or now.isoweekday()
        semesters = db.scalars(
            select(SyncSemester).where(
                SyncSemester.user_id == subscription.user_id,
                SyncSemester.is_current.is_(True),
                SyncSemester.deleted.is_(False),
            )
        ).all()
        for semester in semesters:
            semester_start = date.fromisoformat(semester.start_date)
            week = (now.date() - semester_start).days // 7 + 1
            if week < 1 or week > semester.total_weeks:
                continue
            courses = db.scalars(
                select(SyncCourse).where(
                    SyncCourse.user_id == subscription.user_id,
                    SyncCourse.semester_uuid == semester.uuid,
                    SyncCourse.deleted.is_(False),
                )
            ).all()
            courses_by_uuid = {course.uuid: course for course in courses}
            if not courses_by_uuid:
                continue
            schedules = db.scalars(
                select(SyncSchedule).where(
                    SyncSchedule.user_id == subscription.user_id,
                    SyncSchedule.course_uuid.in_(courses_by_uuid),
                    SyncSchedule.day_of_week == effective_weekday,
                    SyncSchedule.deleted.is_(False),
                )
            ).all()
            for schedule in schedules:
                if not _week_is_active(schedule.weeks_type, schedule.custom_weeks, week):
                    continue
                class_start = _class_start(now.date(), schedule.start_section, subscription.section_times)
                if class_start is None:
                    continue
                reminder_at = class_start - timedelta(minutes=_REMINDER_MINUTES)
                if not window_start < reminder_at <= now:
                    continue
                exists = db.scalar(
                    select(PushDelivery.id).where(
                        PushDelivery.subscription_id == subscription.id,
                        PushDelivery.schedule_uuid == schedule.uuid,
                        PushDelivery.class_date == now.date().isoformat(),
                        PushDelivery.reminder_minutes == _REMINDER_MINUTES,
                    )
                )
                if exists is not None:
                    continue
                course = courses_by_uuid[schedule.course_uuid]
                try:
                    await run_in_threadpool(
                        send_web_push,
                        endpoint=subscription.endpoint,
                        p256dh=subscription.p256dh,
                        auth=subscription.auth,
                        payload={
                            "title": f"{_REMINDER_MINUTES} 分钟后上课",
                            "body": f"{course.name} · {schedule.location or '地点待确认'}",
                            "url": "/web/",
                        },
                        private_key=settings.web_push_private_key,
                        subject=settings.web_push_subject,
                    )
                except Exception:
                    continue
                db.add(PushDelivery(
                    subscription_id=subscription.id,
                    schedule_uuid=schedule.uuid,
                    class_date=now.date().isoformat(),
                    reminder_minutes=_REMINDER_MINUTES,
                ))
                subscription.last_success_at = datetime.now(timezone.utc).replace(tzinfo=None)
                db.commit()
                sent += 1
    return sent


@router.post("/reminder-status", response_model=None)
def report_reminder_status(
    data: ReminderStatusIn,
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> dict:
    """App 重排本地提醒后按设备 upsert 最近一次提醒链路状态（指标 4）。"""
    if not _reminder_status_limiter.allow(f"reminder-status:user:{user.id}"):
        raise HTTPException(
            status_code=429, detail={"code": 42941, "message": "上报过于频繁"}
        )
    last_schedule_at = (
        datetime.fromtimestamp(data.last_schedule_at, tz=timezone.utc).replace(tzinfo=None)
        if data.last_schedule_at is not None
        else None
    )
    record = db.scalar(
        select(ReminderStatus).where(
            ReminderStatus.user_id == user.id,
            ReminderStatus.device_id == data.device_id,
        )
    )
    if record is None:
        record = ReminderStatus(user_id=user.id, device_id=data.device_id)
        db.add(record)
    record.platform = data.platform
    record.notif_permission = data.notif_permission
    record.exact_alarm = data.exact_alarm
    record.scheduled_count = data.scheduled_count
    record.last_schedule_at = last_schedule_at
    record.updated_at = datetime.now(timezone.utc).replace(tzinfo=None)
    db.commit()
    return {"code": 0, "message": "ok", "data": {"recorded": True}}


@router.post("/dispatch", dependencies=[Depends(require_admin)])
async def dispatch_due_notifications(db: Session = Depends(get_db)) -> dict:
    if not settings.web_push_private_key:
        raise HTTPException(503, detail={"code": 50340, "message": "课程通知服务尚未配置"})
    sent = await _dispatch_due(db, _now_hk())
    # 新人导入提醒（阶梯：2h/12h/2d/5d/7d，静默时段自动顺延）
    onboarding = await run_in_threadpool(dispatch_onboarding_reminders, db)
    return {"code": 0, "message": "ok", "data": {"sent": sent, "onboarding_sent": onboarding.get("sent", 0)}}
