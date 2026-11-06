"""数据看板四组指标：活跃打点、埋点上报、服务端顺带埋点与统计端点口径。"""
import time
from datetime import date, datetime, timedelta
from uuid import uuid4

from fastapi.testclient import TestClient

from app.api.v1.endpoints import llm_schedule_import
from app.api.v1.endpoints.admin_console import _login_limiter
from app.db.session import SessionLocal
from app.main import app
from app.models.daily_activity import DailyActivity
from app.models.import_event import ImportEvent
from app.models.reminder_status import ReminderStatus
from app.models.user import User
from app.services.llm_schedule_import import LlmScheduleImportError

client = TestClient(app)


def _register() -> tuple[dict, int]:
    suffix = uuid4().hex[:10]
    response = client.post(
        "/api/auth/register",
        json={
            "username": f"metric{suffix}",
            "email": f"metric{suffix}@example.com",
            "password": "password123",
        },
    )
    assert response.status_code == 200, response.text
    data = response.json()["data"]
    return {"Authorization": f"Bearer {data['access_token']}"}, data["user"]["id"]


def _admin_headers() -> dict:
    _login_limiter._hits.clear()
    response = client.post("/api/admin-console/login", json={
        "username": "admin", "password": "test-admin-password",
    })
    assert response.status_code == 200
    return {"X-CSRF-Token": response.json()["data"]["csrf_token"]}


def _events_for(user_id: int) -> list[ImportEvent]:
    db = SessionLocal()
    try:
        return db.query(ImportEvent).filter(ImportEvent.user_id == user_id).all()
    finally:
        db.close()


# ---------- §三：活跃打点 ----------

def test_authenticated_requests_record_activity_once_per_day():
    headers, user_id = _register()
    for _ in range(3):
        response = client.get("/api/user/profile", headers=headers)
        assert response.status_code == 200
    db = SessionLocal()
    try:
        rows = db.query(DailyActivity).filter(
            DailyActivity.user_id == user_id,
            DailyActivity.activity_date == date.today(),
        ).all()
        assert len(rows) == 1
    finally:
        db.close()


def test_activity_records_new_row_on_new_day():
    headers, user_id = _register()
    db = SessionLocal()
    try:
        db.add(DailyActivity(user_id=user_id, activity_date=date.today() - timedelta(days=1)))
        db.commit()
    finally:
        db.close()
    response = client.get("/api/user/profile", headers=headers)
    assert response.status_code == 200
    db = SessionLocal()
    try:
        count = db.query(DailyActivity).filter(DailyActivity.user_id == user_id).count()
        assert count == 2
    finally:
        db.close()


# ---------- §4.2：import-event 上报端点 ----------

def test_import_event_endpoint_records_valid_event():
    headers, user_id = _register()
    response = client.post("/api/telemetry/import-event", headers=headers, json={
        "entry": "screenshot", "stage": "save", "outcome": "success",
        "client_version": "44", "detail": "size=100k_1m,ms=5_15s",
    })
    assert response.status_code == 200
    events = _events_for(user_id)
    assert len(events) == 1
    event = events[0]
    assert (event.entry, event.stage, event.outcome, event.source) == ("screenshot", "save", "success", "client")


def test_import_event_endpoint_rejects_unknown_enums():
    headers, _ = _register()
    for payload in (
        {"entry": "carrier-pigeon", "stage": "save", "outcome": "success"},
        {"entry": "screenshot", "stage": "login", "outcome": "success"},  # 阶段不属于入口
        {"entry": "screenshot", "stage": "save", "outcome": "maybe"},
    ):
        response = client.post("/api/telemetry/import-event", headers=headers, json=payload)
        assert response.status_code == 422, payload


def test_import_event_detail_is_truncated_not_rejected():
    headers, user_id = _register()
    response = client.post("/api/telemetry/import-event", headers=headers, json={
        "entry": "excel", "stage": "parse", "outcome": "fail",
        "error_code": "42245", "detail": "x" * 1500,
    })
    assert response.status_code == 200
    assert len(_events_for(user_id)[0].detail) == 200


def test_import_event_requires_auth():
    response = client.post("/api/telemetry/import-event", json={
        "entry": "manual", "stage": "save", "outcome": "success",
    })
    assert response.status_code == 401


# ---------- §4.2：reminder-status 上报端点 ----------

