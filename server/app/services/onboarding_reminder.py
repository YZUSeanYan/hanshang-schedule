"""新人课表导入提醒：注册后一直没有课表的用户，按阶梯（2 小时/半天/2 天/5 天/7 天）推送引导通知。

由 /api/push/dispatch 驱动（notifier 容器每 5 分钟调用一次）：
- 判定「没有课表」= sync_courses 中没有未删除的课程行（学期建没建都算没导入成功）；
- 每个阶段对同一用户只发一次（onboarding_reminders 表 user_id+stage 唯一约束兜底）；
- 首次扫描时已超过多个阶段的用户，只发当前阶段，早期阶段标记跳过（不补发、不轰炸）；
- 香港时间 22:00–08:00 静默不发，顺延到早上；
- 被管理员限制的账号不发。
"""
import logging
from datetime import datetime, time as dt_time, timedelta, timezone

from sqlalchemy import func, select
from sqlalchemy.orm import Session

from app.core.config import get_settings
from app.models.admin import UserRestriction
from app.models.notification import UserNotification, UserPushDevice
from app.models.onboarding_reminder import OnboardingReminder
from app.models.push_subscription import PushSubscription
from app.models.sync_data import SyncCourse
from app.models.user import User
from app.services.hms_push import HmsPushError, HmsPushUnavailable, send_harmony_notification
from app.services.mobile_push import MobilePushUnavailable, send_account_notification
from app.services.web_push import send_web_push

logger = logging.getLogger(__name__)

_HK_TZ = timezone(timedelta(hours=8))
_QUIET_FROM = dt_time(22, 0)  # 香港时间 22:00 后不发
_QUIET_TO = dt_time(8, 0)     # 08:00 恢复
_WEB_URL = "https://hanshang.seanyan.store/web/"

_SUPPORT = "hanshangdeveloper@163.com"

# 阶梯：注册后超过对应时长还没有课表就发一条；话术随阶段递进（先引导、后提供帮助）。
_STAGES = [
    {
        "key": "2h",
        "delay": timedelta(hours=2),
        "title": "还没添加课表？",
        "body": "打开「导入」页，选一张课表截图或 Excel 表格，AI 会自动识别课程和时间；也可以输入同学分享的 6 位口令直接领取课表。一分钟就能搞定。",
    },
    {
        "key": "12h",
        "delay": timedelta(hours=12),
        "title": "课表还没导入？",
        "body": f"注册半天啦，课表还是空的。最快的方式：「导入」页 → 选择课表截图 → AI 识别 → 核对后保存。用安卓 App 也可以直接从教务系统导入。卡住了就邮件联系我们：{_SUPPORT}",
    },
    {
        "key": "2d",
        "delay": timedelta(days=2),
        "title": "需要帮忙导入课表吗？",
        "body": f"注册两天了还没看到课表。截图和 Excel 表格都能 AI 识别导入，也可以输入同学的 6 位分享口令。如果识别总不成功，欢迎把截图发到 {_SUPPORT}，我们帮你看。",
    },
    {
        "key": "5d",
        "delay": timedelta(days=5),
        "title": "课表导入遇到困难了吗",
        "body": f"五天啦，课表还没建起来。可以试试：截图裁掉无关区域、只留课表主体再识别；表格用 XLSX 格式最稳。实在不行邮件 {_SUPPORT}，我们协助你导入。",
    },
    {
        "key": "7d",
        "delay": timedelta(days=7),
        "title": "邗上课表一直在等你",
        "body": f"注册一周了，课表还是空的。导入其实很快：「导入」页选择课表截图或 Excel 表格就能 AI 识别。如果暂时用不上，可以在「我的」页退出登录，随时回来；需要帮助就邮件 {_SUPPORT}。",
    },
]


def _in_quiet_hours(now_utc_naive: datetime) -> bool:
    hk = now_utc_naive.replace(tzinfo=timezone.utc).astimezone(_HK_TZ)
    current = hk.time()
    # 跨零点区间：22:00–24:00 或 00:00–08:00
    return current >= _QUIET_FROM or current < _QUIET_TO


def _has_courses(db: Session, user_id: int) -> bool:
    return bool(db.scalar(
        select(func.count()).select_from(SyncCourse).where(
            SyncCourse.user_id == user_id, SyncCourse.deleted == False  # noqa: E712
        )
    ))


def _current_stage(created_at: datetime, now: datetime) -> dict | None:
    stage = None
    for candidate in _STAGES:
        if created_at <= now - candidate["delay"]:
            stage = candidate
    return stage


