"""AI 日程理解端点与解析校验（AI 日程 2.0）。"""
import time
from uuid import uuid4

from fastapi.testclient import TestClient

from app.api.v1.endpoints import schedule_ai
from app.core.ratelimit import RateLimiter
from app.main import app
from app.services.llm_event_parse import (
    EventContext,
    EventOperation,
    EventParseError,
    EventParseResult,
    build_prompt,
    operations_from_llm_content,
)

client = TestClient(app)

_NOW = int(time.time() * 1000)
_CTX = EventContext(
    today="2026-09-15",
    weekday_label="星期二",
    semester_start="2026-08-31",
    week_no=3,
    course_names=("概率论", "大学物理"),
)


def _headers() -> dict[str, str]:
    suffix = uuid4().hex[:10]
    resp = client.post(
        "/api/auth/register",
        json={
            "username": f"ai{suffix}",
            "email": f"ai{suffix}@example.com",
            "password": "password123",
        },
    )
    assert resp.status_code == 200, resp.text
    return {"Authorization": f"Bearer {resp.json()['data']['access_token']}"}


_OP = EventOperation(
    action="create",
    type="event",
    title="社会实践手册评审",
    date="2026-09-16",
    start_time="15:30",
    end_time="17:30",
    location="学院515",
    confidence=1.0,
)


class _FakeGateway:
    def __init__(self, result=None, error: EventParseError | None = None):
        self.result = result or EventParseResult(
            operations=[_OP], transcript=None, asr_ms=None, llm_ms=3000
        )
        self.error = error
        self.captured: dict | None = None

    async def parse(self, *, text, audio_b64, image_b64=None, context):
        self.captured = {"text": text, "audio_b64": audio_b64, "context": context}
        if self.error is not None:
            raise self.error
        if audio_b64 is not None:
            # 模拟真实网关：语音输入返回转写文本
            return EventParseResult(
                operations=self.result.operations,
                transcript="周三下午三点半要去学院515做社会实践手册评审",
                asr_ms=800,
                llm_ms=self.result.llm_ms,
            )
        return self.result


def test_parse_requires_authentication():
    assert client.post("/api/schedule-ai/parse", json={"text": "明天开会"}).status_code == 401


def test_parse_requires_some_input():
    resp = client.post("/api/schedule-ai/parse", headers=_headers(), json={})
    assert resp.status_code == 422


def test_parse_text_happy_path(monkeypatch):
    gateway = _FakeGateway()
    monkeypatch.setattr(schedule_ai, "_gateway", gateway)
    resp = client.post(
        "/api/schedule-ai/parse",
        headers=_headers(),
        json={"text": "周三下午三点半要去学院515做社会实践手册评审"},
    )
    assert resp.status_code == 200, resp.text
    data = resp.json()["data"]
    assert data["transcript"] is None
    assert data["llm_ms"] == 3000
    assert data["operations"][0]["action"] == "create"
    assert data["operations"][0]["date"] == "2026-09-16"
    assert data["operations"][0]["start_time"] == "15:30"
    # None 字段不展开成空串
    assert data["operations"][0]["weekday"] is None


def test_parse_text_is_stripped_before_gateway(monkeypatch):
    gateway = _FakeGateway()
    monkeypatch.setattr(schedule_ai, "_gateway", gateway)
    resp = client.post(
        "/api/schedule-ai/parse",
        headers=_headers(),
        json={"text": "学号 20261234567 的同学周三下午三点半评审"},
    )
    assert resp.status_code == 200, resp.text
    assert "20261234567" not in gateway.captured["text"]


def test_parse_voice_returns_transcript(monkeypatch):
    gateway = _FakeGateway()
    monkeypatch.setattr(schedule_ai, "_gateway", gateway)
    resp = client.post(
        "/api/schedule-ai/parse",
        headers=_headers(),
        json={"audio_base64": "QUJDREVGRw=="},
    )
    assert resp.status_code == 200, resp.text
    data = resp.json()["data"]
    assert data["transcript"] == "周三下午三点半要去学院515做社会实践手册评审"
    assert data["asr_ms"] == 800
    assert gateway.captured["audio_b64"] == "QUJDREVGRw=="


def test_parse_maps_gateway_errors(monkeypatch):
    monkeypatch.setattr(
        schedule_ai,
        "_gateway",
        _FakeGateway(error=EventParseError(422, 42250, "没有听懂日程安排，可以换个说法再试试")),
    )
    resp = client.post("/api/schedule-ai/parse", headers=_headers(), json={"text": "今天天气不错"})
    assert resp.status_code == 422
    body = resp.json()
    # 统一错误格式为顶层 {"code","message"}，HTTPException(detail=dict) 会被处理器展开
    payload = body.get("detail", body)
    assert payload["code"] == 42250


