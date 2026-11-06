"""同步接口的请求/响应模型。

时间字段约定：
- updated_at：客户端写入时间，epoch 毫秒（int），LWW 比较依据；
- synced_at：服务端入库时间 time.time_ns()（int），仅服务端产出，作为拉取游标。
"""
from pydantic import BaseModel, Field


class SemesterSyncItem(BaseModel):
    # 注：墓碑（deleted=true）只带 uuid/updated_at/deleted，其余字段允许为空
    uuid: str = Field(min_length=1, max_length=64)
    name: str = Field(default="", max_length=64)
    start_date: str = Field(default="1970-01-01", pattern=r"^\d{4}-\d{2}-\d{2}$")
    total_weeks: int = Field(default=20, ge=1, le=60)
    is_current: bool = False
    updated_at: int = Field(ge=0)
    deleted: bool = False


class CourseSyncItem(BaseModel):
    uuid: str = Field(min_length=1, max_length=64)
    semester_uuid: str = Field(default="", max_length=64)
    name: str = Field(default="", max_length=128)
    short_name: str = Field(default="", max_length=16)
    teacher: str = Field(default="", max_length=128)
    color: int = 0
    note: str = Field(default="", max_length=2000)
    updated_at: int = Field(ge=0)
    deleted: bool = False


class ScheduleSyncItem(BaseModel):
    uuid: str = Field(min_length=1, max_length=64)
    course_uuid: str = Field(default="", max_length=64)
    day_of_week: int = Field(ge=1, le=7)
    start_section: int = Field(ge=1, le=30)
    end_section: int = Field(ge=1, le=30)
    weeks_type: int = Field(ge=0, le=3)
    custom_weeks: str = Field(default="", max_length=255, description="逗号分隔周次")
    location: str = Field(default="", max_length=255)
    updated_at: int = Field(ge=0)
    deleted: bool = False


class EventSyncItem(BaseModel):
    # 个人日程（AI 日程 2.0）。time 字段允许空串：DDL 只有日期、节次表达的
    # 日程没有时间；其余约束（如 date 与 weekday 二选一）由客户端写入时保证。
    uuid: str = Field(min_length=1, max_length=64)
    title: str = Field(default="", max_length=128)
    short_title: str = Field(default="", max_length=16)
    event_type: str = Field(default="event", pattern=r"^(event|ddl|exam|recurring)$")
    date: str = Field(default="", pattern=r"^(\d{4}-\d{2}-\d{2})?$")
    weekday: int = Field(default=0, ge=0, le=7)
    start_time: str = Field(default="", pattern=r"^$|^([01]\d|2[0-3]):[0-5]\d$")
    end_time: str = Field(default="", pattern=r"^$|^([01]\d|2[0-3]):[0-5]\d$")
    start_section: int = Field(default=0, ge=0, le=30)
    end_section: int = Field(default=0, ge=0, le=30)
    busy_sections: str = Field(default="", max_length=64, description="逗号分隔占用节次")
    location: str = Field(default="", max_length=255)
    note: str = Field(default="", max_length=500)
    color: int = 0
    remind_minutes: int = Field(default=-1, ge=-1, le=1440)
    source: str = Field(default="manual", max_length=16)
    updated_at: int = Field(ge=0)
    deleted: bool = False


class OverrideSyncItem(BaseModel):
    uuid: str = Field(min_length=1, max_length=64)
    date: str = Field(pattern=r"^\d{4}-\d{2}-\d{2}$")
    kind: str = Field(pattern=r"^(off|makeup)$")
    weekday: int = Field(default=0, ge=0, le=7)
    note: str = Field(default="", max_length=200)
    updated_at: int = Field(ge=0)
    deleted: bool = False


class SyncPushIn(BaseModel):
    semesters: list[SemesterSyncItem] = Field(default_factory=list, max_length=500)
    courses: list[CourseSyncItem] = Field(default_factory=list, max_length=500)
    schedules: list[ScheduleSyncItem] = Field(default_factory=list, max_length=500)
    events: list[EventSyncItem] = Field(default_factory=list, max_length=500)
    overrides: list[OverrideSyncItem] = Field(default_factory=list, max_length=500)
