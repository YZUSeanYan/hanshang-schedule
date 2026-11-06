"""「墨程」AI 目标规划端点（POST /api/schedule-ai/goal-plan）与规划解析校验。"""
import asyncio
import base64
import time
from datetime import date, datetime, timedelta, timezone
from uuid import uuid4

from fastapi.testclient import TestClient

from app.api.v1.endpoints import schedule_ai
from app.core.ratelimit import RateLimiter
from app.main import app
from app.services.llm_event_parse import (
    GOAL_TASK_DAYS,
    MAX_CHAT_IMAGE_BASE64_CHARS,
    EventContext,
    EventOperation,
    EventParseError,
    GoalMilestone,
    GoalPlanResult,
    MimoEventGateway,
    build_goal_plan_prompt,
    goal_plan_result_from_llm_content,
)

client = TestClient(app)

_NOW = int(time.time() * 1000)
_SHANGHAI = timezone(timedelta(hours=8))
_TODAY = datetime.now(_SHANGHAI).date()
_LAST_DAY = _TODAY + timedelta(days=GOAL_TASK_DAYS - 1)

_CTX = EventContext(
    today=_TODAY.isoformat(),
    weekday_label="星期一",
    semester_start="2026-08-31",
    week_no=5,
    course_names=("高等数学",),
)

_TASK = EventOperation(
    action="create",
    type="ddl",
    title="高等数学 第3章习题 20 道",
    short_title="高数习题",
    date=_TODAY.isoformat(),
    start_time="19:30",
    end_time="20:30",
    confidence=0.9,
)

_MILESTONE = GoalMilestone(title="完成基础概念", date=_TODAY.isoformat(), note="看完第1-2章")


class _FakeGoalGateway:
    """只实现 goal_plan 的桩：端点只调用这一个方法。"""

    def __init__(
        self,
        result: GoalPlanResult | None = None,
        error: EventParseError | None = None,
    ):
        self.result = result or GoalPlanResult(
            reply="已为你拆好：先打基础再刷题，每天晚自习一小时。",
            milestones=[_MILESTONE],
            tasks=[_TASK],
            llm_ms=1200,
        )
        self.error = error
        self.captured: dict | None = None

    async def goal_plan(self, *, title, detail, target_date, daily_minutes, image_b64, context, agenda, week_schedule):
        self.captured = {
            "title": title,
            "detail": detail,
            "target_date": target_date,
            "daily_minutes": daily_minutes,
            "image_b64": image_b64,
            "context": context,
            "agenda": agenda,
            "week_schedule": week_schedule,
        }
        if self.error is not None:
            raise self.error
        return self.result


def _headers() -> dict[str, str]:
    suffix = uuid4().hex[:10]
    resp = client.post(
        "/api/auth/register",
        json={
            "username": f"goal{suffix}",
            "email": f"goal{suffix}@example.com",
            "password": "password123",
        },
    )
    assert resp.status_code == 200, resp.text
    return {"Authorization": f"Bearer {resp.json()['data']['access_token']}"}


# ---------------------------------------------------------------------------
# 端点行为
# ---------------------------------------------------------------------------


def test_goal_plan_requires_authentication():
    assert client.post("/api/schedule-ai/goal-plan", json={"title": "过四级"}).status_code == 401


def test_goal_plan_requires_title():
    resp = client.post("/api/schedule-ai/goal-plan", headers=_headers(), json={})
    assert resp.status_code == 422


def test_goal_plan_detail_max_length():
    resp = client.post(
        "/api/schedule-ai/goal-plan",
        headers=_headers(),
        json={"title": "过四级", "detail": "啊" * 4001},
    )
    assert resp.status_code == 422


def test_goal_plan_rejects_bad_target_date():
    resp = client.post(
        "/api/schedule-ai/goal-plan",
        headers=_headers(),
        json={"title": "过四级", "target_date": "2026/12/19"},
    )
    assert resp.status_code == 422


def test_goal_plan_rejects_bad_daily_minutes():
    for value in (5, 721):
        resp = client.post(
            "/api/schedule-ai/goal-plan",
            headers=_headers(),
            json={"title": "过四级", "daily_minutes": value},
        )
        assert resp.status_code == 422, value


