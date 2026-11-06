"""管理控制台：独立会话、CSRF、用户删除、数据清理和审计。"""
from fastapi.testclient import TestClient
from datetime import datetime, timedelta

from sqlalchemy import func, select

from app.main import app
from app.db.session import SessionLocal
from app.models.credential_vault import CredentialVault
from app.models.email_code import EmailCode
from app.models.push_subscription import PushDelivery, PushSubscription
from app.models.share_code import ShareCode
from app.models.sync_data import SyncCourse, SyncSchedule, SyncSemester
from app.models.token_session import RefreshTokenSession, UserTokenState
from app.models.user import User
from app.models.admin import UserRestriction
from app.models.client_version import ClientVersion
from app.models.daily_activity import DailyActivity

client = TestClient(app)


def _login_admin() -> str:
    response = client.post("/api/admin-console/login", json={
        "username": "admin", "password": "test-admin-password",
    })
    assert response.status_code == 200, response.text
    return response.json()["data"]["csrf_token"]


def test_admin_console_security_and_user_lifecycle():
    assert client.get("/api/admin-console/summary").status_code == 401
    assert client.post("/api/admin-console/login", json={
        "username": "admin", "password": "wrong-password",
    }).status_code == 401

    csrf = _login_admin()
    headers = {"X-CSRF-Token": csrf}
    registered = client.post("/api/auth/register", json={
        "username": "admin_target",
        "email": "admin-target@example.com",
        "password": "password123",
    })
    assert registered.status_code == 200, registered.text

    users = client.get("/api/admin-console/users", params={"q": "admin_target"})
    assert users.status_code == 200
    target = users.json()["data"]["items"][0]
    user_id = target["id"]
    assert "password_hash" not in target

    no_csrf = client.patch(f"/api/admin-console/users/{user_id}", json={
        "username": "admin_target_2", "email": "admin-target-2@example.com",
    })
    assert no_csrf.status_code == 403
    updated = client.patch(f"/api/admin-console/users/{user_id}", headers=headers, json={
        "username": "admin_target_2", "email": "admin-target-2@example.com",
    })
    assert updated.status_code == 200, updated.text

    # A legacy restriction row must no longer disable an account now that the
    # disable feature has been removed from both the API and the admin console.
    with SessionLocal() as db:
        db.add(UserRestriction(user_id=user_id, reason="legacy-only"))
        db.commit()

    assert client.post("/api/auth/login", json={
        "account": "admin_target_2", "password": "password123",
    }).status_code == 200

    assert client.post(
        f"/api/admin-console/users/{user_id}/disable",
        headers=headers,
        json={"reason": "must not exist"},
    ).status_code == 404
    assert client.post(
        f"/api/admin-console/users/{user_id}/enable",
        headers=headers,
    ).status_code == 404

    wrong_confirm = client.request(
        "DELETE", f"/api/admin-console/users/{user_id}/sync-data",
        headers=headers, json={"confirm": "wrong"},
    )
    assert wrong_confirm.status_code == 400
    cleared = client.request(
        "DELETE", f"/api/admin-console/users/{user_id}/sync-data",
        headers=headers, json={"confirm": "admin_target_2"},
    )
    assert cleared.status_code == 200

    audit = client.get("/api/admin-console/audit")
    assert audit.status_code == 200
    actions = {row["action"] for row in audit.json()["data"]}
    assert {"user.update", "user.sync_data.clear"} <= actions


def test_admin_site_has_strict_browser_headers():
    response = client.get("/admin/")
    assert response.status_code == 200
    html = response.text
    assert "邗上课表" in html
    dialog = html.split('<dialog id="userDialog">', 1)[1].split("</dialog>", 1)[0]
    assert '<form method="dialog"' not in dialog
    assert 'id="dialogClose"' in dialog
    assert 'id="notifications"' in html
    # 管理后台 UI v2（2026-09-09）把单人输入框换成收件人选择器
    assert 'id="notificationMode"' in html
    assert 'id="notificationRecipients"' in html
    assert 'id="notificationDevice"' in html
    assert "default-src 'self'" in response.headers["content-security-policy"]
    assert response.headers["x-frame-options"] == "DENY"
    assert response.headers["cache-control"] == "no-store"

    script = client.get("/admin/assets/admin.js")
    assert script.status_code == 200
    assert "notificationUserChanged" in script.text
    assert "notificationDevice" in script.text
    assert "toggleUser" not in script.text
    assert "/disable" not in script.text
    assert "/enable" not in script.text


