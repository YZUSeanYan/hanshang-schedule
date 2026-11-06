from datetime import datetime, timedelta, timezone
from uuid import uuid4

from fastapi.testclient import TestClient

from app.main import app
from app.api.v1.endpoints.admin_console import _login_limiter
from app.api.v1.endpoints import admin_console
from app.db.session import SessionLocal
from app.models.admin import AdminAuditLog
from app.models.notification import UserNotification, UserPushDevice
from app.services.hms_push import HmsPushError, HmsPushUnavailable
from app.services.mobile_push import MobilePushUnavailable

client = TestClient(app)


def _admin_csrf() -> str:
    _login_limiter._hits.clear()
    response = client.post("/api/admin-console/login", json={
        "username": "admin", "password": "test-admin-password",
    })
    assert response.status_code == 200
    return response.json()["data"]["csrf_token"]


def test_targeted_notification_is_persisted_and_readable_without_provider():
    registered = client.post("/api/auth/register", json={
        "username": "notify_target",
        "email": "notify-target@example.com",
        "password": "password123",
    })
    assert registered.status_code == 200, registered.text
    data = registered.json()["data"]
    user_id = data["user"]["id"]
    auth = {"Authorization": f"Bearer {data['access_token']}"}

    binding = client.get("/api/notifications/binding", headers=auth)
    assert binding.status_code == 200
    assert binding.json()["data"]["account"] == f"yzu-user-{user_id}"

    csrf = _admin_csrf()
    no_csrf = client.post(
        f"/api/admin-console/users/{user_id}/notifications",
        json={"title": "测试", "body": "无 CSRF 不得发送"},
    )
    assert no_csrf.status_code == 403

    sent = client.post(
        f"/api/admin-console/users/{user_id}/notifications",
        headers={"X-CSRF-Token": csrf},
        json={"title": "维护提醒", "body": "今晚 23:00 进行维护"},
    )
    assert sent.status_code == 200, sent.text
    assert sent.json()["data"]["status"] == "stored"

    inbox = client.get("/api/notifications", headers=auth)
    assert inbox.status_code == 200
    payload = inbox.json()["data"]
    assert payload["unread"] == 1
    assert payload["items"][0]["title"] == "维护提醒"
    notification_id = payload["items"][0]["id"]

    read = client.post(f"/api/notifications/{notification_id}/read", headers=auth)
    assert read.status_code == 200
    assert client.get("/api/notifications", headers=auth).json()["data"]["unread"] == 0


def _register_notification_user(prefix: str) -> tuple[int, dict[str, str]]:
    suffix = uuid4().hex[:10]
    response = client.post("/api/auth/register", json={
        "username": f"{prefix}_{suffix}",
        "email": f"{prefix}-{suffix}@example.com",
        "password": "password123",
    })
    assert response.status_code == 200, response.text
    data = response.json()["data"]
    return data["user"]["id"], {
        "Authorization": f"Bearer {data['access_token']}"
    }


def _create_notifications(user_id: int, count: int) -> list[int]:
    with SessionLocal() as db:
        rows = [
            UserNotification(user_id=user_id, title=f"notice-{index}", body="body")
            for index in range(count)
        ]
        db.add_all(rows)
        db.commit()
        return [row.id for row in rows]


def test_keyset_pagination_is_stable_when_new_notification_arrives():
    user_id, auth = _register_notification_user("notify_page")
    original_ids = _create_notifications(user_id, 5)

    first = client.get("/api/notifications?limit=2", headers=auth)
    assert first.status_code == 200
    first_data = first.json()["data"]
    assert [item["id"] for item in first_data["items"]] == original_ids[-2:][::-1]
    assert first_data["has_more"] is True
    assert first_data["next_before_id"] == original_ids[-2]

    inserted_id = _create_notifications(user_id, 1)[0]
    second = client.get(
        f"/api/notifications?limit=2&before_id={first_data['next_before_id']}",
        headers=auth,
    )
    second_data = second.json()["data"]
    assert [item["id"] for item in second_data["items"]] == original_ids[1:3][::-1]
    assert inserted_id not in {item["id"] for item in second_data["items"]}
    assert second_data["has_more"] is True
    assert second_data["next_before_id"] == original_ids[1]

    final = client.get(
        f"/api/notifications?limit=2&before_id={second_data['next_before_id']}",
        headers=auth,
    ).json()["data"]
    assert [item["id"] for item in final["items"]] == [original_ids[0]]
    assert final["has_more"] is False
    assert final["next_before_id"] is None
    assert first_data["unread"] == 5
    assert second_data["unread"] == 6


