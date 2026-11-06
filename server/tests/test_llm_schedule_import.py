import asyncio
import json

import pytest
from uuid import uuid4

from fastapi.testclient import TestClient

from app.api.v1.endpoints import llm_schedule_import
from app.main import app
from app.services.academic_schedule_parser import (
    AcademicScheduleCourse,
    AcademicScheduleParseError,
    AcademicScheduleSlot,
)
from app.services.llm_schedule_import import (
    LlmImportResult,
    LlmScheduleImportError,
    _try_rule_parse,
    clean_timetable_html,
    courses_from_llm_content,
    strip_identity_info,
)

client = TestClient(app)

_HTML = "<html><body><table><tr><th>星期一</th></tr><tr><td>高等数学 1-16周 1-2节</td></tr></table></body></html>" + "x" * 200


def _headers() -> dict[str, str]:
    suffix = uuid4().hex[:10]
    response = client.post(
        "/api/auth/register",
        json={
            "username": f"llm{suffix}",
            "email": f"llm{suffix}@example.com",
            "password": "password123",
        },
    )
    assert response.status_code == 200, response.text
    return {"Authorization": f"Bearer {response.json()['data']['access_token']}"}


_COURSE = AcademicScheduleCourse(
    name="高等数学",
    teacher="王老师",
    slots=(
        AcademicScheduleSlot(
            day_of_week=1,
            start_section=1,
            end_section=2,
            weeks_text="1-16周",
            location="文津楼201",
        ),
    ),
)


class _SuccessfulGateway:
    def __init__(self):
        self.called_with: dict | None = None

    async def import_schedule(self, *, html: str, captured: list[str]):
        self.called_with = {"html": html, "captured": captured}
        return LlmImportResult(courses=[_COURSE], source="llm")


def test_llm_import_requires_authentication():
    response = client.post("/api/education-import/llm-parse", json={"html": _HTML})
    assert response.status_code == 401


def test_llm_import_returns_normalized_courses(monkeypatch):
    gateway = _SuccessfulGateway()
    monkeypatch.setattr(llm_schedule_import, "_gateway", gateway)
    response = client.post(
        "/api/education-import/llm-parse",
        headers=_headers(),
        json={"html": _HTML, "captured": ["{}"], "page_url": "https://jw.example.edu.cn/kb"},
    )

    assert response.status_code == 200, response.text
    assert gateway.called_with["html"] == _HTML
    data = response.json()["data"]
    assert data["source"] == "llm"
    assert data["courses"][0]["slots"][0]["location"] == "文津楼201"
    # 上传的原始 HTML 不得出现在响应里
    assert _HTML not in response.text


def test_llm_import_rejects_tiny_html_before_gateway(monkeypatch):
    gateway = _SuccessfulGateway()
    monkeypatch.setattr(llm_schedule_import, "_gateway", gateway)
    response = client.post(
        "/api/education-import/llm-parse",
        headers=_headers(),
        json={"html": "too short"},
    )

    assert response.status_code == 422
    assert gateway.called_with is None


class _HangingGateway:
    async def import_schedule(self, *, html: str, captured: list[str]):
        await asyncio.sleep(30)
        raise AssertionError("总时限必须先触发并取消本协程")


def test_llm_import_returns_structured_timeout_before_request_deadline(monkeypatch):
    monkeypatch.setattr(llm_schedule_import, "_gateway", _HangingGateway())
    monkeypatch.setattr(
        llm_schedule_import._settings, "llm_import_deadline_seconds", 0.05
    )
    response = client.post(
        "/api/education-import/llm-parse",
        headers=_headers(),
        json={"html": _HTML},
    )

    assert response.status_code == 504
    body = response.json()
    assert body["code"] == 50434
    assert "超时" in body["message"]


class _FailingGateway:
    async def import_schedule(self, *, html: str, captured: list[str]):
        raise LlmScheduleImportError(502, 50232, "课程解析服务暂时不可用，请稍后重试")


