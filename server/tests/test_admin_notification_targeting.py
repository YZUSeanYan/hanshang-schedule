"""管理后台通知定向扩展：网页端设备、批量与广播、收件箱删除。"""
from fastapi.testclient import TestClient

from app.main import app
from app.api.v1.endpoints import admin_console
from app.api.v1.endpoints.admin_console import _login_limiter
from app.db.session import SessionLocal
from app.models.notification import UserNotification
from app.models.user import User

client = TestClient(app)


def _admin_csrf() -> str:
    _login_limiter._hits.clear()
    response = client.post("/api/admin-console/login", json={
        "username": "admin", "password": "test-admin-password",
    })
    assert response.status_code == 200
    return response.json()["data"]["csrf_token"]


def _register(name: str):
    response = client.post("/api/auth/register", json={
        "username": name,
        "email": f"{name}@example.com",
        "password": "password123",
    })
    assert response.status_code == 200, response.text
    data = response.json()["data"]
    return data["user"]["id"], {"Authorization": f"Bearer {data['access_token']}"}


def _web_subscribe(auth: dict, endpoint: str = "https://push.example.com/sub-42") -> None:
    response = client.post("/api/push/subscribe", headers=auth, json={
        "endpoint": endpoint,
        "keys": {
            "p256dh": "BPd8XhLQw9a2e5y6u7i8o9p0q1r2s3t4u5v6w7x8y9z0",
            "auth": "base64url-auth-1234567890",
        },
    })
    assert response.status_code == 200, response.text
    assert response.json()["data"]["subscribed"] is True


def test_devices_list_includes_web_push_subscriptions():
    user_id, auth = _register("webdev_admin")
    _web_subscribe(auth)
    _admin_csrf()
    response = client.get(f"/api/admin-console/users/{user_id}/devices")
    assert response.status_code == 200
    devices = response.json()["data"]
    web = [d for d in devices if d["platform"] == "web"]
    assert len(web) == 1
    assert web[0]["device_id"].startswith("web:")
    assert "网页端" in web[0]["label"]


def test_admin_can_target_web_device(monkeypatch):
    user_id, auth = _register("webdev_send")
    _web_subscribe(auth, endpoint="https://push.example.com/sub-webdev-send")
    csrf = _admin_csrf()

    devices = client.get(f"/api/admin-console/users/{user_id}/devices").json()["data"]
    web_device = next(d["device_id"] for d in devices if d["platform"] == "web")

    delivered = []
    monkeypatch.setattr(
        admin_console, "send_web_push",
        lambda **kwargs: delivered.append(kwargs) or None,
    )
    response = client.post(
        f"/api/admin-console/users/{user_id}/notifications",
        headers={"X-CSRF-Token": csrf},
        json={"title": "网页端通知", "body": "通过 Web Push 投递", "device_id": web_device},
    )
    assert response.status_code == 200, response.text
    data = response.json()["data"]
    assert data["status"] == "accepted"
    assert data["target_label"] == "网页端（PWA）"
    assert delivered and delivered[0]["payload"]["title"] == "网页端通知"

    inbox = client.get("/api/notifications", headers=auth).json()["data"]
    assert inbox["items"][0]["title"] == "网页端通知"


def test_admin_batch_notification(monkeypatch):
    user_a, auth_a = _register("batch_a")
    user_b, _ = _register("batch_b")
    csrf = _admin_csrf()

    sent = []
    monkeypatch.setattr(
        admin_console, "send_account_notification",
        lambda **kwargs: sent.append(kwargs) or "msg-batch",
    )
    response = client.post(
        "/api/admin-console/notifications/batch",
        headers={"X-CSRF-Token": csrf},
        json={"title": "批量通知", "body": "多账户投递", "user_ids": [user_a, user_b]},
    )
    assert response.status_code == 200, response.text
    data = response.json()["data"]
    assert data["targeted"] == 2
    assert len(sent) == 2

    inbox = client.get("/api/notifications", headers=auth_a).json()["data"]
    assert inbox["items"][0]["title"] == "批量通知"


def test_admin_broadcast_uses_per_account_inbox_ids(monkeypatch):
    user_a, auth_a = _register("broadcast_a")
    user_b, auth_b = _register("broadcast_b")
    csrf = _admin_csrf()

    sent = []
    monkeypatch.setattr(
        admin_console, "send_account_notification",
        lambda **kwargs: sent.append(kwargs) or f"msg-{kwargs['user_id']}",
    )
    response = client.post(
        "/api/admin-console/notifications/broadcast",
        headers={"X-CSRF-Token": csrf},
        json={"title": "广播通知", "body": "全体账户投递"},
    )
    assert response.status_code == 200, response.text
    data = response.json()["data"]
    assert data["users"] >= 2
    assert data["android_status"] == "accepted"

    calls = {call["user_id"]: call for call in sent}
    inbox_a = client.get("/api/notifications", headers=auth_a).json()["data"]["items"][0]
    inbox_b = client.get("/api/notifications", headers=auth_b).json()["data"]["items"][0]
    assert calls[user_a]["notification_id"] == inbox_a["id"]
    assert calls[user_b]["notification_id"] == inbox_b["id"]
    assert calls[user_a]["notification_id"] != calls[user_b]["notification_id"]


