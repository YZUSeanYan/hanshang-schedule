"""Privacy-minimised couple timetable APIs for the hosted Android module."""
from __future__ import annotations

import json
import secrets
from datetime import date, datetime, timedelta, timezone

from fastapi import APIRouter, Depends, Header, HTTPException, Query, Request
from pydantic import BaseModel, Field, field_validator
from sqlalchemy import delete, func, or_, select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session

from app.api.deps import require_module_user
from app.core.ratelimit import RateLimiter
from app.core.security import hash_scoped_secret
from app.db.session import get_db
from app.models.couple_schedule import CoupleConnection, CoupleMembership
from app.models.notification import UserNotification
from app.models.personal_event import SyncEvent
from app.models.sync_data import SyncCourse, SyncSchedule, SyncSemester
from app.models.user import User
from app.services.mobile_push import MobilePushUnavailable, send_account_notification

router = APIRouter(prefix="/couple-schedule", tags=["共同空闲"])
_module_user = require_module_user("couple_schedule", require_grant=False)
_alphabet = "23456789ABCDEFGHJKLMNPQRSTUVWXYZ"
_invite_limiter = RateLimiter(12, 60)
_respond_limiter = RateLimiter(12, 60)
_search_limiter = RateLimiter(20, 60)


class ClaimInviteIn(BaseModel):
    code: str = Field(min_length=8, max_length=8, pattern=r"^[2-9A-HJ-NP-Z]{8}$")


class CreateUsernameInviteIn(BaseModel):
    username: str = Field(min_length=1, max_length=32)

    @field_validator("username", mode="before")
    @classmethod
    def trim_username(cls, value: object) -> object:
        return value.strip() if isinstance(value, str) else value


class RespondInviteIn(BaseModel):
    invitation_id: str = Field(pattern=r"^[a-f0-9]{64}$")
    accept: bool


def _now() -> datetime:
    return datetime.now(timezone.utc).replace(tzinfo=None)


def _module_header(value: str | None = Header(default=None, alias="X-App-Module")) -> None:
    if value != "couple_schedule":
        raise HTTPException(
            status_code=403,
            detail={"code": 40331, "message": "请从邗上课表 App 打开此功能"},
        )


def _active_connection(db: Session, user_id: int) -> CoupleConnection | None:
    return db.scalar(
        select(CoupleConnection)
        .join(CoupleMembership, CoupleMembership.connection_id == CoupleConnection.id)
        .where(CoupleMembership.user_id == user_id, CoupleConnection.revoked_at.is_(None))
    )


def _limit_action(limiter: RateLimiter, request: Request, user_id: int, action: str) -> None:
    client_ip = request.client.host if request.client else "unknown"
    if not limiter.allow(f"{action}:user:{user_id}") or not limiter.allow(
        f"{action}:ip:{client_ip}"
    ):
        raise HTTPException(
            status_code=429,
            detail={"code": 42940, "message": "邀请操作过于频繁，请稍后再试"},
        )


def _pending_between(db: Session, *user_ids: int) -> list[CoupleConnection]:
    ids = set(user_ids)
    if not ids:
        return []
    return list(
        db.scalars(
            select(CoupleConnection).where(
                CoupleConnection.accepted_at.is_(None),
                CoupleConnection.revoked_at.is_(None),
                or_(
                    CoupleConnection.inviter_user_id.in_(ids),
                    CoupleConnection.partner_user_id.in_(ids),
                ),
            )
        ).all()
    )