def test_llm_import_preserves_gateway_error_codes(monkeypatch):
    monkeypatch.setattr(llm_schedule_import, "_gateway", _FailingGateway())
    response = client.post(
        "/api/education-import/llm-parse",
        headers=_headers(),
        json={"html": _HTML},
    )

    assert response.status_code == 502
    assert response.json()["code"] == 50232


class _UnparseableGateway:
    async def import_schedule(self, *, html: str, captured: list[str]):
        raise AcademicScheduleParseError("页面内容不像课表页")


def test_llm_import_maps_parse_error_to_50231(monkeypatch):
    monkeypatch.setattr(llm_schedule_import, "_gateway", _UnparseableGateway())
    response = client.post(
        "/api/education-import/llm-parse",
        headers=_headers(),
        json={"html": _HTML},
    )

    assert response.status_code == 502
    assert response.json()["code"] == 50231


# ---- 失败要给可执行提示 + 埋点要能区分失败成因 ----
# 回归背景（2026-09-22）：线上一条 school/parse 失败，用户只看到「课表内容暂不支持
# 解析」，不知道下一步做什么；埋点 detail 也只记了耗时桶，事后无法判断是预筛拦截
# 还是模型没识别出课程。这两条测试锁住新行为。


def _events_for(user_id):
    from sqlalchemy import select

    from app.db.session import SessionLocal
    from app.models.import_event import ImportEvent

    db = SessionLocal()
    try:
        return list(
            db.scalars(select(ImportEvent).where(ImportEvent.user_id == user_id))
        )
    finally:
        db.close()


def _headers_with_user():
    suffix = uuid4().hex[:10]
    response = client.post(
        "/api/auth/register",
        json={
            "username": f"u{suffix}",
            "email": f"u{suffix}@example.com",
            "password": "password123",
        },
    )
    assert response.status_code == 200, response.text
    data = response.json()["data"]
    return {"Authorization": f"Bearer {data['access_token']}"}, data["user"]["id"]


class _ReasonedGateway:
    def __init__(self, exc):
        self._exc = exc

    async def import_schedule(self, *, html: str, captured: list[str]):
        raise self._exc


def test_llm_import_returns_actionable_message_not_boilerplate(monkeypatch):
    monkeypatch.setattr(
        llm_schedule_import,
        "_gateway",
        _ReasonedGateway(
            AcademicScheduleParseError(
                "页面内容不像课表页",
                reason="not_timetable",
                user_message="这个页面看起来不是课表页。请先打开教务系统的「本学期课表」再抓取，也可以改用截图导入。",
            )
        ),
    )
    headers, _ = _headers_with_user()
    response = client.post(
        "/api/education-import/llm-parse", headers=headers, json={"html": _HTML}
    )

    assert response.status_code == 502
    body = response.json()
    message = body.get("message") or body.get("detail", {}).get("message", "")
    assert message != "课表内容暂不支持解析", "不能再给用户笼统文案"
    assert "课表页" in message and "截图" in message, "提示必须告诉用户下一步做什么"


def test_llm_import_records_reason_token_in_telemetry(monkeypatch):
    llm_schedule_import._user_daily_limiter._hits.clear()
    monkeypatch.setattr(
        llm_schedule_import,
        "_gateway",
        _ReasonedGateway(
            AcademicScheduleParseError(
                "页面内容不像课表页",
                reason="page_empty",
                user_message="页面内容太少，可能没抓到课表。请先打开教务系统的「本学期课表」页面，再重新抓取。",
            )
        ),
    )
    headers, user_id = _headers_with_user()
    response = client.post(
        "/api/education-import/llm-parse", headers=headers, json={"html": _HTML}
    )
    assert response.status_code == 502

    events = [e for e in _events_for(user_id) if e.outcome == "fail"]
    assert len(events) == 1
    assert "reason=page_empty" in (events[0].detail or ""), events[0].detail
    assert "ms=" in events[0].detail


