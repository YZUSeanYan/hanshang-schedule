"""Huawei Push Kit provider using server-side environment credentials only."""
import json
import time
from dataclasses import dataclass, field
from functools import lru_cache
from threading import Lock
from typing import Protocol
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode
from urllib.request import Request, urlopen

from app.core.config import get_settings
from app.services.notification_payload import build_notification_payload


class HmsPushUnavailable(RuntimeError):
    pass


class HmsPushError(RuntimeError):
    def __init__(self, message: str, *, stale_token: bool = False) -> None:
        super().__init__(message)
        self.stale_token = stale_token


class HarmonyPushProvider(Protocol):
    def send_device_notification(
        self, *, token: str, title: str, body: str, notification_id: int
    ) -> str: ...


_STALE_TOKEN_CODES = {"80300007", "80300010", "80300011", "80300013"}


@dataclass
class HmsPushProvider:
    app_id: str
    client_id: str
    client_secret: str
    timeout_seconds: int = 10
    _cached_access_token: str = field(default="", init=False, repr=False)
    _access_token_expires_at: float = field(default=0.0, init=False, repr=False)
    _token_lock: Lock = field(default_factory=Lock, init=False, repr=False)

    def _request_json(
        self, url: str, *, data: bytes, headers: dict[str, str]
    ) -> dict:
        request = Request(url, data=data, headers=headers, method="POST")
        try:
            with urlopen(request, timeout=self.timeout_seconds) as response:
                return json.loads(response.read().decode("utf-8"))
        except HTTPError as error:
            try:
                payload = json.loads(error.read().decode("utf-8"))
            except (UnicodeDecodeError, json.JSONDecodeError):
                payload = {}
            code = str(payload.get("code") or error.code)
            raise HmsPushError(
                f"HMS HTTP {code}", stale_token=code in _STALE_TOKEN_CODES
            ) from error
        except (URLError, TimeoutError) as error:
            raise HmsPushError("HMS network error") from error

    def _access_token(self) -> str:
        now = time.monotonic()
        if self._cached_access_token and now < self._access_token_expires_at:
            return self._cached_access_token
        with self._token_lock:
            now = time.monotonic()
            if self._cached_access_token and now < self._access_token_expires_at:
                return self._cached_access_token
            payload = self._request_json(
                "https://oauth-login.cloud.huawei.com/oauth2/v3/token",
                data=urlencode({
                    "grant_type": "client_credentials",
                    "client_id": self.client_id,
                    "client_secret": self.client_secret,
                }).encode("ascii"),
                headers={"Content-Type": "application/x-www-form-urlencoded"},
            )
            token = str(payload.get("access_token") or "")
            if not token:
                raise HmsPushError("HMS authentication failed")
            try:
                expires_in = max(1, int(payload.get("expires_in") or 3600))
            except (TypeError, ValueError):
                expires_in = 3600
            self._cached_access_token = token
            self._access_token_expires_at = now + max(1, expires_in - 60)
            return token

    def send_device_notification(
        self, *, token: str, title: str, body: str, notification_id: int
    ) -> str:
        payload = self._request_json(
            f"https://push-api.cloud.huawei.com/v1/{self.app_id}/messages:send",
            data=json.dumps({
                "validate_only": False,
                "message": {
                    "token": [token],
                    "notification": {"title": title, "body": body},
                    "data": json.dumps(
                        build_notification_payload(notification_id),
                        ensure_ascii=False,
                    ),
                },
            }, ensure_ascii=False).encode("utf-8"),
            headers={
                "Authorization": f"Bearer {self._access_token()}",
                "Content-Type": "application/json; charset=UTF-8",
            },
        )
        code = str(payload.get("code") or "")
        if code != "80000000":
            raise HmsPushError(
                f"HMS response {code or 'unknown'}",
                stale_token=code in _STALE_TOKEN_CODES,
            )
        return str(payload.get("requestId") or payload.get("msg") or "")


@lru_cache
def _configured_provider(
    app_id: str, client_id: str, client_secret: str
) -> HmsPushProvider:
    return HmsPushProvider(
        app_id=app_id, client_id=client_id, client_secret=client_secret
    )


def get_harmony_push_provider() -> HarmonyPushProvider:
    settings = get_settings()
    if not settings.hms_push_enabled:
        raise HmsPushUnavailable("HMS 推送尚未启用")
    return _configured_provider(
        settings.hms_push_app_id,
        settings.hms_push_client_id,
        settings.hms_push_client_secret,
    )


def send_harmony_notification(
    *, token: str, title: str, body: str, notification_id: int
) -> str:
    return get_harmony_push_provider().send_device_notification(
        token=token, title=title, body=body, notification_id=notification_id
    )
