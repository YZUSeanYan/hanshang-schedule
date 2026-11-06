"""版本发布核心逻辑：X-Admin-Token 端点与管理后台会话端点共用。

统一标准：
- 「定向测试版」= 有目标账号（app_version_targets 有行）的版本，仅这些账号可见；
- 「正式版」= 无目标账号，全员可见；
- 定向版本不允许强制更新；发布/加目标可选发送收件箱+推送通知。
"""
from fastapi import HTTPException
from sqlalchemy import or_, select
from sqlalchemy.orm import Session

from app.models.app_version import AppVersion
from app.models.notification import UserNotification
from app.models.release_target import AppVersionTarget
from app.models.user import User
from app.schemas.version import VersionPublishIn
from app.services.mobile_push import MobilePushUnavailable, send_account_notification


def _resolve_accounts(db: Session, accounts: list[str]) -> tuple[list[User], list[str]]:
    users: list[User] = []
    missing: list[str] = []
    for account in accounts:
        user = db.scalar(
            select(User).where(or_(User.username == account, User.email == account))
        )
        if user is None:
            missing.append(account)
        else:
            users.append(user)
    return users, missing


def publish_version(db: Session, data: VersionPublishIn) -> dict:
    """发布新版本（统一入口）。返回发布结果与通知状态。"""
    if db.scalar(select(AppVersion).where(AppVersion.version_code == data.version_code)):
        raise HTTPException(
            status_code=409, detail={"code": 40903, "message": "该 version_code 已发布过"}
        )
    targets = list(dict.fromkeys(item.strip() for item in data.target_accounts if item.strip()))
    users, missing = _resolve_accounts(db, targets)
    if missing:
        raise HTTPException(
            status_code=422,
            detail={"code": 42241, "message": "测试账号不存在", "accounts": missing},
        )
    if data.notify_targets and not users:
        raise HTTPException(
            status_code=422,
            detail={"code": 42242, "message": "只有定向测试版本可以发送测试通知"},
        )
    if users and (data.is_force_update or data.force_codes):
        raise HTTPException(
            status_code=422,
            detail={"code": 42243, "message": "定向测试版本不能设为强制更新"},
        )
    values = data.model_dump(mode="json", exclude={"target_accounts", "notify_targets"})
    row = AppVersion(**values)
    db.add(row)
    db.flush()
    add_targets(db, row, users, commit=False)
    notices = _notify_targets(db, row, users) if data.notify_targets else []
    db.commit()
    statuses = _deliver_notices(db, notices)
    return {
        "id": row.id,
        "version_code": row.version_code,
        "release_channel": "targeted_test" if users else "stable",
        "target_user_ids": [user.id for user in users],
        "notifications": statuses,
    }


def add_targets(
    db: Session,
    version: AppVersion,
    users: list[User],
    *,
    commit: bool = True,
) -> list[User]:
    """给既有版本补目标账号（幂等：已在名单的跳过）。"""
    added: list[User] = []
    for user in users:
        exists = db.scalar(
            select(AppVersionTarget.id).where(
                AppVersionTarget.version_id == version.id,
                AppVersionTarget.user_id == user.id,
            )
        )
        if exists is not None:
            continue
        db.add(AppVersionTarget(version_id=version.id, user_id=user.id))
        added.append(user)
    if commit:
        db.commit()
    return added


def remove_target(db: Session, version_id: int, user_id: int) -> bool:
    row = db.scalar(
        select(AppVersionTarget).where(
            AppVersionTarget.version_id == version_id,
            AppVersionTarget.user_id == user_id,
        )
    )
    if row is None:
        return False
    db.delete(row)
    db.commit()
    return True


def _notify_targets(
    db: Session, version: AppVersion, users: list[User]
) -> list[tuple[User, UserNotification]]:
    notices: list[tuple[User, UserNotification]] = []
    title = f"邗上课表 {version.version_name} 测试邀请"
    body = version.release_notes.strip() or "新版本正在小范围测试，欢迎更新体验。"
    for user in users:
        notice = UserNotification(
            user_id=user.id,
            title=title[:64],
            body=body[:500],
            data_json='{"type":"targeted_app_update"}',
            target_type="ACCOUNT",
            target_label="测试账号的全部 Android 设备",
        )
        db.add(notice)
        db.flush()
        notices.append((user, notice))
    return notices


def _deliver_notices(
    db: Session, notices: list[tuple[User, UserNotification]]
) -> list[dict]:
    # 先落库再联系外部推送：推送瞬时失败也不能回滚一次有效的发布。
    statuses: list[dict] = []
    for user, notice in notices:
        try:
            notice.provider_message_id = send_account_notification(
                user_id=user.id,
                title=notice.title,
                body=notice.body,
                notification_id=notice.id,
            )
            notice.delivery_status = "accepted"
        except MobilePushUnavailable as error:
            notice.delivery_status = "stored"
            notice.delivery_error = str(error)[:500]
        except Exception as error:
            notice.delivery_status = "failed"
            notice.delivery_error = type(error).__name__[:500]
        statuses.append({"user_id": user.id, "status": notice.delivery_status})
    if notices:
        db.commit()
    return statuses