def test_parse_rate_limit(monkeypatch):
    monkeypatch.setattr(schedule_ai, "_user_daily_limiter", RateLimiter(1, 60))
    monkeypatch.setattr(schedule_ai, "_gateway", _FakeGateway())
    h = _headers()
    assert client.post("/api/schedule-ai/parse", headers=h, json={"text": "明天开会"}).status_code == 200
    resp = client.post("/api/schedule-ai/parse", headers=h, json={"text": "后天也开会"})
    assert resp.status_code == 429


def test_context_includes_current_semester_courses(monkeypatch):
    gateway = _FakeGateway()
    monkeypatch.setattr(schedule_ai, "_gateway", gateway)
    h = _headers()
    client.post(
        "/api/sync/push",
        headers=h,
        json={
            "semesters": [
                {
                    "uuid": "sem-ctx",
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
                    "uuid": "cou-ctx",
                    "semester_uuid": "sem-ctx",
                    "name": "概率论",
                    "teacher": "",
                    "color": 0,
                    "note": "",
                    "updated_at": _NOW,
                    "deleted": False,
                }
            ],
        },
    )
    resp = client.post("/api/schedule-ai/parse", headers=h, json={"text": "把概率论调到周五"})
    assert resp.status_code == 200, resp.text
    ctx: EventContext = gateway.captured["context"]
    assert ctx.semester_start == "2026-08-31"
    assert "概率论" in ctx.course_names


# ---------------------------------------------------------------------------
# operations_from_llm_content 单元测试
# ---------------------------------------------------------------------------


def test_ops_parse_fence_wrapped_json():
    content = '```json\n{"operations": [{"action": "create", "type": "event", "title": "团建", "date": "2026-09-21", "start_time": "19:00", "end_time": "21:00", "confidence": 1.0}]}\n```'
    ops = operations_from_llm_content(content)
    assert len(ops) == 1
    assert ops[0].title == "团建"
    assert ops[0].start_time == "19:00"


def test_ops_reject_broken_json():
    try:
        operations_from_llm_content("这不是JSON")
    except EventParseError as exc:
        assert exc.code == 50242
    else:
        raise AssertionError("broken JSON 应抛 50242")


def test_ops_empty_list_means_not_understood():
    try:
        operations_from_llm_content('{"operations": []}')
    except EventParseError as exc:
        assert exc.code == 42250
    else:
        raise AssertionError("空操作列表应抛 42250")


def test_ops_drop_invalid_entries():
    content = '{"operations": [' \
        '{"action": "create", "type": "event", "title": "", "date": "2026-09-16"},' \
        '{"action": "create", "type": "event", "title": "没日期的"},' \
        '{"action": "nonsense", "type": "event", "title": "坏动作", "date": "2026-09-16"},' \
        '{"action": "create", "type": "recurring", "title": "没星期"},' \
        '{"action": "reschedule", "type": "event", "confidence": 0.9},' \
        '{"action": "create", "type": "exam", "title": "四级考试", "date": "2026-12-19", "start_section": 9, "end_section": 11, "confidence": 0.8}' \
        ']}'
    ops = operations_from_llm_content(content)
    assert len(ops) == 1
    assert ops[0].type == "exam"
    assert ops[0].start_section == 9


def test_ops_section_order_and_confidence_clamp():
    content = '{"operations": [{"action": "create", "type": "event", "title": "讲座", "date": "2026-09-18", "start_section": 8, "end_section": 6, "confidence": 3.7}]}'
    ops = operations_from_llm_content(content)
    assert ops[0].start_section == 6
    assert ops[0].end_section == 8
    assert ops[0].confidence == 1.0


def test_ops_reschedule_uses_target():
    content = '{"operations": [{"action": "reschedule", "type": "recurring", "target": "概率论", "weekday": 5, "start_section": 3, "end_section": 4, "location": "文津楼N107", "confidence": 0.9}]}'
    ops = operations_from_llm_content(content)
    assert ops[0].target == "概率论"
    assert ops[0].weekday == 5
    d = ops[0].to_dict()
    assert d["from_weekday"] is None
    assert d["title"] is None


def test_build_prompt_variants():
    with_sem = build_prompt(_CTX)
    assert "2026-09-15" in with_sem and "第 3 周" in with_sem
    assert "概率论" in with_sem
    no_sem = build_prompt(
        EventContext(
            today="2026-07-10",
            weekday_label="星期五",
            semester_start="",
            week_no=0,
            course_names=(),
        )
    )
    assert "假期中" in no_sem