def test_notification_timestamps_are_explicit_utc_after_read():
    user_id, auth = _register_notification_user("notify_utc")
    notification_id = _create_notifications(user_id, 1)[0]

    unread = client.get("/api/notifications", headers=auth).json()["data"]["items"][0]
    assert unread["created_at"].endswith("+00:00")
    assert unread["read_at"] is None

    assert client.post(
        f"/api/notifications/{notification_id}/read", headers=auth
    ).status_code == 200
    read = client.get("/api/notifications", headers=auth).json()["data"]["items"][0]
    assert read["created_at"].endswith("+00:00")
    assert read["read_at"].endswith("+00:00")


def test_notification_pagination_bounds_are_validated():
    _, auth = _register_notification_user("notify_bounds")
    for query in ("limit=0", "limit=101", "before_id=0", "before_id=-1"):
        assert client.get(f"/api/notifications?{query}", headers=auth).status_code == 422


def test_read_all_delete_clear_and_ownership_contract():
    first_id, first_auth = _register_notification_user("notify_ops_first")
    second_id, second_auth = _register_notification_user("notify_ops_second")
    first_notifications = _create_notifications(first_id, 3)
    second_notification = _create_notifications(second_id, 1)[0]

    assert client.post(
        f"/api/notifications/{second_notification}/read", headers=first_auth
    ).status_code == 404
    assert client.delete(
        f"/api/notifications/{second_notification}", headers=first_auth
    ).status_code == 404

    read_all = client.post("/api/notifications/read-all", headers=first_auth)
    assert read_all.status_code == 200
    assert read_all.json()["data"]["updated"] == 3
    assert client.post(
        "/api/notifications/read-all", headers=first_auth
    ).json()["data"]["updated"] == 0
    first_inbox = client.get("/api/notifications", headers=first_auth).json()["data"]
    assert first_inbox["unread"] == 0
    assert all(item["read_at"].endswith("+00:00") for item in first_inbox["items"])

    deleted = client.delete(
        f"/api/notifications/{first_notifications[-1]}", headers=first_auth
    )
    assert deleted.status_code == 200
    assert deleted.json()["data"]["deleted"] is True
    assert client.delete(
        f"/api/notifications/{first_notifications[-1]}", headers=first_auth
    ).status_code == 404

    cleared = client.delete("/api/notifications", headers=first_auth)
    assert cleared.json()["data"]["deleted"] == 2
    assert client.delete(
        "/api/notifications", headers=first_auth
    ).json()["data"]["deleted"] == 0
    second_inbox = client.get("/api/notifications", headers=second_auth).json()["data"]
    assert [item["id"] for item in second_inbox["items"]] == [second_notification]
    assert second_inbox["unread"] == 1


def test_notification_validation_and_account_isolation():
    first = client.post("/api/auth/register", json={
        "username": "notify_first", "email": "notify-first@example.com", "password": "password123",
    }).json()["data"]
    second = client.post("/api/auth/register", json={
        "username": "notify_second", "email": "notify-second@example.com", "password": "password123",
    }).json()["data"]
    csrf = _admin_csrf()
    invalid = client.post(
        f"/api/admin-console/users/{first['user']['id']}/notifications",
        headers={"X-CSRF-Token": csrf}, json={"title": " ", "body": " "},
    )
    assert invalid.status_code == 422
    second_auth = {"Authorization": f"Bearer {second['access_token']}"}
    assert client.get("/api/notifications", headers=second_auth).json()["data"]["items"] == []


