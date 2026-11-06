"""管理后台 v3 数据统计与用户管理端点测试。"""
from datetime import date, datetime, timedelta

from fastapi.testclient import TestClient

from app.main import app
from app.api.v1.endpoints.admin_console import _login_limiter
from app.db.session import SessionLocal
from app.models.admin import UserRestriction
from app.models.daily_activity import DailyActivity
from app.models.notification import UserNotification, UserPushDevice
from app.models.push_subscription import PushSubscription
from app.models.sync_data import SyncCourse
from app.models.user import User

client = TestClient(app)


def _admin_csrf() -> str:
    _login_limiter._hits.clear()
    response = client.post("/api/admin-console/login", json={
        "username": "admin", "password": "test-admin-password",
    })
    assert response.status_code == 200
    return response.json()["data"]["csrf_token"]


def _admin() -> dict:
    return {"X-CSRF-Token": _admin_csrf()}


def _register(username: str) -> int:
    response = client.post("/api/auth/register", json={
        "username": username, "email": f"{username}@example.com", "password": "password123",
    })
    assert response.status_code == 200, response.text
    return response.json()["data"]["user"]["id"]


def _add_course(user_id: int) -> None:
    db = SessionLocal()
    try:
        db.add(SyncCourse(
            user_id=user_id, uuid=f"stats-course-{user_id}", semester_uuid="sem-1",
            name="统计学", teacher="", color=0, note="", updated_at=1, deleted=False, synced_at=1,
        ))
        db.commit()
    finally:
        db.close()


def _add_activity(user_id: int, days_ago: int = 0) -> None:
    db = SessionLocal()
    try:
        db.add(DailyActivity(user_id=user_id, activity_date=date.today() - timedelta(days=days_ago)))
        db.commit()
    finally:
        db.close()


def test_overview_extended_fields():
    user_id = _register("stats_overview_user")
    _add_course(user_id)
    _add_activity(user_id)
    response = client.get("/api/admin-console/stats/overview", headers=_admin())
    assert response.status_code == 200
    data = response.json()["data"]
    for key in ("today_dau", "wau", "mau", "total_users", "today_new_users", "week_new_users",
                "total_courses", "total_schedules", "native_devices", "web_subscriptions",
                "total_notifications", "today_notifications", "couple_memberships"):
        assert key in data, key
    assert data["total_users"] >= 1
    # 不用 today_new_users（UTC-本地时区差 8h 内会挂），周窗口覆盖
    assert data["week_new_users"] >= 1
    assert data["today_dau"] >= 1
    assert data["total_courses"] >= 1


def test_growth_series_shape_and_today():
    _register("stats_growth_user")
    response = client.get("/api/admin-console/stats/growth-series?days=30", headers=_admin())
    assert response.status_code == 200
    series = response.json()["data"]
    assert len(series) == 30
    assert series[-1]["date"] == date.today().isoformat()
    # 同理：UTC 与本地日界错位时新用户计在昨天，断言全窗口总量
    assert sum(item["count"] for item in series) >= 1
    assert all(set(item) == {"date", "count"} for item in series)


def test_platforms_distribution():
    user_id = _register("stats_platform_user")
    db = SessionLocal()
    try:
        db.add(UserPushDevice(user_id=user_id, device_id=f"stats-dev-{user_id}", platform="android", last_seen_at=datetime.utcnow()))
        db.add(PushSubscription(user_id=user_id, endpoint=f"https://push.example.com/stats-{user_id}", p256dh="k", auth="a"))
        db.add(UserNotification(user_id=user_id, title="测试", body="投递状态统计", delivery_status="accepted"))
        db.commit()
    finally:
        db.close()
    response = client.get("/api/admin-console/stats/platforms", headers=_admin())
    assert response.status_code == 200
    data = response.json()["data"]
    assert data["devices"].get("android", 0) >= 1
    assert data["web_subscriptions"] >= 1
    assert data["notification_status"].get("accepted", 0) >= 1
    assert "onboarding_reminders" in data


def test_users_list_has_v3_fields():
    user_id = _register("stats_list_user")
    _add_course(user_id)
    _add_activity(user_id, days_ago=1)
    response = client.get("/api/admin-console/users?page=1&page_size=100", headers=_admin())
    assert response.status_code == 200
    item = next(row for row in response.json()["data"]["items"] if row["id"] == user_id)
    assert item["course_count"] == 1
    assert item["last_active"] == (date.today() - timedelta(days=1)).isoformat()
    assert item["restricted"] is False


def test_user_detail_has_state_and_devices():
    user_id = _register("stats_detail_user")
    db = SessionLocal()
    try:
        db.add(UserPushDevice(user_id=user_id, device_id=f"stats-detail-dev-{user_id}", platform="harmony", last_seen_at=datetime.utcnow()))
        db.add(UserRestriction(user_id=user_id, reason="测试限制"))
        db.commit()
    finally:
        db.close()
    response = client.get(f"/api/admin-console/users/{user_id}", headers=_admin())
    assert response.status_code == 200
    data = response.json()["data"]
    assert data["restricted"]["active"] is True
    assert data["restricted"]["reason"] == "测试限制"
    assert data["devices"][0]["platform"] == "harmony"
    assert data["web_count"] == 0
