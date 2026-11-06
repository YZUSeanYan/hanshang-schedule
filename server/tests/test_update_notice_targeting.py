"""「只提醒版本落后用户」的定向规则回归测试。

背景（2026-09-22）：更新提示条这类写在 App 里的提醒，只有已经装了新版的用户
才看得到——而那些人恰恰不需要被提醒；真正卡在老版本的用户永远收不到。改成
服务端推送后，最危险的回归是「误发给已升级用户」（变成骚扰），其次是
「不知道版本的账号被乱发」。这三条一起锁住边界。
"""
import time

import pytest

from fastapi.testclient import TestClient

from app.main import app
from app.models.notification import UserNotification, UserPushDevice
from app.models.app_version import AppVersion
from app.models.client_version import ClientVersion
from app.models.release_target import AppVersionTarget
from app.db.session import SessionLocal
from app.services.version_release import (
    _parse_app_version_code,
    notify_outdated_users,
    outdated_user_ids,
)
from sqlalchemy import select

client = TestClient(app)
_NOW = int(time.time() * 1000)


@pytest.fixture(scope="module", autouse=True)
def _cleanup_versions():
    """本模块会往共享测试库写版本记录，跑完必须删干净。

    否则 test_version.py 的「无版本时返回无更新」等断言会被污染——这个坑
    在 test_admin_versions.py 已经踩过一次（记忆：模块级 teardown 必删）。
    """
    yield
    db = SessionLocal()
    try:
        # 定向记录必须先删：SQLite 会复用被删行的 rowid，留下的孤儿
        # AppVersionTarget 会被后面发布的版本「继承」，把它误判成定向版本
        # 而对所有人不可见（曾让 test_version 的 force_codes 用例挂掉）。
        doomed = list(
            db.scalars(select(AppVersion).where(AppVersion.version_code >= 200))
        )
        doomed_ids = [row.id for row in doomed]
        if doomed_ids:
            for target in db.scalars(
                select(AppVersionTarget).where(AppVersionTarget.version_id.in_(doomed_ids))
            ):
                db.delete(target)
        for row in doomed:
            db.delete(row)
        for row in db.scalars(select(UserNotification)):
            db.delete(row)
        db.commit()
    finally:
        db.close()


def _register(suffix: str) -> tuple[dict, int]:
    resp = client.post("/api/auth/register", json={
        "username": f"upd{suffix}",
        "email": f"upd{suffix}@example.com",
        "password": "password123",
    })
    assert resp.status_code == 200, resp.text
    data = resp.json()["data"]
    return {"Authorization": f"Bearer {data['access_token']}"}, data["user"]["id"]


def _set_client_code(user_id: int, code: int) -> None:
    db = SessionLocal()
    try:
        row = db.scalar(select(ClientVersion).where(ClientVersion.user_id == user_id))
        if row is None:
            db.add(ClientVersion(user_id=user_id, current_code=code))
        else:
            row.current_code = code
        db.commit()
    finally:
        db.close()


def _set_device_version(user_id: int, version: str) -> None:
    db = SessionLocal()
    try:
        db.add(UserPushDevice(
            user_id=user_id, device_id=f"dev-{user_id}-{version}",
            platform="android", app_version=version,
        ))
        db.commit()
    finally:
        db.close()


def _make_version(code: int, name: str) -> AppVersion:
    db = SessionLocal()
    try:
        row = AppVersion(
            version_name=name, version_code=code,
            apk_url=f"https://api.seanyan.store/yzu-apk/a{code}.apk",
            sha256="cd" * 32,
            release_notes="", is_force_update=False,
        )
        db.add(row)
        db.commit()
        db.refresh(row)
        return row
    finally:
        db.close()


def test_版本号解析():
    assert _parse_app_version_code("2.0.0+62") == 62
    assert _parse_app_version_code("1.0.33+33") == 33
    assert _parse_app_version_code("2.0.0") == 0
    assert _parse_app_version_code(None) == 0
    assert _parse_app_version_code("") == 0


def test_只挑出落后账号_已升级的不发():
    _, behind_id = _register("b1")
    _, current_id = _register("c1")
    _set_client_code(behind_id, 39)      # 1.1.1 → 落后
    _set_client_code(current_id, 63)     # 已是最新

    found = outdated_user_ids(SessionLocal(), 63)
    try:
        assert behind_id in found, "落后账号必须被挑出来"
        assert current_id not in found, "已升级账号绝不能被骚扰"
    finally:
        SessionLocal().close()


def test_版本未知的账号也算落后_不能当成已最新():
    """2026-09-22 用户指正：新版本刚发出去时绝大多数人还没上报版本，
    此时「未知」＝「肯定还在老版本」，漏发就等于把最该通知的人全跳过了。"""
    _, unknown_id = _register("u1")   # 两端都没有版本记录

    found = outdated_user_ids(SessionLocal(), 63)
    try:
        assert unknown_id in found, "版本未知必须按落后处理"
    finally:
        SessionLocal().close()


