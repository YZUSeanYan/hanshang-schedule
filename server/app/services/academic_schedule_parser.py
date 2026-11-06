"""Normalize the YZU student timetable callback without retaining source data.

The WebVPN session layer passes the response body directly to this module.  It
returns only the course fields needed by the client and deliberately exposes no
cookies, credentials, response URL, or upstream diagnostic payload.
"""
from __future__ import annotations

import json
import re
from collections.abc import Iterable
from dataclasses import dataclass
from datetime import date
from typing import Any


class AcademicScheduleParseError(ValueError):
    """The upstream response did not contain a recognizable timetable.

    三个属性都不含用户内容，可安全记录与展示：

    - ``message``      内部短语，固定文案，写日志用；
    - ``reason``       稳定的机读标记，写进 import_events.detail 便于统计失败原因；
    - ``user_message`` 给用户看的**可执行**提示，会原样返回给客户端。

    2026-09-22 之前只有一句「课表内容暂不支持解析」，用户不知道下一步该做什么
    （实测有测试者导入了门户首页也只得到这句），所以拆出 reason 与 user_message。
    """

    def __init__(
        self,
        message: str,
        *,
        reason: str = "unknown",
        user_message: str | None = None,
    ) -> None:
        super().__init__(message)
        self.reason = reason
        self.user_message = user_message or "课表内容暂不支持解析"


@dataclass(frozen=True)
class AcademicScheduleSlot:
    day_of_week: int
    start_section: int
    end_section: int
    weeks_text: str
    location: str


@dataclass(frozen=True)
class AcademicScheduleCourse:
    name: str
    teacher: str
    slots: tuple[AcademicScheduleSlot, ...]


_NAME_KEYS = ("kcmc", "kcm", "KCM", "courseName", "course_name", "kcName", "name", "title")
_TEACHER_KEYS = ("jsxm", "jsm", "JSXM", "teacherName", "attendClassTeacher", "teacher", "jsmc", "SKJS")
_LOCATION_KEYS = ("jxcdm", "jxcd", "roomName", "location", "cdmc", "place", "room", "skdd")
_DAY_KEYS = ("xqj", "skxq", "XQI", "weekDay", "dayOfWeek", "classDay", "day", "xq")
_SECTIONS_KEYS = ("jcs", "jcdm", "sections", "sectionText", "jc", "nodes", "jiec", "JC", "time")
_START_KEYS = ("startSection", "sectionStart", "ksjc", "startNode", "classSessions", "skjc")
_END_KEYS = ("endSection", "sectionEnd", "jsjc", "endNode")
_WEEKS_KEYS = ("zcd", "zcsm", "ZCD", "weeksText", "weeks", "zc", "skzc", "skzcs", "weekText", "zcs")


def parse_academic_schedule(payload: str | bytes | Any) -> list[AcademicScheduleCourse]:
    """Return a compact course model from the student timetable JSON.

    The callback format has changed between URP revisions.  The parser accepts
    the field aliases already supported by the mobile importer, but requires a
    course name plus a valid weekday and section range before emitting a slot.
    """
    data = _decode_payload(payload)
    course_rows = _find_course_rows(data)
    if course_rows is None:
        raise AcademicScheduleParseError(
            "未识别到教务课表数据",
            reason="no_schedule_data",
            user_message="没能读到课表数据。请确认是「本学期课表」的完整页面或截图，再试一次。",
        )

    grouped: dict[tuple[str, str], list[AcademicScheduleSlot]] = {}
    for row in course_rows:
        name = _pick_text(row, _NAME_KEYS)
        if not name:
            continue
        teacher = _pick_text(row, _TEACHER_KEYS) or ""
        candidates: Iterable[dict[str, Any]] = (row,)
        nested = row.get("timeAndPlaceList")
        if isinstance(nested, list) and any(isinstance(item, dict) for item in nested):
            candidates = (item for item in nested if isinstance(item, dict))
        for candidate in candidates:
            # 移动版结构里周次（skzcs）挂在课程级而非时间段级，时间段缺省时继承课程级周次
            slot = _slot_from_row(candidate, fallback_weeks=_pick_text(row, _WEEKS_KEYS))
            if slot is not None:
                grouped.setdefault((name, teacher), []).append(slot)

    courses = [
        AcademicScheduleCourse(name=name, teacher=teacher, slots=tuple(slots))
        for (name, teacher), slots in grouped.items()
        if slots
    ]
    if not courses:
        raise AcademicScheduleParseError(
            "课表数据缺少可用的上课时间",
            reason="missing_times",
            user_message="课表数据不完整（缺少上课时间）。请换一份内容再试，或改用截图、Excel 导入。",
        )
    return courses