def test_goal_plan_returns_reply_milestones_tasks(monkeypatch):
    """正常拆解：契约字段齐全，tasks 与 /parse 的 operations 同构。"""
    gateway = _FakeGoalGateway()
    monkeypatch.setattr(schedule_ai, "_gateway", gateway)
    resp = client.post(
        "/api/schedule-ai/goal-plan",
        headers=_headers(),
        json={
            "title": "期末高等数学上 90 分",
            "detail": "目前第1章学完，有教材和往年卷",
            "target_date": (_TODAY + timedelta(days=30)).isoformat(),
            "daily_minutes": 90,
        },
    )
    assert resp.status_code == 200, resp.text
    body = resp.json()
    assert body["code"] == 0
    data = body["data"]
    assert data["reply"] == "已为你拆好：先打基础再刷题，每天晚自习一小时。"
    assert data["milestones"] == [
        {"title": "完成基础概念", "date": _TODAY.isoformat(), "note": "看完第1-2章"}
    ]
    assert len(data["tasks"]) == 1
    task = data["tasks"][0]
    assert task["action"] == "create"
    assert task["type"] == "ddl"
    assert task["title"] == "高等数学 第3章习题 20 道"
    assert task["date"] == _TODAY.isoformat()
    assert task["start_time"] == "19:30"
    assert task["end_time"] == "20:30"
    # 与 /parse 相同的结构约定：空字段展开为 None
    assert task["weekday"] is None
    assert task["target"] is None
    assert isinstance(data["elapsed_ms"], int)
    # 参数原样进网关
    captured = gateway.captured
    assert captured["title"] == "期末高等数学上 90 分"
    assert captured["detail"] == "目前第1章学完，有教材和往年卷"
    assert captured["target_date"] == (_TODAY + timedelta(days=30)).isoformat()
    assert captured["daily_minutes"] == 90


def test_goal_plan_defaults_when_optional_fields_missing(monkeypatch):
    """无目标日期/无 detail/默认 daily_minutes：兜底走默认值，不报错。"""
    gateway = _FakeGoalGateway()
    monkeypatch.setattr(schedule_ai, "_gateway", gateway)
    resp = client.post(
        "/api/schedule-ai/goal-plan",
        headers=_headers(),
        json={"title": "每天背 50 个单词"},
    )
    assert resp.status_code == 200, resp.text
    captured = gateway.captured
    assert captured["target_date"] is None
    assert captured["detail"] == ""
    assert captured["daily_minutes"] == 60


def test_goal_plan_rate_limit(monkeypatch):
    monkeypatch.setattr(schedule_ai, "_goal_plan_daily_limiter", RateLimiter(1, 60))
    monkeypatch.setattr(schedule_ai, "_gateway", _FakeGoalGateway())
    h = _headers()
    assert (
        client.post("/api/schedule-ai/goal-plan", headers=h, json={"title": "目标一"}).status_code
        == 200
    )
    resp = client.post("/api/schedule-ai/goal-plan", headers=h, json={"title": "目标二"})
    assert resp.status_code == 429
    body = resp.json()
    payload = body.get("detail", body)
    assert payload["code"] == 42956


def test_goal_plan_maps_gateway_errors(monkeypatch):
    monkeypatch.setattr(
        schedule_ai,
        "_gateway",
        _FakeGoalGateway(error=EventParseError(502, 50244, "目标规划服务返回异常，请稍后重试")),
    )
    resp = client.post(
        "/api/schedule-ai/goal-plan", headers=_headers(), json={"title": "过四级"}
    )
    assert resp.status_code == 502
    body = resp.json()
    payload = body.get("detail", body)
    assert payload["code"] == 50244


def test_goal_plan_injects_agenda_and_week_schedule(monkeypatch):
    """system prompt 注入：今日摘要 + 本周课表占用（节次换算时刻）。"""
    gateway = _FakeGoalGateway()
    monkeypatch.setattr(schedule_ai, "_gateway", gateway)
    h = _headers()
    weekday = _TODAY.isoweekday()
    client.post(
        "/api/sync/push",
        headers=h,
        json={
            "semesters": [
                {
                    "uuid": "sem-goal",
                    "name": "2026秋",
                    "start_date": "2026-08-31",
                    "total_weeks": 20,
                    "is_current": True,
                    "updated_at": _NOW,
                    "deleted": False,
                }
            ],
            "courses": [
                {
                    "uuid": "cou-goal",
                    "semester_uuid": "sem-goal",
                    "name": "高等数学",
                    "teacher": "李老师",
                    "color": 0,
                    "note": "",
                    "updated_at": _NOW,
                    "deleted": False,
                }
            ],
            "schedules": [
                {
                    "uuid": "sch-goal",
                    "course_uuid": "cou-goal",
                    "day_of_week": weekday,
                    "start_section": 1,
                    "end_section": 2,
                    "weeks_type": 0,
                    "custom_weeks": "",
                    "location": "文津楼N107",
                    "updated_at": _NOW,
                    "deleted": False,
                }
            ],
        },
    )
    resp = client.post(
        "/api/schedule-ai/goal-plan", headers=h, json={"title": "期末高数上 90"}
    )
    assert resp.status_code == 200, resp.text
    captured = gateway.captured
    assert "高等数学" in captured["agenda"]
    assert "第1-2节" in captured["agenda"]
    assert "08:00" in captured["agenda"]
    # 本周课表占用带星期标签与节次时刻
    assert "星期" in captured["week_schedule"]
    assert "高等数学" in captured["week_schedule"]
    assert "08:00" in captured["week_schedule"]
    assert "文津楼N107" in captured["week_schedule"]