def test_device_registration_targeting_and_session_stays_valid(monkeypatch):
    registered = client.post("/api/auth/register", json={
        "username": "notify_device", "email": "notify-device@example.com", "password": "password123",
    }).json()["data"]
    user_id = registered["user"]["id"]
    auth = {"Authorization": f"Bearer {registered['access_token']}"}
    refresh = registered["refresh_token"]
    device_id = "a" * 64
    device = client.post("/api/notifications/devices", headers=auth, json={
        "device_id": device_id,
        "label": "Xiaomi 15",
        "platform": "android",
        "app_version": "1.0.21+23",
    })
    assert device.status_code == 200, device.text

    calls = []
    monkeypatch.setattr(
        admin_console,
        "send_account_notification",
        lambda **kwargs: calls.append(kwargs) or "provider-1",
    )
    csrf = _admin_csrf()
    devices = client.get(f"/api/admin-console/users/{user_id}/devices")
    assert devices.status_code == 200
    assert devices.json()["data"][0]["label"] == "Xiaomi 15"
    sent = client.post(
        f"/api/admin-console/users/{user_id}/notifications",
        headers={"X-CSRF-Token": csrf},
        json={"title": "定向消息", "body": "仅发此设备", "device_id": device_id},
    )
    assert sent.status_code == 200, sent.text
    assert sent.json()["data"]["target_label"] == "Xiaomi 15"
    assert calls[0]["device_id"] == device_id

    # 发送通知绝不能撤销、轮换或清空用户会话。
    refreshed = client.post("/api/auth/refresh", json={"refresh_token": refresh})
    assert refreshed.status_code == 200, refreshed.text

    other = client.post("/api/auth/register", json={
        "username": "notify_other_device", "email": "notify-other-device@example.com", "password": "password123",
    }).json()["data"]
    rejected = client.post(
        f"/api/admin-console/users/{other['user']['id']}/notifications",
        headers={"X-CSRF-Token": csrf},
        json={"title": "越权", "body": "不得发送", "device_id": device_id},
    )
    assert rejected.status_code == 404


def test_harmony_device_routes_to_hms_and_can_unregister(monkeypatch):
    registered = client.post("/api/auth/register", json={
        "username": "notify_harmony",
        "email": "notify-harmony@example.com",
        "password": "password123",
    }).json()["data"]
    user_id = registered["user"]["id"]
    auth = {"Authorization": f"Bearer {registered['access_token']}"}
    token = "harmony-push-token-1234567890"
    response = client.post("/api/notifications/devices", headers=auth, json={
        "device_id": token,
        "label": "Mate 70",
        "platform": "harmony",
        "app_version": "1.0.0",
    })
    assert response.status_code == 200, response.text

    hms_calls = []
    monkeypatch.setattr(
        admin_console,
        "send_harmony_notification",
        lambda **kwargs: hms_calls.append(kwargs) or "hms-message-1",
    )
    monkeypatch.setattr(
        admin_console,
        "send_account_notification",
        lambda **kwargs: (_ for _ in ()).throw(AssertionError("Aliyun must not run")),
    )
    csrf = _admin_csrf()
    sent = client.post(
        f"/api/admin-console/users/{user_id}/notifications",
        headers={"X-CSRF-Token": csrf},
        json={"title": "鸿蒙通知", "body": "HMS 定向投递", "device_id": token},
    )
    assert sent.status_code == 200, sent.text
    assert sent.json()["data"]["status"] == "accepted"
    assert sent.json()["data"]["provider_message_id"] == "hms-message-1"
    assert hms_calls[0]["token"] == token

    removed = client.delete(f"/api/notifications/devices/{token}", headers=auth)
    assert removed.status_code == 200
    assert removed.json()["data"]["unregistered"] is True
    repeated = client.delete(f"/api/notifications/devices/{token}", headers=auth)
    assert repeated.json()["data"]["unregistered"] is False