def parse_portal_schedule(payload: str | bytes | Any) -> list[AcademicScheduleCourse]:
    """Normalize the timetable embedded by ``https://i.yzu.edu.cn/Student``.

    The portal renders a compact ``weeks -> days -> sections`` model.  The
    same lesson appears once per teaching week, so occurrences are folded back
    into one slot with a compact week expression before returning it to the
    clients.
    """
    data = _decode_payload(payload)
    if not isinstance(data, dict) or not isinstance(data.get("weeks"), list):
        raise AcademicScheduleParseError(
            "一网通办课表数据结构异常",
            reason="portal_shape",
            user_message="内容的结构和预期不符。可以改用截图或 Excel 导入。",
        )

    grouped: dict[
        tuple[str, str],
        dict[tuple[int, int, int, str], set[int]],
    ] = {}
    for week_row in data["weeks"]:
        if not isinstance(week_row, dict):
            continue
        week = _positive_int(week_row.get("week"))
        days = week_row.get("days")
        if week is None or not isinstance(days, list):
            continue
        for day_row in days:
            if not isinstance(day_row, dict):
                continue
            day = _positive_int(day_row.get("day"))
            sections = day_row.get("sections")
            if day is None or not 1 <= day <= 7 or not isinstance(sections, list):
                continue
            for section in sections:
                if not isinstance(section, dict):
                    continue
                name = _pick_text(section, ("course",))
                if not name:
                    continue
                start = _positive_int(section.get("start"))
                end = _positive_int(section.get("end"))
                if start is None and end is not None:
                    start = end
                if end is None and start is not None:
                    end = start
                if start is None or end is None or end < start:
                    continue
                teacher = _pick_text(section, ("teacher",)) or ""
                location = _pick_text(section, ("address",)) or ""
                slot_key = (day, start, end, location)
                grouped.setdefault((name, teacher), {}).setdefault(slot_key, set()).add(week)

    courses: list[AcademicScheduleCourse] = []
    for (name, teacher), slots_by_shape in grouped.items():
        slots = tuple(
            AcademicScheduleSlot(
                day_of_week=day,
                start_section=start,
                end_section=end,
                weeks_text=_format_week_numbers(weeks),
                location=location,
            )
            for (day, start, end, location), weeks in sorted(slots_by_shape.items())
        )
        if slots:
            courses.append(AcademicScheduleCourse(name=name, teacher=teacher, slots=slots))
    return courses


def extract_portal_term_start_year(term: Any) -> int | None:
    """Return the academic start year of a portal term string.

    Accepts both formats seen in production: ``2026-2027-1`` and
    ``2024-2025第2学期``.  A pair that is not a consecutive academic year (or a
    term without a year pair) is unrecognizable and returns ``None``.
    """
    if not isinstance(term, str):
        return None
    years = [int(match.group()) for match in re.finditer(r"(?:19|20)\d{2}", term)]
    if len(years) < 2 or years[1] != years[0] + 1:
        return None
    return years[0]


def is_acceptable_term_start_year(start_year: int, today: date | None = None) -> bool:
    """Return whether a term belongs to the current or next academic year.

    September is the academic-year boundary.  Data older than the current
    academic year (for example the portal still serving a two-year-old
    semester) must never be reported as the current timetable.
    """
    today = today or date.today()
    current_start_year = today.year if today.month >= 9 else today.year - 1
    return current_start_year <= start_year <= current_start_year + 1


def courses_to_response(courses: Iterable[AcademicScheduleCourse]) -> list[dict[str, Any]]:
    """Produce an API-safe response that contains no raw upstream data."""
    return [
        {
            "name": course.name,
            "teacher": course.teacher,
            "slots": [
                {
                    "day_of_week": slot.day_of_week,
                    "start_section": slot.start_section,
                    "end_section": slot.end_section,
                    "weeks_text": slot.weeks_text,
                    "location": slot.location,
                }
                for slot in course.slots
            ],
        }
        for course in courses
    ]


def _decode_payload(payload: str | bytes | Any) -> Any:
    if isinstance(payload, bytes):
        payload = payload.decode("utf-8")
    if isinstance(payload, str):
        try:
            return json.loads(payload)
        except json.JSONDecodeError as exc:
            raise AcademicScheduleParseError(
                "教务课表响应不是 JSON",
                reason="not_json",
                user_message="没能取到课表数据。请重新登录后再试一次。",
            ) from exc
    return payload


def _find_course_rows(node: Any) -> list[dict[str, Any]] | None:
    if isinstance(node, list):
        rows = [item for item in node if isinstance(item, dict)]
        if rows and any(_pick_text(row, _NAME_KEYS) and _has_schedule(row) for row in rows):
            return rows
        # 移动版 URP：课程列表是"列表里套一个按课程号索引的大字典"
        # （xkxx: [{ "21031003_01": {...课程...}, ... }]），需拆平一层再识别。
        flattened = [
            value for row in rows for value in row.values() if isinstance(value, dict)
        ]
        if flattened and any(
            _pick_text(row, _NAME_KEYS) and _has_schedule(row) for row in flattened
        ):
            return flattened
        for item in node:
            found = _find_course_rows(item)
            if found is not None:
                return found
    elif isinstance(node, dict):
        for item in node.values():
            found = _find_course_rows(item)
            if found is not None:
                return found
    return None


