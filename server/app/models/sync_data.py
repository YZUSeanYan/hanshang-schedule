"""云端同步数据表（设计文档阶段 4：课表云端同步）。

设计要点：
- 三张表与 App 本地 Drift 表一一对应，用 **uuid** 作为全局主键
  （客户端生成，多设备唯一），服务端自增 id 仅作内部索引；
- `updated_at` 为**客户端写入时间（epoch 毫秒）**，last-write-wins 比较依据；
- `synced_at` 为**服务端入库时间（time.time_ns()）**，作为增量拉取游标，
  避免客户端时钟不准导致漏拉；
- `deleted` 为墓碑标记：删除不同步物理删行，否则其他设备永远不知道删了。
"""
from sqlalchemy import Boolean, DateTime, Float, ForeignKey, Index, Integer, String, Text
from sqlalchemy.orm import Mapped, mapped_column

from app.db.base import Base


class SyncSemester(Base):
    __tablename__ = "sync_semesters"

    id: Mapped[int] = mapped_column(primary_key=True)
    user_id: Mapped[int] = mapped_column(ForeignKey("users.id"), index=True)
    uuid: Mapped[str] = mapped_column(String(64), comment="客户端生成的全局唯一 ID")
    name: Mapped[str] = mapped_column(String(64))
    start_date: Mapped[str] = mapped_column(String(10), comment="开学第一周周一 YYYY-MM-DD")
    total_weeks: Mapped[int] = mapped_column(Integer, default=20)
    is_current: Mapped[bool] = mapped_column(Boolean, default=False)
    updated_at: Mapped[int] = mapped_column(Integer, comment="客户端写入时间 epoch 毫秒")
    deleted: Mapped[bool] = mapped_column(Boolean, default=False, comment="墓碑标记")
    synced_at: Mapped[int] = mapped_column(Integer, comment="服务端入库时间 time.time_ns()，拉取游标")

    __table_args__ = (
        Index("ix_sync_semesters_user_uuid", "user_id", "uuid", unique=True),
        Index("ix_sync_semesters_user_synced", "user_id", "synced_at"),
    )


class SyncCourse(Base):
    __tablename__ = "sync_courses"

    id: Mapped[int] = mapped_column(primary_key=True)
    user_id: Mapped[int] = mapped_column(ForeignKey("users.id"), index=True)
    uuid: Mapped[str] = mapped_column(String(64))
    semester_uuid: Mapped[str] = mapped_column(String(64), comment="所属学期 uuid")
    name: Mapped[str] = mapped_column(String(128))
    short_name: Mapped[str] = mapped_column(
        String(16), default="", comment="用户自定义课程简称（卡片优先显示），空=用 name"
    )
    teacher: Mapped[str] = mapped_column(String(128), default="")
    color: Mapped[int] = mapped_column(Integer, default=0, comment="ARGB32 颜色值")
    note: Mapped[str] = mapped_column(Text, default="")
    updated_at: Mapped[int] = mapped_column(Integer)
    deleted: Mapped[bool] = mapped_column(Boolean, default=False)
    synced_at: Mapped[int] = mapped_column(Integer)

    __table_args__ = (
        Index("ix_sync_courses_user_uuid", "user_id", "uuid", unique=True),
        Index("ix_sync_courses_user_synced", "user_id", "synced_at"),
    )


class SyncSchedule(Base):
    __tablename__ = "sync_schedules"

    id: Mapped[int] = mapped_column(primary_key=True)
    user_id: Mapped[int] = mapped_column(ForeignKey("users.id"), index=True)
    uuid: Mapped[str] = mapped_column(String(64))
    course_uuid: Mapped[str] = mapped_column(String(64), comment="所属课程 uuid")
    day_of_week: Mapped[int] = mapped_column(Integer, comment="1=周一 … 7=周日")
    start_section: Mapped[int] = mapped_column(Integer)
    end_section: Mapped[int] = mapped_column(Integer)
    weeks_type: Mapped[int] = mapped_column(Integer, comment="0每周 1单周 2双周 3自定义")
    custom_weeks: Mapped[str] = mapped_column(String(255), default="", comment="逗号分隔，如 1,3,5-8")
    location: Mapped[str] = mapped_column(String(255), default="")
    updated_at: Mapped[int] = mapped_column(Integer)
    deleted: Mapped[bool] = mapped_column(Boolean, default=False)
    synced_at: Mapped[int] = mapped_column(Integer)

    __table_args__ = (
        Index("ix_sync_schedules_user_uuid", "user_id", "uuid", unique=True),
        Index("ix_sync_schedules_user_synced", "user_id", "synced_at"),
    )
