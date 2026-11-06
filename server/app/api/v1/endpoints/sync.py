"""云端同步端点（设计文档阶段 4）。

- POST /sync/push：批量上传本地变更，按 uuid + updated_at 做 last-write-wins；
  服务端只接受"比库存记录更新"的写入，返回实际应用条数与冲突（被拒）条数。
- GET  /sync/pull：按 synced_at 游标增量拉取（含墓碑），
  客户端保存返回的 cursor 作为下次拉取起点。

幂等性：push 重复提交同批数据是安全的（updated_at 相同 → 不覆盖）。
"""
import time

from fastapi import APIRouter, Depends, Query
from sqlalchemy import select
from sqlalchemy.orm import Session

from app.api.deps import get_current_user
from app.db.session import get_db
from app.models.personal_event import SyncEvent, SyncOverride
from app.models.sync_data import SyncCourse, SyncSchedule, SyncSemester
from app.models.user import User
from app.schemas.sync import SyncPushIn

router = APIRouter(tags=["同步"])

# (模型, 请求字段列表) 三元组驱动批量 upsert，几张表逻辑完全一致
_TABLES = (
    (SyncSemester, "semesters"),
    (SyncCourse, "courses"),
    (SyncSchedule, "schedules"),
    (SyncEvent, "events"),
    (SyncOverride, "overrides"),
)

_MAX_NORMALIZED_WEEKS = 200


def normalize_weeks(value: str) -> str:
    """把客户端各种周次写法统一成逗号分隔整数列表（如 "1-18" → "1,2,…,18"）。

    Web 端写范围（"1-8,10,12"），App 写平铺列表（"1,2,3,…"），而 App 的
    同步解析器只认平铺列表；不规范化会让混用两端的数据在 App 端解析失败。
    """
    if not value:
        return ""
    result: list[int] = []
    for piece in str(value).split(","):
        piece = piece.strip()
        if not piece:
            continue
        if "-" in piece:
            try:
                start, end = (int(x) for x in piece.split("-", 1))
            except ValueError:
                continue
            if end < start:
                start, end = end, start
            if end - start + 1 > _MAX_NORMALIZED_WEEKS:
                end = start + _MAX_NORMALIZED_WEEKS - 1
            result.extend(range(start, end + 1))
        else:
            try:
                result.append(int(piece))
            except ValueError:
                continue
        if len(result) > _MAX_NORMALIZED_WEEKS:
            result = result[:_MAX_NORMALIZED_WEEKS]
            break
    return ",".join(str(w) for w in dict.fromkeys(result))  # 去重保序


def _normalize_schedule_items(items: list) -> None:
    """就地规范化排课记录里的 custom_weeks（防范围写法破坏 App 解析）。"""
    for item in items:
        raw = getattr(item, "custom_weeks", None)
        if raw:
            item.custom_weeks = normalize_weeks(raw)


def _upsert(db: Session, model, user_id: int, items: list) -> tuple[int, int]:
    """对单张表执行 LWW upsert，返回 (应用条数, 冲突条数)。"""
    applied = 0
    conflicts = 0
    if not items:
        return applied, conflicts
    uuids = [item.uuid for item in items]
    existing_by_uuid = {
        row.uuid: row
        for row in db.scalars(
            select(model).where(model.user_id == user_id, model.uuid.in_(uuids))
        ).all()
    }
    for item in items:
        data = item.model_dump()
        if model is SyncSchedule:
            data["custom_weeks"] = normalize_weeks(data.get("custom_weeks", ""))
        uuid = data.pop("uuid")
        existing = existing_by_uuid.get(uuid)
        now_ns = time.time_ns()
        if existing is None:
            row = model(user_id=user_id, uuid=uuid, synced_at=now_ns, **data)
            db.add(row)
            existing_by_uuid[uuid] = row
            applied += 1
        elif data["updated_at"] > existing.updated_at:
            # 客户端记录更新 → 覆盖（last-write-wins）
            for k, v in data.items():
                setattr(existing, k, v)
            existing.synced_at = now_ns
            applied += 1
        else:
            # 服务端记录更新或一样新 → 拒绝，客户端下次 pull 会拿到服务端版本
            conflicts += 1
    return applied, conflicts


