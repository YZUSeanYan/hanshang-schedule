"""AI 日程理解端点（AI 日程 2.0）。

``POST /api/schedule-ai/parse``：文字或语音 → 结构化日程操作列表。
文字与图片理解走 llm_import_model（mimo-v2.6-flash）；语音走
mimo-v2.5-asr 转写后复用同一条理解管线（转写模型不随文本模型升级，
原因见 config.llm_import_asr_model 的注释）；转写文本随响应返回
（客户端预览页展示「听到的是」让用户纠错），服务端不保存。
"""
import asyncio
import time
from datetime import date, datetime, timedelta, timezone

from fastapi import APIRouter, Depends, HTTPException, Request
from sqlalchemy import and_, or_, select
from sqlalchemy.orm import Session

from app.api.deps import get_current_user
from app.api.v1.endpoints.push import _week_is_active
from app.core.config import get_settings
from app.core.ratelimit import RateLimiter
from app.db.session import get_db
from app.models.personal_event import SyncEvent
from app.models.sync_data import SyncCourse, SyncSchedule, SyncSemester
from app.models.user import User
from app.schemas.schedule_ai import (
    HolidayParseIn,
    ScheduleAiChatIn,
    ScheduleAiGoalPlanIn,
    ScheduleAiParseIn,
    ScheduleAiTranscribeIn,
)
from app.services.llm_event_parse import (
    EventContext,
    EventParseError,
    EventParseGateway,
    MimoEventGateway,
    UnavailableEventGateway,
    strip_identity_info,
)

router = APIRouter(prefix="/schedule-ai", tags=["AI 日程"])

# 日程录入是高频动作（随手记），额度比课表导入宽：每用户每天 30 次。
# 校园网/运营商 NAT 共享出口常见，IP 上限不能成为整栋楼的全局限额。
_user_daily_limiter = RateLimiter(30, 24 * 60 * 60)
_ip_daily_limiter = RateLimiter(300, 24 * 60 * 60)
_settings = get_settings()
_gateway: EventParseGateway = (
    MimoEventGateway(
        base_url=_settings.llm_import_base_url,
        api_key=_settings.llm_import_api_key,
        model=_settings.llm_import_model,
        asr_model=_settings.llm_import_asr_model,
        timeout_seconds=_settings.llm_import_timeout_seconds,
    )
    if _settings.llm_import_enabled and _settings.llm_import_api_key
    else UnavailableEventGateway()
)

# 分段转写（实时上屏）单独限流：一次录音最多约 25 段；
# 按 150 次/天/用户（≈6 次完整录音），正常用量不会中途断流
_transcribe_daily_limiter = RateLimiter(150, 24 * 60 * 60)


_WEEKDAY_LABELS = "一二三四五六日"

# 扬大常见楼宇/场馆（语音识别偏置词表兜底；用户自己的课表数据优先）
_YZU_PLACES = (
    "文津楼", "文汇楼", "文经楼", "昭文馆", "敬文馆", "鸿远楼", "逸夫馆",
    "力行楼", "敏行楼", "笃行楼", "知行楼", "半塘书院", "体育馆", "田径场",
    "大学生活动中心", "学生活动中心", "图书馆", "教学楼", "实验楼",
)

import re as _re
_BUILDING_RE = _re.compile(r"([一-鿿]{1,6}?(?:楼|馆|中心|书院|体育馆|操场|球场))")


def _place_names(db: Session, user_id: int, limit: int = 40) -> tuple[str, ...]:
    """地点词表：优先用户自己课表里出现过的楼名，再补扬大常见楼宇。"""
    found: list[str] = []
    seen: set[str] = set()
    try:
        rows = db.scalars(
            select(SyncSchedule.location)
            .where(SyncSchedule.user_id == user_id, SyncSchedule.deleted.is_(False))
            .limit(400)
        ).all()
        for raw in rows:
            for match in _BUILDING_RE.findall(raw or ""):
                name = match.strip()
                if name and name not in seen:
                    seen.add(name)
                    found.append(name)
    except Exception:
        pass
    for name in _YZU_PLACES:
        if name not in seen:
            seen.add(name)
            found.append(name)
    return tuple(found[:limit])

