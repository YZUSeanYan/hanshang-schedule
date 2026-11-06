"""个人日程同步表（AI 日程 2.0）。

与 sync_data 三表同一套约定：uuid 全局主键（客户端生成）、updated_at 为
客户端写入时间（epoch 毫秒，LWW 依据）、synced_at 为服务端入库时间
（time.time_ns()，增量拉取游标）、deleted 为墓碑标记（不同步物理删行）。

日程与课程的区别：课程挂在学期下按周次循环；日程是用户随手记录的安排，
不挂学期——一次性日程（event/ddl/exam）用绝对日期，周期日程（recurring）
按星期几长期有效（例会、社团活动等）。
"""
from sqlalchemy import Boolean, ForeignKey, Index, Integer, String
from sqlalchemy.orm import Mapped, mapped_column

from app.db.base import Base


class SyncEvent(Base):
    __tablename__ = "sync_events"

    id: Mapped[int] = mapped_column(primary_key=True)
    user_id: Mapped[int] = mapped_column(ForeignKey("users.id"), index=True)
    uuid: Mapped[str] = mapped_column(String(64))
    title: Mapped[str] = mapped_column(String(128))
    short_title: Mapped[str] = mapped_column(
        String(16), default="", comment="课表格子上展示的 AI 简写（≤16 字符），空=用 title"
    )
    event_type: Mapped[str] = mapped_column(
        String(16), default="event", comment="event / ddl / exam / recurring"
    )
    date: Mapped[str] = mapped_column(
        String(10), default="", comment="一次性日程日期 YYYY-MM-DD；recurring 为空"
    )
    weekday: Mapped[int] = mapped_column(
        Integer, default=0, comment="recurring 专用：1=周一 … 7=周日；其余类型为 0"
    )
    start_time: Mapped[str] = mapped_column(String(5), default="", comment="HH:MM，可空")
    end_time: Mapped[str] = mapped_column(String(5), default="", comment="HH:MM，可空")
    start_section: Mapped[int] = mapped_column(Integer, default=0, comment="节次表达时的起始节，0=未用")
    end_section: Mapped[int] = mapped_column(Integer, default=0, comment="节次表达时的结束节，0=未用")
    busy_sections: Mapped[str] = mapped_column(
        String(64),
        default="",
        comment="客户端按本地作息算好的占用节次（逗号分隔），共同空闲直接取用，服务端不需要作息表",
    )
    location: Mapped[str] = mapped_column(String(255), default="")
    note: Mapped[str] = mapped_column(String(500), default="")
    color: Mapped[int] = mapped_column(Integer, default=0, comment="ARGB32；0=客户端按标题哈希取色")
    remind_minutes: Mapped[int] = mapped_column(
        Integer, default=-1, comment="提前提醒分钟数；-1=跟随全局默认，0=不提醒"
    )
    source: Mapped[str] = mapped_column(String(16), default="manual", comment="voice / text / manual")
    updated_at: Mapped[int] = mapped_column(Integer, comment="客户端写入时间 epoch 毫秒")
    deleted: Mapped[bool] = mapped_column(Boolean, default=False, comment="墓碑标记")
    synced_at: Mapped[int] = mapped_column(Integer, comment="服务端入库时间 time.time_ns()，拉取游标")

    __table_args__ = (
        Index("ix_sync_events_user_uuid", "user_id", "uuid", unique=True),
        Index("ix_sync_events_user_synced", "user_id", "synced_at"),
    )


class SyncOverride(Base):
    """调休覆盖同步表：放假（off）与补课（makeup，按指定星期上课）。

    与其它 sync_* 表同一套约定：uuid 全局主键、updated_at 客户端毫秒时间
    （LWW 依据）、synced_at 服务端入库时间（拉取游标）、deleted 墓碑。
    """

    __tablename__ = "sync_overrides"

    id: Mapped[int] = mapped_column(primary_key=True)
    user_id: Mapped[int] = mapped_column(ForeignKey("users.id"), index=True)
    uuid: Mapped[str] = mapped_column(String(64))
    date: Mapped[str] = mapped_column(String(10), comment="YYYY-MM-DD")
    kind: Mapped[str] = mapped_column(String(8), comment="off 放假 / makeup 补课")
    weekday: Mapped[int] = mapped_column(Integer, default=0, comment="makeup 补哪一天（1-7）")
    note: Mapped[str] = mapped_column(String(200), default="")
    updated_at: Mapped[int] = mapped_column(Integer)
    deleted: Mapped[bool] = mapped_column(Boolean, default=False)
    synced_at: Mapped[int] = mapped_column(Integer)

    __table_args__ = (
        Index("ix_sync_overrides_user_uuid", "user_id", "uuid", unique=True),
        Index("ix_sync_overrides_user_synced", "user_id", "synced_at"),
    )
