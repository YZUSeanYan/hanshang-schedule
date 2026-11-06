"""「墨程」AI 助手对话端点（POST /api/schedule-ai/chat）与对话解析校验。"""
import asyncio
import base64
import time
from datetime import datetime, timedelta, timezone
from uuid import uuid4

from fastapi.testclient import TestClient

from app.api.v1.endpoints import schedule_ai
from app.core.ratelimit import RateLimiter
from app.main import app
from app.services.llm_event_parse import (
    MAX_CHAT_IMAGE_BASE64_CHARS,
    ChatResult,
    EventContext,
    EventOperation,
    EventParseError,
    MimoEventGateway,
    build_chat_prompt,
    chat_result_from_llm_content,
)

client = TestClient(app)

_NOW = int(time.time() * 1000)
_SHANGHAI = timezone(timedelta(hours=8))
_TODAY = datetime.now(_SHANGHAI).date()

_CTX = EventContext(
    today=_TODAY.isoformat(),
    weekday_label="星期一",
    semester_start="2026-08-31",
    week_no=5,
    course_names=("概率论", "大学物理"),
)

_OP = EventOperation(
    action="create",
    type="event",
    title="班级团建",
    short_title="团建",
    date="2026-09-30",
    start_time="19:00",
    end_time="21:00",
    location="体育馆",
    confidence=0.95,
)


class _FakeChatGateway:
    """只实现 chat 的桩：端点只调用这一个方法。"""

    def __init__(self, result: ChatResult | None = None, error: EventParseError | None = None):
        self.result = result or ChatResult(reply="好的，记下了。", operations=[_OP], llm_ms=900)
        self.error = error
        self.captured: dict | None = None

    async def chat(self, *, message, image_b64, history, context, agenda):
        self.captured = {
            "message": message,
            "image_b64": image_b64,
            "history": history,
            "context": context,
            "agenda": agenda,
        }
        if self.error is not None:
            raise self.error
        return self.result


def _headers() -> dict[str, str]:
    suffix = uuid4().hex[:10]
    resp = client.post(
        "/api/auth/register",
        json={
            "username": f"chat{suffix}",
            "email": f"chat{suffix}@example.com",
            "password": "password123",
        },
    )
    assert resp.status_code == 200, resp.text
    return {"Authorization": f"Bearer {resp.json()['data']['access_token']}"}


# ---------------------------------------------------------------------------
# 端点行为
# ---------------------------------------------------------------------------


def test_chat_requires_authentication():
    assert client.post("/api/schedule-ai/chat", json={"message": "你好"}).status_code == 401


def test_chat_requires_message():
    resp = client.post("/api/schedule-ai/chat", headers=_headers(), json={})
    assert resp.status_code == 422


def test_chat_message_max_length():
    resp = client.post(
        "/api/schedule-ai/chat", headers=_headers(), json={"message": "啊" * 2001}
    )
    assert resp.status_code == 422


def test_chat_history_max_ten_turns():
    history = [{"role": "user", "content": "你好"}] * 11
    resp = client.post(
        "/api/schedule-ai/chat",
        headers=_headers(),
        json={"message": "你好", "history": history},
    )
    assert resp.status_code == 422


def test_chat_small_talk_returns_empty_operations(monkeypatch):
    gateway = _FakeChatGateway(
        result=ChatResult(reply="今天也要加油呀！", operations=[], llm_ms=600)
    )
    monkeypatch.setattr(schedule_ai, "_gateway", gateway)
    resp = client.post(
        "/api/schedule-ai/chat", headers=_headers(), json={"message": "今天天气怎么样"}
    )
    assert resp.status_code == 200, resp.text
    body = resp.json()
    assert body["code"] == 0
    data = body["data"]
    assert data["reply"] == "今天也要加油呀！"
    assert data["operations"] == []
    assert isinstance(data["elapsed_ms"], int)


