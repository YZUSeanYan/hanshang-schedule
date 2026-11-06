"""管理后台版本发布管理端点测试（统一标准：定向=有目标账号，正式=无）。"""
import pytest
from fastapi.testclient import TestClient
from sqlalchemy import delete, select

from app.api.v1.endpoints.admin_console import _login_limiter
from app.db.session import SessionLocal
from app.main import app
from app.models.app_version import AppVersion
from app.models.release_target import AppVersionTarget

client = TestClient(app)

_counter = [900]
_created_codes: set[int] = set()


@pytest.fixture(autouse=True, scope="module")
def _cleanup_published_versions():
    """本模块发布的测试版本在结束时清除，避免污染共享测试库里的其他版本测试。"""
    yield
    db = SessionLocal()
    try:
        for code in _created_codes:
            row = db.scalar(select(AppVersion).where(AppVersion.version_code == code))
            if row is not None:
                db.execute(delete(AppVersionTarget).where(AppVersionTarget.version_id == row.id))
                db.delete(row)
        db.commit()
    finally:
        db.close()


def _admin_headers() -> dict:
    _login_limiter._hits.clear()
    response = client.post("/api/admin-console/login", json={
        "username": "admin", "password": "test-admin-password",
    })
    assert response.status_code == 200
    return {"X-CSRF-Token": response.json()["data"]["csrf_token"]}


def _register(username: str) -> int:
    response = client.post("/api/auth/register", json={
        "username": username, "email": f"{username}@example.com", "password": "password123",
    })
    assert response.status_code == 200, response.text
    return response.json()["data"]["user"]["id"]


def _publish_payload(code: int, targets=None, notify=False, force=False) -> dict:
    _created_codes.add(code)
    return {
        "version_name": f"2.0.0-test{code}",
        "version_code": code,
        "apk_url": "https://api.seanyan.store/yzu-apk/test.apk",
        "sha256": "a" * 64,
        "release_notes": "测试发布",
        "is_force_update": force,
        "target_accounts": targets or [],
        "notify_targets": notify,
    }


def test_publish_stable_via_admin_session():
    headers = _admin_headers()
    code = _counter[0] = _counter[0] + 1
    response = client.post("/api/admin-console/versions", headers=headers, json=_publish_payload(code))
    assert response.status_code == 200, response.text
    data = response.json()["data"]
    assert data["release_channel"] == "stable"
    assert data["target_user_ids"] == []


def _publish_targeted_for_user(username: str):
    """发布一个定向给 username 的版本，返回 (version_id, user_id)。"""
    headers = _admin_headers()
    user_id = _register(username)
    code = _counter[0] = _counter[0] + 1
    ok = client.post("/api/admin-console/versions", headers=headers,
                     json=_publish_payload(code, targets=[username]))
    assert ok.status_code == 200, ok.text
    return ok.json()["data"]["id"], user_id


def test_publish_targeted_and_visibility_rules():
    headers = _admin_headers()
    user_id = _register("vtarget_user")
    code = _counter[0] = _counter[0] + 1
    # 定向+强更应被 422 拒绝（统一标准）
    bad = client.post("/api/admin-console/versions", headers=headers,
                      json=_publish_payload(code, targets=["vtarget_user"], force=True))
    assert bad.status_code == 422
    # 定向不存在的账号 → 422 带 missing
    missing = client.post("/api/admin-console/versions", headers=headers,
                          json=_publish_payload(code, targets=["no_such_user_xx"]))
    assert missing.status_code == 422
    # 正常定向发布
    ok = client.post("/api/admin-console/versions", headers=headers,
                     json=_publish_payload(code, targets=["vtarget_user"]))
    assert ok.status_code == 200, ok.text
    data = ok.json()["data"]
    assert data["release_channel"] == "targeted_test"
    assert data["target_user_ids"] == [user_id]
    # 重复 version_code → 409
    dup = client.post("/api/admin-console/versions", headers=headers, json=_publish_payload(code))
    assert dup.status_code == 409


def test_versions_list_and_target_management():
    version_id, user_id = _publish_targeted_for_user("vtarget_list_user")
    headers = _admin_headers()
    # 列表包含定向信息
    listing = client.get("/api/admin-console/versions", headers=headers)
    assert listing.status_code == 200
    row = next(r for r in listing.json()["data"] if r["id"] == version_id)
    assert row["channel"] == "targeted_test"
    assert row["targets"][0]["user_id"] == user_id
    # 加目标（已有则幂等）
    again = client.post(f"/api/admin-console/versions/{version_id}/targets",
                        headers=headers, json={"account": "vtarget_list_user", "notify": False})
    assert again.status_code == 200
    assert again.json()["data"]["added"] == []
    # 加另一个账号 + 通知
    other_id = _register("vtarget_other")
    added = client.post(f"/api/admin-console/versions/{version_id}/targets",
                        headers=headers, json={"account": "vtarget_other", "notify": True})
    assert added.status_code == 200
    assert added.json()["data"]["added"] == [other_id]
    # 移除目标
    removed = client.delete(f"/api/admin-console/versions/{version_id}/targets/{other_id}",
                            headers=headers)
    assert removed.status_code == 200
    assert removed.json()["data"]["removed"] is True
    # 再删一次 → removed False
    again2 = client.delete(f"/api/admin-console/versions/{version_id}/targets/{other_id}",
                           headers=headers)
    assert again2.json()["data"]["removed"] is False


def test_add_target_validations():
    headers = _admin_headers()
    response = client.post("/api/admin-console/versions/99999/targets",
                           headers=headers, json={"account": "x", "notify": False})
    assert response.status_code == 404
    code = _counter[0] = _counter[0] + 1
    pub = client.post("/api/admin-console/versions", headers=headers, json=_publish_payload(code))
    vid = pub.json()["data"]["id"]
    bad = client.post(f"/api/admin-console/versions/{vid}/targets",
                      headers=headers, json={"account": "ghost_user_xx", "notify": False})
    assert bad.status_code == 422


def test_versions_endpoints_require_admin_session():
    anonymous = TestClient(app)
    assert anonymous.get("/api/admin-console/versions").status_code == 401
    assert anonymous.post("/api/admin-console/versions", json={}).status_code == 401
    assert anonymous.post("/api/admin-console/versions/1/targets", json={}).status_code == 401
    assert anonymous.delete("/api/admin-console/versions/1/targets/1").status_code == 401