def notify_users_of_version(
    db: Session, version: AppVersion, users: list[User]
) -> list[dict]:
    """给补加的目标账号发测试邀请通知（加目标时可选）。"""
    notices = _notify_targets(db, version, users)
    db.commit()
    return _deliver_notices(db, notices)

def _parse_app_version_code(raw: str | None) -> int:
    """'2.0.0+62' -> 62；'1.0.33+33' -> 33。解析不出返回 0。"""
    if not raw:
        return 0
    tail = raw.rsplit('+', 1)[-1]
    return int(tail) if tail.isdigit() else 0


def outdated_user_ids(db: Session, min_code: int) -> list[int]:
    """找出「没被确认在 min_code 之上」的账号 id。

    **版本未知也算落后**：只有客户端冷启动上报过 current_code 才算「已知」，
    而新版本往往刚发出去、绝大多数人还没上报——此时「未知」＝「肯定还在老
    版本」，绝不能当成「可能已最新」而漏发（2026-09-22 用户明确指正过这一点）。

    只有两类账号不发：

    1. **确定的纯网页版用户**（有网页推送订阅且没有任何 App 端信号）——PWA
       自己会更新，跟 APK 版本无关，给他们发「打开 App 检查更新」是错的；
    2. **正在被定向测试 min_code 及以上版本的账号**（内测名单）——否则会和
       测试邀请自相矛盾。

    App 端信号 = user_push_devices（推送注册）或 client_versions
    （冷启动上报）；两者同账号取大者作为已知版本。
    """
    from app.models.client_version import ClientVersion
    from app.models.notification import UserPushDevice
    from app.models.push_subscription import PushSubscription

    known: dict[int, int] = {}
    app_signal: set[int] = set()
    for user_id, code in db.execute(
        select(ClientVersion.user_id, ClientVersion.current_code)
    ).all():
        app_signal.add(user_id)
        known[user_id] = max(int(code), known.get(user_id, 0))
    for user_id, raw in db.execute(
        select(UserPushDevice.user_id, UserPushDevice.app_version)
    ).all():
        app_signal.add(user_id)
        known[user_id] = max(_parse_app_version_code(raw), known.get(user_id, 0))
    web_signal = set(db.scalars(select(PushSubscription.user_id).distinct()))

    newer_targets = set(db.scalars(
        select(AppVersionTarget.user_id)
        .join(AppVersion, AppVersion.id == AppVersionTarget.version_id)
        .where(AppVersion.version_code >= min_code)
    ))

    out: list[int] = []
    for user_id in db.scalars(select(User.id)):
        if user_id in newer_targets:
            continue
        code = known.get(user_id)
        if code is not None and code >= min_code:
            continue  # 已确认在最新版上
        if user_id in web_signal and user_id not in app_signal:
            continue  # 纯网页版：PWA 自己更新，与 APK 无关
        out.append(user_id)
    return sorted(out)


def notify_outdated_users(
    db: Session, version: AppVersion, *, commit: bool = True
) -> list[dict]:
    """只提醒「版本落后」的账号去更新（版本转正后调用）。

    与 _notify_targets 的区别：那条发给内测名单，带「测试邀请」字样；
    这条发给**全体落后用户**，面向普通用户，正文直接告诉他们怎么更新。

    为什么必须走推送/收件箱：更新提示条这类写在 App 里的提醒，只有已经装了
    新版的用户才看得到——而那些人恰恰不需要被提醒；真正卡在老版本的用户，
    包里根本没有那段代码，永远收不到。
    """
    user_ids = outdated_user_ids(db, version.version_code)
    if not user_ids:
        return []
    title = f"邗上课表 {version.version_name} 已发布"
    body = (
        "你正在使用的版本可以升级了。打开 App →「我的」→「检查更新」，"
        "即可下载新版本。不升级也不影响继续使用。"
    )
    notices: list[tuple[User, UserNotification]] = []
    for user_id in user_ids:
        # 幂等：同一版本对同一账号只提醒一次
        already = db.scalar(
            select(UserNotification.id).where(
                UserNotification.user_id == user_id,
                UserNotification.title == title[:64],
            )
        )
        if already is not None:
            continue
        user = db.get(User, user_id)
        if user is None:
            continue
        notice = UserNotification(
            user_id=user.id,
            title=title[:64],
            body=body[:500],
            data_json='{{"type":"targeted_app_update"}}',
            target_type="ACCOUNT",
            target_label="版本落后的账号",
        )
        db.add(notice)
        db.flush()
        notices.append((user, notice))
    # 无论 commit 与否都必须先落库再推送：_deliver_notices 的不变量是
    # 「先落库再联系外部推送」，推送瞬时失败也不能把一次有效的提醒回滚掉。
    if commit:
        db.commit()
    else:
        db.flush()
    return _deliver_notices(db, notices)
