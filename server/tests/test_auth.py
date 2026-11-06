"""认证接口全流程测试。"""
import re
from datetime import datetime, timedelta, timezone

import jwt

from fastapi.testclient import TestClient
from sqlalchemy import select, update

from app.db.session import SessionLocal
from app.main import app
from app.models.email_code import EmailCode
from app.models.token_session import RefreshTokenSession
from app.api.v1.endpoints import auth as auth_endpoint
from app.core.config import get_settings
from app.core.security import hash_token_identifier

client = TestClient(app)

_USER = {"username": "测试同学", "email": "test@example.com", "password": "password123"}


def _register() -> dict:
    resp = client.post("/api/auth/register", json=_USER)
    assert resp.status_code == 200, resp.text
    return resp.json()["data"]


def test_注册成功并自动登录():
    data = _register()
    assert data["user"]["username"] == _USER["username"]
    assert data["access_token"] and data["refresh_token"]
    assert data["token_type"] == "bearer"


def test_用户名或邮箱重复注册被拒():
    resp = client.post("/api/auth/register", json=_USER)
    assert resp.status_code == 409
    assert resp.json()["code"] in (40901, 40902)


def test_非法参数返回统一_422():
    resp = client.post("/api/auth/register", json={"username": "a", "email": "not-an-email"})
    assert resp.status_code == 422
    assert resp.json()["code"] == 42200
    assert resp.json()["message"] == "请求参数格式不正确"
    assert "errors" not in resp.json()


def test_用户名和邮箱都能登录():
    for account in (_USER["username"], _USER["email"]):
        resp = client.post("/api/auth/login", json={"account": account, "password": _USER["password"]})
        assert resp.status_code == 200, resp.text
        assert resp.json()["data"]["access_token"]


def test_错误密码返回统一错误():
    resp = client.post("/api/auth/login", json={"account": _USER["username"], "password": "wrong-pass"})
    assert resp.status_code == 401
    assert resp.json()["code"] == 40103


def test_刷新_token_可重复使用并滑动续期():
    tokens = client.post(
        "/api/auth/login", json={"account": _USER["username"], "password": _USER["password"]}
    ).json()["data"]
    # 不再单次轮换：同一 refresh token 在有效期内可重复使用（多设备/多标签页
    # 互不顶掉），refresh_token 原样返回，每次只换发新 access token。
    for _ in range(3):
        resp = client.post("/api/auth/refresh", json={"refresh_token": tokens["refresh_token"]})
        assert resp.status_code == 200
        data = resp.json()["data"]
        assert data["access_token"]
        assert data["refresh_token"] == tokens["refresh_token"]
    # 会话真正过期后才拒绝：把 expires_at 改到过去再试。
    settings = get_settings()
    payload = jwt.decode(
        tokens["refresh_token"], settings.jwt_secret_key, algorithms=[settings.jwt_algorithm]
    )
    token_hash = hash_token_identifier(payload["jti"])
    stale = datetime.now(timezone.utc).replace(tzinfo=None) - timedelta(minutes=1)
    with SessionLocal() as db:
        db.execute(
            update(RefreshTokenSession)
            .where(RefreshTokenSession.token_hash == token_hash)
            .values(expires_at=stale)
        )
        db.commit()
    replay_late = client.post(
        "/api/auth/refresh", json={"refresh_token": tokens["refresh_token"]}
    )
    assert replay_late.status_code == 401


def test_access_token_不能用于刷新接口():
    tokens = client.post(
        "/api/auth/login", json={"account": _USER["username"], "password": _USER["password"]}
    ).json()["data"]
    resp = client.post("/api/auth/refresh", json={"refresh_token": tokens["access_token"]})
    assert resp.status_code == 401