def _has_schedule(row: dict[str, Any]) -> bool:
    if _parse_day(row) is not None and _parse_sections(row) is not None:
        return True
    nested = row.get("timeAndPlaceList")
    return isinstance(nested, list) and any(
        isinstance(item, dict) and _parse_day(item) is not None and _parse_sections(item) is not None
        for item in nested
    )


def _slot_from_row(
    row: dict[str, Any], fallback_weeks: str | None = None
) -> AcademicScheduleSlot | None:
    day = _parse_day(row)
    sections = _parse_sections(row)
    if day is None or sections is None:
        return None
    return AcademicScheduleSlot(
        day_of_week=day,
        start_section=sections[0],
        end_section=sections[1],
        weeks_text=_pick_text(row, _WEEKS_KEYS) or fallback_weeks or "",
        location=_parse_location(row),
    )


def _pick_text(row: dict[str, Any], keys: Iterable[str]) -> str | None:
    for key in keys:
        value = row.get(key)
        if isinstance(value, str) and value.strip():
            return value.strip()
        if isinstance(value, (int, float)):
            return str(value)
    return None


def _parse_day(row: dict[str, Any]) -> int | None:
    for source in _row_and_id(row):
        for key in _DAY_KEYS:
            value = source.get(key)
            if isinstance(value, (int, float)) and 1 <= int(value) <= 7:
                return int(value)
            if isinstance(value, str):
                numeric = int(value.strip()) if value.strip().isdigit() else None
                if numeric is not None and 1 <= numeric <= 7:
                    return numeric
                for index, chinese_day in enumerate("一二三四五六日", start=1):
                    if chinese_day in value:
                        return index
    return None


def _parse_sections(row: dict[str, Any]) -> tuple[int, int] | None:
    for key in _SECTIONS_KEYS:
        value = row.get(key)
        if isinstance(value, list):
            values = sorted(int(item) for item in value if str(item).isdigit())
            if values:
                return values[0], values[-1]
        if isinstance(value, (int, float)) and int(value) > 0:
            return int(value), int(value)
        if isinstance(value, str):
            values = [int(match.group()) for match in re.finditer(r"\d+", value)]
            if values:
                return min(values), max(values)
    start = _pick_int(row, _START_KEYS) or _pick_int(_id_row(row), _START_KEYS)
    end = _pick_int(row, _END_KEYS) or _pick_int(_id_row(row), _END_KEYS)
    if start and end and end >= start:
        return start, end
    count = _pick_int(row, ("cxjc", "sectionCount", "duration")) or _pick_int(
        _id_row(row), ("cxjc", "sectionCount", "duration")
    )
    if start and count and count > 0:
        return start, start + count - 1
    return None


def _parse_location(row: dict[str, Any]) -> str:
    pieces = [
        _pick_text(row, ("xqm", "campusName")) or "",
        _pick_text(row, ("jxlm", "teachingBuildingName", "buildingName")) or "",
        _pick_text(row, ("jasm", "classroomName", "roomName")) or "",
    ]
    joined = "".join(piece for piece in pieces if piece)
    return joined or _pick_text(row, _LOCATION_KEYS) or ""


def _pick_int(row: dict[str, Any], keys: Iterable[str]) -> int | None:
    for key in keys:
        value = row.get(key)
        if isinstance(value, (int, float)) and int(value) > 0:
            return int(value)
        if isinstance(value, str) and value.strip().isdigit() and int(value.strip()) > 0:
            return int(value.strip())
    return None


def _positive_int(value: Any) -> int | None:
    if isinstance(value, bool):
        return None
    if isinstance(value, (int, float)) and int(value) > 0:
        return int(value)
    if isinstance(value, str) and value.strip().isdigit() and int(value.strip()) > 0:
        return int(value.strip())
    return None


def _format_week_numbers(weeks: Iterable[int]) -> str:
    values = sorted(set(weeks))
    if not values:
        return ""
    ranges: list[str] = []
    start = previous = values[0]
    for value in values[1:]:
        if value == previous + 1:
            previous = value
            continue
        ranges.append(str(start) if start == previous else f"{start}-{previous}")
        start = previous = value
    ranges.append(str(start) if start == previous else f"{start}-{previous}")
    return ",".join(ranges)


def _id_row(row: dict[str, Any]) -> dict[str, Any]:
    value = row.get("id")
    return value if isinstance(value, dict) else {}


def _row_and_id(row: dict[str, Any]) -> Iterable[dict[str, Any]]:
    yield row
    identifier = _id_row(row)
    if identifier:
        yield identifier