# 产品只面向国内用户：固定 UTC+8，不依赖 IANA tzdata（Windows 没有时区库）。
_SHANGHAI = timezone(timedelta(hours=8))


def _rate_limit(request: Request, user: User) -> None:
    client_ip = request.client.host if request.client else "unknown"
    if not _user_daily_limiter.allow(f"schedule-ai:user:{user.id}"):
        raise HTTPException(status_code=429, detail={"code": 42950, "message": "今日 AI 日程次数已达上限"})
    if not _ip_daily_limiter.allow(f"schedule-ai:ip:{client_ip}"):
        raise HTTPException(status_code=429, detail={"code": 42951, "message": "当前网络的 AI 日程请求过于频繁"})


def _build_context(db: Session, user_id: int) -> EventContext:
    """从同步表取当前学期与课程名，给模型理解「周三/下周/那节课」的锚点。"""
    today = datetime.now(_SHANGHAI).date()
    weekday_label = f"星期{_WEEKDAY_LABELS[today.weekday()]}"
    semester = db.scalar(
        select(SyncSemester)
        .where(
            SyncSemester.user_id == user_id,
            SyncSemester.is_current.is_(True),
            SyncSemester.deleted.is_(False),
        )
        .order_by(SyncSemester.updated_at.desc())
        .limit(1)
    )
    semester_start = ""
    week_no = 0
    course_names: tuple[str, ...] = ()
    if semester is not None:
        try:
            start = date.fromisoformat(semester.start_date)
        except ValueError:
            start = None
        if start is not None:
            delta_weeks = (today - start).days // 7
            if 0 <= delta_weeks < semester.total_weeks:
                semester_start = semester.start_date
                week_no = delta_weeks + 1
        if semester_start:
            rows = db.scalars(
                select(SyncCourse.name)
                .where(
                    SyncCourse.user_id == user_id,
                    SyncCourse.semester_uuid == semester.uuid,
                    SyncCourse.deleted.is_(False),
                )
                .limit(40)
            ).all()
            course_names = tuple(dict.fromkeys(name.strip() for name in rows if name.strip()))
    return EventContext(
        today=today.isoformat(),
        weekday_label=weekday_label,
        semester_start=semester_start,
        week_no=week_no,
        course_names=course_names,
        place_names=_place_names(db, user_id),
    )


