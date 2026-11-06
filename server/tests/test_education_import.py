"""服务器代抓教务导入已于 2026-09-02 全面下线（合规红线）。

端点一律返回 410 Gone，且不再解析请求体——学号与教务密码根本不会进入
服务端处理流程。原网关行为测试保留在 test_webvpn_import.py /
test_portal_import.py（服务代码保留但无入口可达）。
"""
from uuid import uuid4

from fastapi.testclient import TestClient

from app.main import app

client = TestClient(app)

_PAYLOAD = {"student_id": "12345678", "password": "not-a-real-password"}


def _headers() -> dict[str, str]:
    suffix = uuid4().hex[:10]
    response = client.post(
        "/api/auth/register",
        json={
            "username": f"import{suffix}",
            "email": f"import{suffix}@example.com",
            "password": "password123",
        },
    )
    assert response.status_code == 200, response.text
    return {"Authorization": f"Bearer {response.json()['data']['access_token']}"}


def test_webvpn_import_is_gone_for_authenticated_users():
    response = client.post(
        "/api/education-import/webvpn", headers=_headers(), json=_PAYLOAD
    )
    assert response.status_code == 410
    body = response.json()
    assert body["code"] == 41031
    assert "下线" in body["message"]


def test_webvpn_import_is_gone_without_authentication():
    # 端点连登录都不再要求：不解析请求体，教务密码不进入服务端处理流程。
    response = client.post("/api/education-import/webvpn", json=_PAYLOAD)
    assert response.status_code == 410


def test_webvpn_import_rejects_even_malformed_bodies():
    # 非 JSON/缺字段的载荷同样 410（旧版是 422，证明请求体已不再被校验解析）。
    response = client.post(
        "/api/education-import/webvpn",
        content=b"not-json-at-all",
        headers={"Content-Type": "application/json"},
    )
    assert response.status_code == 410
