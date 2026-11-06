"""用户资料修改（用户名/头像）与语音分段转写端点测试。"""
import io as _io
import uuid

from fastapi.testclient import TestClient

from app.api.v1.endpoints import schedule_ai
from app.main import app

client = TestClient(app)


def _register() -> tuple[dict, int]:
    suffix = uuid.uuid4().hex[:10]
    response = client.post("/api/auth/register", json={
        "username": f"profile{suffix}",
        "email": f"profile{suffix}@example.com",
        "password": "password123",
    })
    assert response.status_code == 200, response.text
    data = response.json()["data"]
    return {"Authorization": f"Bearer {data['access_token']}"}, data["user"]["id"]


_PNG_1PX = (
    b"\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR\x00\x00\x00\x01\x00\x00\x00\x01"
    b"\x08\x06\x00\x00\x00\x1f\x15\xc4\x89\x00\x00\x00\nIDATx\x9cc\x00\x01"
    b"\x00\x00\x05\x00\x01\r\n-\xb4\x00\x00\x00\x00IEND\xaeB`\x82"
)


class _FakeTranscribeGateway:
    async def transcribe_partial(self, audio_b64: str, hint: str = "") -> str:
        assert "地名" in hint  # 地点词表已注入（扬大楼名兜底）
        return "明天下午三点开会"


class _FailingTranscribeGateway:
    async def transcribe_partial(self, audio_b64: str, hint: str = "") -> str:
        from app.services.llm_event_parse import EventParseError
        raise EventParseError(503, 50341, "AI 日程理解暂未开放")


# ---------- 修改用户名 ----------

def test_update_username_success():
    headers, _ = _register()
    new_name = f"新昵称{uuid.uuid4().hex[:6]}"
    response = client.patch("/api/user/profile", headers=headers, json={"username": new_name})
    assert response.status_code == 200
    assert response.json()["data"]["username"] == new_name
    # 改后能用新名字登录（用户名即登录账号）
    # 直接读 profile 验证持久化
    again = client.get("/api/user/profile", headers=headers)
    assert again.json()["data"]["username"] == new_name


def test_update_username_conflict():
    headers_a, _ = _register()
    headers_b, _ = _register()
    taken = client.get("/api/user/profile", headers=headers_b).json()["data"]["username"]
    response = client.patch("/api/user/profile", headers=headers_a, json={"username": taken})
    assert response.status_code == 409


def test_update_username_rejects_bad_charset_and_length():
    headers, _ = _register()
    for bad in ("a", "", "x" * 33, "带空格 的名字", "emoji😀名", "<script>"):
        response = client.patch("/api/user/profile", headers=headers, json={"username": bad})
        assert response.status_code == 422, bad


def test_update_username_requires_auth():
    assert client.patch("/api/user/profile", json={"username": "abc"}).status_code == 401


# ---------- 头像上传 ----------

def test_avatar_upload_and_serve():
    headers, _ = _register()
    response = client.post(
        "/api/user/avatar", headers=headers,
        files={"file": ("a.png", _PNG_1PX, "image/png")},
    )
    assert response.status_code == 200, response.text
    name = response.json()["data"]["avatar_media"]
    assert name.endswith(".png")
    # 头像可公开读取（随机名不可枚举）
    got = client.get(f"/api/user/avatar/{name}")
    assert got.status_code == 200
    assert got.headers["x-content-type-options"] == "nosniff"
    # profile 里能读到
    assert client.get("/api/user/profile", headers=headers).json()["data"]["avatar_media"] == name
    # 再传一次，旧文件被清理
    response2 = client.post(
        "/api/user/avatar", headers=headers,
        files={"file": ("b.png", _PNG_1PX, "image/png")},
    )
    name2 = response2.json()["data"]["avatar_media"]
    assert name2 != name
    assert client.get(f"/api/user/avatar/{name}").status_code == 404


def test_avatar_rejects_non_image_and_oversize():
    headers, _ = _register()
    fake = client.post(
        "/api/user/avatar", headers=headers,
        files={"file": ("evil.png", b"MZ not an image at all", "image/png")},
    )
    assert fake.status_code == 415
    big = client.post(
        "/api/user/avatar", headers=headers,
        files={"file": ("big.png", _PNG_1PX + b"\x00" * (2 * 1024 * 1024 + 10), "image/png")},
    )
    assert big.status_code == 413


def test_avatar_name_traversal_404():
    headers, _ = _register()
    assert client.get("/api/user/avatar/..%2f..%2fmain.py").status_code == 404
    assert client.get("/api/user/avatar/nothex.png").status_code == 404


# ---------- 分段转写 ----------

def test_transcribe_returns_text(monkeypatch):
    monkeypatch.setattr(schedule_ai, "_gateway", _FakeTranscribeGateway())
    schedule_ai._transcribe_daily_limiter._hits.clear()
    headers, _ = _register()
    import base64
    audio = base64.b64encode(b"\x00" * 8000).decode()
    response = client.post("/api/schedule-ai/transcribe", headers=headers,
                           json={"audio_base64": audio})
    assert response.status_code == 200
    assert response.json()["data"]["text"] == "明天下午三点开会"


def test_transcribe_requires_auth():
    assert client.post("/api/schedule-ai/transcribe", json={"audio_base64": "eA=="}) \
        .status_code == 401
