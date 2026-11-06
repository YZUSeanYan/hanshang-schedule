from uuid import uuid4
from datetime import datetime

from fastapi.testclient import TestClient

from app.api.v1.endpoints import push
from app.main import app

client = TestClient(app)


def _headers():
    suffix = uuid4().hex[:10]
    response = client.post("/api/auth/register", json={
        "username": f"push{suffix}",
        "email": f"push{suffix}@example.com",
        "password": "password123",
    })
    return {"Authorization": f"Bearer {response.json()['data']['access_token']}"}


def _subscription():
    return {
        "endpoint": f"https://push.example.test/{uuid4().hex}",
        "keys": {"p256dh": "A" * 65, "auth": "B" * 22},
    }


def test_subscription_requires_authentication():
    response = client.post("/api/push/subscribe", json=_subscription())
    assert response.status_code == 401


def test_subscription_rejects_non_https_endpoint():
    response = client.post(
        "/api/push/subscribe",
        headers=_headers(),
        json={
            "endpoint": "http://push.example.test/not-secure",
            "keys": {"p256dh": "A" * 65, "auth": "B" * 22},
        },
    )
    assert response.status_code == 422


def test_subscribe_and_unsubscribe_are_idempotent():
    headers = _headers()
    body = _subscription()
    first = client.post("/api/push/subscribe", headers=headers, json=body)
    second = client.post("/api/push/subscribe", headers=headers, json=body)
    removed = client.request("DELETE", "/api/push/subscribe", headers=headers, json={"endpoint": body["endpoint"]})
    assert first.status_code == second.status_code == removed.status_code == 200


def test_notification_uses_server_keys_without_returning_subscription(monkeypatch):
    headers = _headers()
    body = _subscription()
    client.post("/api/push/subscribe", headers=headers, json=body)
    calls = []
    monkeypatch.setattr(push.settings, "web_push_private_key", "private-test-key")
    monkeypatch.setattr(push, "send_web_push", lambda **kwargs: calls.append(kwargs))
    response = client.post("/api/push/test", headers=headers)
    assert response.status_code == 200, response.text
    assert calls[0]["endpoint"] == body["endpoint"]
    assert "endpoint" not in response.text
    assert "private-test-key" not in response.text


def test_course_dispatch_is_idempotent(monkeypatch):
    headers = _headers()
    body = _subscription()
    client.post("/api/push/subscribe", headers=headers, json=body)
    now = 1_786_413_600_000
    semester_uuid = str(uuid4())
    course_uuid = str(uuid4())
    schedule_uuid = str(uuid4())
    client.post("/api/sync/push", headers=headers, json={
        "semesters": [{
            "uuid": semester_uuid, "name": "测试学期", "start_date": "2026-08-10",
            "total_weeks": 20, "is_current": True, "updated_at": now, "deleted": False,
        }],
        "courses": [{
            "uuid": course_uuid, "semester_uuid": semester_uuid, "name": "高等数学",
            "teacher": "王老师", "color": 0, "note": "", "updated_at": now, "deleted": False,
        }],
        "schedules": [{
            "uuid": schedule_uuid, "course_uuid": course_uuid, "day_of_week": 2,
            "start_section": 1, "end_section": 2, "weeks_type": 0,
            "custom_weeks": "", "location": "文津楼201", "updated_at": now, "deleted": False,
        }],
    })
    calls = []
    monkeypatch.setattr(push.settings, "admin_token", "admin-test-token")
    monkeypatch.setattr(push.settings, "web_push_private_key", "private-test-key")
    monkeypatch.setattr(push, "send_web_push", lambda **kwargs: calls.append(kwargs))
    monkeypatch.setattr(push, "_now_hk", lambda: datetime(2026, 8, 11, 7, 45, tzinfo=push._HONG_KONG_TZ))
    admin_headers = {"X-Admin-Token": "admin-test-token"}
    first = client.post("/api/push/dispatch", headers=admin_headers)
    second = client.post("/api/push/dispatch", headers=admin_headers)
    assert first.json()["data"]["sent"] == 1
    assert second.json()["data"]["sent"] == 0
    assert len(calls) == 1