def test_部署前无_jti_刷新令牌兼容重复使用():
    login_data = client.post(
        "/api/auth/login",
        json={"account": _USER["username"], "password": _USER["password"]},
    ).json()["data"]
    settings = get_settings()
    now = datetime.now(timezone.utc)
    legacy = jwt.encode(
        {
            "sub": str(login_data["user"]["id"]),
            "type": "refresh",
            "iat": now,
            "exp": now + timedelta(minutes=5),
        },
        settings.jwt_secret_key,
        algorithm=settings.jwt_algorithm,
    )
    assert client.post(
        "/api/auth/refresh", json={"refresh_token": legacy}
    ).status_code == 200
    # 首次使用登记为正常会话后可重复使用，直至 JWT 自身过期。
    assert client.post(
        "/api/auth/refresh", json={"refresh_token": legacy}
    ).status_code == 200


def test_个人信息接口鉴权():
    # 未带 token → 401 统一格式
    resp = client.get("/api/user/profile")
    assert resp.status_code == 401
    assert resp.json()["code"] == 40101

    # 带 token → 返回个人信息
    tokens = client.post(
        "/api/auth/login", json={"account": _USER["username"], "password": _USER["password"]}
    ).json()["data"]
    resp = client.get(
        "/api/user/profile", headers={"Authorization": f"Bearer {tokens['access_token']}"}
    )
    assert resp.status_code == 200
    assert resp.json()["data"]["email"] == _USER["email"]


def test_忘记密码_验证码哈希落库_重置密码全流程(monkeypatch):
    sent_mail: dict[str, str] = {}

    def capture_mail(*, to: str, subject: str, text: str) -> bool:
        sent_mail.update(to=to, subject=subject, text=text)
        return True

    monkeypatch.setattr(auth_endpoint, "send_mail", capture_mail)
    # 重置前签发的 access token 应在成功改密后整体失效。
    old_tokens = client.post(
        "/api/auth/login",
        json={"account": _USER["username"], "password": _USER["password"]},
    ).json()["data"]

    # 1. 发送验证码；测试替身捕获邮件正文，数据库只允许保存摘要。
    resp = client.post("/api/auth/forgot-password", json={"email": _USER["email"]})
    assert resp.status_code == 200
    match = re.search(r"\b(\d{6})\b", sent_mail["text"])
    assert match is not None
    code = match.group(1)

    db = SessionLocal()
    try:
        record = db.scalar(
            select(EmailCode)
            .where(EmailCode.email == _USER["email"], EmailCode.used.is_(False))
            .order_by(EmailCode.id.desc())
        )
        assert record is not None and len(record.code) == 8
        assert record.code != code
    finally:
        db.close()

    # 2. 错误验证码被拒
    bad = "000000" if code != "000000" else "111111"
    resp = client.post("/api/auth/reset-password", json={
        "email": _USER["email"], "code": bad, "new_password": "newpassword456",
    })
    assert resp.status_code == 400
    assert resp.json()["code"] == 40001

    # 3. 正确验证码重置成功
    resp = client.post("/api/auth/reset-password", json={
        "email": _USER["email"], "code": code, "new_password": "newpassword456",
    })
    assert resp.status_code == 200

    revoked = client.get(
        "/api/user/profile",
        headers={"Authorization": f"Bearer {old_tokens['access_token']}"},
    )
    assert revoked.status_code == 401

    # 4. 旧密码失效，新密码可登录
    assert client.post("/api/auth/login", json={
        "account": _USER["username"], "password": _USER["password"]}).status_code == 401
    assert client.post("/api/auth/login", json={
        "account": _USER["username"], "password": "newpassword456"}).status_code == 200


def test_忘记密码_不存在的邮箱也返回成功_防枚举():
    resp = client.post("/api/auth/forgot-password", json={"email": "ghost@example.com"})
    assert resp.status_code == 200
    assert resp.json()["code"] == 0


# ---- Web 会话 Cookie 流程（同源 /web-api 代理 + HttpOnly 刷新 Cookie）----

