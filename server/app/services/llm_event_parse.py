"""AI 日程理解（AI 日程 2.0）：随口一句话 → 结构化日程操作。

两段式管线，复用与课表 LLM 解析相同的网关约定（单请求独立会话、有界重试、
关闭思考、JSON mode）：

1. **转写**：mimo-v2.5-asr，经 chat/completions 的 ``input_audio`` 内容块上传
   PCM WAV（2026-09-15 实测：5 秒语音冷启动约 7 秒、热路径 1 秒内，
   中文数字会按口语读出如「五百一十五」「N幺零七」，由下一步归一化）；
2. **理解**：mimo-v2.6-flash 以当前日期/学期周次/已有课程名为上下文，把文本解析成
   操作列表 JSON（create / reschedule / cancel）。2026-09-22 由 mimo-v2.5
   升级（同题单条解析 4.0s→1.0s）；语音转写仍固定用 mimo-v2.5-asr，
   原因见 config.llm_import_asr_model 的注释。

隐私红线：音频与转写文本只存在于单次请求内存中——不落库、不写日志、
不进限流 key；文本在送入大模型前过一遍 strip_identity_info 脱敏。
"""
from __future__ import annotations

import asyncio
import base64
import binascii
import json
import logging
import re
import time
from dataclasses import dataclass
from datetime import date as _date
from datetime import timedelta as _timedelta
from typing import Any, Protocol

import aiohttp

from app.services.llm_schedule_import import strip_identity_info

# 只记录元数据（状态码/大小/耗时），绝不记录音频、转写文本或解析结果内容。
logger = logging.getLogger(__name__)

# 16kHz 16bit 单声道 WAV 约 32KB/s；4MB base64 ≈ 90 秒录音，覆盖所有随口场景。
MAX_AUDIO_BASE64_CHARS = 4_000_000
# 日程截图/海报：JPEG/PNG 压缩后通常 1-3MB，base64 上限 6MB。
MAX_IMAGE_BASE64_CHARS = 6_000_000
# 对话图片（「墨程」AI 助手）：接口契约 ≤2MB 二进制；2MiB 的 base64 恰好
# 2796204 字符（ceil(2097152/3)*4），上限按此取齐。
MAX_CHAT_IMAGE_BASE64_CHARS = 2_796_204

_ACTIONS = ("create", "reschedule", "cancel")
_TYPES = ("event", "ddl", "exam", "recurring")
_DATE_RE = re.compile(r"^\d{4}-\d{2}-\d{2}$")
_TIME_RE = re.compile(r"^([01]\d|2[0-3]):[0-5]\d$")


class EventParseError(Exception):
    """Structured failure mirrored to the client with a stable code."""

    def __init__(self, status_code: int, code: int, message: str):
        super().__init__(message)
        self.status_code = status_code
        self.code = code
        self.message = message


@dataclass(frozen=True)
class EventOperation:
    action: str  # create / reschedule / cancel
    type: str  # event / ddl / exam / recurring
    title: str = ""
    short_title: str = ""  # 课表格子上展示的简写（≤16 字符），空=用 title
    date: str = ""  # YYYY-MM-DD，一次性日程
    weekday: int = 0  # recurring：1=周一…7=周日
    start_time: str = ""  # HH:MM
    end_time: str = ""
    start_section: int = 0
    end_section: int = 0
    location: str = ""
    target: str = ""  # reschedule/cancel 要匹配的课程名或日程标题
    from_weekday: int = 0  # reschedule 原时间筛选（一门课多个时段时定位用）
    from_start_section: int = 0
    confidence: float = 1.0

    def to_dict(self) -> dict[str, Any]:
        return {
            "action": self.action,
            "type": self.type,
            "title": self.title or None,
            "short_title": self.short_title or None,
            "date": self.date or None,
            "weekday": self.weekday or None,
            "start_time": self.start_time or None,
            "end_time": self.end_time or None,
            "start_section": self.start_section or None,
            "end_section": self.end_section or None,
            "location": self.location or None,
            "target": self.target or None,
            "from_weekday": self.from_weekday or None,
            "from_start_section": self.from_start_section or None,
            "confidence": self.confidence,
        }


@dataclass(frozen=True)
class EventParseResult:
    operations: list[EventOperation]
    transcript: str | None  # 语音输入时的转写文本；纯文字输入为 None
    asr_ms: int | None
    llm_ms: int


@dataclass(frozen=True)
class ChatResult:
    """AI 助手对话结果：给用户的文字回复 + 可选的结构化日程操作。"""

    reply: str
    operations: list[EventOperation]
    llm_ms: int


@dataclass(frozen=True)
class GoalMilestone:
    """目标规划的阶段里程碑：标题 + 完成日期 + 完成标志。"""

    title: str
    date: str  # YYYY-MM-DD
    note: str

    def to_dict(self) -> dict[str, Any]:
        return {"title": self.title, "date": self.date, "note": self.note or None}


@dataclass(frozen=True)
class GoalPlanResult:
    """目标规划结果：规划说明 + 里程碑 + 未来 14 天每日任务（EventOperation）。"""

    reply: str
    milestones: list[GoalMilestone]
    tasks: list[EventOperation]
    llm_ms: int


@dataclass(frozen=True)
class EventContext:
    """解析锚点：让模型正确理解「周三」「下周」等相对时间。"""

    today: str  # YYYY-MM-DD（Asia/Shanghai）
    weekday_label: str  # 星期二 等
    semester_start: str  # 当前学期第 1 周周一；无当前学期为空串
    week_no: int  # 当前周次；不在学期周内为 0
    course_names: tuple[str, ...]
    # 常用地点词表（用户课表里出现过的楼宇/教室 + 校本部楼名）：
    # 语音转写与理解都用它纠正同音错字（「文津楼」被听成「文经楼」等）
    place_names: tuple[str, ...] = ()


