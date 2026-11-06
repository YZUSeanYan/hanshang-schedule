import json
import sys
from types import ModuleType, SimpleNamespace

import pytest

from app.services import mobile_push
from app.services.hms_push import HmsPushError, HmsPushProvider
from app.services.notification_payload import build_notification_payload


def test_hms_provider_builds_notification_payload(monkeypatch):
    provider = HmsPushProvider("app-1", "client-1", "secret-1")
    requests = []

    def fake_request(url, *, data, headers):
        requests.append((url, data, headers))
        if "oauth2" in url:
            return {"access_token": "access-1", "expires_in": 3600}
        return {"code": "80000000", "requestId": "request-1"}

    monkeypatch.setattr(provider, "_request_json", fake_request)
    message_id = provider.send_device_notification(
        token="token-1", title="Title", body="Body", notification_id=42
    )

    assert message_id == "request-1"
    payload = json.loads(requests[1][1].decode("utf-8"))
    assert payload["message"]["token"] == ["token-1"]
    assert payload["message"]["notification"] == {"title": "Title", "body": "Body"}
    assert json.loads(payload["message"]["data"]) == {
        "version": "1",
        "type": "account_notification",
        "destination": "notifications",
        "deeplink": "hanshang://notifications",
        "notification_id": "42",
    }
    assert all(
        isinstance(value, str)
        for value in json.loads(payload["message"]["data"]).values()
    )
    assert requests[1][2]["Authorization"] == "Bearer access-1"


def test_notification_payload_builder_is_versioned_string_only_and_fresh():
    first = build_notification_payload(42)
    second = build_notification_payload(43)

    assert first == {
        "version": "1",
        "type": "account_notification",
        "destination": "notifications",
        "deeplink": "hanshang://notifications",
        "notification_id": "42",
    }
    assert all(isinstance(value, str) for value in first.values())
    assert first is not second


def test_aliyun_android_uses_shared_notification_payload(monkeypatch):
    captured = {}

    class FakePushRequest:
        def __getattr__(self, name):
            if name.startswith("set_"):
                return lambda value: captured.__setitem__(name[4:], value)
            raise AttributeError(name)

    class FakeClient:
        def __init__(self, *args, **kwargs):
            pass

        def do_action_with_exception(self, request):
            return b'{"MessageId":"aliyun-message-1"}'

    module_map = {
        "aliyunsdkcore.auth.credentials": SimpleNamespace(
            EcsRamRoleCredential=lambda **kwargs: object()
        ),
        "aliyunsdkcore.client": SimpleNamespace(AcsClient=FakeClient),
        "aliyunsdkpush.request.v20160801.PushRequest": SimpleNamespace(
            PushRequest=FakePushRequest
        ),
    }
    for name, attributes in module_map.items():
        module = ModuleType(name)
        module.__dict__.update(vars(attributes))
        monkeypatch.setitem(sys.modules, name, module)
    monkeypatch.setattr(mobile_push, "get_settings", lambda: SimpleNamespace(
        aliyun_push_enabled=True,
        aliyun_push_app_key="123",
        aliyun_push_ecs_role_name="push-role",
        aliyun_push_region="cn-hangzhou",
    ))

    message_id = mobile_push.send_account_notification(
        user_id=7,
        title="Title",
        body="Body",
        notification_id=42,
    )

    assert message_id == "aliyun-message-1"
    assert captured["Target"] == "ACCOUNT"
    assert captured["TargetValue"] == "yzu-user-7"
    assert json.loads(captured["AndroidExtParameters"]) == build_notification_payload(42)


def test_hms_provider_reuses_oauth_token(monkeypatch):
    provider = HmsPushProvider("app-1", "client-1", "secret-1")
    oauth_requests = []

    def fake_request(url, *, data, headers):
        if "oauth2" in url:
            oauth_requests.append(url)
            return {"access_token": "cached-access", "expires_in": 3600}
        return {"code": "80000000", "requestId": "request-1"}

    monkeypatch.setattr(provider, "_request_json", fake_request)
    for notification_id in (41, 42):
        provider.send_device_notification(
            token="token-1", title="Title", body="Body",
            notification_id=notification_id,
        )

    assert len(oauth_requests) == 1


def test_hms_provider_marks_permanent_token_error(monkeypatch):
    provider = HmsPushProvider("app-1", "client-1", "secret-1")
    monkeypatch.setattr(provider, "_access_token", lambda: "access-1")
    monkeypatch.setattr(
        provider,
        "_request_json",
        lambda *args, **kwargs: {"code": "80300007", "msg": "invalid token"},
    )

    with pytest.raises(HmsPushError) as captured:
        provider.send_device_notification(
            token="stale-token", title="Title", body="Body", notification_id=1
        )
    assert captured.value.stale_token is True