def test_goal_plan_week_schedule_empty_when_no_data(monkeypatch):
    gateway = _FakeGoalGateway()
    monkeypatch.setattr(schedule_ai, "_gateway", gateway)
    resp = client.post(
        "/api/schedule-ai/goal-plan", headers=_headers(), json={"title": "过四级"}
    )
    assert resp.status_code == 200, resp.text
    assert gateway.captured["week_schedule"] == ""


# ---------------------------------------------------------------------------
# goal_plan_result_from_llm_content / build_goal_plan_prompt / 真实网关单元测试
# ---------------------------------------------------------------------------


def test_goal_result_parses_reply_milestones_tasks():
    content = (
        '{"reply": "按阶段来。", "milestones": [{"title": "基础", "date": "2026-10-10", "note": "看完前3章"}],'
        ' "tasks": [{"action": "create", "type": "ddl", "title": "高数习题",'
        ' "date": "' + _TODAY.isoformat() + '", "start_time": "19:30", "end_time": "20:30", "confidence": 0.8}'
        "]}"
    )
    reply, milestones, tasks = goal_plan_result_from_llm_content(content, _TODAY.isoformat())
    assert reply == "按阶段来。"
    assert len(milestones) == 1
    assert milestones[0].title == "基础"
    assert len(tasks) == 1
    assert tasks[0].type == "ddl"


def test_goal_result_drops_tasks_outside_window():
    """14 天窗口外的 task 一律丢弃（服务端兜契约，不让超窗任务落库）。"""
    outside = (_TODAY + timedelta(days=GOAL_TASK_DAYS + 5)).isoformat()
    content = (
        '{"reply": "好", "milestones": [], "tasks": ['
        f'{{"action": "create", "type": "ddl", "title": "窗口内", "date": "{_LAST_DAY.isoformat()}"}},'
        f'{{"action": "create", "type": "ddl", "title": "窗口外", "date": "{outside}"}},'
        f'{{"action": "cancel", "type": "ddl", "title": "非create", "date": "{_TODAY.isoformat()}"}}'
        "]}"
    )
    _, milestones, tasks = goal_plan_result_from_llm_content(content, _TODAY.isoformat())
    assert [t.title for t in tasks] == ["窗口内"]


def test_goal_result_drops_bad_milestones_keeps_valid():
    content = (
        '{"reply": "好", "milestones": ['
        '{"title": "", "date": "2026-10-01", "note": "空标题丢弃"},'
        '{"title": "里程碑", "date": "10月1日", "note": "非法日期丢弃"},'
        '{"title": "里程碑B", "date": "2026-10-20", "note": ""},'
        '{"title": "里程碑A", "date": "2026-10-05", "note": "有效"}'
        '], "tasks": []}'
    )
    _, milestones, _ = goal_plan_result_from_llm_content(content, _TODAY.isoformat())
    # 校验后按日期升序
    assert [m.title for m in milestones] == ["里程碑A", "里程碑B"]


def test_goal_result_rejects_broken_json():
    try:
        goal_plan_result_from_llm_content("这不是JSON", _TODAY.isoformat())
    except EventParseError as exc:
        assert exc.code == 50244
    else:
        raise AssertionError("broken JSON 应抛 50244")


def test_goal_result_rejects_empty_reply():
    try:
        goal_plan_result_from_llm_content(
            '{"reply": "", "milestones": [], "tasks": []}', _TODAY.isoformat()
        )
    except EventParseError as exc:
        assert exc.code == 50244
    else:
        raise AssertionError("空 reply 应抛 50244")


def test_build_goal_plan_prompt_with_target_date():
    prompt = build_goal_plan_prompt(
        _CTX,
        "课程 高等数学 第1-2节 08:00-09:40",
        "星期一 高等数学 第1-2节 08:00-09:40 @ 文津楼N107",
        title="期末高数上 90",
        detail="学完第1章",
        target_date="2026-12-20",
        daily_minutes=90,
    )
    assert _CTX.today in prompt
    assert _LAST_DAY.isoformat() in prompt
    assert "2026-12-20" in prompt
    assert "90 分钟" in prompt
    assert "高等数学" in prompt
    assert "第1-2节" in prompt
    assert '"reply"' in prompt and '"milestones"' in prompt and '"tasks"' in prompt


def test_build_goal_plan_prompt_without_target_date_fallback():
    """无目标日期兜底：prompt 说明由 AI 按节奏安排，里程碑上限为今天+28 天。"""
    prompt = build_goal_plan_prompt(
        _CTX, "", "", title="过四级", detail="", target_date=None, daily_minutes=60
    )
    assert "（未指定" in prompt
    fallback = (_TODAY + timedelta(days=28)).isoformat()
    assert fallback in prompt
    assert "（本周没有课程，全天可自由安排）" in prompt