class EventParseGateway(Protocol):
    async def parse(
        self,
        *,
        text: str | None,
        audio_b64: str | None,
        image_b64: str | None = None,
        context: EventContext,
    ) -> EventParseResult: ...

    async def transcribe_partial(self, audio_b64: str, hint: str = "") -> str:
        """录音进行中的分段转写（实时上屏用）；文本不落库、不记内容日志。"""
        ...

    async def parse_holiday(
        self, *, text: str | None, image_b64: str | None, year: int
    ) -> list[dict[str, Any]]:
        """调休通知 → 调整列表（放假/补课）。"""
        ...

    async def chat(
        self,
        *,
        message: str,
        image_b64: str | None,
        history: list[dict[str, str]],
        context: EventContext,
        agenda: str,
    ) -> ChatResult:
        """AI 助手对话：回复 + 可选日程操作（无日程意图时 operations 为空）。"""
        ...

    async def goal_plan(
        self,
        *,
        title: str,
        detail: str,
        target_date: str | None,
        daily_minutes: int,
        image_b64: str | None,
        context: EventContext,
        agenda: str,
        week_schedule: str,
    ) -> GoalPlanResult:
        """目标规划：目标 → 阶段里程碑 + 未来 14 天每日任务（避开课程时段）。"""
        ...


class UnavailableEventGateway:
    async def parse(
        self,
        *,
        text: str | None,
        audio_b64: str | None,
        image_b64: str | None = None,
        context: EventContext,
    ) -> EventParseResult:
        raise EventParseError(503, 50341, "AI 日程理解暂未开放")

    async def transcribe_partial(self, audio_b64: str, hint: str = "") -> str:
        raise EventParseError(503, 50341, "AI 日程理解暂未开放")

    async def parse_holiday(
        self, *, text: str | None, image_b64: str | None, year: int
    ) -> list[dict[str, Any]]:
        raise EventParseError(503, 50341, "AI 日程理解暂未开放")

    async def chat(
        self,
        *,
        message: str,
        image_b64: str | None,
        history: list[dict[str, str]],
        context: EventContext,
        agenda: str,
    ) -> ChatResult:
        raise EventParseError(503, 50342, "AI 助手暂未开放")

    async def goal_plan(
        self,
        *,
        title: str,
        detail: str,
        target_date: str | None,
        daily_minutes: int,
        image_b64: str | None,
        context: EventContext,
        agenda: str,
        week_schedule: str,
    ) -> GoalPlanResult:
        raise EventParseError(503, 50343, "AI 目标规划暂未开放")


_PROMPT_TEMPLATE = """你是大学生的日程理解助手。把用户随口说的一句话解析成结构化的日程操作。

当前上下文:
- 今天是 {today}（{weekday_label}）
{semester_line}
- 本学期已有课程: {course_names}

常用地点词表（涉及地点时优先匹配这些名称，纠正同音字，如「文津楼」不要写成「文经楼」）: {place_names_line}

只输出 JSON:
{{
  "operations": [
    {{
      "action": "create" | "reschedule" | "cancel",
      "type": "event" | "ddl" | "exam" | "recurring",
      "title": "事件标题（create 必填，简明如「班级团建」）",
      "short_title": "课表小格子上的简写（create 必填，2-6 字，提炼 title 核心词，如「团建」「小组讨论」「交报告」）",
      "date": "YYYY-MM-DD 或 null（event/ddl/exam 一次性日程填）",
      "weekday": 1-7 或 null（recurring 周期日程填，1=周一）,
      "start_time": "HH:MM 或 null",
      "end_time": "HH:MM 或 null",
      "start_section": 整数或 null（用户用节次表达时填，如「三四节」→ 3）,
      "end_section": 整数或 null,
      "location": "地点或 null",
      "target": "reschedule/cancel 要操作的已有课程名或日程标题，create 为 null",
      "from_weekday": 1-7 或 null（reschedule 的原星期，用于一门课有多个时段时定位）,
      "from_start_section": 整数或 null（reschedule 的原起始节）,
      "confidence": 0.0-1.0
    }}
  ]
}}

规则:
1. 「周X/星期X」指本周（周一为一周起点）；若那天的那个时间已经过去则指下周。「下周X」明确指下周。
2. 用户没说结束时间时按类型推断：会议/评审/聚餐/团建 2 小时，上课/讲座 1.5 小时，其余 1 小时；DDL（作业/提交截止）只填 date。
3. 「下午」=13:00 后，「晚上」=18:00 后，「三点半」=15:30，「中午」=12:00 前后。
4. 节次表达（「三四节」）填 start_section/end_section，time 留 null；时刻表达填 time，section 留 null。
5. 地点里的中文数字编号转成阿拉伯数字：「学院五百一十五」→「学院515」，「N幺零七」→「N107」。
6. 类型判断：考试/测验 → exam；作业/报告/材料「提交/交」 → ddl；每周/每周都 → recurring；其余一次性安排 → event。
7. 拿不准就降低 confidence，不要编造字段；与日程无关的话返回 {{"operations": []}}。
8. 一句话可能含多个操作，全部提取。"""


_HOLIDAY_PROMPT = """你是高校课表助手。用户会给一段调休通知（文字或截图），请提取其中的课程调整安排。

规则：
1. 「X月X日放假/停课」→ kind=off（当天不上课）。
2. 「X月X日（周几）补周N的课」「按周N课表上课」→ kind=makeup，weekday 填被补的那个星期的数字（1=周一…7=周日）；通知里写的星期是那天本身的星期，不要混淆。
3. 日期一律输出完整 YYYY-MM-DD；通知只写月日时按 {year} 年推断。
4. 提取不到任何调整时输出 {{"adjustments": []}}，不要编造。
5. note 填原文关键短语（≤30 字），如「国庆假期」「按周三课表上课」。

只输出 JSON：
{{
  "adjustments": [
    {{"date": "YYYY-MM-DD", "kind": "off" | "makeup", "weekday": 1-7 或 null, "note": "简短说明"}}
  ]
}}"""


