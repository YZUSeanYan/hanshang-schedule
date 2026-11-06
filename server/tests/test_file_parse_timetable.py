"""分小班课表结构化提取的回归测试（免大模型规则路径）。

样本：tests/fixtures/yzu-split-class-timetable-202610.xlsx——结构等价的全合成课表
（4 张网格课表：单元格=小班代号+教室，如 C1WenjinN202；6 张学生名单：
课程|学号|姓名|专业|班级；所有姓名/学号均虚构，不含真实用户数据）。
"""
import asyncio
import datetime as dt
from pathlib import Path

import pytest

from app.services.academic_schedule_parser import AcademicScheduleParseError
from app.services.file_schedule_import import prepare_schedule_file
from app.services.llm_schedule_import import (
    LlmImportResult,
    UnavailableLlmScheduleGateway,
    _compress_weeks,
    _weeks_from_cell,
    extract_class_grid_schedule,
    extract_structured_table,
)

_FIXTURE = Path(__file__).parent / "fixtures" / "yzu-split-class-timetable-202610.xlsx"
_SEMESTER_START = dt.date(2026, 9, 7)  # 2026-2027 秋第 1 周周一


def _table_text() -> str:
    return prepare_schedule_file(_FIXTURE.name, _FIXTURE.read_bytes()).table_text


def test_matched_class_imports_only_your_class():
    # 命中名单的用户只拿到自己小班的课（26 计科 C1 → 英语交际能力）
    courses = extract_class_grid_schedule(
        _table_text(), username="测试学生", semester_start=_SEMESTER_START
    )
    assert courses is not None and len(courses) == 1
    course = courses[0]
    assert course.name == "英语交际能力"
    slots = [(s.day_of_week, s.start_section, s.end_section, s.weeks_text, s.location)
             for s in course.slots]
    assert slots == [
        (1, 11, 11, "8-11周", "WenjinN510"),
        (2, 1, 1, "8-11周", "WenjinN510"),
        (5, 9, 9, "8-11周", "WenjinN510"),
    ]


def test_fallback_all_classes_with_suffixes():
    # 未命中名单 → 全部小班各出一门「课程（小班）」，用户在预览里删除多余的
    courses = extract_class_grid_schedule(
        _table_text(), username="不存在的人", semester_start=_SEMESTER_START
    )
    assert courses is not None
    names = sorted(c.name for c in courses)
    assert len(names) == 15
    assert "英语能力进阶（M1）" in names
    assert "英语交际能力（C4）" in names
    # 不带后缀的裸课程名不允许出现（避免用户误以为只需导入一门）
    assert "英语能力进阶" not in names


def test_weeks_compressed_from_grid_dates():
    # 网格日期 + 开学日 → 学期周次；Week 块 2026-10-26 起 = 第 8 周
    courses = extract_class_grid_schedule(
        _table_text(), username="测试学生", semester_start=_SEMESTER_START
    )
    weeks = {s.weeks_text for s in courses[0].slots}
    assert weeks == {"8-11周"}


def test_semester_required_for_grid_tables():
    with pytest.raises(AcademicScheduleParseError) as exc:
        extract_class_grid_schedule(_table_text(), username="测试学生")
    assert exc.value.reason == "semester_required"


def test_row_layout_still_supported():
    # 教务导出的行式课表（班号|上课周次|星期|节次|课程名称|教师|教室）不受影响
    text = (
        "工作表：Sheet1\n"
        "3\t班号\t上课周次\t星期\t节次\t课程名称\t教师\t教室\n"
        "4\t1\t(1-16周)(调2)\t周五\t3-4节\t计算机网络\t教师A\t1-308\n"
        "5\t1\t(2-9周)(单)(11-17周)\t周一\t3-4节\t材料力学\t教师B\t2-106\n"
    )
    courses = extract_structured_table(text)
    assert courses is not None
    actual = {
        (c.name, c.teacher): [
            (s.day_of_week, s.start_section, s.end_section, s.weeks_text, s.location)
            for s in c.slots
        ]
        for c in courses
    }
    assert actual == {
        ("计算机网络", "教师A"): [(5, 3, 4, "1-16周", "1-308")],
        ("材料力学", "教师B"): [(1, 3, 4, "2-9周(单),11-17周", "2-106")],
    }