def _seed_tuesday_course(headers, now=1_786_413_600_000):
    """周二（2026-08-11）第 1-2 节的一门课；_now_hk 固定为当天 07:45 时命中提醒窗口。"""
    semester_uuid = str(uuid4())
    course_uuid = str(uuid4())
    schedule_uuid = str(uuid4())
    client.post("/api/sync/push", headers=headers, json={
        "semesters": [{
            "uuid": semester_uuid, "name": "测试学期", "start_date": "2026-08-10",
            "total_weeks": 20, "is_current": True, "updated_at": now, "deleted": False,
        }],
        "courses": [{
            "uuid": course_uuid, "semester_uuid": semester_uuid, "name": "高等数学",
            "teacher": "王老师", "color": 0, "note": "", "updated_at": now, "deleted": False,
        }],
        "schedules": [{
            "uuid": schedule_uuid, "course_uuid": course_uuid, "day_of_week": 2,
            "start_section": 1, "end_section": 2, "weeks_type": 0,
            "custom_weeks": "", "location": "文津楼201", "updated_at": now, "deleted": False,
        }],
    })
    return course_uuid


def test_course_dispatch_skips_holiday_override(monkeypatch):
    """调休放假（off）：当天即使课表命中也不发送上课提醒。"""
    headers = _headers()
    body = _subscription()
    client.post("/api/push/subscribe", headers=headers, json=body)
    _seed_tuesday_course(headers)
    client.post("/api/sync/push", headers=headers, json={
        "overrides": [{
            "uuid": str(uuid4()), "date": "2026-08-11", "kind": "off",
            "weekday": 0, "note": "国庆放假", "updated_at": 1_786_413_600_000, "deleted": False,
        }],
    })
    calls = []
    monkeypatch.setattr(push.settings, "admin_token", "admin-test-token")
    monkeypatch.setattr(push.settings, "web_push_private_key", "private-test-key")
    monkeypatch.setattr(push, "send_web_push", lambda **kwargs: calls.append(kwargs))
    monkeypatch.setattr(push, "_now_hk", lambda: datetime(2026, 8, 11, 7, 45, tzinfo=push._HONG_KONG_TZ))
    response = client.post("/api/push/dispatch", headers={"X-Admin-Token": "admin-test-token"})
    assert response.json()["data"]["sent"] == 0
    assert calls == []


def test_course_dispatch_follows_makeup_override(monkeypatch):
    """调休补课（makeup）：周二补周三的课时，按周三课表在周二发提醒。"""
    headers = _headers()
    body = _subscription()
    client.post("/api/push/subscribe", headers=headers, json=body)
    now = 1_786_413_600_000
    semester_uuid = str(uuid4())
    course_uuid = str(uuid4())
    schedule_uuid = str(uuid4())
    client.post("/api/sync/push", headers=headers, json={
        "semesters": [{
            "uuid": semester_uuid, "name": "测试学期", "start_date": "2026-08-10",
            "total_weeks": 20, "is_current": True, "updated_at": now, "deleted": False,
        }],
        "courses": [{
            "uuid": course_uuid, "semester_uuid": semester_uuid, "name": "大学英语",
            "teacher": "李老师", "color": 0, "note": "", "updated_at": now, "deleted": False,
        }],
        # 补课日是周二，课程排在周三（day_of_week=3）
        "schedules": [{
            "uuid": schedule_uuid, "course_uuid": course_uuid, "day_of_week": 3,
            "start_section": 1, "end_section": 2, "weeks_type": 0,
            "custom_weeks": "", "location": "文津楼301", "updated_at": now, "deleted": False,
        }],
        "overrides": [{
            "uuid": str(uuid4()), "date": "2026-08-11", "kind": "makeup",
            "weekday": 3, "note": "补周三的课", "updated_at": now, "deleted": False,
        }],
    })
    calls = []
    monkeypatch.setattr(push.settings, "admin_token", "admin-test-token")
    monkeypatch.setattr(push.settings, "web_push_private_key", "private-test-key")
    monkeypatch.setattr(push, "send_web_push", lambda **kwargs: calls.append(kwargs))
    monkeypatch.setattr(push, "_now_hk", lambda: datetime(2026, 8, 11, 7, 45, tzinfo=push._HONG_KONG_TZ))
    response = client.post("/api/push/dispatch", headers={"X-Admin-Token": "admin-test-token"})
    assert response.json()["data"]["sent"] == 1
    assert len(calls) == 1
    assert "大学英语" in calls[0]["payload"]["body"]
