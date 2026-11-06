"""版本更新接口测试。"""
from fastapi.testclient import TestClient

from app.main import app

client = TestClient(app)

_ADMIN = {"X-Admin-Token": "test-admin-token"}


def test_无版本时返回无更新():
    resp = client.get("/api/version/latest", params={"current_code": 1})
    assert resp.status_code == 200
    assert resp.json()["data"]["has_update"] is False


def test_无管理令牌发布被拒():
    resp = client.post("/api/admin/versions", json={
        "version_name": "1.0.0", "version_code": 100,
        "apk_url": "https://example.com/app.apk", "sha256": "ab" * 32,
    })
    assert resp.status_code == 403
    assert resp.json()["code"] == 40300


def test_发布版本并检测更新():
    resp = client.post("/api/admin/versions", headers=_ADMIN, json={
        "version_name": "1.0.0", "version_code": 100,
        "apk_url": "https://example.com/app-v1.0.0.apk",
        "sha256": "ab" * 32, "release_notes": "首个版本",
    })
    assert resp.status_code == 200, resp.text

    # 低版本 → 有更新
    data = client.get("/api/version/latest", params={"current_code": 1}).json()["data"]
    assert data["has_update"] is True
    assert data["version_name"] == "1.0.0"
    assert data["sha256"] == "ab" * 32

    # 同等/更高版本 → 无更新
    data = client.get("/api/version/latest", params={"current_code": 100}).json()["data"]
    assert data["has_update"] is False


def test_重复发布同一版本号被拒():
    resp = client.post("/api/admin/versions", headers=_ADMIN, json={
        "version_name": "1.0.0", "version_code": 100,
        "apk_url": "https://example.com/a.apk", "sha256": "cd" * 32,
    })
    assert resp.status_code == 409
    assert resp.json()["code"] == 40903


def test_发布版本必须提供完整_sha256():
    resp = client.post("/api/admin/versions", headers=_ADMIN, json={
        "version_name": "1.0.1", "version_code": 101,
        "apk_url": "https://example.com/app-v1.0.1.apk", "sha256": "abc",
    })
    assert resp.status_code == 422
    assert resp.json() == {"code": 42200, "message": "请求参数格式不正确"}


def test_force_codes_只对指定旧版本强制():
    resp = client.post("/api/admin/versions", headers=_ADMIN, json={
        "version_name": "1.0.31", "version_code": 131,
        "apk_url": "https://example.com/a.apk", "sha256": "ef" * 32,
        "release_notes": "修复 AI 导入", "is_force_update": False,
        "force_codes": "130",
    })
    assert resp.status_code == 200, resp.text

    # 被点名的旧版本 → 强制
    data = client.get("/api/version/latest", params={"current_code": 130}).json()["data"]
    assert data["has_update"] is True
    assert data["is_force_update"] is True

    # 其他旧版本 → 可选
    data = client.get("/api/version/latest", params={"current_code": 129}).json()["data"]
    assert data["has_update"] is True
    assert data["is_force_update"] is False

    # 已是最新 → 无更新且不强制
    data = client.get("/api/version/latest", params={"current_code": 131}).json()["data"]
    assert data["has_update"] is False
    assert data["is_force_update"] is False


def test_force_codes_拒绝非法格式():
    resp = client.post("/api/admin/versions", headers=_ADMIN, json={
        "version_name": "1.0.32", "version_code": 132,
        "apk_url": "https://example.com/a.apk", "sha256": "ab" * 32,
        "force_codes": "abc",
    })
    assert resp.status_code == 422
