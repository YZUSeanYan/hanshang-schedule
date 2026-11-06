"""设备配对码（手表登录）接口测试。

配对码流程：手机端登录 -> POST /api/auth/device-pair 生成 6 位数字码 ->
手表输码 -> POST /api/auth/device-pair/claim 换取令牌（免登录）。
"""
import uuid
from datetime import datetime, timedelta, timezone

from fastapi.testclient import TestClient
from sqlalchemy import update

from app.db.session import SessionLocal
from app.main import app
from app.models.device_pair import DevicePairCode

client = TestClient(app)

_seq = 0


def _new_user() -> dict:
    global _seq
    _seq += 1
    return {
        "username": f"配对同学{_seq}",
        "email": f"pair{_seq}_{uuid.uuid4().hex[:8]}@example.com",
        "password": "password123",
    }


def _register() -> dict:
    resp = client.post("/api/auth/register", json=_new_user())
    assert resp.status_code == 200, resp.text
    return resp.json()["data"]


def _gen_pair() -> tuple[str, str]:
    """注册并生成配对码，返回 (code, access_token)。"""
    data = _register()
    resp = client.post(
        "/api/auth/device-pair",
        headers={"Authorization": f"Bearer {data['access_token']}"},
    )
    assert resp.status_code == 200, resp.text
    return resp.json()["data"]["code"], data["access_token"]


def _claim(code: str, device_name: str = "Redmi Watch 6"):
    return client.post("/api/auth/device-pair/claim", json={"code": code, "device_name": device_name})


def test_生成配对码需要登录():
    resp = client.post("/api/auth/device-pair")
    assert resp.status_code == 401


def test_生成配对码返回6位数字():
    _, token = _gen_pair()
    resp = client.post(
        "/api/auth/device-pair",
        headers={"Authorization": f"Bearer {token}"},
    )
    assert resp.status_code == 200, resp.text
    code = resp.json()["data"]["code"]
    assert len(code) == 6 and code.isdigit()
    assert resp.json()["data"]["expires_minutes"] == 10


def test_正确配对码领取成功且令牌可用():
    code, _ = _gen_pair()
    resp = _claim(code)
    assert resp.status_code == 200, resp.text
    claim = resp.json()["data"]
    assert claim["access_token"] and claim["refresh_token"]
    assert claim["user"]["username"].startswith("配对同学")
    # 领取到的 access token 可访问受保护接口
    me = client.get(
        "/api/sync/pull?since=0",
        headers={"Authorization": f"Bearer {claim['access_token']}"},
    )
    assert me.status_code == 200


def test_错误配对码被拒():
    code, _ = _gen_pair()
    wrong = "000000" if code != "000000" else "111111"
    resp = _claim(wrong)
    assert resp.status_code == 400
    assert resp.json()["code"] == 40020


def test_配对码只能使用一次():
    code, _ = _gen_pair()
    first = _claim(code)
    assert first.status_code == 200
    second = _claim(code)
    assert second.status_code == 400
    assert second.json()["code"] == 40020


def test_过期配对码被拒():
    _gen_pair()
    with SessionLocal() as db:
        db.execute(
            update(DevicePairCode).values(
                expires_at=datetime.now(timezone.utc).replace(tzinfo=None) - timedelta(minutes=1)
            )
        )
        db.commit()
    resp = _claim("000000")
    assert resp.status_code == 400
    assert resp.json()["code"] == 40020


def test_重新生成后旧码失效():
    code1, token = _gen_pair()
    resp = client.post(
        "/api/auth/device-pair",
        headers={"Authorization": f"Bearer {token}"},
    )
    code2 = resp.json()["data"]["code"]
    assert code1 != code2
    assert _claim(code1).status_code == 400
    assert _claim(code2).status_code == 200


def test_非法配对码参数返回统一_422():
    resp = client.post("/api/auth/device-pair/claim", json={"code": "123"})
    assert resp.status_code == 422
    assert resp.json()["code"] == 42200
