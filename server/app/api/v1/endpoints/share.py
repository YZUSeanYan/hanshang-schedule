"""Schedule snapshot sharing.

This module intentionally works only with the existing per-user sync tables.
It therefore gives Android and the Web companion the same data contract without
ever reading browser/WebView cookies or education-system credentials.
"""
import json
import secrets
import time
from datetime import datetime, timedelta, timezone
from uuid import uuid4

from fastapi import APIRouter, Depends, HTTPException, Request
from sqlalchemy import select
from sqlalchemy.orm import Session

from app.api.deps import get_current_user
from app.api.v1.endpoints.sync import normalize_weeks
from app.core.ratelimit import RateLimiter, make_rate_limit_dependency
from app.db.session import get_db
from app.models.share_code import ShareCode
from app.models.sync_data import SyncCourse, SyncSchedule, SyncSemester
from app.models.user import User
from app.schemas.share import (
    ShareClaimIn,
    ShareClaimOut,
    ShareCodeOut,
    ShareCreateIn,
    SharePreviewOut,
)
from app.services.import_events import record_import_event

router = APIRouter(prefix="/share", tags=["课表分享"])

_ALPHABET = "ABCDEFGHJKMNPQRSTUVWXYZ23456789"
_CODE_TTL = timedelta(days=7)
_create_limiter = RateLimiter(10, 60)
_read_limiter = RateLimiter(10, 60)
_create_rate_limited = Depends(make_rate_limit_dependency(_create_limiter, "share-create"))
_read_rate_limited = Depends(make_rate_limit_dependency(_read_limiter, "share-read"))


def _now() -> datetime:
    # SQLite stores the existing project timestamps without tzinfo.  Keep that
    # representation while deriving the value from UTC explicitly.
    return datetime.now(timezone.utc).replace(tzinfo=None)


def _not_found() -> HTTPException:
    # Use the same response for unknown, expired and revoked codes.  It avoids
    # leaking which short codes have ever existed.
    return HTTPException(
        status_code=404,
        detail={"code": 40410, "message": "口令已失效，让同学重新分享一个吧"},
    )


def _active_code(db: Session, code: str) -> ShareCode:
    record = db.scalar(select(ShareCode).where(ShareCode.code == code.upper()))
    if record is None or record.is_revoked or record.expires_at <= _now():
        raise _not_found()
    return record


def _new_code(db: Session) -> str:
    # Checking before insertion makes a collision extraordinarily unlikely;
    # the unique index remains the final integrity guard.
    for _ in range(20):
        code = "".join(secrets.choice(_ALPHABET) for _ in range(6))
        if db.scalar(select(ShareCode.id).where(ShareCode.code == code)) is None:
            return code
    raise HTTPException(status_code=503, detail={"code": 50310, "message": "口令生成繁忙，请稍后重试"})


def _snapshot_for_semester(db: Session, user_id: int, semester_uuid: str) -> dict:
    semester = db.scalar(
        select(SyncSemester).where(
            SyncSemester.user_id == user_id,
            SyncSemester.uuid == semester_uuid,
            SyncSemester.deleted.is_(False),
        )
    )
    if semester is None:
        raise HTTPException(status_code=404, detail={"code": 40411, "message": "未找到可分享的学期，请先同步课表"})

    courses = db.scalars(
        select(SyncCourse).where(
            SyncCourse.user_id == user_id,
            SyncCourse.semester_uuid == semester.uuid,
            SyncCourse.deleted.is_(False),
        )
    ).all()
    if not courses:
        raise HTTPException(status_code=400, detail={"code": 40010, "message": "该学期还没有可分享的课程"})
    course_ids = [course.uuid for course in courses]
    slots = db.scalars(
        select(SyncSchedule).where(
            SyncSchedule.user_id == user_id,
            SyncSchedule.course_uuid.in_(course_ids),
            SyncSchedule.deleted.is_(False),
        )
    ).all()
    slots_by_course: dict[str, list[dict]] = {course_id: [] for course_id in course_ids}
    for slot in slots:
        slots_by_course.setdefault(slot.course_uuid, []).append(
            {
                "day_of_week": slot.day_of_week,
                "start_section": slot.start_section,
                "end_section": slot.end_section,
                "weeks_type": slot.weeks_type,
                "custom_weeks": normalize_weeks(slot.custom_weeks),
                "location": slot.location,
            }
        )
    return {
        "version": 1,
        "semester": {
            "name": semester.name,
            "start_date": semester.start_date,
            "total_weeks": semester.total_weeks,
        },
        "courses": [
            {
                "name": course.name,
                "short_name": getattr(course, "short_name", ""),
                "teacher": course.teacher,
                "color": course.color,
                "slots": slots_by_course.get(course.uuid, []),
            }
            for course in courses
        ],
    }


