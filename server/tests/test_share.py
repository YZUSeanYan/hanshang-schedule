"""Share-code API tests: snapshots stay private and claims create copies."""
import time
from uuid import uuid4

from fastapi.testclient import TestClient

from app.main import app
from app.models.share_code import ShareCode
from app.db.session import SessionLocal

client = TestClient(app)


def _headers() -> dict:
    suffix = uuid4().hex[:10]
    response = client.post(
        "/api/auth/register",
        json={
            "username": f"share{suffix}",
            "email": f"share{suffix}@example.com",
            "password": "password123",
        },
    )
    assert response.status_code == 200, response.text
    return {"Authorization": f"Bearer {response.json()['data']['access_token']}"}


def _sync_source(headers: dict, *, semester_uuid: str = "semester-share") -> None:
    now = int(time.time() * 1000)
    response = client.post(
        "/api/sync/push",
        headers=headers,
        json={
            "semesters": [{
                "uuid": semester_uuid,
                "name": "2026秋",
                "start_date": "2026-09-07",
                "total_weeks": 20,
                "is_current": True,
                "updated_at": now,
                "deleted": False,
            }],
            "courses": [{
                "uuid": "course-share",
                "semester_uuid": semester_uuid,
                "name": "高等数学",
                "teacher": "张老师",
                "color": 123,
                "note": "仅分享者可见的私人备注",
                "updated_at": now,
                "deleted": False,
            }],
            "schedules": [{
                "uuid": "slot-share",
                "course_uuid": "course-share",
                "day_of_week": 1,
                "start_section": 1,
                "end_section": 2,
                "weeks_type": 0,
                "custom_weeks": "",
                "location": "文汇楼101",
                "updated_at": now,
                "deleted": False,
            }],
        },
    )
    assert response.status_code == 200, response.text


def _create_code(headers: dict) -> str:
    response = client.post(
        "/api/share/create",
        headers=headers,
        json={"semester_uuid": "semester-share"},
    )
    assert response.status_code == 200, response.text
    return response.json()["data"]["code"]


def test_share_preview_requires_login_and_excludes_owner_data():
    owner = _headers()
    _sync_source(owner)
    code = _create_code(owner)

    unauthenticated = client.get(f"/api/share/{code}")
    assert unauthenticated.status_code == 401

    preview = client.get(f"/api/share/{code}", headers=_headers())
    assert preview.status_code == 200, preview.text
    payload = preview.json()["data"]["payload"]
    assert payload["semester"]["name"] == "2026秋"
    assert payload["courses"][0]["slots"][0]["location"] == "文汇楼101"
    assert "owner" not in preview.json()["data"]
    assert "email" not in str(payload)
    assert "password" not in str(payload)
    assert "note" not in payload["courses"][0]
    assert "私人备注" not in str(payload)


def test_claim_makes_fresh_user_owned_copy_and_requires_overwrite_confirmation():
    owner = _headers()
    _sync_source(owner)
    code = _create_code(owner)
    recipient = _headers()

    claim = client.post(f"/api/share/{code}/claim", headers=recipient, json={})
    assert claim.status_code == 200, claim.text
    claimed_semester_uuid = claim.json()["data"]["semester_uuid"]
    assert claimed_semester_uuid != "semester-share"

    pull = client.get("/api/sync/pull", headers=recipient, params={"since": 0})
    data = pull.json()["data"]
    assert data["semesters"][0]["uuid"] == claimed_semester_uuid
    assert data["courses"][0]["semester_uuid"] == claimed_semester_uuid
    assert data["courses"][0]["uuid"] != "course-share"
    assert data["schedules"][0]["course_uuid"] == data["courses"][0]["uuid"]

    conflict = client.post(f"/api/share/{code}/claim", headers=recipient, json={})
    assert conflict.status_code == 409
    overwrite = client.post(
        f"/api/share/{code}/claim",
        headers=recipient,
        json={"replace_existing": True},
    )
    assert overwrite.status_code == 200, overwrite.text


def test_revoked_or_expired_code_is_not_discoverable():
    owner = _headers()
    _sync_source(owner)
    code = _create_code(owner)
    revoke = client.delete(f"/api/share/{code}", headers=owner)
    assert revoke.status_code == 200
    assert client.get(f"/api/share/{code}", headers=_headers()).status_code == 404

    fresh_code = _create_code(owner)
    db = SessionLocal()
    try:
        record = db.query(ShareCode).filter(ShareCode.code == fresh_code).one()
        record.expires_at = record.created_at
        db.commit()
    finally:
        db.close()
    assert client.get(f"/api/share/{fresh_code}", headers=_headers()).status_code == 404


def test_cors_allows_only_the_official_web_origin():
    allowed = client.options(
        "/api/share/ABCDEF",
        headers={
            "Origin": "https://hanshang.seanyan.store",
            "Access-Control-Request-Method": "GET",
        },
    )
    assert allowed.headers["access-control-allow-origin"] == "https://hanshang.seanyan.store"
    blocked = client.options(
        "/api/share/ABCDEF",
        headers={
            "Origin": "https://example.invalid",
            "Access-Control-Request-Method": "GET",
        },
    )
    assert "access-control-allow-origin" not in blocked.headers
