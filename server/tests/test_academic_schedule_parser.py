import pytest
from datetime import date

from app.services.academic_schedule_parser import (
    AcademicScheduleParseError,
    courses_to_response,
    extract_portal_term_start_year,
    is_acceptable_term_start_year,
    parse_academic_schedule,
    parse_portal_schedule,
)


def test_parses_nested_urp_course_rows_without_retaining_raw_payload():
    courses = parse_academic_schedule(
        {
            "data": {
                "rows": [
                    {
                        "kcmc": "大学物理",
                        "jsxm": "李老师",
                        "timeAndPlaceList": [
                            {
                                "xqj": "2",
                                "jcs": "3-4节",
                                "zcd": "1-16周",
                                "xqm": "扬子津",
                                "jxlm": "文津楼",
                                "jasm": "201",
                            }
                        ],
                    }
                ]
            }
        }
    )

    assert courses_to_response(courses) == [
        {
            "name": "大学物理",
            "teacher": "李老师",
            "slots": [
                {
                    "day_of_week": 2,
                    "start_section": 3,
                    "end_section": 4,
                    "weeks_text": "1-16周",
                    "location": "扬子津文津楼201",
                }
            ],
        }
    ]


def test_accepts_direct_rows_and_id_based_sections():
    courses = parse_academic_schedule(
        '[{"courseName":"高等数学","teacherName":"王老师",'
        '"id":{"xqj":5,"skjc":1},"cxjc":2,"weeksText":"单周"}]'
    )

    slot = courses[0].slots[0]
    assert (slot.day_of_week, slot.start_section, slot.end_section, slot.weeks_text) == (5, 1, 2, "单周")


@pytest.mark.parametrize("payload", ["not-json", {"data": []}, [{"kcmc": "无时间"}]])
def test_rejects_unrecognized_or_incomplete_payload(payload):
    with pytest.raises(AcademicScheduleParseError):
        parse_academic_schedule(payload)


def test_parses_portal_week_day_section_model_and_compacts_weeks():
    payload = {
        "term": "2026-2027-1",
        "weeks": [
            {
                "week": week,
                "days": [
                    {
                        "day": 2,
                        "sections": [
                            {
                                "course": "大学物理",
                                "teacher": "李老师",
                                "address": "扬子津东校区文津楼N201",
                                "start": 3,
                                "end": 4,
                            }
                        ],
                    }
                ],
            }
            for week in (1, 2, 3, 5)
        ],
    }

    assert courses_to_response(parse_portal_schedule(payload)) == [
        {
            "name": "大学物理",
            "teacher": "李老师",
            "slots": [
                {
                    "day_of_week": 2,
                    "start_section": 3,
                    "end_section": 4,
                    "weeks_text": "1-3,5",
                    "location": "扬子津东校区文津楼N201",
                }
            ],
        }
    ]


def test_accepts_structurally_valid_empty_portal_schedule():
    assert parse_portal_schedule({"term": "2026-2027-1", "weeks": []}) == []


@pytest.mark.parametrize("payload", [{}, {"weeks": None}, []])
def test_rejects_invalid_portal_schedule(payload):
    with pytest.raises(AcademicScheduleParseError):
        parse_portal_schedule(payload)


def test_extracts_portal_term_start_year_from_common_formats():
    assert extract_portal_term_start_year("2026-2027-1") == 2026
    assert extract_portal_term_start_year("2024-2025第2学期") == 2024
    assert extract_portal_term_start_year("2026-2027学年第一学期") == 2026


@pytest.mark.parametrize(
    "term",
    [None, "", 2026, ["2026-2027-1"], "2026年第一学期", "第2学期", "2026-2028-1"],
)
def test_rejects_unrecognizable_portal_terms(term):
    assert extract_portal_term_start_year(term) is None


@pytest.mark.parametrize(
    "start_year,expected",
    [(2025, True), (2026, True), (2024, False), (2027, False)],
)
def test_portal_term_must_be_current_or_next_academic_year(start_year, expected):
    # 2026-08-11：当前学年 2025-2026，只接受 2025/2026；2024-2025 已过期两年。
    assert (
        is_acceptable_term_start_year(start_year, today=date(2026, 8, 11))
        is expected
    )


def test_portal_term_window_moves_after_september():
    # 2026-09-01 进入新学年后，上学年数据不再被当作当前学期。
    assert is_acceptable_term_start_year(2026, today=date(2026, 9, 1)) is True
    assert is_acceptable_term_start_year(2025, today=date(2026, 9, 1)) is False
