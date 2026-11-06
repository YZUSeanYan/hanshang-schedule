"""新人课表导入提醒：阶梯触发、防重复、有课跳过、静默时段。"""
from datetime import datetime, timedelta

from fastapi.testclient import TestClient

from app.main import app
from app.db.session import SessionLocal
from app.models.notification import UserNotification
from app.models.onboarding_reminder import OnboardingReminder
from app.models.sync_data import SyncCourse
from app.models.user import User
from app.services.onboarding_reminder import dispatch_onboarding_reminders

client = TestClient(app)

_NOW = datetime(2026, 9, 15, 3, 0, 0)  # UTC 03:00 = 香港 11:00（非静默）


def _register(username: str) -> int:
    response = client.post("/api/auth/register", json={
        "username": username,
        "email": f"{username}@example.com",
        "password": "password123",
    })
    assert response.status_code == 200, response.text
    return response.json()["data"]["user"]["id"]


def _set_created_at(user_id: int, when: datetime) -> None:
    db = SessionLocal()
    try:
        db.query(User).filter(User.id == user_id).update({"created_at": when})
        db.commit()
    finally:
        db.close()


def _add_course(user_id: int) -> None:
    db = SessionLocal()
    try:
        db.add(SyncCourse(
            user_id=user_id, uuid=f"course-{user_id}", semester_uuid="sem-1",
            name="测试课", teacher="", color=0, note="",
            updated_at=1, deleted=False, synced_at=1,
        ))
        db.commit()
    finally:
        db.close()


def _inbox_titles(user_id: int) -> list[str]:
    db = SessionLocal()
    try:
        return [row.title for row in db.query(UserNotification).filter(
            UserNotification.user_id == user_id
        ).all()]
    finally:
        db.close()


def _stages_sent(user_id: int) -> list[str]:
    db = SessionLocal()
    try:
        return sorted(row.stage for row in db.query(OnboardingReminder).filter(
            OnboardingReminder.user_id == user_id
        ).all())
    finally:
        db.close()


def test_two_hours_without_schedule_gets_reminder():
    user_id = _register("onboard_2h")
    _set_created_at(user_id, _NOW - timedelta(hours=3))
    result = dispatch_onboarding_reminders(SessionLocal(), now=_NOW)
    assert result["sent"] >= 1
    assert "还没添加课表？" in _inbox_titles(user_id)
    assert _stages_sent(user_id) == ["2h"]


def test_reminder_not_resent():
    user_id = _register("onboard_dup")
    _set_created_at(user_id, _NOW - timedelta(hours=3))
    dispatch_onboarding_reminders(SessionLocal(), now=_NOW)
    again = dispatch_onboarding_reminders(SessionLocal(), now=_NOW + timedelta(minutes=5))
    assert again["sent"] == 0
    assert len(_inbox_titles(user_id)) == 1


def test_user_with_courses_not_reminded():
    user_id = _register("onboard_has_course")
    _set_created_at(user_id, _NOW - timedelta(days=3))
    _add_course(user_id)
    result = dispatch_onboarding_reminders(SessionLocal(), now=_NOW)
    assert result["sent"] == 0
    assert _inbox_titles(user_id) == []


def test_fresh_user_not_reminded():
    user_id = _register("onboard_fresh")
    _set_created_at(user_id, _NOW - timedelta(minutes=30))
    result = dispatch_onboarding_reminders(SessionLocal(), now=_NOW)
    assert result["sent"] == 0
    assert _inbox_titles(user_id) == []


def test_old_user_gets_only_latest_stage():
    """注册 8 天首次扫到：只发 7d 一条，早期阶段标记跳过不补发。"""
    user_id = _register("onboard_old")
    _set_created_at(user_id, _NOW - timedelta(days=8))
    result = dispatch_onboarding_reminders(SessionLocal(), now=_NOW)
    assert result["sent"] >= 1
    assert _inbox_titles(user_id) == ["邗上课表一直在等你"]
    assert _stages_sent(user_id) == ["12h", "2d", "2h", "5d", "7d"]


def test_quiet_hours_defer():
    user_id = _register("onboard_quiet")
    _set_created_at(user_id, _NOW - timedelta(hours=5))
    quiet_now = datetime(2026, 9, 15, 15, 0, 0)  # UTC 15:00 = 香港 23:00
    result = dispatch_onboarding_reminders(SessionLocal(), now=quiet_now)
    assert result["quiet"] is True
    assert result["sent"] == 0
    assert _inbox_titles(user_id) == []
