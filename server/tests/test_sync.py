"""云端同步接口测试：推送、LWW 冲突、增量拉取、墓碑、多用户隔离。"""
import time

from fastapi.testclient import TestClient

from app.main import app

client = TestClient(app)

_NOW = int(time.time() * 1000)

def _register_and_headers(suffix: str) -> dict:
    resp = client.post("/api/auth/register", json={
        "username": f"sync用户{suffix}",
        "email": f"sync{suffix}@example.com",
        "password": "password123",
    })
    assert resp.status_code == 200, resp.text
    token = resp.json()["data"]["access_token"]
    return {"Authorization": f"Bearer {token}"}

def _semester(uuid: str, updated_at: int, **kw) -> dict:
    base = {
        "uuid": uuid,
        "name": "2026春",
        "start_date": "2026-03-02",
        "total_weeks": 20,
        "is_current": True,
        "updated_at": updated_at,
        "deleted": False,
    }
    base.update(kw)
    return base

def _course(uuid: str, semester_uuid: str, updated_at: int, **kw) -> dict:
    base = {
        "uuid": uuid,
        "semester_uuid": semester_uuid,
        "name": "大学物理Ⅳ",
        "teacher": "教师A",
        "color": 0,
        "note": "",
        "updated_at": updated_at,
        "deleted": False,
    }
    base.update(kw)
    return base

def _schedule(uuid: str, course_uuid: str, updated_at: int, **kw) -> dict:
    base = {
        "uuid": uuid,
        "course_uuid": course_uuid,
        "day_of_week": 2,
        "start_section": 1,
        "end_section": 2,
        "weeks_type": 3,
        "custom_weeks": "1,2,3,4,5,6,7,8",
        "location": "文津楼101",
        "updated_at": updated_at,
        "deleted": False,
    }
    base.update(kw)
    return base


class TestSyncPushPull:
    h = _register_and_headers("a")

    def test_未登录被拒(self):
        resp = client.post("/api/sync/push", json={})
        assert resp.status_code == 401

    def test_首次推送并全量拉取(self):
        resp = client.post("/api/sync/push", headers=self.h, json={
            "semesters": [_semester("sem-1", _NOW)],
            "courses": [_course("cou-1", "sem-1", _NOW)],
            "schedules": [_schedule("sch-1", "cou-1", _NOW)],
        })
        assert resp.status_code == 200, resp.text
        data = resp.json()["data"]
        assert data["applied"] == {"semesters": 1, "courses": 1, "schedules": 1, "events": 0, "overrides": 0}
        assert data["conflicts"] == {"semesters": 0, "courses": 0, "schedules": 0, "events": 0, "overrides": 0}

        pull = client.get("/api/sync/pull", headers=self.h, params={"since": 0})
        body = pull.json()["data"]
        assert len(body["semesters"]) == 1
        assert body["semesters"][0]["name"] == "2026春"
        assert len(body["courses"]) == 1
        assert len(body["schedules"]) == 1
        assert body["schedules"][0]["location"] == "文津楼101"
        assert body["cursor"] > 0

    def test_重复推送幂等(self):
        # 同样的 updated_at 再推一次：不覆盖、计入冲突
        resp = client.post("/api/sync/push", headers=self.h, json={
            "semesters": [_semester("sem-1", _NOW)],
        })
        data = resp.json()["data"]
        assert data["applied"]["semesters"] == 0
        assert data["conflicts"]["semesters"] == 1

    def test_旧数据不覆盖新数据_LWW(self):
        # 先推一条更新的
        client.post("/api/sync/push", headers=self.h, json={
            "courses": [_course("cou-1", "sem-1", _NOW + 1000, note="新版备注")],
        })
        # 再推一条更旧的 → 被拒
        resp = client.post("/api/sync/push", headers=self.h, json={
            "courses": [_course("cou-1", "sem-1", _NOW, note="旧版备注")],
        })
        assert resp.json()["data"]["conflicts"]["courses"] == 1
        # 拉取验证仍是新版
        body = client.get("/api/sync/pull", headers=self.h, params={"since": 0}).json()["data"]
        course = [c for c in body["courses"] if c["uuid"] == "cou-1"][0]
        assert course["note"] == "新版备注"

    def test_增量拉取只返回变化(self):
        first = client.get("/api/sync/pull", headers=self.h, params={"since": 0}).json()["data"]
        cursor = first["cursor"]
        # 推一条新课程
        client.post("/api/sync/push", headers=self.h, json={
            "courses": [_course("cou-2", "sem-1", _NOW + 2000, name="概率论")],
        })
        inc = client.get("/api/sync/pull", headers=self.h, params={"since": cursor}).json()["data"]
        assert len(inc["courses"]) == 1
        assert inc["courses"][0]["uuid"] == "cou-2"
        assert inc["semesters"] == []

    def test_删除走墓碑(self):
        client.post("/api/sync/push", headers=self.h, json={
            "schedules": [_schedule("sch-1", "cou-1", _NOW + 3000, deleted=True)],
        })
        body = client.get("/api/sync/pull", headers=self.h, params={"since": 0}).json()["data"]
        sch = [s for s in body["schedules"] if s["uuid"] == "sch-1"][0]
        assert sch["deleted"] is True

    def test_多用户数据隔离(self):
        other = _register_and_headers("b")
        body = client.get("/api/sync/pull", headers=other, params={"since": 0}).json()["data"]
        assert body["semesters"] == []
        assert body["courses"] == []
        assert body["schedules"] == []


