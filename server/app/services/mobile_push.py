"""Alibaba Cloud Mobile Push client using short-lived ECS RAM-role credentials."""
import json
from datetime import datetime, timedelta, timezone
from uuid import NAMESPACE_URL, uuid5

from app.core.config import get_settings
from app.services.notification_payload import build_notification_payload


class MobilePushUnavailable(RuntimeError):
    pass


def account_for_user(user_id: int) -> str:
    return f"yzu-user-{user_id}"


def _send_push(
    *, title: str, body: str, notification_id: int,
    target: str, target_value: str,
) -> str:
    settings = get_settings()
    if (
        not settings.aliyun_push_enabled
        or not settings.aliyun_push_app_key
        or not settings.aliyun_push_ecs_role_name
    ):
        raise MobilePushUnavailable("移动推送尚未启用")
    try:
        from aliyunsdkcore.auth.credentials import EcsRamRoleCredential
        from aliyunsdkcore.client import AcsClient
        from aliyunsdkpush.request.v20160801.PushRequest import PushRequest
    except ImportError as error:
        raise MobilePushUnavailable("移动推送服务端 SDK 未安装") from error

    credential = EcsRamRoleCredential(role_name=settings.aliyun_push_ecs_role_name)
    client = AcsClient(region_id=settings.aliyun_push_region, credential=credential)
    request = PushRequest()
    request.set_accept_format("json")
    request.set_AppKey(int(settings.aliyun_push_app_key))
    request.set_DeviceType("ANDROID")
    request.set_PushType("NOTICE")
    request.set_Target(target)
    request.set_TargetValue(target_value)
    request.set_Title(title)
    request.set_Body(body)
    request.set_AndroidOpenType("APPLICATION")
    request.set_AndroidNotificationChannel("account_messages")
    request.set_AndroidNotifyType("BOTH")
    # 通知栏展示优先级拉满(Android PRIORITY_* 值域 -2~2,2=PRIORITY_MAX),客户端 channel 已是 IMPORTANCE_HIGH
    request.set_AndroidNotificationBarPriority(2)
    request.set_StoreOffline(True)
    request.set_ExpireTime(
        (datetime.now(timezone.utc) + timedelta(days=7)).strftime("%Y-%m-%dT%H:%M:%SZ")
    )
    request.set_IdempotentToken(
        str(uuid5(NAMESPACE_URL, f"hanshang-notification:{notification_id}"))
    )
    request.set_AndroidExtParameters(
        json.dumps(build_notification_payload(notification_id), ensure_ascii=False)
    )
    raw = client.do_action_with_exception(request)
    result = json.loads(raw.decode("utf-8"))
    return str(result.get("MessageId") or result.get("RequestId") or "")


def send_account_notification(
    *, user_id: int, title: str, body: str, notification_id: int,
    device_id: str | None = None,
) -> str:
    return _send_push(
        title=title, body=body, notification_id=notification_id,
        target="DEVICE" if device_id else "ACCOUNT",
        target_value=device_id or account_for_user(user_id),
    )


def send_broadcast_notification(
    *, title: str, body: str, notification_id: int,
) -> str:
    """Push one notice to every device of the app (Target=ALL)."""
    return _send_push(
        title=title, body=body, notification_id=notification_id,
        target="ALL", target_value="ALL",
    )