def test_pre_filter_splits_empty_page_from_wrong_page():
    """两种预筛拦截必须给出不同 reason（补救动作不同）。"""
    from app.services.llm_schedule_import import MimoScheduleGateway

    gateway = MimoScheduleGateway(
        base_url="https://example.invalid/v1",
        api_key="test",
        model="mimo-v2.6-flash",
        timeout_seconds=5,
    )

    import asyncio

    # 太短：清洗后不足 200 字符
    with pytest.raises(AcademicScheduleParseError) as short:
        asyncio.run(gateway.import_schedule(html="<html>hi</html>", captured=[]))
    assert short.value.reason == "page_empty"
    assert "本学期课表" in short.value.user_message

    # 够长但不含课表关键词
    long_wrong = "<html><body>" + "这是一段介绍文字" * 60 + "</body></html>"
    with pytest.raises(AcademicScheduleParseError) as wrong:
        asyncio.run(gateway.import_schedule(html=long_wrong, captured=[]))
    assert wrong.value.reason == "not_timetable"
    assert wrong.value.user_message != short.value.user_message


# ---- 清洗与解析纯函数 ----


def test_clean_timetable_html_strips_noise_and_keeps_semantics():
    raw = (
        "<html><head><style>.a{color:red}</style>"
        + "x" * 5000
        + "</style><script>var a=1;</script></head>"
        '<body><input type="hidden" id="classCodec" value="2501机械">'
        '<table class="table" id="courseTable"><thead><tr><th>星期一</th></tr></thead>'
        '<tbody><tr><td id="1_1" style="color:red" onclick="x()">'
        '<div class="class_div"><p class="p-kcm-1">大学物理Ⅳ_02</p>'
        "<p>1-16周</p><p>1-2节</p></div></td></tr></tbody></table></body></html>"
    )
    cleaned = clean_timetable_html(raw)

    assert "color:red" not in cleaned
    assert "var a=1" not in cleaned
    assert "classCodec" not in cleaned  # 隐藏域剔除
    assert "onclick" not in cleaned
    assert 'class="class_div"' in cleaned  # class/id 语义线索保留
    assert 'id="1_1"' in cleaned
    assert "大学物理Ⅳ_02" in cleaned
    assert len(cleaned) < 1000


def test_clean_timetable_html_selects_course_table():
    noise_table = "<table><tr><td>菜单导航链接</td></tr></table>"
    course_table = "<table><tr><th>星期一 星期二</th></tr><tr><td>高等数学 1-16周 1-2节 教室</td></tr></table>"
    raw = noise_table + "x" * 300 + course_table
    assert clean_timetable_html(raw) == course_table


def test_courses_from_llm_content_parses_fenced_json():
    content = """```json
{"courses": [
  {"name": "大学物理Ⅳ", "teacher": "教师A", "slots": [
    {"day_of_week": 2, "start_section": 1, "end_section": 2, "weeks_text": "1-16周", "location": "文津楼101"},
    {"day_of_week": 9, "start_section": 1, "end_section": 2, "weeks_text": "", "location": ""},
    {"day_of_week": 4, "start_section": 5, "end_section": 3, "weeks_text": "", "location": ""}
  ]},
  {"name": "坏课", "teacher": "", "slots": []}
]}
```"""
    courses = courses_from_llm_content(content)

    assert len(courses) == 1
    assert courses[0].name == "大学物理Ⅳ"
    # 星期 9 和 节次倒置 的 slot 被丢弃，合法 slot 保留
    assert len(courses[0].slots) == 1
    assert courses[0].slots[0].day_of_week == 2


def test_courses_from_llm_content_rejects_garbage():
    for bad in ["", "not json at all", '{"foo": 1}', '{"courses": []}', '{"courses": [{"name": "x"}]}']:
        try:
            courses_from_llm_content(bad)
        except AcademicScheduleParseError:
            continue
        raise AssertionError(f"应当拒绝: {bad!r}")


def test_try_rule_parse_handles_jsonp_wrapped_payload():
    payload = {
        "data": [
            {
                "kcmc": "高等数学",
                "jsxm": "王老师",
                "skxq": "1",
                "skjc": "1",
                "cxjc": "2",
                "zcsm": "1-16周",
                "skdd": "文津楼201",
            }
        ]
    }
    jsonp = "jQuery1123_callback(" + json.dumps(payload, ensure_ascii=False) + ");"

    courses = _try_rule_parse([jsonp])

    assert courses is not None
    assert courses[0].name == "高等数学"
    assert courses[0].slots[0].start_section == 1
    assert courses[0].slots[0].end_section == 2