_WEB_ORIGIN = "https://hanshang.seanyan.store"
_WEB_COOKIE = "__Host-hanshang_refresh"
# 独立账号：模块内其他测试会重置共享 _USER 的密码，这里不复用。
_WEB_USER = {"username": "网页同学", "email": "web-session@example.com", "password": "password123"}


def _web_client() -> TestClient:
    # 每个测试用全新客户端，避免共享 cookie jar 干扰会话轮换断言。
    return TestClient(app)


def _web_login(web_client: TestClient) -> str:
    resp = web_client.post(
        "/api/auth/register",
        json=_WEB_USER,
        headers={"Origin": _WEB_ORIGIN},
    )
    if resp.status_code == 409:  # 用户名/邮箱已存在（同一测试库重跑）
        resp = web_client.post(
            "/api/auth/login",
            json={"account": _WEB_USER["username"], "password": _WEB_USER["password"]},
            headers={"Origin": _WEB_ORIGIN},
        )
    assert resp.status_code == 200, resp.text
    set_cookie = resp.headers.get("set-cookie", "")
    assert _WEB_COOKIE in set_cookie
    assert "HttpOnly" in set_cookie and "samesite=strict" in set_cookie.lower()
    # 返回 "name=value" 供显式 Cookie 头使用：TestClient 的 cookie jar
    # 对 Secure + __Host- 前缀 cookie 在 http://testserver 下不可靠。
    return set_cookie.split(";", 1)[0]


def test_未信任来源登录不写入Web刷新Cookie():
    web_client = _web_client()
    _web_login(web_client)  # 先注册该账号（可信来源）
    resp = web_client.post(
        "/api/auth/login",
        json={"account": _WEB_USER["username"], "password": _WEB_USER["password"]},
        headers={"Origin": "https://evil.example"},
    )
    assert resp.status_code == 200
    assert _WEB_COOKIE not in resp.headers.get("set-cookie", "")


def test_刷新接口从WebCookie读取凭据并返回user():
    web_client = _web_client()
    cookie = _web_login(web_client)
    resp = web_client.post(
        "/api/auth/refresh",
        headers={"Origin": _WEB_ORIGIN, "Cookie": cookie},
    )
    assert resp.status_code == 200, resp.text
    data = resp.json()["data"]
    assert data["user"]["username"] == _WEB_USER["username"]
    assert data["access_token"] and data["refresh_token"]
    # 无 Cookie 的裸刷新请求必须失败，而不是落到登录页。
    assert web_client.post("/api/auth/refresh").status_code == 401


def test_Cookie刷新无Origin也写回新Cookie():
    web_client = _web_client()
    cookie = _web_login(web_client)
    # iOS PWA 冷启动可能不带 Origin 头：凭据来自 Cookie 时必须照样写回新
    # Cookie，否则旧会话已被消费、新 Cookie 缺失，下次刷新必 401 被迫重新登录。
    resp = web_client.post("/api/auth/refresh", headers={"Cookie": cookie})
    assert resp.status_code == 200, resp.text
    rotated = resp.headers.get("set-cookie", "")
    assert _WEB_COOKIE in rotated
    # 新 Cookie 能继续完成下一次轮换。
    follow_up = web_client.post(
        "/api/auth/refresh",
        headers={"Cookie": rotated.split(";", 1)[0]},
    )
    assert follow_up.status_code == 200, follow_up.text


def test_登出撤销Web会话并清除Cookie():
    web_client = _web_client()
    cookie = _web_login(web_client)
    resp = web_client.post(
        "/api/auth/logout",
        headers={"Origin": _WEB_ORIGIN, "Cookie": cookie},
    )
    assert resp.status_code == 200
    cleared = resp.headers.get("set-cookie", "").lower()
    assert "hanshang_refresh=" in cleared and "max-age=0" in cleared
    replay = web_client.post(
        "/api/auth/refresh",
        headers={"Origin": _WEB_ORIGIN, "Cookie": cookie},
    )
    assert replay.status_code == 401