def test_about_content_can_be_edited_and_media_is_validated():
    csrf = _login_admin()
    headers = {"X-CSRF-Token": csrf}
    updated = client.patch(
        "/api/admin-console/about",
        headers=headers,
        json={
            "display_name": "邗上课表工作室",
            "intro": "测试介绍",
            "website_url": "https://example.com",
        },
    )
    assert updated.status_code == 200, updated.text
    public = client.get("/api/about")
    assert public.status_code == 200
    assert public.json()["data"]["intro"] == "测试介绍"

    invalid = client.post(
        "/api/admin-console/about/media/avatar",
        headers=headers,
        files={"upload": ("avatar.txt", b"not-an-image", "text/plain")},
    )
    assert invalid.status_code == 415

    png = b"\x89PNG\r\n\x1a\n" + b"test-image-payload"
    uploaded = client.post(
        "/api/admin-console/about/media/avatar",
        headers=headers,
        files={"upload": ("avatar.png", png, "image/png")},
    )
    assert uploaded.status_code == 200, uploaded.text
    name = uploaded.json()["data"]["avatar_media"]
    assert "/" not in name and name.endswith(".png")
    media = client.get(f"/api/about/media/{name}")
    assert media.status_code == 200
    assert media.content == png
    assert media.headers["x-content-type-options"] == "nosniff"


def test_credential_vault_endpoints_are_gone_and_admin_can_only_delete_leftovers():
    registered = client.post("/api/auth/register", json={
        "username": "vault_target",
        "email": "vault-target@example.com",
        "password": "password123",
    })
    assert registered.status_code == 200, registered.text
    auth_data = registered.json()["data"]
    user_id = auth_data["user"]["id"]
    auth_headers = {"Authorization": f"Bearer {auth_data['access_token']}"}

    # 合规红线（2026-09-02）：用户端凭据接口已下线，一律 410，
    # 服务器不接收、不存储任何教务凭据。
    for method in (client.get, client.put, client.delete):
        response = method("/api/credential-vault", headers=auth_headers)
        assert response.status_code == 410
    assert client.post(
        "/api/credential-vault/verified", headers=auth_headers
    ).status_code == 410

    # 下线前的历史残留行：管理员详情只见状态不见密文，且只能删除。
    with SessionLocal() as db:
        db.add(CredentialVault(
            user_id=user_id, ciphertext="opaque", nonce="123456789012",
            student_id_hint="******1234", schema_version=1,
        ))
        db.commit()

    csrf = _login_admin()
    detail = client.get(f"/api/admin-console/users/{user_id}")
    assert detail.status_code == 200
    vault_status = detail.json()["data"]["credential_vault"]
    assert vault_status["exists"] is True
    assert vault_status["student_id_hint"] == "******1234"
    assert "ciphertext" not in vault_status

    deleted = client.request(
        "DELETE",
        f"/api/admin-console/users/{user_id}/credential-vault",
        headers={"X-CSRF-Token": csrf},
        json={"confirm": "vault_target"},
    )
    assert deleted.status_code == 200
    detail_after = client.get(f"/api/admin-console/users/{user_id}")
    assert detail_after.json()["data"]["credential_vault"]["exists"] is False