def _notify_invitee(db: Session, *, invitation: CoupleConnection, sender: User, target: User) -> None:
    notice = UserNotification(
        user_id=target.id,
        title="共同空闲邀请",
        body=f"{sender.username} 邀请你一起查看双方都有空的时间。打开邗上课表后可接受或拒绝。",
        data_json=json.dumps(
            {
                "type": "shared_availability_invite",
                "route": "/features/couple_schedule",
                "invitation_id": invitation.invite_hash,
            },
            ensure_ascii=False,
            separators=(",", ":"),
        ),
        target_type="ACCOUNT",
        target_label="被邀请账号的全部 Android 设备",
    )
    db.add(notice)
    db.commit()
    try:
        notice.provider_message_id = send_account_notification(
            user_id=target.id,
            title=notice.title,
            body=notice.body,
            notification_id=notice.id,
        )
        notice.delivery_status = "accepted"
    except MobilePushUnavailable as error:
        notice.delivery_status = "stored"
        notice.delivery_error = str(error)[:500]
    except Exception as error:
        notice.delivery_status = "failed"
        notice.delivery_error = type(error).__name__[:500]
    db.commit()


def _partner_id(row: CoupleConnection, user_id: int) -> int:
    value = row.partner_user_id if row.inviter_user_id == user_id else row.inviter_user_id
    if value is None:
        raise HTTPException(status_code=409, detail={"code": 40941, "message": "尚未完成配对"})
    return value


def _status_data(db: Session, user: User) -> dict:
    connection = _active_connection(db, user.id)
    if connection is not None:
        partner = db.get(User, _partner_id(connection, user.id))
        if partner is None:
            db.execute(delete(CoupleMembership).where(CoupleMembership.connection_id == connection.id))
            db.delete(connection)
            db.commit()
        else:
            return {
                "state": "connected",
                "partner": {"username": partner.username},
                "connected_at": connection.accepted_at.isoformat() + "Z",
            }
    outgoing = db.scalar(
        select(CoupleConnection)
        .where(
            CoupleConnection.inviter_user_id == user.id,
            CoupleConnection.partner_user_id.is_not(None),
            CoupleConnection.accepted_at.is_(None),
            CoupleConnection.revoked_at.is_(None),
            CoupleConnection.invite_expires_at > _now(),
        )
        .order_by(CoupleConnection.id.desc())
    )
    if outgoing is not None:
        target = db.get(User, outgoing.partner_user_id)
        return {
            "state": "waiting",
            "invite_type": "username",
            "expires_at": outgoing.invite_expires_at.isoformat() + "Z",
            "outgoing": {
                "invitation_id": outgoing.invite_hash,
                "username": target.username if target is not None else "",
            },
        }
    incoming = list(
        db.scalars(
            select(CoupleConnection)
            .where(
                CoupleConnection.partner_user_id == user.id,
                CoupleConnection.accepted_at.is_(None),
                CoupleConnection.revoked_at.is_(None),
                CoupleConnection.invite_expires_at > _now(),
            )
            .order_by(CoupleConnection.id.desc())
            .limit(10)
        ).all()
    )
    if incoming:
        return {
            "state": "invited",
            "invitations": [
                {
                    "invitation_id": row.invite_hash,
                    "username": db.get(User, row.inviter_user_id).username,
                    "expires_at": row.invite_expires_at.isoformat() + "Z",
                }
                for row in incoming
                if db.get(User, row.inviter_user_id) is not None
            ],
        }
    legacy = db.scalar(
        select(CoupleConnection)
        .where(
            CoupleConnection.inviter_user_id == user.id,
            CoupleConnection.partner_user_id.is_(None),
            CoupleConnection.accepted_at.is_(None),
            CoupleConnection.revoked_at.is_(None),
            CoupleConnection.invite_expires_at > _now(),
        )
        .order_by(CoupleConnection.id.desc())
    )
    if legacy is not None:
        return {
            "state": "waiting",
            "invite_type": "code",
            "expires_at": legacy.invite_expires_at.isoformat() + "Z",
        }
    return {"state": "disconnected"}


@router.get("/status", dependencies=[Depends(_module_header)])
def status(user: User = Depends(_module_user), db: Session = Depends(get_db)) -> dict:
    return {"code": 0, "message": "ok", "data": _status_data(db, user)}