def _normalize_current_semesters(db: Session, user_id: int) -> int:
    """保证一个用户恰好保留一个未删除的当前学期，并让修复可增量下发。

    `is_current` 是跨多行的不变量，不能由单行 uuid 的 LWW 自动保证。
    两种失衡都要修：

    - **多个**当前学期：以客户端 `updated_at` 最新者为赢家；平局时用服务端
      入库时间和 uuid 确定性裁决。
    - **零个**当前学期：没有当前学期时，网页版会兜底取最新学期（app.js 的
      currentSemester 回退）所以看着一切正常，但 App 三处都严格按
      `is_current = true` 取学期——课表页、课前提醒、桌面小组件——结果是
      整个课表空白，且用户自己没有任何入口能恢复。常见成因是删掉当前学期
      后没有补选，或旧客户端把 `is_current= false` 写回了当前学期。

    两种修复都刷新 LWW 时间与同步游标（`synced_at`），旧客户端下次 pull
    也能自愈：pull 按 `synced_at > since` 增量下发，不刷新游标就传不出去。
    """
    # 测试与部分部署会关闭 autoflush；显式 flush 才能让同一 push 请求刚
    # 插入/更新的学期参与跨行不变量裁决，同时仍处于同一事务、可整体回滚。
    db.flush()
    active = db.scalars(
        select(SyncSemester).where(
            SyncSemester.user_id == user_id,
            SyncSemester.deleted.is_(False),
        )
    ).all()
    current = [row for row in active if row.is_current]

    if not current:
        if not active:
            return 0
        # 取最近更新的一个，与网页版 currentSemester 的回退规则一致，
        # 避免服务端和网页版对“该显示哪个学期”给出不同答案。
        winner = max(active, key=lambda row: (row.updated_at, row.synced_at, row.uuid))
        winner.is_current = True
        winner.updated_at = max(int(time.time() * 1000), winner.updated_at + 1)
        winner.synced_at = time.time_ns()
        return 1

    if len(current) == 1:
        return 0

    current.sort(key=lambda row: (row.updated_at, row.synced_at, row.uuid), reverse=True)
    repair_updated_at = max(
        int(time.time() * 1000),
        max(row.updated_at for row in current) + 1,
    )
    for offset, row in enumerate(current[1:]):
        row.is_current = False
        row.updated_at = repair_updated_at + offset
        row.synced_at = time.time_ns()
    return len(current) - 1


@router.post("/sync/push", summary="上传本地变更（LWW 合并）")
def sync_push(
    data: SyncPushIn,
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> dict:
    result = {"applied": {}, "conflicts": {}}
    for model, field in _TABLES:
        applied, conflicts = _upsert(db, model, user.id, getattr(data, field))
        result["applied"][field] = applied
        result["conflicts"][field] = conflicts
    result["repaired_current_semesters"] = _normalize_current_semesters(db, user.id)
    db.commit()
    return {"code": 0, "message": "ok", "data": result}


def _dump(model, rows: list) -> list[dict]:
    """模型行 → 同步字典（去掉内部 id/user_id，保留 uuid 与墓碑）。"""
    skip = {"id", "user_id"}
    dumped = [
        {k: v for k, v in row.__dict__.items() if not k.startswith("_") and k not in skip}
        for row in rows
    ]
    if model is SyncSchedule:
        # 历史遗留的范围写法（如 "1-18"）在读取时也归一化，存量数据自愈，
        # 保证任何版本客户端拿到的都是平铺列表。
        for item in dumped:
            raw = item.get("custom_weeks")
            if raw:
                item["custom_weeks"] = normalize_weeks(raw)
    return dumped




def _record_activity(db, user_id: int) -> None:
    """同步/refresh 时埋点当日活跃（INSERT OR IGNORE，绝不阻断主流程）。"""
    from datetime import date as _date
    from sqlalchemy import text
    try:
        db.execute(
            text(
                "INSERT OR IGNORE INTO daily_activity (user_id, activity_date, created_at) "
                "VALUES (:uid, :d, datetime('now'))"
            ),
            {"uid": user_id, "d": _date.today().isoformat()},
        )
        db.commit()
    except Exception:
        pass


@router.get("/sync/pull", summary="增量拉取云端变更")
def sync_pull(
    since: int = Query(0, description="上次拉取返回的 cursor（synced_at），首次传 0 全量"),
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> dict:
    # 读取时也做一次廉价自愈，覆盖历史脏数据与旧客户端遗留状态。
    if _normalize_current_semesters(db, user.id):
        db.commit()
    data: dict = {}
    cursor = since
    for model, field in _TABLES:
        rows = db.scalars(
            select(model)
            .where(model.user_id == user.id, model.synced_at > since)
            .order_by(model.synced_at)
        ).all()
        data[field] = _dump(model, rows)
        for row in rows:
            cursor = max(cursor, row.synced_at)
    _record_activity(db, user.id)
    db.commit()
    data["cursor"] = cursor
    return {"code": 0, "message": "ok", "data": data}