def test_纯网页版用户不发_PWA自己会更新():
    _, web_only_id = _register("w1")
    _, web_and_app_id = _register("w2")
    # web_only_id 只给网页订阅（不给 user_push_devices，那会算 App 端信号）→ 不发
    db = SessionLocal()
    try:
        from app.models.push_subscription import PushSubscription
        db.add(PushSubscription(user_id=web_only_id, endpoint="https://e/p/1",
                               p256dh="a", auth="b"))
        db.add(PushSubscription(user_id=web_and_app_id, endpoint="https://e/p/2",
                               p256dh="a", auth="b"))
        db.commit()
    finally:
        db.close()
    _set_client_code(web_and_app_id, 33)   # 同时有 App 端信号 → 要发

    found = outdated_user_ids(SessionLocal(), 63)
    try:
        assert web_only_id not in found, "纯网页版用户不该收到 APK 更新提醒"
        assert web_and_app_id in found, "同时用 App 的网页订阅者仍要提醒"
    finally:
        SessionLocal().close()


def test_两处版本来源取大者_不把已升级的误判成落后():
    _, mixed_id = _register("m1")
    _set_device_version(mixed_id, "1.0.33+33")   # 存量兜底里是老版本
    _set_client_code(mixed_id, 63)               # 但最新上报已是最新

    found = outdated_user_ids(SessionLocal(), 63)
    try:
        assert mixed_id not in found, "取大者：不能因为一条旧记录就误判成落后"
    finally:
        SessionLocal().close()


def test_通知只发给落后账号_且同一版本只发一次():
    _, behind_id = _register("b2")
    _, current_id = _register("c2")
    _set_client_code(behind_id, 39)
    _set_client_code(current_id, 200)   # 已是最新
    version = _make_version(200, "9.9.9")

    first = notify_outdated_users(SessionLocal(), version)
    try:
        got = {item["user_id"] for item in first}
        assert behind_id in got, "落后账号必须收到更新提醒"
        assert current_id not in got, "已升级账号绝不能被骚扰"
    finally:
        SessionLocal().close()

    db = SessionLocal()
    try:
        titles = [r.title for r in db.scalars(
            select(UserNotification).where(UserNotification.user_id == current_id)
        )]
        assert all("已发布" not in t for t in titles), "已升级账号不该收到更新提醒"

        again = notify_outdated_users(db, version)
        assert again == [], "同一版本对同一账号只能提醒一次"
    finally:
        db.close()

def test_正在内测更新版本的账号不再被旧版本催更():
    _, tester_id = _register("t1")
    _set_client_code(tester_id, 39)          # 本地还是老版本
    newer = _make_version(300, "10.0.0")     # 但已被邀请测试更新的版本
    db = SessionLocal()
    try:
        from app.models.release_target import AppVersionTarget
        db.add(AppVersionTarget(version_id=newer.id, user_id=tester_id))
        db.commit()
    finally:
        db.close()

    found = outdated_user_ids(SessionLocal(), 63)
    try:
        assert tester_id not in found, "已被引导升级到更新版本的账号，不该再收到旧版本的催更"
    finally:
        SessionLocal().close()

def test_正在被定向测试同版本的账号也不再被催更():
    _, same_ver_tester = _register("s1")
    _set_client_code(same_ver_tester, 39)   # 本地还是老版本
    same = _make_version(400, "11.0.0")     # 正被定向测试的就是公告里的新版本
    db = SessionLocal()
    try:
        db.add(AppVersionTarget(version_id=same.id, user_id=same_ver_tester))
        db.commit()
    finally:
        db.close()

    found = outdated_user_ids(SessionLocal(), 400)
    try:
        assert same_ver_tester not in found, "正在定向测试该版本的账号，不该再收到它的公告"
    finally:
        SessionLocal().close()


def _admin_headers() -> dict:
    from app.api.v1.endpoints.admin_console import _login_limiter
    _login_limiter._hits.clear()
    response = client.post("/api/admin-console/login", json={
        "username": "admin", "password": "test-admin-password",
    })
    assert response.status_code == 200, response.text
    return {"X-CSRF-Token": response.json()["data"]["csrf_token"]}


def test_管理端能看到版本分布与落后用户邮箱():
    _, stale_id = _register("ad1")
    _set_client_code(stale_id, 33)
    headers = _admin_headers()

    resp = client.get("/api/admin-console/stats/client-versions", headers=headers)
    assert resp.status_code == 200, resp.text
    data = resp.json()["data"]
    assert data["latest"]["version_code"] > 0, "要显示当前正式版"
    assert "distribution" in data and "outdated" in data

    row = next((r for r in data["outdated"] if r["user_id"] == stale_id), None)
    assert row is not None, "落后账号要能被看到"
    assert row["email"], "催更需要邮箱"
    assert row["current_code"] == 33


def test_管理端一键催更只发给落后账号():
    _, stale_id = _register("ad2")
    _, fresh_id = _register("ad3")
    _set_client_code(stale_id, 33)
    _set_client_code(fresh_id, 500)   # 远超当前正式版
    version = _make_version(500, "12.0.0")   # 用它做「当前正式版」，两者差距明确

    headers = _admin_headers()
    resp = client.post(
        f"/api/admin-console/versions/{version.id}/notify-outdated", headers=headers
    )
    assert resp.status_code == 200, resp.text
    got = {item["user_id"] for item in resp.json()["data"]["sent"]}

    assert stale_id in got
    assert fresh_id not in got, "已升级账号绝不能被一键催更骚扰"