@router.get("/users/search", dependencies=[Depends(_module_header)])
def search_users(
    request: Request,
    q: str = Query(min_length=2, max_length=32),
    user: User = Depends(_module_user),
    db: Session = Depends(get_db),
) -> dict:
    """Return a small username-only prefix result set for an invite picker."""
    _limit_action(_search_limiter, request, user.id, "availability-search")
    query = q.strip()
    if len(query) < 2:
        raise HTTPException(
            status_code=422,
            detail={"code": 42246, "message": "请至少输入 2 个字符"},
        )
    lowered = query.lower()
    users = list(
        db.scalars(
            select(User)
            .where(
                User.id != user.id,
                func.lower(User.username).startswith(lowered, autoescape=True),
            )
            .order_by(
                (func.lower(User.username) == lowered).desc(),
                func.length(User.username),
                User.username,
            )
            .limit(5)
        ).all()
    )
    # SQLite LIKE is case-insensitive for ASCII, but keep this guard explicit
    # for database backends whose default collation differs.
    matches = [item for item in users if item.username.lower().startswith(lowered)]
    return {
        "code": 0,
        "message": "ok",
        "data": {"items": [{"username": item.username} for item in matches]},
    }


@router.post("/invites", dependencies=[Depends(_module_header)])
def create_invite(
    request: Request,
    data: CreateUsernameInviteIn | None = None,
    user: User = Depends(_module_user),
    db: Session = Depends(get_db),
) -> dict:
    _limit_action(_invite_limiter, request, user.id, "availability-invite")
    if _active_connection(db, user.id) is not None:
        raise HTTPException(status_code=409, detail={"code": 40940, "message": "你已与另一账号配对"})
    now = _now()
    old_rows = db.scalars(
        select(CoupleConnection).where(
            CoupleConnection.inviter_user_id == user.id,
            CoupleConnection.accepted_at.is_(None),
            CoupleConnection.revoked_at.is_(None),
        )
    ).all()
    for row in old_rows:
        row.revoked_at = now
    if data is not None:
        target = db.scalar(
            select(User).where(func.lower(User.username) == data.username.lower())
        )
        if (
            target is None
            or target.id == user.id
            or _active_connection(db, target.id) is not None
        ):
            # One generic response avoids disclosing whether an exact account
            # exists, is the caller, or is already connected.
            raise HTTPException(
                status_code=409,
                detail={
                    "code": 40946,
                    "message": "无法发送邀请，请检查用户名或让对方先解除已有连接",
                },
            )
        invitation = CoupleConnection(
            inviter_user_id=user.id,
            partner_user_id=target.id,
            invite_hash=secrets.token_hex(32),
            invite_expires_at=now + timedelta(days=7),
            created_at=now,
        )
        db.add(invitation)
        db.flush()
        _notify_invitee(db, invitation=invitation, sender=user, target=target)
        return {
            "code": 0,
            "message": "ok",
            "data": {
                "invitation_id": invitation.invite_hash,
                "username": target.username,
                "expires_at": invitation.invite_expires_at.isoformat() + "Z",
            },
        }
    code = "".join(secrets.choice(_alphabet) for _ in range(8))
    expires_at = now + timedelta(minutes=15)
    db.add(
        CoupleConnection(
            inviter_user_id=user.id,
            invite_hash=hash_scoped_secret("couple-invite", code),
            invite_expires_at=expires_at,
            created_at=now,
        )
    )
    db.commit()
    return {
        "code": 0,
        "message": "ok",
        "data": {"code": code, "expires_at": expires_at.isoformat() + "Z"},
    }