class TestWeeksNormalization:
    """Web 端写范围（"1-18"）、App 写平铺列表——服务端统一成平铺列表。"""

    h = _register_and_headers("c")

    def test_推送范围写法_拉取得到平铺列表(self):
        client.post("/api/sync/push", headers=self.h, json={
            "semesters": [_semester("sem-n1", _NOW)],
            "courses": [_course("cou-n1", "sem-n1", _NOW)],
            "schedules": [
                _schedule("sch-n1", "cou-n1", _NOW, custom_weeks="1-18"),
                _schedule("sch-n2", "cou-n1", _NOW + 1, custom_weeks="1-8,10,12"),
                _schedule("sch-n3", "cou-n1", _NOW + 2, custom_weeks="2,4,6-8"),
            ],
        })
        body = client.get("/api/sync/pull", headers=self.h, params={"since": 0}).json()["data"]
        by_uuid = {s["uuid"]: s["custom_weeks"] for s in body["schedules"]}
        assert by_uuid["sch-n1"] == ",".join(str(w) for w in range(1, 19))
        assert by_uuid["sch-n2"] == "1,2,3,4,5,6,7,8,10,12"
        assert by_uuid["sch-n3"] == "2,4,6,7,8"

    def test_覆盖更新时同样规范化(self):
        client.post("/api/sync/push", headers=self.h, json={
            "schedules": [_schedule("sch-n1", "cou-n1", _NOW + 10000, custom_weeks="1-3")],
        })
        body = client.get("/api/sync/pull", headers=self.h, params={"since": 0}).json()["data"]
        sch = [s for s in body["schedules"] if s["uuid"] == "sch-n1"][0]
        assert sch["custom_weeks"] == "1,2,3"

    def test_空值与非法片段被安全忽略(self):
        client.post("/api/sync/push", headers=self.h, json={
            "schedules": [
                _schedule("sch-n4", "cou-n1", _NOW + 20000, custom_weeks=""),
                _schedule("sch-n5", "cou-n1", _NOW + 20001, custom_weeks="abc,5-7,,9"),
            ],
        })
        body = client.get("/api/sync/pull", headers=self.h, params={"since": 0}).json()["data"]
        by_uuid = {s["uuid"]: s["custom_weeks"] for s in body["schedules"]}
        assert by_uuid["sch-n4"] == ""
        assert by_uuid["sch-n5"] == "5,6,7,9"


class TestCurrentSemesterInvariant:
    """跨 UUID 的“仅一个当前学期”必须由服务端统一维护。"""

    h = _register_and_headers("d")

    def test_重复当前状态自动裁决_可增量下发_并支持后续切换(self):
        first = client.post("/api/sync/push", headers=self.h, json={
            "semesters": [
                _semester("sem-current-old", _NOW + 30000, name="旧学期"),
                _semester("sem-current-new", _NOW + 31000, name="新学期"),
            ],
        })
        assert first.status_code == 200, first.text
        assert first.json()["data"]["repaired_current_semesters"] == 1

        body = client.get("/api/sync/pull", headers=self.h, params={"since": 0}).json()["data"]
        semesters = {row["uuid"]: row for row in body["semesters"]}
        assert len(semesters) == 2
        assert semesters["sem-current-new"]["is_current"] is True
        assert semesters["sem-current-old"]["is_current"] is False
        assert semesters["sem-current-old"]["updated_at"] > _NOW + 31000

        # 用户以后明确切回旧学期时，新写入的 LWW 时间应正常胜出，而不是
        # 被一次性修复永久锁死。
        switch_at = semesters["sem-current-old"]["updated_at"] + 1000
        switched = client.post("/api/sync/push", headers=self.h, json={
            "semesters": [
                _semester("sem-current-old", switch_at, name="旧学期"),
            ],
        })
        assert switched.status_code == 200, switched.text
        assert switched.json()["data"]["repaired_current_semesters"] == 1

        latest = client.get("/api/sync/pull", headers=self.h, params={"since": 0}).json()["data"]
        current = [row for row in latest["semesters"] if row["is_current"] and not row["deleted"]]
        assert [row["uuid"] for row in current] == ["sem-current-old"]