_IMAGE_PROMPT = """这张图片可能是活动海报、班级通知或聊天截图。请提取其中提到的日程安排，输出与文字输入相同的 operations JSON。
规则：只提取图片中明确出现的时间与事项；没有时间信息的内容不要编造；地点中的编号保持阿拉伯数字。图片中若含姓名、学号等信息，忽略即可。
""" +  """

"""


def build_prompt(context: EventContext) -> str:
    if context.semester_start and context.week_no > 0:
        semester_line = (
            f"- 本学期开学日期: {context.semester_start}（第1周周一），本周是第 {context.week_no} 周"
        )
    else:
        semester_line = "- 当前不在学期周内（假期中），不要按周次理解日期"
    names = "、".join(context.course_names[:40]) if context.course_names else "（无）"
    places = "、".join(context.place_names[:40]) if context.place_names else "（无）"
    return _PROMPT_TEMPLATE.format(
        today=context.today,
        weekday_label=context.weekday_label,
        semester_line=semester_line,
        course_names=names,
        place_names_line=places,
    )


def _bounded_int(value: Any, low: int, high: int) -> int:
    if isinstance(value, bool):
        return 0
    if isinstance(value, (int, float)) and low <= int(value) <= high:
        return int(value)
    if isinstance(value, str) and value.strip().isdigit() and low <= int(value.strip()) <= high:
        return int(value.strip())
    return 0


def _text(value: Any, max_len: int) -> str:
    return value.strip()[:max_len] if isinstance(value, str) else ""


def _operation_from_llm(raw: Any) -> EventOperation | None:
    """校验并收敛单个操作；结构性不可用的返回 None（整条丢弃）。"""
    if not isinstance(raw, dict):
        return None
    action = raw.get("action")
    if action not in _ACTIONS:
        return None
    op_type = raw.get("type")
    if op_type not in _TYPES:
        op_type = "event"
    title = _text(raw.get("title"), 128)
    short_title = _text(raw.get("short_title"), 16)
    target = _text(raw.get("target"), 128)
    date = raw.get("date")
    date = date.strip() if isinstance(date, str) and _DATE_RE.match(date.strip()) else ""
    weekday = _bounded_int(raw.get("weekday"), 1, 7)
    start_time = raw.get("start_time")
    start_time = start_time.strip() if isinstance(start_time, str) and _TIME_RE.match(start_time.strip()) else ""
    end_time = raw.get("end_time")
    end_time = end_time.strip() if isinstance(end_time, str) and _TIME_RE.match(end_time.strip()) else ""
    start_section = _bounded_int(raw.get("start_section"), 1, 30)
    end_section = _bounded_int(raw.get("end_section"), 1, 30)
    if start_section and end_section and end_section < start_section:
        start_section, end_section = end_section, start_section
    try:
        confidence = float(raw.get("confidence", 0.5))
    except (TypeError, ValueError):
        confidence = 0.5
    confidence = max(0.0, min(1.0, confidence))

    if action == "create":
        if not title:
            return None
        if op_type == "recurring":
            if weekday == 0:
                return None
        elif not date:
            return None
    else:
        # reschedule/cancel 必须有可匹配的目标
        if not target and not title:
            return None
        if not target:
            target = title
            title = ""
    return EventOperation(
        action=action,
        type=op_type,
        title=title,
        short_title=short_title,
        date=date,
        weekday=weekday,
        start_time=start_time,
        end_time=end_time,
        start_section=start_section,
        end_section=end_section,
        location=_text(raw.get("location"), 255),
        target=target,
        from_weekday=_bounded_int(raw.get("from_weekday"), 1, 7),
        from_start_section=_bounded_int(raw.get("from_start_section"), 1, 30),
        confidence=confidence,
    )


def operations_from_llm_content(content: str) -> list[EventOperation]:
    """把模型回答解析成操作列表；逐条校验，坏条目丢弃，全坏才报错。"""
    text = content.strip()
    fence = re.search(r"```(?:json)?\s*(.*?)```", text, flags=re.S)
    if fence:
        text = fence.group(1).strip()
    start, end = text.find("{"), text.rfind("}")
    if start == -1 or end <= start:
        raise EventParseError(502, 50242, "日程理解服务返回异常，请稍后重试")
    try:
        data = json.loads(text[start : end + 1])
    except json.JSONDecodeError as exc:
        raise EventParseError(502, 50242, "日程理解服务返回异常，请稍后重试") from exc
    raw_ops = data.get("operations") if isinstance(data, dict) else None
    if not isinstance(raw_ops, list):
        raise EventParseError(502, 50242, "日程理解服务返回异常，请稍后重试")
    operations = [op for op in (_operation_from_llm(item) for item in raw_ops) if op is not None]
    if not operations:
        # 模型合法地给出空列表 = 没听懂这句话与日程有关，用 422 引导用户重述
        raise EventParseError(422, 42250, "没有听懂日程安排，可以换个说法再试试")
    return operations


