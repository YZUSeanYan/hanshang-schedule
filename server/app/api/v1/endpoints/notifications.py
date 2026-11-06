"""Authenticated in-app notification inbox."""
import json
from datetime import datetime, timedelta, timezone

from fastapi import APIRouter, Depends, HTTPException, Query
from sqlalchemy import delete, func, select, update
from sqlalchemy.orm import Session

from app.api.deps import get_current_user
from app.core.config import get_settings
from app.db.session import get_db
from app.models.notification import UserNotification, UserPushDevice
from app.models.user import User
from app.schemas.notification import PushDeviceRegistrationIn
from app.services.mobile_push import account_for_user

router = APIRouter(prefix="/notifications", tags=["notifications"])


def _utc_iso(value: datetime | None) -> str | None:
    if value is None:
        return None
    if value.tzinfo is None:
        value = value.replace(tzinfo=timezone.utc)
    return value.astimezone(timezone.utc).isoformat()


def _item(row: UserNotification) -> dict:
    try:
        data = json.loads(row.data_json)
        if not isinstance(data, dict):
            data = {}
    except (TypeError, ValueError, json.JSONDecodeError):
        data = {}
    return {
        "id": row.id,
        "title": row.title,
        "body": row.body,
        "delivery_status": row.delivery_status,
        "created_at": _utc_iso(row.created_at),
        "read_at": _utc_iso(row.read_at),
        "data": data,
    }


@router.get("")
def list_notifications(
    limit: int = Query(default=50, ge=1, le=100),
    before_id: int | None = Query(default=None, ge=1),
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> dict:
    query = select(UserNotification).where(UserNotification.user_id == user.id)
    if before_id is not None:
        query = query.where(UserNotification.id < before_id)
    rows = list(db.scalars(
        query.order_by(UserNotification.id.desc()).limit(limit + 1)
    ).all())
    has_more = len(rows) > limit
    items = rows[:limit]
    unread = db.scalar(
        select(func.count()).select_from(UserNotification).where(
            UserNotification.user_id == user.id,
            UserNotification.read_at.is_(None),
        )
    ) or 0
    return {"code": 0, "message": "ok", "data": {
        "items": [_item(row) for row in items],
        "unread": unread,
        "has_more": has_more,
        "next_before_id": items[-1].id if has_more else None,
    }}


@router.get("/binding")
def binding(user: User = Depends(get_current_user)) -> dict:
    return {"code": 0, "message": "ok", "data": {"account": account_for_user(user.id)}}


@router.post("/devices")
def register_device(
    data: PushDeviceRegistrationIn,
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> dict:
    device_id = data.device_id.strip()
    label = data.label.strip()
    if not device_id or not label:
        raise HTTPException(status_code=422, detail={"code": 42232, "message": "设备信息不能为空"})
    now = datetime.now(timezone.utc).replace(tzinfo=None)
    expiry_cutoff = now - timedelta(days=get_settings().push_device_expire_days)
    db.execute(delete(UserPushDevice).where(UserPushDevice.last_seen_at < expiry_cutoff))
    row = db.scalar(select(UserPushDevice).where(UserPushDevice.device_id == device_id))
    if row is None:
        row = UserPushDevice(user_id=user.id, device_id=device_id)
        db.add(row)
    # 同一设备改登其他账号时重新归属，避免继续向旧账号暴露该设备。
    row.user_id = user.id
    row.label = label
    row.platform = data.platform.strip().lower()
    row.app_version = data.app_version.strip()
    row.last_seen_at = now
    db.commit()
    return {"code": 0, "message": "ok", "data": {"registered": True}}


@router.delete("/devices/{device_id}")
def unregister_device(
    device_id: str,
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> dict:
    """Remove only the caller's matching native push registration."""
    result = db.execute(delete(UserPushDevice).where(
        UserPushDevice.user_id == user.id,
        UserPushDevice.device_id == device_id,
    ))
    db.commit()
    return {
        "code": 0,
        "message": "ok",
        "data": {"unregistered": bool(result.rowcount)},
    }


@router.post("/{notification_id}/read")
def mark_read(
    notification_id: int,
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> dict:
    row = db.scalar(select(UserNotification).where(
        UserNotification.id == notification_id,
        UserNotification.user_id == user.id,
    ))
    if row is None:
        raise HTTPException(status_code=404, detail={"code": 40431, "message": "通知不存在"})
    if row.read_at is None:
        row.read_at = datetime.now(timezone.utc).replace(tzinfo=None)
        db.commit()
    return {"code": 0, "message": "ok", "data": {"read": True}}


@router.post("/read-all")
def mark_all_read(
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> dict:
    now = datetime.now(timezone.utc).replace(tzinfo=None)
    result = db.execute(update(UserNotification).where(
        UserNotification.user_id == user.id,
        UserNotification.read_at.is_(None),
    ).values(read_at=now))
    db.commit()
    return {"code": 0, "message": "ok", "data": {"updated": result.rowcount or 0}}


@router.delete("/{notification_id}")
def delete_notification(
    notification_id: int,
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> dict:
    row = db.scalar(select(UserNotification).where(
        UserNotification.id == notification_id,
        UserNotification.user_id == user.id,
    ))
    if row is None:
        raise HTTPException(status_code=404, detail={"code": 40431, "message": "通知不存在"})
    db.delete(row)
    db.commit()
    return {"code": 0, "message": "ok", "data": {"deleted": True}}


@router.delete("")
def clear_notifications(
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> dict:
    result = db.execute(delete(UserNotification).where(
        UserNotification.user_id == user.id,
    ))
    db.commit()
    return {"code": 0, "message": "ok", "data": {"deleted": result.rowcount or 0}}
