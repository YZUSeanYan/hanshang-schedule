"""调休覆盖同步 + 调休通知 AI 解析端点测试。"""
import uuid

from fastapi.testclient import TestClient

from app.api.v1.endpoints import schedule_ai
from app.main import app
from app.services.llm_event_parse import EventParseError

client = TestClient(app)


def _headers() -> dict:
    suffix = uuid.uuid4().hex[:10]
    response = client.post("/api/auth/register", json={
        "username": f"ovr{suffix}", "email": f"ovr{suffix}@example.com", "password": "password123",
    })
    assert response.status_code == 200, response.text
    return {"Authorization": f"Bearer {response.json()['data']['access_token']}"}


def test_override_sync_roundtrip():
    headers = _headers()
    payload = {
        "overrides": [{
            "uuid": "ovr-semester-holiday", "date": "2026-10-01", "kind": "off",
            "weekday": 0, "note": "国庆假期", "updated_at": 1789000000000, "deleted": False,
        }, {
            "uuid": "ovr-makeup-1", "date": "2026-10-11", "kind": "makeup",
            "weekday": 3, "note": "补周三课", "updated_at": 1789000000001, "deleted": False,
        }],
    }
    pushed = client.post("/api/sync/push", headers=headers, json=payload)
    assert pushed.status_code == 200, pushed.text
    assert pushed.json()["data"]["applied"]["overrides"] == 2

    pulled = client.get("/api/sync/pull?since=0", headers=headers)
    rows = pulled.json()["data"]["overrides"]
    assert {row["date"] for row in rows} == {"2026-10-01", "2026-10-11"}
    makeup = next(row for row in rows if row["kind"] == "makeup")
    assert makeup["weekday"] == 3 and makeup["note"] == "补周三课"


def test_override_rejects_bad_kind():
    headers = _headers()
    bad = client.post("/api/sync/push", headers=headers, json={
        "overrides": [{
            "uuid": "x", "date": "2026-10-01", "kind": "party",
            "updated_at": 1, "deleted": False,
        }],
    })
    assert bad.status_code == 422


class _FakeHolidayGateway:
    async def parse_holiday(self, *, text, image_b64, year):
        assert year >= 2026
        return [
            {"date": "2026-10-01", "kind": "off", "weekday": 0, "note": "国庆假期"},
            {"date": "2026-10-11", "kind": "makeup", "weekday": 3, "note": "补周三课"},
        ]


class _EmptyHolidayGateway:
    async def parse_holiday(self, *, text, image_b64, year):
        raise EventParseError(422, 42253, "没有识别到调休安排，换张更清晰的截图或换种说法")


def test_holiday_parse_returns_adjustments(monkeypatch):
    monkeypatch.setattr(schedule_ai, "_gateway", _FakeHolidayGateway())
    schedule_ai._user_daily_limiter._hits.clear()
    headers = _headers()
    response = client.post("/api/schedule-ai/holiday-parse", headers=headers,
                           json={"text": "10月1日至7日放假，10月11日补周三的课"})
    assert response.status_code == 200, response.text
    data = response.json()["data"]["adjustments"]
    assert len(data) == 2
    assert data[1]["kind"] == "makeup" and data[1]["weekday"] == 3


def test_holiday_parse_empty_result_is_422(monkeypatch):
    monkeypatch.setattr(schedule_ai, "_gateway", _EmptyHolidayGateway())
    schedule_ai._user_daily_limiter._hits.clear()
    headers = _headers()
    response = client.post("/api/schedule-ai/holiday-parse", headers=headers,
                           json={"text": "今天天气不错"})
    assert response.status_code == 422
    assert response.json()["code"] == 42253


def test_holiday_parse_requires_auth():
    assert client.post("/api/schedule-ai/holiday-parse", json={"text": "x"}).status_code == 401