class TestZeroCurrentSemesterRepair:
    """「一个当前学期都没有」也必须修复。

    回归背景（合成场景）：网页版在没有 is_current 时会兜底取最新
    学期，所以这种状态在网页上看着一切正常；而 App 三处都严格按
    is_current=true 取学期（课表页 / 课前提醒 / 桌面小组件），结果是课表整页
    空白，且用户没有任何入口能恢复。此处用合成账号覆盖该历史边界条件。
    """

    # 每个用例用独立账号：零个当前学期是全局不变量，共享账号会让前一个用例
    # 提升出的当前学期污染后一个用例的前置状态。
    def test_单个非当前学期会被提升为当前(self):
        h = _register_and_headers("z1")
        push = client.post("/api/sync/push", headers=h, json={
            "semesters": [_semester("sem-only", _NOW + 40000, is_current=False)],
        })
        assert push.status_code == 200, push.text
        assert push.json()["data"]["repaired_current_semesters"] == 1

        body = client.get("/api/sync/pull", headers=h, params={"since": 0}).json()["data"]
        rows = {row["uuid"]: row for row in body["semesters"]}
        assert rows["sem-only"]["is_current"] is True

    def test_多个非当前学期提升最近更新的那个(self):
        h = _register_and_headers("z2")
        client.post("/api/sync/push", headers=h, json={
            "semesters": [
                _semester("sem-zero-old", _NOW + 41000, is_current=False, name="旧"),
                _semester("sem-zero-new", _NOW + 42000, is_current=False, name="新"),
            ],
        })
        body = client.get("/api/sync/pull", headers=h, params={"since": 0}).json()["data"]
        current = [row["uuid"] for row in body["semesters"] if row["is_current"]]
        assert current == ["sem-zero-new"], "应与网页版回退规则一致：取最近更新的"

    def test_修复能通过增量拉取下发(self):
        h = _register_and_headers("z3")
        """旧客户端靠增量 pull 自愈，不刷新 synced_at 就永远收不到修复。"""
        client.post("/api/sync/push", headers=h, json={
            "semesters": [_semester("sem-incr", _NOW + 43000, is_current=False)],
        })
        first = client.get("/api/sync/pull", headers=h, params={"since": 0}).json()["data"]
        cursor = first["cursor"]

        # 再制造一次失衡：把它写成非当前（模拟旧客户端把 is_current=false 回传）
        client.post("/api/sync/push", headers=h, json={
            "semesters": [_semester("sem-incr", cursor // 1_000_000 + _NOW + 44000,
                                    is_current=False)],
        })
        incremental = client.get(
            "/api/sync/pull", headers=h, params={"since": cursor}
        ).json()["data"]
        rows = {row["uuid"]: row for row in incremental["semesters"]}
        assert "sem-incr" in rows, "修复必须落在增量窗口内"
        assert rows["sem-incr"]["is_current"] is True

    def test_已删除学期不会被提升(self):
        h = _register_and_headers("z4")
        client.post("/api/sync/push", headers=h, json={
            "semesters": [
                _semester("sem-del", _NOW + 45000, is_current=False, deleted=True),
                _semester("sem-alive", _NOW + 45001, is_current=False),
            ],
        })
        body = client.get("/api/sync/pull", headers=h, params={"since": 0}).json()["data"]
        rows = {row["uuid"]: row for row in body["semesters"]}
        assert rows["sem-alive"]["is_current"] is True
        assert rows["sem-del"]["is_current"] is False

    def test_完全没有学期时不凭空造一个(self):
        h = _register_and_headers("z0")
        push = client.post("/api/sync/push", headers=h, json={})
        assert push.status_code == 200, push.text
        assert push.json()["data"]["repaired_current_semesters"] == 0

        body = client.get("/api/sync/pull", headers=h, params={"since": 0}).json()["data"]
        assert body["semesters"] == []

    def test_已经恰好一个当前学期时不做改动(self):
        h = _register_and_headers("z6")
        client.post("/api/sync/push", headers=h, json={
            "semesters": [_semester("sem-stable", _NOW + 46000)],
        })
        before = client.get("/api/sync/pull", headers=h, params={"since": 0}).json()["data"]
        row = next(r for r in before["semesters"] if r["uuid"] == "sem-stable")
        stamp = row["updated_at"]

        again = client.post("/api/sync/push", headers=h, json={
            "semesters": [_semester("sem-stable", _NOW + 46000)],
        })
        assert again.json()["data"]["repaired_current_semesters"] == 0

        after = client.get("/api/sync/pull", headers=h, params={"since": 0}).json()["data"]
        row2 = next(r for r in after["semesters"] if r["uuid"] == "sem-stable")
        assert row2["is_current"] is True
        assert row2["updated_at"] == stamp, "幂等：不该反复抬高 LWW 时间"