def test_try_rule_parse_returns_none_for_unrecognized_bodies():
    assert _try_rule_parse(['{"hello": "world"}', "plain text"]) is None
    assert _try_rule_parse([]) is None


def test_try_rule_parse_handles_mobile_urp_indexed_map():
    """扬大移动版 ajaxStudentSchedule：xkxx 是列表里套按课程号索引的大字典，
    周次（skzcs）挂在课程级，时间段里只有 id.skxq/skjc/cxjc。
    2026-08-23 真实失败案例还原。"""
    course = {
        "courseName": "毛泽东思想和中国特色社会主义理论体系概论",
        "attendClassTeacher": "教师F",
        "skzcs": "1-18",
        "unit": 3.0,
        "timeAndPlaceList": [
            {
                "id": {"skxq": "4", "skjc": "9", "cxjc": "2"},
                "skdd": "扬子津东校区文津楼E206",
            }
        ],
    }
    payload = {
        "rwbgLists": [],
        "allUnits": 2.0,
        "xkxx": [{"21031003_01": course, "17082011_12": dict(course, courseName="概率论与数理统计Ⅱ", attendClassTeacher="教师C")}],
    }

    courses = _try_rule_parse([json.dumps(payload, ensure_ascii=False)])

    assert courses is not None
    assert len(courses) == 2
    first = courses[0]
    assert first.teacher == "教师F"
    slot = first.slots[0]
    assert slot.day_of_week == 4
    assert (slot.start_section, slot.end_section) == (9, 10)
    # 周次从课程级 skzcs 继承到时间段
    assert slot.weeks_text == "1-18"
    assert slot.location == "扬子津东校区文津楼E206"


# ---- 身份脱敏（合规红线：姓名/学号不送大模型、不落库、不写日志）----


def test_strip_identity_info_masks_names_and_student_ids():
    raw = (
        "<div>姓名：张三</div><div>学号: 2113401234</div>"
        '{"xm":"李四","xh":"2113401234","kcmc":"高等数学","name":"高等数学"}'
        "联系电话 13800001111"
    )
    stripped = strip_identity_info(raw)

    assert "张三" not in stripped
    assert "李四" not in stripped
    assert "2113401234" not in stripped
    assert "13800001111" not in stripped
    # 课程名与课程字段不受影响（通用 name 键是课程名，不得抹除）
    assert stripped.count("高等数学") == 2
    assert '"kcmc":"高等数学"' in stripped


def test_strip_identity_info_handles_split_table_cells():
    # 清洗后的 HTML：标签与值分处相邻单元格
    raw = "<tr><td>姓名</td><td>王五</td></tr><tr><td>学号</td><td>2098012345</td></tr>"
    stripped = strip_identity_info(raw)
    assert "王五" not in stripped
    assert "2098012345" not in stripped


def test_strip_identity_info_keeps_course_data():
    # 8 位及以内的课程代码、周次、节次、教室号都不受影响
    raw = "高等数学 1-16周 第1-2节 文津楼N107 10021001 2026-2027"
    assert strip_identity_info(raw) == raw


def test_llm_import_sanitizes_identity_before_gateway(monkeypatch):
    gateway = _SuccessfulGateway()
    monkeypatch.setattr(llm_schedule_import, "_gateway", gateway)
    dirty = _HTML + '<p>姓名：李四季</p><p>学号：2299012345</p>'
    response = client.post(
        "/api/education-import/llm-parse",
        headers=_headers(),
        json={"html": dirty, "captured": ['{"xh":"2299012345","kcmc":"x"}']},
    )

    assert response.status_code == 200, response.text
    assert "李四季" not in gateway.called_with["html"]
    assert "2299012345" not in gateway.called_with["html"]
    assert "2299012345" not in gateway.called_with["captured"][0]
