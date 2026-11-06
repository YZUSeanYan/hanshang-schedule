"""接口冒烟测试：健康检查、统一错误格式、Swagger 可用。"""
from fastapi.testclient import TestClient

from app.main import app

client = TestClient(app)


def test_健康检查():
    resp = client.get("/api/health")
    assert resp.status_code == 200
    body = resp.json()
    assert body["code"] == 0
    assert body["data"]["status"] == "up"


def test_swagger_文档可用():
    assert client.get("/docs").status_code == 200
    assert client.get("/openapi.json").status_code == 200


def test_登录接口空参数返回统一_422():
    resp = client.post("/api/auth/login", json={})
    assert resp.status_code == 422
    body = resp.json()
    assert body["code"] == 42200
    assert "message" in body


def test_未知路径_404_也是统一格式():
    resp = client.get("/api/not-exists")
    assert resp.status_code == 404
    body = resp.json()
    assert body["code"] == 404
    assert "message" in body