def _already_sent(db: Session, user_id: int, stage_key: str) -> bool:
    return db.scalar(select(func.count()).select_from(OnboardingReminder).where(
        OnboardingReminder.user_id == user_id, OnboardingReminder.stage == stage_key
    )) > 0


def _is_restricted(db: Session, user_id: int) -> bool:
    return db.scalar(select(func.count()).select_from(UserRestriction).where(
        UserRestriction.user_id == user_id
    )) > 0


def _deliver_web(db: Session, user_id: int, title: str, body: str, settings) -> int:
    delivered = 0
    if not settings.web_push_private_key:
        return 0
    subscriptions = db.scalars(select(PushSubscription).where(PushSubscription.user_id == user_id)).all()
    for sub in subscriptions:
        try:
            send_web_push(
                endpoint=sub.endpoint, p256dh=sub.p256dh, auth=sub.auth,
                payload={"title": title, "body": body, "url": _WEB_URL},
                private_key=settings.web_push_private_key,
                subject=settings.web_push_subject,
            )
            sub.last_success_at = datetime.now(timezone.utc).replace(tzinfo=None)
            delivered += 1
        except Exception as error:  # noqa: BLE001 - 单个订阅失败不影响其他渠道
            logger.warning("onboarding web push failed sub_id=%s: %s", sub.id, type(error).__name__)
    return delivered


def _deliver_harmony(db: Session, user_id: int, title: str, body: str, notification_id: int) -> int:
    cutoff = datetime.now(timezone.utc).replace(tzinfo=None) - timedelta(days=90)
    devices = db.scalars(select(UserPushDevice).where(
        UserPushDevice.user_id == user_id,
        UserPushDevice.platform == "harmony",
        UserPushDevice.last_seen_at >= cutoff,
    )).all()
    delivered = 0
    for device in devices:
        try:
            send_harmony_notification(
                token=device.device_id, title=title, body=body,
                notification_id=notification_id,
            )
            delivered += 1
        except HmsPushUnavailable:
            pass
        except HmsPushError as error:
            if getattr(error, "stale_token", False):
                db.delete(device)
        except Exception as error:  # noqa: BLE001
            logger.warning("onboarding harmony push failed user=%s: %s", user_id, type(error).__name__)
    return delivered


def _send_one(db: Session, user: User, stage: dict, settings) -> None:
    row = UserNotification(
        user_id=user.id, title=stage["title"], body=stage["body"],
        target_type="ACCOUNT", target_label="新用户引导",
    )
    db.add(row)
    db.flush()

    status, provider_id, error = "stored", "", ""
    try:
        provider_id = str(send_account_notification(
            user_id=user.id, title=stage["title"], body=stage["body"],
            notification_id=row.id,
        ) or "")
        status = "accepted"
    except MobilePushUnavailable as push_error:
        error = str(push_error)[:500]
    except Exception as send_error:  # noqa: BLE001 - 推送失败不影响收件箱与其他渠道
        status = "failed"
        error = type(send_error).__name__[:500]

    harmony_count = _deliver_harmony(db, user.id, stage["title"], stage["body"], row.id)
    if status != "accepted" and harmony_count:
        status = "accepted"
    web_count = _deliver_web(db, user.id, stage["title"], stage["body"], settings)

    row.delivery_status = status
    row.provider_message_id = provider_id
    row.delivery_error = error
    logger.info(
        "onboarding reminder sent user=%s stage=%s android=%s harmony=%s web=%s",
        user.id, stage["key"], status, harmony_count, web_count,
    )

    # 标记当前及全部更早阶段为已处理（早期阶段不补发）
    for candidate in _STAGES:
        if candidate["delay"] <= stage["delay"] and not _already_sent(db, user.id, candidate["key"]):
            db.add(OnboardingReminder(
                user_id=user.id, stage=candidate["key"], notification_id=row.id,
            ))


def dispatch_onboarding_reminders(db: Session, now: datetime | None = None) -> dict:
    """扫描并发送到期的新人导入提醒。now 为 UTC naive（与库存储一致）；返回统计。"""
    now = now or datetime.now(timezone.utc).replace(tzinfo=None)
    if _in_quiet_hours(now):
        return {"sent": 0, "quiet": True}
    settings = get_settings()
    oldest_delay = _STAGES[0]["delay"]
    candidates = db.scalars(select(User).where(User.created_at <= now - oldest_delay)).all()
    sent = 0
    for user in candidates:
        stage = _current_stage(user.created_at, now)
        if stage is None:
            continue
        if _already_sent(db, user.id, stage["key"]):
            continue
        if _is_restricted(db, user.id):
            continue
        if _has_courses(db, user.id):
            continue
        _send_one(db, user, stage, settings)
        sent += 1
    db.commit()
    return {"sent": sent, "quiet": False}