@router.post("/create", response_model=None, dependencies=[_create_rate_limited])
def create_share_code(
    data: ShareCreateIn,
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> dict:
    snapshot = _snapshot_for_semester(db, user.id, data.semester_uuid)
    expires_at = _now() + _CODE_TTL
    record = ShareCode(
        code=_new_code(db),
        owner_user_id=user.id,
        semester_uuid=data.semester_uuid,
        payload=json.dumps(snapshot, ensure_ascii=False, separators=(",", ":")),
        expires_at=expires_at,
    )
    db.add(record)
    db.commit()
    return {"code": 0, "message": "ok", "data": ShareCodeOut(code=record.code, expires_at=expires_at).model_dump(mode="json")}


@router.get("/{code}", dependencies=[_read_rate_limited])
def preview_share_code(
    code: str,
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> dict:
    try:
        record = _active_code(db, code)
    except HTTPException as exc:
        code_value = str(exc.detail.get("code", "")) if isinstance(exc.detail, dict) else ""
        record_import_event(
            db, user_id=user.id, entry="sharecode", stage="preview",
            outcome="fail", error_code=code_value, source="server",
        )
        raise
    record_import_event(
        db, user_id=user.id, entry="sharecode", stage="preview",
        outcome="success", source="server",
    )
    preview = SharePreviewOut(
        code=record.code,
        expires_at=record.expires_at,
        use_count=record.use_count,
        payload=json.loads(record.payload),
    )
    return {"code": 0, "message": "ok", "data": preview.model_dump(mode="json")}


def _matching_semesters(db: Session, user_id: int, snapshot: dict) -> list[SyncSemester]:
    semester = snapshot["semester"]
    return db.scalars(
        select(SyncSemester).where(
            SyncSemester.user_id == user_id,
            SyncSemester.name == semester["name"],
            SyncSemester.start_date == semester["start_date"],
            SyncSemester.deleted.is_(False),
        )
    ).all()


def _replace_semesters(db: Session, user_id: int, semesters: list[SyncSemester]) -> None:
    now_ms = int(time.time() * 1000)
    now_ns = time.time_ns()
    for semester in semesters:
        courses = db.scalars(
            select(SyncCourse).where(
                SyncCourse.user_id == user_id,
                SyncCourse.semester_uuid == semester.uuid,
                SyncCourse.deleted.is_(False),
            )
        ).all()
        course_ids = [course.uuid for course in courses]
        if course_ids:
            for slot in db.scalars(
                select(SyncSchedule).where(
                    SyncSchedule.user_id == user_id,
                    SyncSchedule.course_uuid.in_(course_ids),
                    SyncSchedule.deleted.is_(False),
                )
            ):
                slot.deleted, slot.updated_at, slot.synced_at = True, now_ms, now_ns
        for course in courses:
            course.deleted, course.updated_at, course.synced_at = True, now_ms, now_ns
        semester.deleted, semester.updated_at, semester.synced_at = True, now_ms, now_ns


def _claim_snapshot(db: Session, user_id: int, snapshot: dict) -> str:
    now_ms = int(time.time() * 1000)
    semester_uuid = str(uuid4())
    now_ns = time.time_ns()
    semester = snapshot["semester"]
    db.add(SyncSemester(
        user_id=user_id,
        uuid=semester_uuid,
        name=semester["name"],
        start_date=semester["start_date"],
        total_weeks=semester["total_weeks"],
        is_current=False,
        updated_at=now_ms,
        deleted=False,
        synced_at=now_ns,
    ))
    for course_data in snapshot["courses"]:
        course_uuid = str(uuid4())
        db.add(SyncCourse(
            user_id=user_id,
            uuid=course_uuid,
            semester_uuid=semester_uuid,
            name=course_data["name"],
            short_name=str(course_data.get("short_name", ""))[:16],
            teacher=course_data.get("teacher", ""),
            color=course_data.get("color", 0),
            # Free-form notes can contain personal information.  A shared
            # snapshot intentionally keeps only timetable fields.
            note="",
            updated_at=now_ms,
            deleted=False,
            synced_at=time.time_ns(),
        ))
        for slot_data in course_data.get("slots", []):
            db.add(SyncSchedule(
                user_id=user_id,
                uuid=str(uuid4()),
                course_uuid=course_uuid,
                day_of_week=slot_data["day_of_week"],
                start_section=slot_data["start_section"],
                end_section=slot_data["end_section"],
                weeks_type=slot_data["weeks_type"],
                custom_weeks=normalize_weeks(slot_data.get("custom_weeks", "")),
                location=slot_data.get("location", ""),
                updated_at=now_ms,
                deleted=False,
                synced_at=time.time_ns(),
            ))
    return semester_uuid


@router.post("/{code}/claim", dependencies=[_read_rate_limited])
def claim_share_code(
    code: str,
    data: ShareClaimIn,
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> dict:
    try:
        record = _active_code(db, code)
    except HTTPException as exc:
        code_value = str(exc.detail.get("code", "")) if isinstance(exc.detail, dict) else ""
        record_import_event(
            db, user_id=user.id, entry="sharecode", stage="apply",
            outcome="fail", error_code=code_value, source="server",
        )
        raise
    snapshot = json.loads(record.payload)
    existing = _matching_semesters(db, user.id, snapshot)
    if existing and not data.replace_existing:
        record_import_event(
            db, user_id=user.id, entry="sharecode", stage="apply",
            outcome="fail", error_code="40910", source="server",
        )
        raise HTTPException(status_code=409, detail={"code": 40910, "message": "你已有同一学期的课表，请确认是否覆盖"})
    if existing:
        _replace_semesters(db, user.id, existing)
    semester_uuid = _claim_snapshot(db, user.id, snapshot)
    record.use_count += 1
    db.commit()
    record_import_event(
        db, user_id=user.id, entry="sharecode", stage="apply",
        outcome="success", source="server",
    )
    return {
        "code": 0,
        "message": "ok",
        "data": ShareClaimOut(semester_uuid=semester_uuid, course_count=len(snapshot["courses"])).model_dump(),
    }


@router.delete("/{code}", dependencies=[_create_rate_limited])
def revoke_share_code(
    code: str,
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> dict:
    record = db.scalar(select(ShareCode).where(ShareCode.code == code.upper()))
    if record is None or record.owner_user_id != user.id:
        raise _not_found()
    record.is_revoked = True
    db.commit()
    return {"code": 0, "message": "ok", "data": {"revoked": True}}