@router.post("/parse", response_model=None)
async def parse_schedule_intent(
    payload: ScheduleAiParseIn,
    request: Request,
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> dict:
    """Parse one spoken or typed utterance into structured schedule operations."""
    _rate_limit(request, user)
    started = time.monotonic()
    # 合规红线（同课表解析）：身份信息在服务端边界即抹除，不进理解流程、
    # 不送大模型、不写日志；网关入口会再脱一次。
    text = strip_identity_info(payload.text.strip()) or None
    audio = payload.audio_base64.strip() or None
    image = payload.image_base64.strip() or None
    context = _build_context(db, user.id)
    try:
        result = await asyncio.wait_for(
            _gateway.parse(text=text, audio_b64=audio, image_b64=image, context=context),
            timeout=_settings.llm_import_deadline_seconds,
        )
        return {
            "code": 0,
            "message": "ok",
            "data": {
                "transcript": result.transcript,
                "operations": [op.to_dict() for op in result.operations],
                "asr_ms": result.asr_ms,
                "llm_ms": result.llm_ms,
                "elapsed_ms": int((time.monotonic() - started) * 1000),
            },
        }
    except asyncio.TimeoutError:
        raise HTTPException(
            status_code=504,
            detail={"code": 50442, "message": "AI 日程理解超时，请稍后重试"},
        ) from None
    except EventParseError as exc:
        raise HTTPException(
            status_code=exc.status_code,
            detail={"code": exc.code, "message": exc.message},
        ) from None

@router.post("/transcribe", response_model=None)
async def transcribe_partial(
    data: ScheduleAiTranscribeIn,
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> dict:
    """录音进行中的分段转写（实时上屏）。

    音频经 base64 入 MiMo ASR 即转即弃：不落库、不记内容日志；只返回文本。
    """
    if not _transcribe_daily_limiter.allow(f"schedule-ai-asr:user:{user.id}"):
        raise HTTPException(
            status_code=429,
            detail={"code": 42952, "message": "语音转写过于频繁，请稍后再试"},
        )
    hint = ""
    places = _place_names(db, user.id)
    if places:
        hint = "本次录音涉及的地名（请按这些名称转写）：" + "、".join(places[:30])
    try:
        text = await asyncio.wait_for(
            _gateway.transcribe_partial(data.audio_base64, hint=hint),
            timeout=30,
        )
    except asyncio.TimeoutError:
        # 分段超时不是致命错：客户端静默跳过本段即可
        return {"code": 0, "message": "ok", "data": {"text": ""}}
    except EventParseError as exc:
        raise HTTPException(
            status_code=exc.status_code,
            detail={"code": exc.code, "message": exc.message},
        ) from None
    return {"code": 0, "message": "ok", "data": {"text": text}}


@router.post("/holiday-parse", response_model=None)
async def parse_holiday_notice(
    data: HolidayParseIn,
    user: User = Depends(get_current_user),
) -> dict:
    """调休通知（文字/截图）→ 放假与补课安排列表，客户端确认后保存。

    只做识别不做保存：图片/文字即转即弃，不落库、不记内容日志。
    """
    if not _user_daily_limiter.allow(f"schedule-ai:user:{user.id}"):
        raise HTTPException(status_code=429, detail={"code": 42950, "message": "今日 AI 日程次数已达上限"})
    year = datetime.now(_SHANGHAI).year
    try:
        adjustments = await asyncio.wait_for(
            _gateway.parse_holiday(
                text=data.text.strip() or None,
                image_b64=data.image_base64.strip() or None,
                year=year,
            ),
            timeout=_settings.llm_import_deadline_seconds,
        )
    except asyncio.TimeoutError:
        raise HTTPException(
            status_code=504,
            detail={"code": 50434, "message": "识别超时，请稍后重试"},
        ) from None
    except EventParseError as exc:
        raise HTTPException(
            status_code=exc.status_code,
            detail={"code": exc.code, "message": exc.message},
        ) from None
    return {"code": 0, "message": "ok", "data": {"adjustments": adjustments}}


# ---------------------------------------------------------------------------
# 「墨程」AI 助手对话（POST /api/schedule-ai/chat）
# ---------------------------------------------------------------------------

# 对话是高频交互，额度比单句解析（30 次/天）宽：每用户每天 60 次。
_chat_daily_limiter = RateLimiter(60, 24 * 60 * 60)

# 12 节次模板（与 push.py 课程提醒一致）：5-9 月夏令作息，其余月份冬令作息。
_SECTION_STARTS_SPRING = ("08:00", "08:55", "09:55", "10:50", "11:45", "14:30", "15:25", "16:20", "17:15", "18:10", "19:30", "20:25")
_SECTION_STARTS_AUTUMN = ("08:00", "08:55", "09:55", "10:50", "11:45", "14:00", "14:55", "15:50", "16:45", "17:40", "19:00", "19:55")
_SECTION_MINUTES = 45


def _section_span(day: date, start_section: int, end_section: int) -> tuple[str, str] | None:
    """节次区间 → 起止时刻（如 3-4 节 → 09:55-11:35）；越界返回 None。"""
    starts = _SECTION_STARTS_SPRING if 5 <= day.month <= 9 else _SECTION_STARTS_AUTUMN
    if not (1 <= start_section <= len(starts) and 1 <= end_section <= len(starts)):
        return None
    if end_section < start_section:
        start_section, end_section = end_section, start_section
    start_text = starts[start_section - 1]
    hour, minute = (int(v) for v in starts[end_section - 1].split(":"))
    end = datetime.combine(day, datetime.min.time()) + timedelta(
        hours=hour, minutes=minute + _SECTION_MINUTES
    )
    return start_text, f"{end.hour:02d}:{end.minute:02d}"


def _section_text(start_section: int, end_section: int) -> str:
    return (
        f"第{start_section}-{end_section}节"
        if end_section != start_section
        else f"第{start_section}节"
    )


def _event_time_text(day: date, event: SyncEvent) -> str:
    """日程的时间描述：时刻优先，其次节次换算，最后「全天」。"""
    if event.start_time:
        return f"{event.start_time}-{event.end_time}" if event.end_time else event.start_time
    if event.start_section:
        end_section = event.end_section or event.start_section
        section_text = _section_text(event.start_section, end_section)
        span = _section_span(day, event.start_section, end_section)
        if span is not None:
            return f"{section_text} {span[0]}-{span[1]}"
        return section_text
    return "全天"


def _build_today_agenda(db: Session, user_id: int) -> str:
    """当前用户今日（Asia/Shanghai）课程与日程摘要，注入对话 system prompt。

    数据来源：sync_semesters（当前学期定周次）→ sync_courses + sync_schedules
    （今日星期 + 周次过滤，节次换算成时刻）→ sync_events（今日一次性日程 +
    今日星期的周期日程）。
    """
    today = datetime.now(_SHANGHAI).date()
    weekday = today.isoweekday()
    lines: list[str] = []

    semester = db.scalar(
        select(SyncSemester)
        .where(
            SyncSemester.user_id == user_id,
            SyncSemester.is_current.is_(True),
            SyncSemester.deleted.is_(False),
        )
        .order_by(SyncSemester.updated_at.desc())
        .limit(1)
    )
    if semester is not None:
        try:
            start = date.fromisoformat(semester.start_date)
        except ValueError:
            start = None
        week_no = ((today - start).days // 7 + 1) if start is not None else 0
        if 1 <= week_no <= semester.total_weeks:
            courses = db.scalars(
                select(SyncCourse).where(
                    SyncCourse.user_id == user_id,
                    SyncCourse.semester_uuid == semester.uuid,
                    SyncCourse.deleted.is_(False),
                )
            ).all()
            courses_by_uuid = {course.uuid: course for course in courses}
            if courses_by_uuid:
                schedules = db.scalars(
                    select(SyncSchedule).where(
                        SyncSchedule.user_id == user_id,
                        SyncSchedule.course_uuid.in_(courses_by_uuid),
                        SyncSchedule.day_of_week == weekday,
                        SyncSchedule.deleted.is_(False),
                    )
                ).all()
                for schedule in sorted(
                    schedules, key=lambda s: (s.start_section, s.end_section)
                ):
                    if not _week_is_active(schedule.weeks_type, schedule.custom_weeks, week_no):
                        continue
                    course = courses_by_uuid.get(schedule.course_uuid)
                    if course is None:
                        continue
                    span = _section_span(today, schedule.start_section, schedule.end_section)
                    time_text = _section_text(schedule.start_section, schedule.end_section)
                    if span is not None:
                        time_text = f"{time_text} {span[0]}-{span[1]}"
                    parts = [f"课程 {course.name}", time_text]
                    if schedule.location:
                        parts.append(f"@ {schedule.location}")
                    if course.teacher:
                        parts.append(f"（{course.teacher}）")
                    lines.append(" ".join(parts))

    today_str = today.isoformat()
    events = db.scalars(
        select(SyncEvent)
        .where(
            SyncEvent.user_id == user_id,
            SyncEvent.deleted.is_(False),
            or_(
                SyncEvent.date == today_str,
                and_(SyncEvent.event_type == "recurring", SyncEvent.weekday == weekday),
            ),
        )
        .limit(40)
    ).all()

    def _event_sort_key(event: SyncEvent) -> str:
        return event.start_time or (f"{event.start_section:02d}:00" if event.start_section else "99:99")

    for event in sorted(events, key=_event_sort_key)[:20]:
        label = {"event": "日程", "ddl": "DDL", "exam": "考试", "recurring": "周期日程"}.get(
            event.event_type, "日程"
        )
        parts = [f"{label} {event.title}"]
        if event.event_type == "ddl":
            parts.append("今日截止")
        else:
            parts.append(_event_time_text(today, event))
        if event.location:
            parts.append(f"@ {event.location}")
        lines.append(" ".join(parts))

    if not lines:
        return "（今天没有课程或日程）"
    return "\n".join(lines[:30])


@router.post("/chat", response_model=None)
async def chat_with_assistant(
    payload: ScheduleAiChatIn,
    request: Request,
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> dict:
    """「墨程」App 内置 AI 助手：对话回复 + 可选的结构化日程操作。

    今日课程与日程摘要在服务端注入 system prompt；operations 与 /parse 的
    EventOperation 结构完全一致，客户端确认后直接落库。对话内容不落库、
    不写内容日志；图片即转即弃。
    """
    del request  # 限流按用户维度，不用 IP
    if not _chat_daily_limiter.allow(f"schedule-ai-chat:user:{user.id}"):
        raise HTTPException(
            status_code=429,
            detail={"code": 42953, "message": "今日 AI 助手对话次数已达上限"},
        )
    started = time.monotonic()
    message = strip_identity_info(payload.message.strip())
    image = payload.image_base64.strip() or None
    if not message and image is None:
        raise HTTPException(
            status_code=422,
            detail={"code": 42254, "message": "说点什么吧"},
        )
    history = [
        {"role": turn.role, "content": turn.content.strip()}
        for turn in payload.history
        if turn.content.strip()
    ]
    context = _build_context(db, user.id)
    agenda = _build_today_agenda(db, user.id)
    try:
        result = await asyncio.wait_for(
            _gateway.chat(
                message=message,
                image_b64=image,
                history=history,
                context=context,
                agenda=agenda,
            ),
            timeout=_settings.llm_import_deadline_seconds,
        )
        return {
            "code": 0,
            "message": "ok",
            "data": {
                "reply": result.reply,
                "operations": [op.to_dict() for op in result.operations],
                "elapsed_ms": int((time.monotonic() - started) * 1000),
            },
        }
    except asyncio.TimeoutError:
        raise HTTPException(
            status_code=504,
            detail={"code": 50443, "message": "AI 助手响应超时，请稍后重试"},
        ) from None
    except EventParseError as exc:
        raise HTTPException(
            status_code=exc.status_code,
            detail={"code": exc.code, "message": exc.message},
        ) from None


# ---------------------------------------------------------------------------
# 「墨程」AI 目标规划（POST /api/schedule-ai/goal-plan）
# ---------------------------------------------------------------------------

# 目标规划是低频重操作（一次出 14 天任务），额度比对话窄：每用户每天 20 次。
_goal_plan_daily_limiter = RateLimiter(20, 24 * 60 * 60)


def _build_week_schedule(db: Session, user_id: int) -> str:
    """当前用户本周（Asia/Shanghai，周一起）课程占用摘要，注入规划 prompt 作空档依据。

    只列课表占用：每行「周X 课程名 节次（起止时刻）@ 地点」。无课程/不在学期
    周内时返回空串，prompt 侧翻译成「全天可自由安排」。
    """
    today = datetime.now(_SHANGHAI).date()
    semester = db.scalar(
        select(SyncSemester)
        .where(
            SyncSemester.user_id == user_id,
            SyncSemester.is_current.is_(True),
            SyncSemester.deleted.is_(False),
        )
        .order_by(SyncSemester.updated_at.desc())
        .limit(1)
    )
    if semester is None:
        return ""
    try:
        start = date.fromisoformat(semester.start_date)
    except ValueError:
        return ""
    week_no = (today - start).days // 7 + 1
    if not (1 <= week_no <= semester.total_weeks):
        return ""
    courses = db.scalars(
        select(SyncCourse).where(
            SyncCourse.user_id == user_id,
            SyncCourse.semester_uuid == semester.uuid,
            SyncCourse.deleted.is_(False),
        )
    ).all()
    courses_by_uuid = {course.uuid: course for course in courses}
    if not courses_by_uuid:
        return ""
    schedules = db.scalars(
        select(SyncSchedule).where(
            SyncSchedule.user_id == user_id,
            SyncSchedule.course_uuid.in_(courses_by_uuid),
            SyncSchedule.deleted.is_(False),
        )
    ).all()
    lines: list[str] = []
    for schedule in sorted(
        schedules, key=lambda s: (s.day_of_week, s.start_section, s.end_section)
    ):
        if not _week_is_active(schedule.weeks_type, schedule.custom_weeks, week_no):
            continue
        course = courses_by_uuid.get(schedule.course_uuid)
        if course is None:
            continue
        day = start + timedelta(weeks=week_no - 1, days=schedule.day_of_week - 1)
        time_text = _section_text(schedule.start_section, schedule.end_section)
        span = _section_span(day, schedule.start_section, schedule.end_section)
        if span is not None:
            time_text = f"{time_text} {span[0]}-{span[1]}"
        parts = [f"星期{_WEEKDAY_LABELS[schedule.day_of_week - 1]}", course.name, time_text]
        if schedule.location:
            parts.append(f"@ {schedule.location}")
        lines.append(" ".join(parts))
    return "\n".join(lines[:60])


@router.post("/goal-plan", response_model=None)
async def plan_goal(
    payload: ScheduleAiGoalPlanIn,
    request: Request,
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> dict:
    """「墨程」AI 目标规划：目标 → 阶段里程碑 + 未来 14 天每日任务。

    system prompt 注入今日课程与日程摘要（_build_today_agenda）+ 本周课表占用
    （_build_week_schedule），AI 拆解为里程碑 + 每日任务（避开课程时段、
    每天 ≈daily_minutes 分钟）。tasks 与 /parse 的 EventOperation
    同构（action=create、type 主用 ddl），客户端直接落库；milestones 由客户端
    存本地 goal 表。内容不落库、不写内容日志；图片即转即弃。
    """
    del request  # 限流按用户维度，不用 IP
    if not _goal_plan_daily_limiter.allow(f"schedule-ai-goal:user:{user.id}"):
        raise HTTPException(
            status_code=429,
            detail={"code": 42956, "message": "今日目标规划次数已达上限"},
        )
    started = time.monotonic()
    title = strip_identity_info(payload.title.strip())
    if not title:
        raise HTTPException(
            status_code=422,
            detail={"code": 42255, "message": "先写个目标吧"},
        )
    image = payload.image_base64.strip() or None
    context = _build_context(db, user.id)
    agenda = _build_today_agenda(db, user.id)
    week_schedule = _build_week_schedule(db, user.id)
    try:
        result = await asyncio.wait_for(
            _gateway.goal_plan(
                title=title,
                detail=payload.detail.strip(),
                target_date=payload.target_date,
                daily_minutes=payload.daily_minutes,
                image_b64=image,
                context=context,
                agenda=agenda,
                week_schedule=week_schedule,
            ),
            timeout=_settings.llm_import_deadline_seconds,
        )
        return {
            "code": 0,
            "message": "ok",
            "data": {
                "reply": result.reply,
                "milestones": [m.to_dict() for m in result.milestones],
                "tasks": [op.to_dict() for op in result.tasks],
                "elapsed_ms": int((time.monotonic() - started) * 1000),
            },
        }
    except asyncio.TimeoutError:
        raise HTTPException(
            status_code=504,
            detail={"code": 50444, "message": "AI 目标规划超时，请稍后重试"},
        ) from None
    except EventParseError as exc:
        raise HTTPException(
            status_code=exc.status_code,
            detail={"code": exc.code, "message": exc.message},
        ) from None