_CHAT_PROMPT_TEMPLATE = """你是「墨程」App（大学生课程表应用）的内置 AI 助手，用简洁友好的中文与用户对话。

当前上下文:
- 今天是 {today}（{weekday_label}）
{semester_line}
- 本学期已有课程: {course_names}

常用地点词表（涉及地点时优先匹配这些名称）: {place_names_line}

用户今天（{today}）的课程与日程:
{agenda}

你可以做的事:
1. 闲聊与答疑：学习规划、校园生活、今天/本周的安排（依据上面的今日课程与日程回答）等；
2. 日程操作：当用户想新增/调整/取消日程或课程安排时，在 operations 里给出结构化操作，客户端会自动执行落库。

只输出 JSON:
{{
  "reply": "给用户看的回复（中文，简洁自然，≤300 字）",
  "operations": [
    {{
      "action": "create" | "reschedule" | "cancel",
      "type": "event" | "ddl" | "exam" | "recurring",
      "title": "事件标题（create 必填，简明如「班级团建」）",
      "short_title": "课表小格子上的简写（create 必填，2-6 字）",
      "date": "YYYY-MM-DD 或 null（event/ddl/exam 一次性日程填）",
      "weekday": 1-7 或 null（recurring 周期日程填，1=周一）,
      "start_time": "HH:MM 或 null",
      "end_time": "HH:MM 或 null",
      "start_section": 整数或 null（用户用节次表达时填）,
      "end_section": 整数或 null,
      "location": "地点或 null",
      "target": "reschedule/cancel 要操作的已有课程名或日程标题，create 为 null",
      "from_weekday": 1-7 或 null,
      "from_start_section": 整数或 null,
      "confidence": 0.0-1.0
    }}
  ]
}}

规则:
1. 没有日程操作意图（闲聊、查询、建议）时 operations 输出 []，只在 reply 里回答；
2. 有操作时 reply 用一句话说明将要执行什么，如「好的，已为你创建明天下午三点半的评审安排」；
3. 「周X/星期X」指本周（周一为一周起点），若那天的那个时间已过则指下周；「下周X」明确指下周；
4. 用户没说结束时间时按类型推断：会议/评审/聚餐/团建 2 小时，上课/讲座 1.5 小时，其余 1 小时；DDL（作业/提交截止）只填 date；
5. 节次表达（「三四节」）填 start_section/end_section，time 留 null；时刻表达填 time，section 留 null；
6. 类型判断：考试/测验 → exam；作业/报告/材料「提交/交」 → ddl；每周/每周都 → recurring；其余一次性安排 → event；
7. 拿不准就降低 confidence，不要编造字段；不要输出 JSON 以外的任何内容。"""


def build_chat_prompt(context: EventContext, agenda: str) -> str:
    """对话用 system prompt：上下文 + 今日课程与日程摘要。"""
    if context.semester_start and context.week_no > 0:
        semester_line = (
            f"- 本学期开学日期: {context.semester_start}（第1周周一），本周是第 {context.week_no} 周"
        )
    else:
        semester_line = "- 当前不在学期周内（假期中），不要按周次理解日期"
    names = "、".join(context.course_names[:40]) if context.course_names else "（无）"
    places = "、".join(context.place_names[:40]) if context.place_names else "（无）"
    return _CHAT_PROMPT_TEMPLATE.format(
        today=context.today,
        weekday_label=context.weekday_label,
        semester_line=semester_line,
        course_names=names,
        place_names_line=places,
        agenda=agenda or "（今天没有课程或日程）",
    )


def chat_result_from_llm_content(content: str) -> tuple[str, list[EventOperation]]:
    """解析对话模型的回答：reply 必填，operations 允许为空数组（无日程意图）。"""
    text = content.strip()
    fence = re.search(r"```(?:json)?\s*(.*?)```", text, flags=re.S)
    if fence:
        text = fence.group(1).strip()
    start, end = text.find("{"), text.rfind("}")
    if start == -1 or end <= start:
        raise EventParseError(502, 50243, "AI 助手服务返回异常，请稍后重试")
    try:
        data = json.loads(text[start : end + 1])
    except json.JSONDecodeError as exc:
        raise EventParseError(502, 50243, "AI 助手服务返回异常，请稍后重试") from exc
    if not isinstance(data, dict):
        raise EventParseError(502, 50243, "AI 助手服务返回异常，请稍后重试")
    reply = data.get("reply")
    reply = reply.strip()[:1000] if isinstance(reply, str) else ""
    if not reply:
        raise EventParseError(502, 50243, "AI 助手服务返回异常，请稍后重试")
    raw_ops = data.get("operations")
    operations: list[EventOperation] = []
    if isinstance(raw_ops, list):
        operations = [
            op for op in (_operation_from_llm(item) for item in raw_ops) if op is not None
        ]
    return reply, operations


# ---------------------------------------------------------------------------
# 「墨程」AI 目标规划（POST /api/schedule-ai/goal-plan）
# ---------------------------------------------------------------------------

# 每日任务只排「今天起 14 天内」（含今天，共 14 天）。
GOAL_TASK_DAYS = 14

_GOAL_PLAN_PROMPT_TEMPLATE = """你是「墨程」App（大学生课程表应用）的目标规划师。用户给你一个学习目标，你把它拆解成可执行的规划。

当前上下文:
- 今天是 {today}（{weekday_label}）
{semester_line}
- 本学期已有课程: {course_names}

用户今天的课程与日程:
{agenda}

用户本周课表占用的时段（未占用的时间是可安排的空档）:
{week_schedule}

用户输入:
- 目标: {title}
- 现状/学习资料: {detail_line}
- 目标达成日期: {target_date_line}
- 每天可投入: {daily_minutes} 分钟

拆解方法:
1. 把目标按内容/能力拆成 3-6 个阶段里程碑，每个有明确完成日期，按日期从近到远递进{milestone_horizon_line}；
2. 只排今天（{today}）起 14 天内、即 {today} 至 {last_day} 的每日任务：每天 1-2 个学习块，总时长约 {daily_minutes} 分钟，必须避开上面列出的课程与日程时段，优先用无课日的整块时间；
3. 每个任务具体可执行（如「高等数学 第3章习题 20 道」，不要「学数学」这种空话）。

只输出 JSON:
{{
  "reply": "给用户的规划说明（中文，简洁自然，≤200 字，讲清阶段划分与每日安排逻辑）",
  "milestones": [
    {{"title": "里程碑标题（≤30 字）", "date": "YYYY-MM-DD", "note": "完成标志（≤60 字）"}}
  ],
  "tasks": [
    {{
      "action": "create",
      "type": "ddl",
      "title": "任务标题（≤30 字，含具体内容）",
      "short_title": "课表格子简写（2-6 字）",
      "date": "YYYY-MM-DD（必须在 {today} 至 {last_day} 之间）",
      "start_time": "HH:MM（避开课程的空档）",
      "end_time": "HH:MM",
      "location": "地点或 null",
      "confidence": 0.0-1.0
    }}
  ]
}}

规则:
1. tasks 的 date 一律落在 {today} ~ {last_day}（含）之间，超出的不要输出；action 一律 "create"，type 主用 "ddl"；
2. tasks 的 start_time/end_time 不得与上面列出的课程和日程时段冲突；
3. 每天任务总时长 ≈ {daily_minutes} 分钟，可 1 块也可拆 2 块；
4. milestones 按日期升序，3-6 个；{milestone_rule}
5. 目标描述含糊时在 reply 里说明你做的假设，不要追问；
6. 不要输出 JSON 以外的任何内容。"""