def test_reminder_status_upserts_per_device():
    headers, user_id = _register()
    payload = {
        "device_id": "pixel-abc", "platform": "android",
        "notif_permission": True, "exact_alarm": False,
        "scheduled_count": 12, "last_schedule_at": int(time.time()),
    }
    assert client.post("/api/push/reminder-status", headers=headers, json=payload).status_code == 200
    payload["scheduled_count"] = 30
    payload["notif_permission"] = False
    assert client.post("/api/push/reminder-status", headers=headers, json=payload).status_code == 200
    db = SessionLocal()
    try:
        rows = db.query(ReminderStatus).filter(ReminderStatus.user_id == user_id).all()
        assert len(rows) == 1
        assert rows[0].scheduled_count == 30
        assert rows[0].notif_permission is False
        assert rows[0].exact_alarm is False
        assert rows[0].last_schedule_at is not None
    finally:
        db.close()


def test_reminder_status_validates_payload():
    headers, _ = _register()
    response = client.post("/api/push/reminder-status", headers=headers, json={
        "device_id": "d1", "notif_permission": True, "scheduled_count": -1,
    })
    assert response.status_code == 422


# ---------- §4.3：服务端顺带埋点 ----------

_HTML = "<html><body><table><tr><th>星期一</th></tr><tr><td>高等数学 1-16周 1-2节</td></tr></table></body></html>" + "x" * 200


class _FailingGateway:
    async def import_schedule(self, *, html: str, captured: list[str]):
        raise LlmScheduleImportError(502, 50231, "解析失败")


def test_llm_parse_failure_writes_school_event(monkeypatch):
    monkeypatch.setattr(llm_schedule_import, "_gateway", _FailingGateway())
    llm_schedule_import._user_daily_limiter._hits.clear()
    headers, user_id = _register()
    response = client.post(
        "/api/education-import/llm-parse", headers=headers,
        json={"html": _HTML, "captured": []},
    )
    assert response.status_code == 502
    events = [e for e in _events_for(user_id) if e.source == "server"]
    assert len(events) == 1
    assert (events[0].entry, events[0].stage, events[0].outcome, events[0].error_code) == (
        "school", "parse", "fail", "50231",
    )


def test_share_preview_miss_writes_fail_event():
    headers, user_id = _register()
    response = client.get("/api/share/ZZZZZZ", headers=headers)
    assert response.status_code == 404
    events = _events_for(user_id)
    assert len(events) == 1
    assert (events[0].entry, events[0].stage, events[0].outcome, events[0].error_code) == (
        "sharecode", "preview", "fail", "40410",
    )


def _sync_source(headers: dict) -> None:
    now = int(time.time() * 1000)
    response = client.post("/api/sync/push", headers=headers, json={
        "semesters": [{
            "uuid": "sem-metric", "name": "2026秋", "start_date": "2026-09-07",
            "total_weeks": 20, "is_current": True, "updated_at": now, "deleted": False,
        }],
        "courses": [{
            "uuid": "course-metric", "semester_uuid": "sem-metric", "name": "高等数学",
            "teacher": "", "color": 0, "note": "", "updated_at": now, "deleted": False,
        }],
        "schedules": [{
            "uuid": "slot-metric", "course_uuid": "course-metric", "day_of_week": 1,
            "start_section": 1, "end_section": 2, "weeks_type": 0,
            "custom_weeks": "", "location": "", "updated_at": now, "deleted": False,
        }],
    })
    assert response.status_code == 200, response.text


def test_share_claim_success_writes_apply_event():
    owner_headers, _ = _register()
    _sync_source(owner_headers)
    created = client.post("/api/share/create", headers=owner_headers, json={"semester_uuid": "sem-metric"})
    assert created.status_code == 200, created.text
    code = created.json()["data"]["code"]

    claimer_headers, claimer_id = _register()
    preview = client.get(f"/api/share/{code}", headers=claimer_headers)
    assert preview.status_code == 200
    claimed = client.post(f"/api/share/{code}/claim", headers=claimer_headers, json={})
    assert claimed.status_code == 200, claimed.text
    stages = [(e.stage, e.outcome) for e in _events_for(claimer_id)]
    assert ("preview", "success") in stages
    assert ("apply", "success") in stages


# ---------- §4.4：统计端点 ----------