def test_admin_permanent_delete_requires_exact_confirmation_and_cleans_dependents():
    registered = client.post("/api/auth/register", json={
        "username": "delete_target",
        "email": "delete-target@example.com",
        "password": "password123",
    })
    assert registered.status_code == 200, registered.text
    user_id = registered.json()["data"]["user"]["id"]

    with SessionLocal() as db:
        semester = SyncSemester(
            user_id=user_id, uuid="delete-semester", name="测试学期",
            start_date="2026-08-10", total_weeks=20, is_current=True,
            updated_at=1, deleted=False, synced_at=1,
        )
        course = SyncCourse(
            user_id=user_id, uuid="delete-course", semester_uuid=semester.uuid,
            name="测试课程", teacher="", color=0, note="", updated_at=1,
            deleted=False, synced_at=2,
        )
        schedule = SyncSchedule(
            user_id=user_id, uuid="delete-schedule", course_uuid=course.uuid,
            day_of_week=1, start_section=1, end_section=2, weeks_type=0,
            custom_weeks="", location="", updated_at=1, deleted=False, synced_at=3,
        )
        subscription = PushSubscription(
            user_id=user_id, endpoint="https://push.invalid/delete-target",
            p256dh="p256dh", auth="auth",
        )
        db.add_all([semester, course, schedule, subscription])
        db.flush()
        delivery = PushDelivery(
            subscription_id=subscription.id, schedule_uuid=schedule.uuid,
            class_date="2026-08-11", reminder_minutes=15,
        )
        db.add_all([
            delivery,
            ShareCode(
                code="DLT123", owner_user_id=user_id, semester_uuid=semester.uuid,
                payload='{"version":1}', expires_at=datetime.now() + timedelta(days=1),
            ),
            CredentialVault(
                user_id=user_id, ciphertext="opaque", nonce="123456789012",
                student_id_hint="******0000", schema_version=1,
            ),
            EmailCode(
                email="delete-target@example.com", code="123456",
                purpose="reset_password", expires_at=datetime.now() + timedelta(minutes=5),
            ),
            # 2026-11-01 增：固定清单曾漏掉这类新增表，注销后数据仍残留
            ClientVersion(user_id=user_id, current_code=64),
            DailyActivity(user_id=user_id, activity_date=datetime.now().date()),
        ])
        db.commit()
        delivery_id = delivery.id

    csrf = _login_admin()
    headers = {"X-CSRF-Token": csrf}
    assert client.request(
        "DELETE", f"/api/admin-console/users/{user_id}",
        headers=headers, json={"confirm": "wrong"},
    ).status_code == 400
    assert client.request(
        "DELETE", f"/api/admin-console/users/{user_id}",
        json={"confirm": "delete_target"},
    ).status_code == 403

    deleted = client.request(
        "DELETE", f"/api/admin-console/users/{user_id}",
        headers=headers, json={"confirm": "delete_target"},
    )
    assert deleted.status_code == 200, deleted.text
    assert deleted.json()["data"]["deleted"] is True
    assert client.get(f"/api/admin-console/users/{user_id}").status_code == 404

    with SessionLocal() as db:
        assert db.scalar(select(func.count()).select_from(User).where(User.id == user_id)) == 0
        for model in (SyncSemester, SyncCourse, SyncSchedule, CredentialVault,
                      RefreshTokenSession, UserTokenState, PushSubscription):
            assert db.scalar(select(func.count()).select_from(model).where(model.user_id == user_id)) == 0
        assert db.scalar(select(func.count()).select_from(ShareCode).where(ShareCode.owner_user_id == user_id)) == 0
        assert db.scalar(select(func.count()).select_from(EmailCode).where(EmailCode.email == "delete-target@example.com")) == 0
        assert db.scalar(select(func.count()).select_from(PushDelivery).where(PushDelivery.id == delivery_id)) == 0
        assert db.scalar(select(func.count()).select_from(ClientVersion).where(ClientVersion.user_id == user_id)) == 0
        assert db.scalar(select(func.count()).select_from(DailyActivity).where(DailyActivity.user_id == user_id)) == 0

    audit = client.get("/api/admin-console/audit").json()["data"]
    deletion = next(row for row in audit if row["action"] == "user.delete")
    assert deletion["target_user_id"] is None
    assert "delete_target" in deletion["detail"]
    assert "delete-target@example.com" not in deletion["detail"]