@router.post("/invites/respond", dependencies=[Depends(_module_header)])
def respond_to_invite(
    data: RespondInviteIn,
    request: Request,
    user: User = Depends(_module_user),
    db: Session = Depends(get_db),
) -> dict:
    _limit_action(_respond_limiter, request, user.id, "availability-respond")
    row = db.scalar(
        select(CoupleConnection).where(
            CoupleConnection.invite_hash == data.invitation_id,
            CoupleConnection.partner_user_id == user.id,
            CoupleConnection.accepted_at.is_(None),
            CoupleConnection.revoked_at.is_(None),
            CoupleConnection.invite_expires_at > _now(),
        )
    )
    if row is None:
        # The same 404 is returned for nonexistent and other users' objects.
        raise HTTPException(
            status_code=404,
            detail={"code": 40440, "message": "邀请不存在、已处理或已过期"},
        )
    if not data.accept:
        row.revoked_at = _now()
        db.commit()
        return {"code": 0, "message": "ok", "data": {"accepted": False}}
    if _active_connection(db, user.id) is not None or _active_connection(db, row.inviter_user_id) is not None:
        row.revoked_at = _now()
        db.commit()
        raise HTTPException(
            status_code=409,
            detail={"code": 40943, "message": "你或对方已建立其他连接"},
        )
    accepted_at = _now()
    row.accepted_at = accepted_at
    for pending in _pending_between(db, user.id, row.inviter_user_id):
        if pending.id != row.id:
            pending.revoked_at = accepted_at
    db.add_all(
        [
            CoupleMembership(
                user_id=row.inviter_user_id,
                connection_id=row.id,
                created_at=accepted_at,
            ),
            CoupleMembership(user_id=user.id, connection_id=row.id, created_at=accepted_at),
        ]
    )
    try:
        db.commit()
    except IntegrityError:
        db.rollback()
        raise HTTPException(
            status_code=409,
            detail={"code": 40945, "message": "你或对方刚刚建立了其他连接，请刷新后重试"},
        )
    return {"code": 0, "message": "ok", "data": _status_data(db, user)}


@router.delete("/invites/{invitation_id}", dependencies=[Depends(_module_header)])
def cancel_username_invite(
    invitation_id: str,
    request: Request,
    user: User = Depends(_module_user),
    db: Session = Depends(get_db),
) -> dict:
    _limit_action(_respond_limiter, request, user.id, "availability-cancel")
    if not secrets.compare_digest(
        invitation_id,
        invitation_id.lower(),
    ) or not all(char in "0123456789abcdef" for char in invitation_id) or len(invitation_id) != 64:
        raise HTTPException(status_code=404, detail={"code": 40440, "message": "邀请不存在"})
    row = db.scalar(
        select(CoupleConnection).where(
            CoupleConnection.invite_hash == invitation_id,
            CoupleConnection.inviter_user_id == user.id,
            CoupleConnection.accepted_at.is_(None),
            CoupleConnection.revoked_at.is_(None),
        )
    )
    if row is None:
        raise HTTPException(status_code=404, detail={"code": 40440, "message": "邀请不存在"})
    row.revoked_at = _now()
    db.commit()
    return {"code": 0, "message": "ok", "data": {"cancelled": True}}


@router.post("/claim", dependencies=[Depends(_module_header)])
def claim_invite(
    data: ClaimInviteIn,
    request: Request,
    user: User = Depends(_module_user),
    db: Session = Depends(get_db),
) -> dict:
    _limit_action(_respond_limiter, request, user.id, "availability-claim")
    if _active_connection(db, user.id) is not None:
        raise HTTPException(status_code=409, detail={"code": 40940, "message": "你已与另一账号配对"})
    row = db.scalar(
        select(CoupleConnection).where(
            CoupleConnection.invite_hash
            == hash_scoped_secret("couple-invite", data.code.upper()),
            CoupleConnection.partner_user_id.is_(None),
            CoupleConnection.accepted_at.is_(None),
            CoupleConnection.revoked_at.is_(None),
            CoupleConnection.invite_expires_at > _now(),
        )
    )
    if row is None:
        raise HTTPException(status_code=404, detail={"code": 40440, "message": "配对码无效或已过期"})
    if row.inviter_user_id == user.id:
        raise HTTPException(status_code=409, detail={"code": 40942, "message": "不能与自己的账号配对"})
    if _active_connection(db, row.inviter_user_id) is not None:
        row.revoked_at = _now()
        db.commit()
        raise HTTPException(status_code=409, detail={"code": 40943, "message": "对方已完成其他配对"})
    row.partner_user_id = user.id
    row.accepted_at = _now()
    db.add_all([
        CoupleMembership(user_id=row.inviter_user_id, connection_id=row.id, created_at=row.accepted_at),
        CoupleMembership(user_id=user.id, connection_id=row.id, created_at=row.accepted_at),
    ])
    try:
        db.commit()
    except IntegrityError:
        db.rollback()
        raise HTTPException(
            status_code=409,
            detail={"code": 40945, "message": "你或对方刚刚完成了其他配对，请刷新后重试"},
        )
    return {"code": 0, "message": "ok", "data": _status_data(db, user)}