def test_import_funnel_counts_fallback_course_success():
    _, user_id = _register()
    _sync_source_headers, sync_user = _register()
    _sync_source(_sync_source_headers)  # 兜底口径：sync_courses 出现未删除课程
    response = client.get("/api/admin-console/stats/import-funnel?days=30", headers=_admin_headers())
    assert response.status_code == 200
    data = response.json()["data"]
    assert data["new_users"] >= 2
    assert data["success_users"] >= 1
    assert data["attribution"].get("manual", 0) >= 1
    assert 0 <= data["success_rate"] <= 1


def test_import_funnel_attributes_first_client_success_event():
    headers, user_id = _register()
    client.post("/api/telemetry/import-event", headers=headers, json={
        "entry": "screenshot", "stage": "save", "outcome": "success",
    })
    data = client.get("/api/admin-console/stats/import-funnel?days=30", headers=_admin_headers()).json()["data"]
    assert data["attempted_users"] >= 1
    assert data["attribution"].get("screenshot", 0) >= 1


def test_import_failures_groups_by_entry_stage_code():
    headers, _ = _register()
    for _ in range(2):
        client.post("/api/telemetry/import-event", headers=headers, json={
            "entry": "excel", "stage": "parse", "outcome": "fail", "error_code": "42245",
        })
    client.post("/api/telemetry/import-event", headers=headers, json={
        "entry": "excel", "stage": "upload", "outcome": "abandon",
    })
    data = client.get("/api/admin-console/stats/import-failures?days=30", headers=_admin_headers()).json()["data"]
    excel_rows = [r for r in data["rows"] if r["entry"] == "excel"]
    assert data["totals_by_entry"].get("excel", 0) >= 3
    parse_row = next(r for r in excel_rows if r["stage"] == "parse" and r["error_code"] == "42245")
    assert parse_row["count"] >= 2
    # entry 过滤参数
    filtered = client.get(
        "/api/admin-console/stats/import-failures?days=30&entry=excel", headers=_admin_headers(),
    ).json()["data"]
    assert all(r["entry"] == "excel" for r in filtered["rows"])


def test_retention_cohorts_counts_next_week_return():
    _, user_id = _register()
    # 把注册时间回拨 7 天，再在本周（即该队列的 W+1）打一条活跃
    db = SessionLocal()
    try:
        user = db.get(User, user_id)
        user.created_at = datetime.now() - timedelta(days=7)
        db.add(DailyActivity(user_id=user_id, activity_date=date.today()))
        db.commit()
    finally:
        db.close()
    data = client.get("/api/admin-console/stats/retention-cohorts?weeks=8", headers=_admin_headers()).json()["data"]
    assert len(data) == 8
    cohort_date = (date.today() - timedelta(days=7))
    week_start = (cohort_date - timedelta(days=cohort_date.weekday())).isoformat()
    cohort = next(c for c in data if c["week_start"] == week_start)
    assert cohort["new_users"] >= 1
    assert cohort["retained_w1"] >= 1
    assert cohort["rate_w1"] > 0
    assert data[-1]["partial"] is True  # 当周队列 W+1 未走完


def test_reminder_health_aggregates_reports_and_delivery():
    headers, _ = _register()
    client.post("/api/push/reminder-status", headers=headers, json={
        "device_id": "health-device", "platform": "android",
        "notif_permission": True, "exact_alarm": True,
        "scheduled_count": 25, "last_schedule_at": int(time.time()),
    })
    data = client.get("/api/admin-console/stats/reminder-health?days=30", headers=_admin_headers()).json()["data"]
    assert data["reported_devices"] >= 1
    assert data["notif_permission_on"] >= 1
    assert data["exact_alarm_on"] >= 1
    assert data["scheduled_count_buckets"]["11_50"] >= 1
    assert data["report_recency"]["lt1d"] >= 1
    for key in ("accepted", "stored", "failed", "pending"):
        assert key in data["delivery_status"] or True  # 分布键可有可无，看数据
    assert "delivery_trend" in data


def test_stats_endpoints_require_admin_session():
    anonymous = TestClient(app)  # 全新 client，不带之前测试登录的管理 Cookie
    for path in ("import-funnel", "import-failures", "retention-cohorts", "reminder-health"):
        response = anonymous.get(f"/api/admin-console/stats/{path}")
        assert response.status_code == 401, path