def test_real_gateway_goal_plan_builds_multimodal_and_filters():
    """真实 MimoEventGateway.goal_plan：system+多模态 user 结构 + 窗口过滤。"""
    captured: dict[str, object] = {}

    async def fake_chat(messages, *, json_mode, model=None):
        captured["messages"] = messages
        captured["json_mode"] = json_mode
        captured["model"] = model
        outside = (_TODAY + timedelta(days=GOAL_TASK_DAYS + 30)).isoformat()
        return (
            '{"reply": "拆好了", "milestones": [{"title": "基础", "date": "2026-10-10", "note": "x"}],'
            ' "tasks": ['
            f'{{"action": "create", "type": "ddl", "title": "内", "date": "{_TODAY.isoformat()}"}},'
            f'{{"action": "create", "type": "ddl", "title": "外", "date": "{outside}"}}'
            "]}"
        )

    gateway = MimoEventGateway(
        base_url="https://example.invalid/v1",
        api_key="test-key",
        model="mimo-v2.6-flash",
        asr_model="mimo-v2.5-asr",
        timeout_seconds=5,
    )
    gateway._chat = fake_chat  # type: ignore[method-assign]

    image_b64 = base64.b64encode(b"\xff\xd8\xff\xe0fake").decode()
    result = asyncio.run(
        gateway.goal_plan(
            title="期末高数上 90",
            detail="学完第1章",
            target_date="2026-12-20",
            daily_minutes=90,
            image_b64=image_b64,
            context=_CTX,
            agenda="（今天没有课程或日程）",
            week_schedule="",
        )
    )
    assert result.reply == "拆好了"
    assert len(result.milestones) == 1
    assert [t.title for t in result.tasks] == ["内"]  # 窗口外被过滤
    messages = captured["messages"]
    assert messages[0]["role"] == "system"
    assert "目标规划师" in messages[0]["content"]
    assert "期末高数上 90" in messages[0]["content"]
    user_msg = messages[1]
    assert user_msg["role"] == "user"
    assert user_msg["content"][1]["type"] == "image_url"
    assert captured["json_mode"] is True
    assert captured["model"] is None  # 用默认 mimo-v2.6-flash，不切 ASR 模型


def test_real_gateway_goal_plan_text_only():
    captured: dict[str, object] = {}

    async def fake_chat(messages, *, json_mode, model=None):
        captured["messages"] = messages
        return '{"reply": "好", "milestones": [], "tasks": []}'

    gateway = MimoEventGateway(
        base_url="https://example.invalid/v1",
        api_key="test-key",
        model="mimo-v2.6-flash",
        asr_model="mimo-v2.5-asr",
        timeout_seconds=5,
    )
    gateway._chat = fake_chat  # type: ignore[method-assign]
    result = asyncio.run(
        gateway.goal_plan(
            title="过四级",
            detail="",
            target_date=None,
            daily_minutes=60,
            image_b64=None,
            context=_CTX,
            agenda="",
            week_schedule="",
        )
    )
    assert result.reply == "好"
    messages = captured["messages"]
    assert isinstance(messages[1]["content"], str)


def test_real_gateway_goal_plan_rejects_bad_image():
    gateway = MimoEventGateway(
        base_url="https://example.invalid/v1",
        api_key="test-key",
        model="mimo-v2.6-flash",
        asr_model="mimo-v2.5-asr",
        timeout_seconds=5,
    )
    try:
        asyncio.run(
            gateway.goal_plan(
                title="过四级",
                detail="",
                target_date=None,
                daily_minutes=60,
                image_b64="!!!not-base64!!!",
                context=_CTX,
                agenda="",
                week_schedule="",
            )
        )
    except EventParseError as exc:
        assert exc.code == 40042
    else:
        raise AssertionError("非法 base64 图片应抛 40042")


def test_real_gateway_goal_plan_rejects_oversize_image():
    gateway = MimoEventGateway(
        base_url="https://example.invalid/v1",
        api_key="test-key",
        model="mimo-v2.6-flash",
        asr_model="mimo-v2.5-asr",
        timeout_seconds=5,
    )
    oversize = "A" * (MAX_CHAT_IMAGE_BASE64_CHARS + 4)
    try:
        asyncio.run(
            gateway.goal_plan(
                title="过四级",
                detail="",
                target_date=None,
                daily_minutes=60,
                image_b64=oversize,
                context=_CTX,
                agenda="",
                week_schedule="",
            )
        )
    except EventParseError as exc:
        assert exc.code == 41342
    else:
        raise AssertionError("超 2MB 图片应抛 41342")
