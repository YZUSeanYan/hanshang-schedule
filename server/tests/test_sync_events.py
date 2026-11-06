"""个人日程同步（AI 日程 2.0）：推送、LWW、墓碑、多用户隔离、共同空闲并入。"""
import time

from fastapi.testclient import TestClient

from app.main import app

client = TestClient(app)

_NOW = int(time.time() * 1000)


def _headers(suffix: str) -> dict:
    resp = client.post(
        "/api/auth/register",
        json={
            "username": f"ev{suffix}",
            "email": f"ev{suffix}@example.com",
            "password": "password123",
        },
    )
    assert resp.status_code == 200, resp.text
    return {"Authorization": f"Bearer {resp.json()['data']['access_token']}"}


def _event(uuid: str, updated_at: int, **kw) -> dict:
    base = {
        "uuid": uuid,
        "title": "社会实践手册评审",
        "event_type": "event",
        "date": "2026-09-16",
        "weekday": 0,
        "start_time": "15:30",
        "end_time": "17:30",
        "start_section": 0,
        "end_section": 0,
        "busy_sections": "8,9,10",
        "location": "学院515",
        "note": "",
        "color": 0,
        "remind_minutes": -1,
        "source": "voice",
        "updated_at": updated_at,
        "deleted": False,
    }
    base.update(kw)
    return base


def test_events_push_and_pull_roundtrip():
    h = _headers("push1")
    resp = client.post("/api/sync/push", headers=h, json={"events": [_event("evt-1", _NOW)]})
    assert resp.status_code == 200, resp.text
    assert resp.json()["data"]["applied"]["events"] == 1

    pull = client.get("/api/sync/pull", headers=h, params={"since": 0})
    body = pull.json()["data"]
    assert len(body["events"]) == 1
    row = body["events"][0]
    assert row["uuid"] == "evt-1"
    assert row["title"] == "社会实践手册评审"
    assert row["busy_sections"] == "8,9,10"
    assert row["start_time"] == "15:30"
    assert row["source"] == "voice"
    assert "id" not in row and "user_id" not in row


def test_events_lww_and_tombstone():
    h = _headers("lww1")
    client.post("/api/sync/push", headers=h, json={"events": [_event("evt-2", _NOW)]})
    # 旧写入被拒
    stale = client.post(
        "/api/sync/push",
        headers=h,
        json={"events": [_event("evt-2", _NOW - 1000, title="旧标题")]},
    )
    assert stale.json()["data"]["conflicts"]["events"] == 1
    # 新写入覆盖
    fresh = client.post(
        "/api/sync/push",
        headers=h,
        json={"events": [_event("evt-2", _NOW + 1000, title="新标题")]},
    )
    assert fresh.json()["data"]["applied"]["events"] == 1
    # 墓碑
    client.post(
        "/api/sync/push",
        headers=h,
        json={"events": [{"uuid": "evt-2", "updated_at": _NOW + 2000, "deleted": True}]},
    )
    pull = client.get("/api/sync/pull", headers=h, params={"since": 0})
    rows = pull.json()["data"]["events"]
    assert len(rows) == 1
    assert rows[0]["deleted"] is True


def test_events_isolated_between_users():
    h1 = _headers("iso1")
    h2 = _headers("iso2")
    client.post("/api/sync/push", headers=h1, json={"events": [_event("evt-iso", _NOW)]})
    pull = client.get("/api/sync/pull", headers=h2, params={"since": 0})
    assert pull.json()["data"]["events"] == []


def test_event_validation_rejects_bad_values():
    h = _headers("val1")
    bad = _event("evt-bad", _NOW, start_time="25:00")
    resp = client.post("/api/sync/push", headers=h, json={"events": [bad]})
    assert resp.status_code == 422
    bad2 = _event("evt-bad2", _NOW, event_type="party")
    resp = client.post("/api/sync/push", headers=h, json={"events": [bad2]})
    assert resp.status_code == 422


def _couple_setup() -> tuple[dict, dict]:
    """注册一对用户并完成配对，返回双方 headers。"""
    suffix = str(_NOW % 100000)
    name_a, name_b = f"cpa{suffix}", f"cpb{suffix}"
    resp_a = client.post(
        "/api/auth/register",
        json={"username": name_a, "email": f"{name_a}@example.com", "password": "password123"},
    )
    resp_b = client.post(
        "/api/auth/register",
        json={"username": name_b, "email": f"{name_b}@example.com", "password": "password123"},
    )
    ha = {"Authorization": f"Bearer {resp_a.json()['data']['access_token']}"}
    hb = {"Authorization": f"Bearer {resp_b.json()['data']['access_token']}"}
    module = {"X-App-Module": "couple_schedule"}
    invite = client.post("/api/couple-schedule/invites", headers={**ha, **module}, json={"username": name_b})
    assert invite.status_code == 200, invite.text
    invitation_id = invite.json()["data"]["invitation_id"]
    accept = client.post(
        "/api/couple-schedule/invites/respond",
        headers={**hb, **module},
        json={"invitation_id": invitation_id, "accept": True},
    )
    assert accept.status_code == 200, accept.text
    return ha, hb


def test_couple_week_includes_personal_events():
    ha, hb = _couple_setup()
    module = {"X-App-Module": "couple_schedule"}
    # 双方都需要一个覆盖目标周的学期，课程网格才有意义；日程不依赖学期
    sem = {
        "uuid": "sem-cp",
        "name": "2026秋",
        "start_date": "2026-08-31",
        "total_weeks": 20,
        "is_current": True,
        "updated_at": _NOW,
        "deleted": False,
    }
    client.post("/api/sync/push", headers=ha, json={"semesters": [sem]})
    client.post("/api/sync/push", headers=hb, json={"semesters": [sem]})
    # A 在 2026-09-16（周三）有一个占 8-10 节的一次性日程
    client.post(
        "/api/sync/push",
        headers=ha,
        json={"events": [_event("evt-cp", _NOW, date="2026-09-16", busy_sections="8,9,10")]},
    )
    # A 还有一个每周一 1-2 节的例会；一个不该计入的 DDL
    client.post(
        "/api/sync/push",
        headers=ha,
        json={
            "events": [
                _event(
                    "evt-rec",
                    _NOW,
                    title="社团例会",
                    event_type="recurring",
                    date="",
                    weekday=1,
                    start_time="",
                    end_time="",
                    busy_sections="1,2",
                ),
                _event(
                    "evt-ddl",
                    _NOW,
                    title="交实验报告",
                    event_type="ddl",
                    date="2026-09-17",
                    start_time="",
                    end_time="",
                    busy_sections="",
                ),
            ]
        },
    )
    week = client.get(
        "/api/couple-schedule/week",
        headers={**hb, **module},
        params={"week_start": "2026-09-14"},
    )
    assert week.status_code == 200, week.text
    days = {d["day"]: d["states"] for d in week.json()["data"]["days"]}
    # 周三（day=3）8-10 节：A 忙 B 闲 → me_busy（对 B 来说是 partner_busy）
    assert days[3][7] == "partner_busy"
    assert days[3][9] == "partner_busy"
    assert days[3][6] == "both_free"
    # 周一（day=1）1-2 节：周期日程也计入
    assert days[1][0] == "partner_busy"
    assert days[1][1] == "partner_busy"
    assert days[1][2] == "both_free"
    # 周四 DDL 不影响空闲
    assert all(state == "both_free" for state in days[4])