def test_chat_create_intent_returns_operation(monkeypatch):
    gateway = _FakeChatGateway()
    monkeypatch.setattr(schedule_ai, "_gateway", gateway)
    resp = client.post(
        "/api/schedule-ai/chat",
        headers=_headers(),
        json={"message": "帮我记一下下周三晚上七点体育馆班级团建"},
    )
    assert resp.status_code == 200, resp.text
    data = resp.json()["data"]
    assert data["reply"] == "好的，记下了。"
    assert len(data["operations"]) == 1
    op = data["operations"][0]
    assert op["action"] == "create"
    assert op["type"] == "event"
    assert op["title"] == "班级团建"
    assert op["date"] == "2026-09-30"
    assert op["start_time"] == "19:00"
    assert op["end_time"] == "21:00"
    assert op["location"] == "体育馆"
    # 与 /parse 相同的结构约定：空字段展开为 None
    assert op["weekday"] is None
    assert op["target"] is None


def test_chat_forwards_history_and_strips_message(monkeypatch):
    gateway = _FakeChatGateway(result=ChatResult(reply="嗯嗯", operations=[], llm_ms=10))
    monkeypatch.setattr(schedule_ai, "_gateway", gateway)
    history = [
        {"role": "user", "content": "我明天有什么课"},
        {"role": "assistant", "content": "明天上午有概率论"},
    ]
    resp = client.post(
        "/api/schedule-ai/chat",
        headers=_headers(),
        json={"message": "学号 20261234567 帮我看看后天的呢", "history": history},
    )
    assert resp.status_code == 200, resp.text
    captured = gateway.captured
    assert captured["history"] == history
    # 身份信息在端点边界即脱敏，不进网关
    assert "20261234567" not in captured["message"]


def test_chat_with_image(monkeypatch):
    gateway = _FakeChatGateway(
        result=ChatResult(reply="海报上的活动已识别。", operations=[_OP], llm_ms=1500)
    )
    monkeypatch.setattr(schedule_ai, "_gateway", gateway)
    image_b64 = base64.b64encode(b"\xff\xd8\xff\xe0fake-jpeg").decode()
    resp = client.post(
        "/api/schedule-ai/chat",
        headers=_headers(),
        json={"message": "这张海报什么时候", "image_base64": image_b64},
    )
    assert resp.status_code == 200, resp.text
    assert gateway.captured["image_b64"] == image_b64
    assert resp.json()["data"]["operations"][0]["action"] == "create"


def test_chat_rate_limit(monkeypatch):
    monkeypatch.setattr(schedule_ai, "_chat_daily_limiter", RateLimiter(1, 60))
    monkeypatch.setattr(schedule_ai, "_gateway", _FakeChatGateway())
    h = _headers()
    assert client.post("/api/schedule-ai/chat", headers=h, json={"message": "你好"}).status_code == 200
    resp = client.post("/api/schedule-ai/chat", headers=h, json={"message": "再说一句"})
    assert resp.status_code == 429
    body = resp.json()
    payload = body.get("detail", body)
    assert payload["code"] == 42953


def test_chat_maps_gateway_errors(monkeypatch):
    monkeypatch.setattr(
        schedule_ai,
        "_gateway",
        _FakeChatGateway(error=EventParseError(502, 50243, "AI 助手服务返回异常，请稍后重试")),
    )
    resp = client.post("/api/schedule-ai/chat", headers=_headers(), json={"message": "你好"})
    assert resp.status_code == 502
    body = resp.json()
    payload = body.get("detail", body)
    assert payload["code"] == 50243