@pytest.mark.parametrize(
    "cell, expected",
    [
        ("(1-16周)(调2)", "1-16周"),
        ("(2-9周)(单)(11-17周)", "2-9周(单),11-17周"),
        ("(3,5周)", "3周,5周"),
        ("3-4周", "3-4周"),
        ("1-16周", "1-16周"),
        ("5", None),
        ("上课周次", None),
        ("", None),
    ],
)
def test_weeks_cell_canonicalization(cell, expected):
    assert _weeks_from_cell(cell) == expected


def test_weeks_compression():
    assert _compress_weeks([8, 9, 10, 11]) == "8-11周"
    assert _compress_weeks([5, 7, 8]) == "5周,7-8周"
    assert _compress_weeks([3]) == "3周"


def test_merged_day_and_weeks_cells_inherit_previous_row():
    text = (
        "工作表：Sheet1\n"
        "3\t班号\t上课周次\t星期\t节次\t课程名称\t教师\t教室\n"
        "4\t1\t(1-8周)\t周一\t1-2节\t离散数学\t教师C\t2-207\n"
        "5\t1\t\t\t3-4节\t离散数学\t教师C\t2-207\n"
    )
    courses = extract_structured_table(text)
    assert [(s.day_of_week, s.start_section, s.end_section, s.weeks_text)
            for s in courses[0].slots] == [
        (1, 1, 2, "1-8周"),
        (1, 3, 4, "1-8周"),
    ]


def test_grid_fixture_does_not_hit_row_layout():
    # 网格表不得被行式提取误命中，也不得把「Week/日期/时间」行当课程
    assert extract_structured_table(_table_text()) is None


def test_room_changes_split_into_separate_slots():
    # 同一（星期,节次）在不同周换教室 → 按教室拆成两个时段、周次各自归组
    text = (
        "工作表：25级计科专业\n"
        "2\t\tMon\tTue\tWed\tThu\tFri\tSat\tSun\n"
        "3\tWeek 1\t2026-10-26T00:00:00\t2026-10-27T00:00:00\t2026-10-28T00:00:00"
        "\t2026-10-29T00:00:00\t2026-10-30T00:00:00\t2026-10-31T00:00:00\t2026-11-01T00:00:00\n"
        "4\t8:00-8:45\tC1RoomA\t\t\t\t\t\t\n"
        "5\tWeek 2\t2026-11-02T00:00:00\t2026-11-03T00:00:00\t2026-11-04T00:00:00"
        "\t2026-11-05T00:00:00\t2026-11-06T00:00:00\t2026-11-07T00:00:00\t2026-11-08T00:00:00\n"
        "6\t8:00-8:45\tC1RoomB\t\t\t\t\t\t\n"
        "工作表：25计科名单\n"
        "1\t课程\t***\t专业\t班级\n"
        "2\t英语能力进阶\t*********\t张三\t计科专业\tC1\n"
    )
    courses = extract_class_grid_schedule(
        text, username="张三", semester_start=_SEMESTER_START
    )
    assert courses is not None and len(courses) == 1
    slots = sorted(
        (s.weeks_text, s.location) for s in courses[0].slots
    )
    assert slots == [("8周", "RoomA"), ("9周", "RoomB")]


def test_roster_sheets_never_reach_llm():
    # 名单册（姓名/学号）只给规则路径用；大模型输入必须剔除（合规红线）
    from app.services.llm_schedule_import import without_roster_sheets

    filtered = without_roster_sheets(_table_text())
    assert "工作表：25机械名单" not in filtered
    assert "工作表：25级学生名单（总）" not in filtered
    assert "*********" not in filtered  # 脱敏后的学号格不进大模型
    assert "工作表：25级计科专业" in filtered  # 课表网格保留
    assert "C1WenjinN202" in filtered


def test_unavailable_gateway_still_serves_rule_path():
    # 大模型未开启时，规则命中路径照常导入（不依赖 LLM）
    text = (
        "工作表：Sheet1\n"
        "3\t班号\t上课周次\t星期\t节次\t课程名称\t教师\t教室\n"
        "4\t1\t(1-8周)\t周一\t1-2节\t离散数学\t教师C\t2-207\n"
        "5\t1\t(1-8周)\t周三\t5-6节\t离散数学\t教师C\t2-207\n"
    )
    result = asyncio.run(
        UnavailableLlmScheduleGateway().import_spreadsheet_schedule(table_text=text)
    )
    assert isinstance(result, LlmImportResult)
    assert result.source == "json"
    assert result.courses[0].name == "离散数学"
    assert len(result.courses[0].slots) == 2