def build_goal_plan_prompt(
    context: EventContext,
    agenda: str,
    week_schedule: str,
    *,
    title: str,
    detail: str,
    target_date: str | None,
    daily_minutes: int,
) -> str:
    """目标规划 system prompt：上下文 + 今日摘要 + 本周课表占用 + 用户目标。"""
    if context.semester_start and context.week_no > 0:
        semester_line = (
            f"- 本学期开学日期: {context.semester_start}（第1周周一），本周是第 {context.week_no} 周"
        )
    else:
        semester_line = "- 当前不在学期周内（假期中），不要按周次理解日期"
    names = "、".join(context.course_names[:40]) if context.course_names else "（无）"
    today = _date.fromisoformat(context.today)
    last_day = today + _timedelta(days=GOAL_TASK_DAYS - 1)
    if target_date:
        target_date_line = target_date
        milestone_horizon_line = f"，最后一个不超过目标达成日期 {target_date}"
        milestone_rule = f"最后一个里程碑的日期不要超过目标达成日期 {target_date}"
    else:
        # 无目标日期兜底：按 4 周节奏自行安排
        fallback = (today + _timedelta(days=28)).isoformat()
        target_date_line = "（未指定，由你按合理节奏安排）"
        milestone_horizon_line = ""
        milestone_rule = f"用户没给目标日期，按约 4 周的节奏安排，最后一个里程碑日期不超过 {fallback}"
    return _GOAL_PLAN_PROMPT_TEMPLATE.format(
        today=context.today,
        weekday_label=context.weekday_label,
        semester_line=semester_line,
        course_names=names,
        agenda=agenda or "（今天没有课程或日程）",
        week_schedule=week_schedule or "（本周没有课程，全天可自由安排）",
        title=title,
        detail_line=detail or "（未提供）",
        target_date_line=target_date_line,
        daily_minutes=daily_minutes,
        last_day=last_day.isoformat(),
        milestone_horizon_line=milestone_horizon_line,
        milestone_rule=milestone_rule,
    )


def _milestone_from_llm(raw: Any) -> GoalMilestone | None:
    """校验单个里程碑：标题与合法日期必填，坏条目丢弃。"""
    if not isinstance(raw, dict):
        return None
    title = _text(raw.get("title"), 60)
    date_value = raw.get("date")
    date_text = date_value.strip() if isinstance(date_value, str) else ""
    if not title or not _DATE_RE.match(date_text):
        return None
    try:
        _date.fromisoformat(date_text)
    except ValueError:
        return None
    return GoalMilestone(title=title, date=date_text, note=_text(raw.get("note"), 120))


def goal_plan_result_from_llm_content(
    content: str, today: str
) -> tuple[str, list[GoalMilestone], list[EventOperation]]:
    """解析目标规划模型的回答。

    reply 必填；milestones 逐条校验；tasks 复用 EventOperation 校验，且只保留
    action=create、date 落在 [today, today+GOAL_TASK_DAYS-1] 窗口内的条目——
    窗口外/非 create 的一律丢弃（客户端按原样落库，服务端必须兜住契约）。
    """
    text = content.strip()
    fence = re.search(r"```(?:json)?\s*(.*?)```", text, flags=re.S)
    if fence:
        text = fence.group(1).strip()
    start, end = text.find("{"), text.rfind("}")
    if start == -1 or end <= start:
        raise EventParseError(502, 50244, "目标规划服务返回异常，请稍后重试")
    try:
        data = json.loads(text[start : end + 1])
    except json.JSONDecodeError as exc:
        raise EventParseError(502, 50244, "目标规划服务返回异常，请稍后重试") from exc
    if not isinstance(data, dict):
        raise EventParseError(502, 50244, "目标规划服务返回异常，请稍后重试")
    reply = data.get("reply")
    reply = reply.strip()[:1000] if isinstance(reply, str) else ""
    if not reply:
        raise EventParseError(502, 50244, "目标规划服务返回异常，请稍后重试")

    raw_milestones = data.get("milestones")
    milestones: list[GoalMilestone] = []
    if isinstance(raw_milestones, list):
        milestones = [
            item
            for item in (_milestone_from_llm(raw) for raw in raw_milestones[:12])
            if item is not None
        ]
        milestones.sort(key=lambda m: m.date)

    first_day = _date.fromisoformat(today)
    last_day = first_day + _timedelta(days=GOAL_TASK_DAYS - 1)
    raw_tasks = data.get("tasks")
    tasks: list[EventOperation] = []
    if isinstance(raw_tasks, list):
        for raw in raw_tasks[:40]:
            op = _operation_from_llm(raw)
            if op is None or op.action != "create" or not op.date:
                continue
            try:
                op_day = _date.fromisoformat(op.date)
            except ValueError:
                continue
            if not (first_day <= op_day <= last_day):
                continue
            tasks.append(op)
    return reply, milestones, tasks