def test_harmony_stale_token_is_removed_and_platform_is_validated(monkeypatch):
    registered = client.post("/api/auth/register", json={
        "username": "notify_harmony_stale",
        "email": "notify-harmony-stale@example.com",
        "password": "password123",
    }).json()["data"]
    user_id = registered["user"]["id"]
    auth = {"Authorization": f"Bearer {registered['access_token']}"}
    token = "stale-harmony-token-1234567890"

    invalid = client.post("/api/notifications/devices", headers=auth, json={
        "device_id": "invalid-platform-token",
        "label": "Unknown",
        "platform": "ios",
    })
    assert invalid.status_code == 422
    assert client.post("/api/notifications/devices", headers=auth, json={
        "device_id": token,
        "label": "Harmony stale",
        "platform": "harmony",
    }).status_code == 200

    monkeypatch.setattr(
        admin_console,
        "send_harmony_notification",
        lambda **kwargs: (_ for _ in ()).throw(
            HmsPushError("HMS response 80300007", stale_token=True)
        ),
    )
    csrf = _admin_csrf()
    sent = client.post(
        f"/api/admin-console/users/{user_id}/notifications",
        headers={"X-CSRF-Token": csrf},
        json={"title": "失效 token", "body": "应清理", "device_id": token},
    )
    assert sent.status_code == 200
    assert sent.json()["data"]["status"] == "failed"
    devices = client.get(f"/api/admin-console/users/{user_id}/devices").json()["data"]
    assert all(device["device_id"] != token for device in devices)


def test_provider_unavailable_and_exception_preserve_inbox_and_audit(monkeypatch):
    registered = client.post("/api/auth/register", json={
        "username": "notify_provider_failure",
        "email": "notify-provider-failure@example.com",
        "password": "password123",
    }).json()["data"]
    user_id = registered["user"]["id"]
    auth = {"Authorization": f"Bearer {registered['access_token']}"}
    csrf = _admin_csrf()

    failures = [
        (MobilePushUnavailable("disabled"), "stored"),
        (RuntimeError("provider exploded"), "failed"),
    ]
    for index, (failure, expected_status) in enumerate(failures):
        monkeypatch.setattr(
            admin_console,
            "send_account_notification",
            lambda failure=failure, **kwargs: (_ for _ in ()).throw(failure),
        )
        response = client.post(
            f"/api/admin-console/users/{user_id}/notifications",
            headers={"X-CSRF-Token": csrf},
            json={"title": f"provider-{index}", "body": "must persist"},
        )
        assert response.status_code == 200, response.text
        assert response.json()["data"]["status"] == expected_status

    inbox = client.get("/api/notifications", headers=auth).json()["data"]["items"]
    assert {item["title"] for item in inbox[:2]} == {"provider-0", "provider-1"}
    with SessionLocal() as db:
        notifications = db.query(UserNotification).filter(
            UserNotification.user_id == user_id
        ).all()
        audits = db.query(AdminAuditLog).filter(
            AdminAuditLog.action == "notification.send",
            AdminAuditLog.target_user_id == user_id,
        ).all()
        assert len(notifications) == 2
        assert len(audits) == 2


def test_none_provider_message_id_does_not_rollback(monkeypatch):
    registered = client.post("/api/auth/register", json={
        "username": "notify_none_provider_id",
        "email": "notify-none-provider-id@example.com",
        "password": "password123",
    }).json()["data"]
    user_id = registered["user"]["id"]
    auth = {"Authorization": f"Bearer {registered['access_token']}"}
    monkeypatch.setattr(admin_console, "send_account_notification", lambda **kwargs: None)

    response = client.post(
        f"/api/admin-console/users/{user_id}/notifications",
        headers={"X-CSRF-Token": _admin_csrf()},
        json={"title": "empty provider id", "body": "must commit"},
    )
    assert response.status_code == 200, response.text
    assert response.json()["data"]["provider_message_id"] == ""
    assert client.get("/api/notifications", headers=auth).json()["data"]["items"][0][
        "title"
    ] == "empty provider id"


def test_batch_rejects_missing_account_ids_without_partial_delivery(monkeypatch):
    registered = client.post("/api/auth/register", json={
        "username": "notify_batch_missing",
        "email": "notify-batch-missing@example.com",
        "password": "password123",
    }).json()["data"]
    user_id = registered["user"]["id"]
    calls = []
    monkeypatch.setattr(
        admin_console, "send_account_notification",
        lambda **kwargs: calls.append(kwargs) or "message-id",
    )
    response = client.post(
        "/api/admin-console/notifications/batch",
        headers={"X-CSRF-Token": _admin_csrf()},
        json={"title": "batch", "body": "body", "user_ids": [user_id, 2147483647]},
    )
    assert response.status_code == 422
    assert response.json()["missing_user_ids"] == [2147483647]
    assert calls == []


