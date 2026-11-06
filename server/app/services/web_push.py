"""Small boundary around pywebpush so secrets and endpoint URLs never hit logs."""
from __future__ import annotations

import json
from typing import Any


class WebPushUnavailable(RuntimeError):
    pass


def send_web_push(
    *,
    endpoint: str,
    p256dh: str,
    auth: str,
    payload: dict[str, Any],
    private_key: str,
    subject: str,
) -> None:
    if not private_key:
        raise WebPushUnavailable("Web Push 尚未配置")
    try:
        from pywebpush import webpush
    except ImportError as exc:
        raise WebPushUnavailable("Web Push 组件尚未安装") from exc
    webpush(
        subscription_info={
            "endpoint": endpoint,
            "keys": {"p256dh": p256dh, "auth": auth},
        },
        data=json.dumps(payload, ensure_ascii=False, separators=(",", ":")),
        vapid_private_key=private_key,
        vapid_claims={"sub": subject},
        ttl=86400,  # PWA 离线补投窗口:60s 太短,关机/断网即丢;24h 与 EMAS 离线保留策略对齐
    )