@router.delete("/invite-code", dependencies=[Depends(_module_header)])
def cancel_invite_code(
    request: Request,
    user: User = Depends(_module_user),
    db: Session = Depends(get_db),
) -> dict:
    _limit_action(_respond_limiter, request, user.id, "availability-code-cancel")
    rows = db.scalars(
        select(CoupleConnection).where(
            CoupleConnection.inviter_user_id == user.id,
            CoupleConnection.partner_user_id.is_(None),
            CoupleConnection.accepted_at.is_(None),
            CoupleConnection.revoked_at.is_(None),
        )
    ).all()
    now = _now()
    for row in rows:
        row.revoked_at = now
    db.commit()
    return {"code": 0, "message": "ok", "data": {"cancelled": bool(rows)}}


@router.delete("/connection", dependencies=[Depends(_module_header)])
def revoke_connection(
    user: User = Depends(_module_user), db: Session = Depends(get_db)
) -> dict:
    rows = db.scalars(
        select(CoupleConnection).where(
            CoupleConnection.revoked_at.is_(None),
            or_(
                CoupleConnection.inviter_user_id == user.id,
                CoupleConnection.partner_user_id == user.id,
            ),
        )
    ).all()
    for row in rows:
        db.execute(delete(CoupleMembership).where(CoupleMembership.connection_id == row.id))
        db.delete(row)
    db.commit()
    return {"code": 0, "message": "ok", "data": {"disconnected": True}}


def _semester_for(db: Session, user_id: int, monday: date) -> tuple[SyncSemester, int] | None:
    rows = db.scalars(
        select(SyncSemester).where(
            SyncSemester.user_id == user_id,
            SyncSemester.deleted.is_(False),
        ).order_by(SyncSemester.is_current.desc(), SyncSemester.updated_at.desc())
    ).all()
    for row in rows:
        try:
            start = date.fromisoformat(row.start_date)
        except ValueError:
            continue
        delta = (monday - start).days
        if delta >= 0 and delta % 7 == 0 and delta // 7 < row.total_weeks:
            return row, delta // 7 + 1
    return None


def _custom_weeks_contains(value: str, week: int) -> bool:
    for part in value.split(","):
        part = part.strip()
        if not part:
            continue
        if "-" in part:
            left, _, right = part.partition("-")
            if left.isdigit() and right.isdigit() and int(left) <= week <= int(right):
                return True
        elif part.isdigit() and int(part) == week:
            return True
    return False


def _occurs(weeks_type: int, custom_weeks: str, week: int) -> bool:
    if weeks_type == 0:
        return True
    if weeks_type == 1:
        return week % 2 == 1
    if weeks_type == 2:
        return week % 2 == 0
    return weeks_type == 3 and _custom_weeks_contains(custom_weeks, week)