def test_broadcast_harmony_payload_uses_each_accounts_inbox_id(monkeypatch):
    accounts = []
    for suffix in ("a", "b"):
        registered = client.post("/api/auth/register", json={
            "username": f"notify_harmony_broadcast_{suffix}",
            "email": f"notify-harmony-broadcast-{suffix}@example.com",
            "password": "password123",
        }).json()["data"]
        user_id = registered["user"]["id"]
        auth = {"Authorization": f"Bearer {registered['access_token']}"}
        token = f"harmony-broadcast-token-{suffix}-123456"
        assert client.post("/api/notifications/devices", headers=auth, json={
            "device_id": token, "label": suffix, "platform": "harmony",
        }).status_code == 200
        accounts.append((user_id, auth, token))

    hms_calls = []
    monkeypatch.setattr(
        admin_console, "send_account_notification",
        lambda **kwargs: (_ for _ in ()).throw(MobilePushUnavailable("disabled")),
    )
    monkeypatch.setattr(
        admin_console, "send_harmony_notification",
        lambda **kwargs: hms_calls.append(kwargs) or "hms-id",
    )
    response = client.post(
        "/api/admin-console/notifications/broadcast",
        headers={"X-CSRF-Token": _admin_csrf()},
        json={"title": "harmony broadcast", "body": "body"},
    )
    assert response.status_code == 200, response.text

    calls_by_token = {call["token"]: call for call in hms_calls}
    for _, auth, token in accounts:
        inbox_id = client.get("/api/notifications", headers=auth).json()["data"]["items"][0]["id"]
        assert calls_by_token[token]["notification_id"] == inbox_id


def test_harmony_unavailable_preserves_targeted_inbox(monkeypatch):
    registered = client.post("/api/auth/register", json={
        "username": "notify_harmony_disabled",
        "email": "notify-harmony-disabled@example.com",
        "password": "password123",
    }).json()["data"]
    user_id = registered["user"]["id"]
    auth = {"Authorization": f"Bearer {registered['access_token']}"}
    token = "harmony-disabled-token-123456789"
    assert client.post("/api/notifications/devices", headers=auth, json={
        "device_id": token, "label": "Harmony", "platform": "harmony",
    }).status_code == 200
    monkeypatch.setattr(
        admin_console, "send_harmony_notification",
        lambda **kwargs: (_ for _ in ()).throw(HmsPushUnavailable("disabled")),
    )

    response = client.post(
        f"/api/admin-console/users/{user_id}/notifications",
        headers={"X-CSRF-Token": _admin_csrf()},
        json={"title": "hms disabled", "body": "must persist", "device_id": token},
    )
    assert response.status_code == 200, response.text
    assert response.json()["data"]["status"] == "stored"
    assert client.get("/api/notifications", headers=auth).json()["data"]["items"][0][
        "title"
    ] == "hms disabled"


def test_expired_native_registration_is_not_targetable():
    registered = client.post("/api/auth/register", json={
        "username": "notify_expired_device",
        "email": "notify-expired-device@example.com",
        "password": "password123",
    }).json()["data"]
    user_id = registered["user"]["id"]
    auth = {"Authorization": f"Bearer {registered['access_token']}"}
    token = "expired-native-token-1234567890"
    assert client.post("/api/notifications/devices", headers=auth, json={
        "device_id": token, "label": "Old device", "platform": "android",
    }).status_code == 200
    with SessionLocal() as db:
        device = db.query(UserPushDevice).filter(UserPushDevice.device_id == token).one()
        device.last_seen_at = (
            datetime.now(timezone.utc).replace(tzinfo=None) - timedelta(days=91)
        )
        db.commit()

    csrf = _admin_csrf()
    devices = client.get(f"/api/admin-console/users/{user_id}/devices").json()["data"]
    assert all(device["device_id"] != token for device in devices)
    response = client.post(
        f"/api/admin-console/users/{user_id}/notifications",
        headers={"X-CSRF-Token": csrf},
        json={"title": "expired", "body": "must reject", "device_id": token},
    )
    assert response.status_code == 404