def test_chat_agenda_includes_today_courses_and_events(monkeypatch):
    """system prompt 注入：今日课程（节次换算时刻）+ 今日日程进 agenda。"""
    gateway = _FakeChatGateway(result=ChatResult(reply="好", operations=[], llm_ms=10))
    monkeypatch.setattr(schedule_ai, "_gateway", gateway)
    h = _headers()
    weekday = _TODAY.isoweekday()
    client.post(
        "/api/sync/push",
        headers=h,
        json={
            "semesters": [
                {
                    "uuid": "sem-chat",
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
                    "uuid": "cou-chat",
                    "semester_uuid": "sem-chat",
                    "name": "概率论",
                    "teacher": "王老师",
                    "color": 0,
                    "note": "",
                    "updated_at": _NOW,
                    "deleted": False,
                }
            ],
            "schedules": [
                {
                    "uuid": "sch-chat",
                    "course_uuid": "cou-chat",
                    "day_of_week": weekday,
                    "start_section": 3,
                    "end_section": 4,
                    "weeks_type": 0,
                    "custom_weeks": "",
                    "location": "文津楼N107",
                    "updated_at": _NOW,
                    "deleted": False,
                }
            ],
            "events": [
                {
                    "uuid": "evt-chat",
                    "title": "交实验报告",
                    "event_type": "ddl",
                    "date": _TODAY.isoformat(),
                    "updated_at": _NOW,
                    "deleted": False,
                }
            ],
        },
    )
    resp = client.post("/api/schedule-ai/chat", headers=h, json={"message": "我今天有啥安排"})
    assert resp.status_code == 200, resp.text
    agenda = gateway.captured["agenda"]
    assert "概率论" in agenda
    assert "第3-4节" in agenda
    assert "09:55" in agenda  # 第 3 节起始时刻（节次换算）
    assert "文津楼N107" in agenda
    assert "交实验报告" in agenda
    assert "今日截止" in agenda


def test_chat_agenda_empty_when_no_data(monkeypatch):
    gateway = _FakeChatGateway(result=ChatResult(reply="好", operations=[], llm_ms=10))
    monkeypatch.setattr(schedule_ai, "_gateway", gateway)
    resp = client.post("/api/schedule-ai/chat", headers=_headers(), json={"message": "你好"})
    assert resp.status_code == 200, resp.text
    assert gateway.captured["agenda"] == "（今天没有课程或日程）"


# ---------------------------------------------------------------------------
# chat_result_from_llm_content / build_chat_prompt / 真实网关 chat 单元测试
# ---------------------------------------------------------------------------


def test_chat_result_parses_reply_and_operations():
    content = (
        '{"reply": "已为你创建。", "operations": [{"action": "create", "type": "event",'
        ' "title": "团建", "date": "2026-09-30", "start_time": "19:00", "confidence": 0.9}]}'
    )
    reply, ops = chat_result_from_llm_content(content)
    assert reply == "已为你创建。"
    assert len(ops) == 1
    assert ops[0].title == "团建"


def test_chat_result_empty_operations_is_valid():
    reply, ops = chat_result_from_llm_content('{"reply": "闲聊回答", "operations": []}')
    assert reply == "闲聊回答"
    assert ops == []


def test_chat_result_missing_operations_defaults_empty():
    reply, ops = chat_result_from_llm_content('{"reply": "没带 operations 字段"}')
    assert ops == []


def test_chat_result_rejects_broken_json():
    try:
        chat_result_from_llm_content("这不是JSON")
    except EventParseError as exc:
        assert exc.code == 50243
    else:
        raise AssertionError("broken JSON 应抛 50243")


def test_chat_result_rejects_empty_reply():
    try:
        chat_result_from_llm_content('{"reply": "", "operations": []}')
    except EventParseError as exc:
        assert exc.code == 50243
    else:
        raise AssertionError("空 reply 应抛 50243")


def test_chat_result_drops_invalid_operations_keeps_reply():
    content = (
        '{"reply": "有一条没法识别。", "operations": ['
        '{"action": "nonsense", "type": "event", "title": "坏动作"},'
        '{"action": "create", "type": "exam", "title": "四级", "date": "2026-12-19"}'
        "]}"
    )
    reply, ops = chat_result_from_llm_content(content)
    assert reply == "有一条没法识别。"
    assert len(ops) == 1
    assert ops[0].type == "exam"


def test_build_chat_prompt_contains_agenda_and_context():
    prompt = build_chat_prompt(_CTX, "课程 概率论 第3-4节 09:55-11:35 @ 文津楼N107")
    assert "2026-08-31" in prompt
    assert "第 5 周" in prompt
    assert "概率论" in prompt
    assert "课程 概率论 第3-4节 09:55-11:35 @ 文津楼N107" in prompt
    assert '"reply"' in prompt and '"operations"' in prompt