def _busy_grid(db: Session, user_id: int, monday: date) -> set[tuple[int, int]]:
    semester_week = _semester_for(db, user_id, monday)
    if semester_week is None:
        return set()
    semester, week = semester_week
    rows = db.scalars(
        select(SyncSchedule).where(
            SyncSchedule.user_id == user_id,
            SyncSchedule.deleted.is_(False),
            SyncSchedule.course_uuid.in_(
                select(SyncCourse.uuid).where(
                    SyncCourse.user_id == user_id,
                    SyncCourse.semester_uuid == semester.uuid,
                    SyncCourse.deleted.is_(False),
                )
            ),
        )
    ).all()
    busy: set[tuple[int, int]] = set()
    for row in rows:
        if not _occurs(row.weeks_type, row.custom_weeks, week):
            continue
        if not 1 <= row.day_of_week <= 7:
            continue
        for section in range(max(1, row.start_section), min(20, row.end_section) + 1):
            busy.add((row.day_of_week, section))
    return busy


def _event_sections(row: SyncEvent) -> list[int]:
    """日程占用的节次：优先用客户端算好的 busy_sections（按本地作息），
    没有则用节次表达的原值；只有时刻没有节次的日程不参与占用。"""
    if row.busy_sections:
        sections: list[int] = []
        for piece in row.busy_sections.split(","):
            piece = piece.strip()
            if piece.isdigit() and 1 <= int(piece) <= 20:
                sections.append(int(piece))
        return sections
    if 1 <= row.start_section <= 20 and 1 <= row.end_section <= 20:
        return list(range(row.start_section, min(20, row.end_section) + 1))
    return []


def _event_busy_grid(db: Session, user_id: int, monday: date) -> set[tuple[int, int]]:
    """AI 日程 2.0：个人日程并入共同空闲。DDL 只占日期不占时间块，不计入。"""
    sunday = monday + timedelta(days=6)
    rows = db.scalars(
        select(SyncEvent).where(
            SyncEvent.user_id == user_id,
            SyncEvent.deleted.is_(False),
        )
    ).all()
    busy: set[tuple[int, int]] = set()
    for row in rows:
        if row.event_type == "ddl":
            continue
        days: list[int] = []
        if row.event_type == "recurring":
            if 1 <= row.weekday <= 7:
                days = [row.weekday]
        elif row.date:
            try:
                event_date = date.fromisoformat(row.date)
            except ValueError:
                continue
            if monday <= event_date <= sunday:
                days = [event_date.isoweekday()]
        for day in days:
            for section in _event_sections(row):
                busy.add((day, section))
    return busy


@router.get("/week", dependencies=[Depends(_module_header)])
def week_view(
    week_start: date = Query(description="周一日期 YYYY-MM-DD"),
    user: User = Depends(_module_user),
    db: Session = Depends(get_db),
) -> dict:
    if week_start.weekday() != 0 or abs((week_start - date.today()).days) > 370:
        raise HTTPException(status_code=422, detail={"code": 42240, "message": "请选择一年内的周一"})
    connection = _active_connection(db, user.id)
    if connection is None:
        raise HTTPException(status_code=409, detail={"code": 40941, "message": "请先完成双方配对"})
    partner_id = _partner_id(connection, user.id)
    partner = db.get(User, partner_id)
    if partner is None:
        raise HTTPException(status_code=409, detail={"code": 40944, "message": "配对关系已失效"})
    mine = _busy_grid(db, user.id, week_start) | _event_busy_grid(db, user.id, week_start)
    theirs = _busy_grid(db, partner_id, week_start) | _event_busy_grid(db, partner_id, week_start)
    section_count = max(12, max((section for _, section in mine | theirs), default=0))
    days = []
    for day in range(1, 8):
        states = []
        for section in range(1, section_count + 1):
            me_busy = (day, section) in mine
            partner_busy = (day, section) in theirs
            states.append(
                "both_busy" if me_busy and partner_busy else
                "me_busy" if me_busy else
                "partner_busy" if partner_busy else "both_free"
            )
        days.append({"day": day, "date": (week_start + timedelta(days=day - 1)).isoformat(), "states": states})
    return {
        "code": 0,
        "message": "ok",
        "data": {
            "week_start": week_start.isoformat(),
            "partner": {"username": partner.username},
            "section_count": section_count,
            "days": days,
        },
    }