def test_inbox_delete_single_and_clear():
    user_id, auth = _register("inbox_delete")
    csrf = _admin_csrf()
    for i in range(3):
        sent = client.post(
            f"/api/admin-console/users/{user_id}/notifications",
            headers={"X-CSRF-Token": csrf},
            json={"title": f"通知{i}", "body": "内容"},
        )
        assert sent.status_code == 200

    inbox = client.get("/api/notifications", headers=auth).json()["data"]
    assert len(inbox["items"]) == 3
    first_id = inbox["items"][0]["id"]

    deleted = client.delete(f"/api/notifications/{first_id}", headers=auth)
    assert deleted.status_code == 200
    remaining = client.get("/api/notifications", headers=auth).json()["data"]["items"]
    assert all(row["id"] != first_id for row in remaining)

    cleared = client.delete("/api/notifications", headers=auth)
    assert cleared.status_code == 200
    assert cleared.json()["data"]["deleted"] == 2
    assert client.get("/api/notifications", headers=auth).json()["data"]["items"] == []


def test_inbox_delete_requires_auth_and_ownership():
    user_id, auth_a = _register("inbox_owner")
    _, auth_b = _register("inbox_other")
    csrf = _admin_csrf()
    sent = client.post(
        f"/api/admin-console/users/{user_id}/notifications",
        headers={"X-CSRF-Token": csrf},
        json={"title": "归属", "body": "归属校验"},
    )
    assert sent.status_code == 200
    nid = client.get("/api/notifications", headers=auth_a).json()["data"]["items"][0]["id"]

    other = client.delete(f"/api/notifications/{nid}", headers=auth_b)
    assert other.status_code == 404
    anon = client.delete(f"/api/notifications/{nid}")
    assert anon.status_code == 401
    ok = client.delete(f"/api/notifications/{nid}", headers=auth_a)
    assert ok.status_code == 200

def test_admin_timestamps_carry_utc_offset():
    """数据库时间是无时区 UTC；管理端接口必须带 +00:00，否则前端按本地时间解析会差 8 小时。"""
    _register("tz_admin")
    _admin_csrf()
    data = client.get("/api/admin-console/users?page=1&page_size=1").json()["data"]
    assert data["items"], "expected at least one user"
    created = data["items"][0]["created_at"]
    assert created.endswith("+00:00"), created


def test_broadcast_silent_writes_inbox_only():
    """静默广播：每个账号落收件箱，但不触发任何外部推送。"""
    import app.api.v1.endpoints.admin_console as ac

    sends = []
    original_account = ac.send_account_notification
    original_web = ac.send_web_push
    original_harmony = ac.send_harmony_notification

    def fail_account(*args, **kwargs):
        sends.append("account")
        raise AssertionError("silent broadcast must not push")

    def fail_web(*args, **kwargs):
        sends.append("web")
        raise AssertionError("silent broadcast must not push")

    def fail_harmony(*args, **kwargs):
        sends.append("harmony")
        raise AssertionError("silent broadcast must not push")

    _register("silent_target_a")
    _register("silent_target_b")
    csrf = _admin_csrf()
    ac.send_account_notification = fail_account
    ac.send_web_push = fail_web
    ac.send_harmony_notification = fail_harmony
    try:
        response = client.post("/api/admin-console/notifications/broadcast",
                               headers={"X-CSRF-Token": csrf},
                               json={"title": "2.0 欢迎更新", "body": "静默公告正文", "silent": True})
    finally:
        ac.send_account_notification = original_account
        ac.send_web_push = original_web
        ac.send_harmony_notification = original_harmony
    assert response.status_code == 200, response.text
    data = response.json()["data"]
    assert data["silent"] is True
    assert data["users"] >= 2
    assert data["android_status"] == "skipped"
    assert data["web_delivered"] == 0
    assert sends == []

    # 收件箱确实落地且标记为静默
    db = SessionLocal()
    try:
        rows = db.query(UserNotification).filter(
            UserNotification.title == "2.0 欢迎更新",
            UserNotification.user_id.in_(
                [u.id for u in db.query(User).filter(
                    User.username.in_(["silent_target_a", "silent_target_b"])).all()]
            ),
        ).all()
        assert len(rows) == 2
        assert all(r.delivery_status == "stored" for r in rows)
        assert all(r.target_label == "静默公告（仅收件箱）" for r in rows)
    finally:
        db.close()


def test_broadcast_web_only_writes_delivery_status():
    """仅网页版广播必须回写投递状态，不能停在默认的 pending。

    回归背景（2026-09-23）：platform=web 时跳过了 android 投递，也就跳过了
    delivery_status 的赋值，行永远停在模型默认值 pending——线上 09-15 那次
    「仅网页版」广播的 182 行就是这么来的，被数据看板统计成「待投递 16%」，
    看着像有大量积压。
    """
    from sqlalchemy import select

    from app.models.push_subscription import PushSubscription

    user_id, _ = _register("webonly_status")
    db = SessionLocal()
    try:
        db.add(PushSubscription(user_id=user_id, endpoint="https://example.invalid/p/1",
                                p256dh="a", auth="b"))
        db.commit()
    finally:
        db.close()

    pushed = []
    original_web = admin_console.send_web_push
    admin_console.send_web_push = lambda **kw: pushed.append(kw) or True
    try:
        csrf = _admin_csrf()
        resp = client.post(
            "/api/admin-console/notifications/broadcast",
            headers={"X-CSRF-Token": csrf},
            json={"title": "仅网页版状态回归", "body": "正文", "platform": "web"},
        )
        assert resp.status_code == 200, resp.text
    finally:
        admin_console.send_web_push = original_web

    assert pushed, "仅网页版广播应该真的投递了网页推送"

    db = SessionLocal()
    try:
        row = db.scalar(select(UserNotification).where(
            UserNotification.user_id == user_id,
            UserNotification.title == "仅网页版状态回归",
        ))
        assert row is not None, "广播应落收件箱"
        assert row.delivery_status != "pending", "不能停在 pending（线上 bug 的判据）"
        assert row.delivery_status == "accepted", "有订阅且投递成功应为 accepted"
    finally:
        db.close()