def test_build_chat_prompt_vacation_variant():
    prompt = build_chat_prompt(
        EventContext(
            today="2026-07-10",
            weekday_label="星期五",
            semester_start="",
            week_no=0,
            course_names=(),
        ),
        "",
    )
    assert "假期中" in prompt
    assert "（今天没有课程或日程）" in prompt


def test_real_gateway_chat_builds_multimodal_and_history():
    """真实 MimoEventGateway.chat：消息结构（system+history+多模态 user）正确。"""
    captured: dict[str, object] = {}

    async def fake_chat(messages, *, json_mode, model=None):
        captured["messages"] = messages
        captured["json_mode"] = json_mode
        captured["model"] = model
        return '{"reply": "好", "operations": []}'

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
        gateway.chat(
            message="这张图上的活动帮我记下来",
            image_b64=image_b64,
            history=[
                {"role": "user", "content": "上一轮"},
                {"role": "assistant", "content": "上一答"},
                {"role": "system", "content": "非法角色应被丢弃"},
            ],
            context=_CTX,
            agenda="（今天没有课程或日程）",
        )
    )
    assert result.reply == "好"
    assert result.operations == []
    messages = captured["messages"]
    assert messages[0]["role"] == "system"
    assert "今日" not in messages[0]["content"] or "课程" in messages[0]["content"]
    assert messages[1] == {"role": "user", "content": "上一轮"}
    assert messages[2] == {"role": "assistant", "content": "上一答"}
    assert all(m["role"] != "system" for m in messages[1:])
    user_msg = messages[-1]
    assert user_msg["role"] == "user"
    assert user_msg["content"][0] == {"type": "text", "text": "这张图上的活动帮我记下来"}
    assert user_msg["content"][1]["type"] == "image_url"
    assert image_b64 in user_msg["content"][1]["image_url"]["url"]
    assert captured["json_mode"] is True
    assert captured["model"] is None  # 用默认 mimo-v2.6-flash，不切 ASR 模型


def test_real_gateway_chat_rejects_bad_image():
    gateway = MimoEventGateway(
        base_url="https://example.invalid/v1",
        api_key="test-key",
        model="mimo-v2.6-flash",
        asr_model="mimo-v2.5-asr",
        timeout_seconds=5,
    )
    try:
        asyncio.run(
            gateway.chat(
                message="看图",
                image_b64="!!!not-base64!!!",
                history=[],
                context=_CTX,
                agenda="",
            )
        )
    except EventParseError as exc:
        assert exc.code == 40042
    else:
        raise AssertionError("非法 base64 图片应抛 40042")


def test_real_gateway_chat_rejects_oversize_image():
    gateway = MimoEventGateway(
        base_url="https://example.invalid/v1",
        api_key="test-key",
        model="mimo-v2.6-flash",
        asr_model="mimo-v2.5-asr",
        timeout_seconds=5,
    )
    # 超过 base64 字符上限（长度检查在解码之前，内容无需是可解码数据）
    oversize = "A" * (MAX_CHAT_IMAGE_BASE64_CHARS + 4)
    try:
        asyncio.run(
            gateway.chat(
                message="看图",
                image_b64=oversize,
                history=[],
                context=_CTX,
                agenda="",
            )
        )
    except EventParseError as exc:
        assert exc.code == 41342
    else:
        raise AssertionError("超 2MB 图片应抛 41342")


def test_real_gateway_chat_empty_message_without_image():
    gateway = MimoEventGateway(
        base_url="https://example.invalid/v1",
        api_key="test-key",
        model="mimo-v2.6-flash",
        asr_model="mimo-v2.5-asr",
        timeout_seconds=5,
    )
    try:
        asyncio.run(
            gateway.chat(message="   ", image_b64=None, history=[], context=_CTX, agenda="")
        )
    except EventParseError as exc:
        assert exc.code == 42254
    else:
        raise AssertionError("空消息应抛 42254")