class MimoEventGateway:
    """MiMo 日程理解网关。两个行为是承重墙（均经线上 API 实测）：

    - ASR 走 chat/completions 的 input_audio 内容块，**不带** response_format
      （转写结果是纯文本，JSON mode 会破坏它）；
    - 理解请求固定 ``thinking: disabled`` + ``response_format: json_object``，
      与课表解析同理，延迟从分钟级降到秒级。
    """

    def __init__(
        self,
        *,
        base_url: str,
        api_key: str,
        model: str,
        asr_model: str,
        timeout_seconds: int,
    ):
        self._base_url = base_url.rstrip("/")
        self._api_key = api_key
        self._model = model
        self._asr_model = asr_model
        self._timeout_seconds = timeout_seconds

    async def parse(
        self,
        *,
        text: str | None,
        audio_b64: str | None,
        image_b64: str | None = None,
        context: EventContext,
    ) -> EventParseResult:
        transcript: str | None = None
        asr_ms: int | None = None
        if image_b64 is not None:
            return await self._parse_image(image_b64, context)
        if audio_b64 is not None:
            started = time.monotonic()
            transcript = await self._transcribe(
                audio_b64, hint=self._asr_hint(context)
            )
            asr_ms = int((time.monotonic() - started) * 1000)
        source_text = (text if text is not None else transcript) or ""
        # 纵深防御：端点边界已脱敏一次，网关入口再脱一次——任何调用路径
        # 都不会把原始身份值送进大模型。
        source_text = strip_identity_info(source_text.strip())
        if not source_text:
            raise EventParseError(422, 42251, "没有听到内容，请再说一遍")
        started = time.monotonic()
        content = await self._chat(
            [
                {"role": "system", "content": build_prompt(context)},
                {"role": "user", "content": source_text},
            ],
            json_mode=True,
        )
        llm_ms = int((time.monotonic() - started) * 1000)
        operations = operations_from_llm_content(content)
        logger.info(
            "event-parse ok: input=%s ops=%d asr_ms=%s llm_ms=%d",
            "voice" if audio_b64 is not None else "text",
            len(operations),
            asr_ms,
            llm_ms,
        )
        return EventParseResult(
            operations=operations, transcript=transcript, asr_ms=asr_ms, llm_ms=llm_ms
        )

    async def parse_holiday(
        self, *, text: str | None, image_b64: str | None, year: int
    ) -> list[dict[str, Any]]:
        """调休通知（文字/截图）→ 调整列表 [{date, kind, weekday, note}]。"""
        system = _HOLIDAY_PROMPT.replace("{year}", str(year))
        if image_b64 is not None:
            if len(image_b64) > MAX_IMAGE_BASE64_CHARS:
                raise EventParseError(413, 41341, "图片太大了，请压缩后再试")
            messages = [{
                "role": "user",
                "content": [
                    {"type": "text", "text": system},
                    {"type": "image_url", "image_url": {"url": f"data:image/jpeg;base64,{image_b64}"}},
                ],
            }]
        else:
            messages = [
                {"role": "system", "content": system},
                {"role": "user", "content": strip_identity_info((text or "").strip())},
            ]
        content = await self._chat(messages, json_mode=True)
        try:
            data = json.loads(content)
        except (json.JSONDecodeError, TypeError):
            data = {}
        raw_items = data.get("adjustments") if isinstance(data, dict) else None
        if not isinstance(raw_items, list):
            raise EventParseError(422, 42253, "没有识别到调休安排，换张更清晰的截图或换种说法")
        result: list[dict[str, Any]] = []
        for raw in raw_items[:60]:
            if not isinstance(raw, dict):
                continue
            date = raw.get("date")
            if not isinstance(date, str) or not _DATE_RE.match(date.strip()):
                continue
            kind = raw.get("kind")
            if kind not in ("off", "makeup"):
                continue
            weekday = _bounded_int(raw.get("weekday"), 1, 7)
            if kind == "makeup" and weekday == 0:
                continue
            result.append({
                "date": date.strip(),
                "kind": kind,
                "weekday": weekday,
                "note": _text(raw.get("note"), 30),
            })
        return result

    async def chat(
        self,
        *,
        message: str,
        image_b64: str | None,
        history: list[dict[str, str]],
        context: EventContext,
        agenda: str,
    ) -> ChatResult:
        """AI 助手对话：文字（可带图）+ 历史 → 回复 + 结构化日程操作。

        与 parse 同一条 _chat 通道（mimo-v2.6-flash、JSON mode、关闭思考）；
        图片走与 _parse_image 相同的 image_url 内容块视觉路径。对话内容
        （含历史）在入口再过一遍 strip_identity_info，不落库、不写内容日志。
        """
        text = strip_identity_info(message.strip())
        if image_b64 is not None:
            if len(image_b64) > MAX_CHAT_IMAGE_BASE64_CHARS:
                raise EventParseError(413, 41342, "图片太大了，请压缩到 2MB 以内再试")
            try:
                base64.b64decode(image_b64, validate=True)
            except (binascii.Error, ValueError):
                raise EventParseError(400, 40042, "图片数据格式异常") from None
            if not text:
                text = "请看这张图片。"
        if not text:
            raise EventParseError(422, 42254, "说点什么吧")
        messages: list[dict[str, Any]] = [
            {"role": "system", "content": build_chat_prompt(context, agenda)}
        ]
        for turn in history[-10:]:
            if not isinstance(turn, dict):
                continue
            role = turn.get("role")
            if role not in ("user", "assistant"):
                continue
            turn_text = strip_identity_info(str(turn.get("content") or "").strip())[:2000]
            if not turn_text:
                continue
            messages.append({"role": role, "content": turn_text})
        if image_b64 is not None:
            messages.append({
                "role": "user",
                "content": [
                    {"type": "text", "text": text},
                    {
                        "type": "image_url",
                        "image_url": {"url": f"data:image/jpeg;base64,{image_b64}"},
                    },
                ],
            })
        else:
            messages.append({"role": "user", "content": text})
        started = time.monotonic()
        content = await self._chat(messages, json_mode=True)
        llm_ms = int((time.monotonic() - started) * 1000)
        reply, operations = chat_result_from_llm_content(content)
        logger.info(
            "schedule-chat ok: image=%s ops=%d llm_ms=%d",
            image_b64 is not None,
            len(operations),
            llm_ms,
        )
        return ChatResult(reply=reply, operations=operations, llm_ms=llm_ms)

    async def goal_plan(
        self,
        *,
        title: str,
        detail: str,
        target_date: str | None,
        daily_minutes: int,
        image_b64: str | None,
        context: EventContext,
        agenda: str,
        week_schedule: str,
    ) -> GoalPlanResult:
        """目标规划：目标 → 阶段里程碑 + 未来 14 天每日任务。

        与 chat 同一条 _chat 通道（mimo-v2.6-flash、JSON mode、关闭思考）；
        system prompt 由 build_goal_plan_prompt 组装（今日摘要 + 本周课表占用），
        用户消息只带目标正文；图片走与 chat 相同的 image_url 多模态路径。
        入口文本再过一遍 strip_identity_info，不落库、不写内容日志。
        """
        text = strip_identity_info(title.strip())[:200]
        if not text:
            raise EventParseError(422, 42255, "先写个目标吧")
        system = build_goal_plan_prompt(
            context,
            agenda,
            week_schedule,
            title=text,
            detail=strip_identity_info(detail.strip())[:4000],
            target_date=target_date,
            daily_minutes=daily_minutes,
        )
        if image_b64 is not None:
            if len(image_b64) > MAX_CHAT_IMAGE_BASE64_CHARS:
                raise EventParseError(413, 41342, "图片太大了，请压缩到 2MB 以内再试")
            try:
                base64.b64decode(image_b64, validate=True)
            except (binascii.Error, ValueError):
                raise EventParseError(400, 40042, "图片数据格式异常") from None
        messages: list[dict[str, Any]] = [{"role": "system", "content": system}]
        if image_b64 is not None:
            messages.append({
                "role": "user",
                "content": [
                    {"type": "text", "text": "请为我的目标制定规划。"},
                    {
                        "type": "image_url",
                        "image_url": {"url": f"data:image/jpeg;base64,{image_b64}"},
                    },
                ],
            })
        else:
            messages.append({"role": "user", "content": "请为我的目标制定规划。"})
        started = time.monotonic()
        content = await self._chat(messages, json_mode=True)
        llm_ms = int((time.monotonic() - started) * 1000)
        reply, milestones, tasks = goal_plan_result_from_llm_content(content, context.today)
        logger.info(
            "goal-plan ok: image=%s milestones=%d tasks=%d llm_ms=%d",
            image_b64 is not None,
            len(milestones),
            len(tasks),
            llm_ms,
        )
        return GoalPlanResult(reply=reply, milestones=milestones, tasks=tasks, llm_ms=llm_ms)

    async def _parse_image(
        self, image_b64: str, context: EventContext
    ) -> EventParseResult:
        """视觉路径：图片直接走多模态模型，一次调用出结构化操作。"""
        if len(image_b64) > MAX_IMAGE_BASE64_CHARS:
            raise EventParseError(413, 41341, "图片太大了，请压缩到 4MB 以内再试")
        try:
            base64.b64decode(image_b64, validate=True)
        except (binascii.Error, ValueError):
            raise EventParseError(400, 40041, "图片数据格式异常") from None
        started = time.monotonic()
        content = await self._chat(
            [
                {"role": "system", "content": build_prompt(context) + "\n\n" + _IMAGE_PROMPT},
                {
                    "role": "user",
                    "content": [
                        {"type": "text", "text": "提取这张图片中的日程安排。"},
                        {
                            "type": "image_url",
                            "image_url": {
                                "url": f"data:image/jpeg;base64,{image_b64}"
                            },
                        },
                    ],
                },
            ],
            json_mode=True,
        )
        llm_ms = int((time.monotonic() - started) * 1000)
        operations = operations_from_llm_content(content)
        logger.info("event-parse ok: input=image ops=%d llm_ms=%d", len(operations), llm_ms)
        return EventParseResult(
            operations=operations, transcript=None, asr_ms=None, llm_ms=llm_ms
        )

    async def transcribe_partial(self, audio_b64: str, hint: str = "") -> str:
        """分段转写（录音中实时上屏）：复用同一 ASR 通道，不建任何记录。

        hint 形参保留只为调用方与协议稳定，**不再发给模型**——原因见 _transcribe
        的说明（上游自 2026-09-22 起拒绝 ASR 请求携带 text 块）。
        另：缺了这个形参会让调用方传 hint= 时抛 TypeError、不传时读未定义名抛
        NameError，两条路都是 500——协议里一直声明着它，实现别再漏。
        """
        if len(audio_b64) > MAX_AUDIO_BASE64_CHARS:
            raise EventParseError(413, 41340, "录音太长了")
        try:
            raw = base64.b64decode(audio_b64, validate=True)
        except (binascii.Error, ValueError):
            raise EventParseError(400, 40040, "音频数据格式异常") from None
        if len(raw) < 3200:
            # 太短的分段（<0.1s 16kHz PCM）没有可识别内容，静默返回空
            return ""
        content: list[dict[str, Any]] = [
            {
                "type": "input_audio",
                "input_audio": {"data": base64.b64encode(raw).decode("ascii"), "format": "wav"},
            }
        ]
        result = await self._chat(
            [{"role": "user", "content": content}],
            json_mode=False,
            model=self._asr_model,
        )
        return result.strip()

    def _asr_hint(self, context: EventContext) -> str:
        """给 ASR 的偏置提示：常用地点词表。

        ⚠️ 2026-09-22 起该提示**发不出去**：MiMo 的 ASR 端点拒绝任何 text 内容块
        （400「ASR request must not include text parts; text prompt is injected
        by the gateway」）。实测独立 system 消息与顶层 prompt / asr_prompt /
        instructions 字段虽返回 200，但一律不被采纳（连「翻译成英文」这种会
        明显改变输出的指令都无效），说明 ASR 已是不接受调用方提示的纯转写服务。
        地名同音纠错因此由理解阶段承担：_PROMPT_TEMPLATE 里带着同一份地点词表
        并明确要求纠正同音字（例：「文津楼」不要写成「文经楼」）。
        本函数与调用点保留，若上游恢复提示能力，只需在 _transcribe /
        transcribe_partial 里把 hint 作为 text 块加回去。
        """
        if not context.place_names:
            return ""
        return "本次录音涉及的地名（请按这些名称转写）：" + "、".join(
            context.place_names[:30]
        )

    async def _transcribe(self, audio_b64: str, hint: str = "") -> str:
        """整段录音转写。

        hint 形参保留但不发送：MiMo 的 ASR 端点自 2026-09-22 起拒绝请求携带
        text 内容块（400），且不采纳 system 消息或顶层 prompt 字段里的提示。
        详见 _asr_hint 的说明。此前把 hint 当 text 块附加，会让**每一条**语音
        路径都 400→502（hint 由 _place_names 生成，含静态楼名表，恒非空）。
        """
        if len(audio_b64) > MAX_AUDIO_BASE64_CHARS:
            raise EventParseError(413, 41340, "录音太长了，一句话日程尽量控制在 60 秒内")
        try:
            # 先解码一次再编码：拒绝非 base64 填充内容直接进请求体
            raw = base64.b64decode(audio_b64, validate=True)
        except (binascii.Error, ValueError):
            raise EventParseError(400, 40040, "音频数据格式异常") from None
        if len(raw) < 1000:
            raise EventParseError(422, 42252, "录音太短了，按住按钮把话说完再松手")
        content: list[dict[str, Any]] = [
            {
                "type": "input_audio",
                "input_audio": {"data": base64.b64encode(raw).decode("ascii"), "format": "wav"},
            }
        ]
        result = await self._chat(
            [{"role": "user", "content": content}],
            json_mode=False,
            model=self._asr_model,
        )
        logger.info("event-asr ok: bytes=%d chars=%d", len(raw), len(result))
        return result.strip()

    async def _chat(
        self,
        messages: list[dict[str, Any]],
        *,
        json_mode: bool,
        model: str | None = None,
    ) -> str:
        url = f"{self._base_url}/chat/completions"
        body: dict[str, Any] = {
            "model": model or self._model,
            "messages": messages,
            "max_tokens": 2048,
        }
        if json_mode:
            body["response_format"] = {"type": "json_object"}
            body["thinking"] = {"type": "disabled"}
        timeout = aiohttp.ClientTimeout(total=self._timeout_seconds)
        retryable_statuses = {408, 425, 429, 500, 502, 503, 504}
        retry_delays = (0.4, 1.2)
        try:
            # 与课表解析网关同理：单请求独立会话，不同用户之间无锁并发。
            async with aiohttp.ClientSession(timeout=timeout) as session:
                payload = None
                for attempt in range(len(retry_delays) + 1):
                    try:
                        async with session.post(
                            url,
                            json=body,
                            headers={"Authorization": f"Bearer {self._api_key}"},
                        ) as response:
                            if response.status == 200:
                                payload = await response.json()
                                break
                            error_body = (await response.text())[:300]
                            should_retry = (
                                response.status in retryable_statuses
                                and attempt < len(retry_delays)
                            )
                            logger.warning(
                                "event-parse upstream error: status=%d attempt=%d/%d retry=%s body=%s",
                                response.status,
                                attempt + 1,
                                len(retry_delays) + 1,
                                should_retry,
                                error_body,
                            )
                            if not should_retry:
                                raise EventParseError(
                                    502, 50242, "日程理解服务暂时不可用，请稍后重试"
                                )
                    except aiohttp.ClientError as exc:
                        if attempt >= len(retry_delays):
                            raise
                        logger.warning(
                            "event-parse transient connection error: %s attempt=%d/%d",
                            type(exc).__name__,
                            attempt + 1,
                            len(retry_delays) + 1,
                        )
                    await asyncio.sleep(retry_delays[attempt])
                if payload is None:
                    raise EventParseError(502, 50242, "日程理解服务暂时不可用，请稍后重试")
        except EventParseError:
            raise
        except (asyncio.TimeoutError, aiohttp.ServerTimeoutError):
            logger.warning("event-parse upstream timeout after %ss", self._timeout_seconds)
            raise EventParseError(504, 50441, "日程理解服务响应超时，请稍后重试") from None
        except (aiohttp.ClientError, json.JSONDecodeError) as exc:
            logger.warning("event-parse upstream call failed: %s: %s", type(exc).__name__, exc)
            raise EventParseError(502, 50242, "日程理解服务暂时不可用，请稍后重试") from None

        try:
            content = payload["choices"][0]["message"]["content"]
        except (KeyError, IndexError, TypeError):
            logger.warning(
                "event-parse upstream malformed payload keys: %s",
                list(payload) if isinstance(payload, dict) else type(payload).__name__,
            )
            raise EventParseError(502, 50242, "日程理解服务暂时不可用，请稍后重试") from None
        if not isinstance(content, str) or not content.strip():
            logger.warning("event-parse empty content")
            raise EventParseError(502, 50242, "日程理解服务暂时不可用，请稍后重试")
        return content
