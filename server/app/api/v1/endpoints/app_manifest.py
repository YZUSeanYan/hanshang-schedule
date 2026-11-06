"""Signed next-generation app manifest and scoped hosted-module sessions.

The private Ed25519 signing key is deliberately not present on this server.
Operations publishes an already-signed envelope to /data. The API only serves
that bounded file and creates a short-lived, module-scoped browser ticket for
authenticated users.
"""
from __future__ import annotations

import base64
import json
import re
import time
from pathlib import Path
from urllib.parse import urlparse

from fastapi import APIRouter, Depends, HTTPException, Request, Response
from pydantic import BaseModel, Field

from app.api.deps import get_current_user, require_admin
from app.core.security import create_module_token
from app.core.token_sessions import current_token_version
from app.db.session import get_db
from app.models.user import User
from app.models.release_target import AppFeatureGrant
from sqlalchemy import delete, or_, select
from sqlalchemy.orm import Session

router = APIRouter()
MANIFEST_FILE = Path("/data/app-manifest-v1.json")
MAX_BYTES = 131072
_TRUSTED_MODULE_HOST = "hanshang.seanyan.store"
_TRUSTED_MODULE_PREFIX = "/web/modules/"


class ModuleSessionIn(BaseModel):
    module_id: str = Field(pattern=r"^[a-z][a-z0-9_-]{2,63}$")
    manifest_revision: int = Field(ge=1)


class FeatureTargetsIn(BaseModel):
    accounts: list[str] = Field(min_length=1, max_length=50)


def _read_manifest_envelope() -> tuple[bytes, dict]:
    try:
        raw = MANIFEST_FILE.read_bytes()
    except FileNotFoundError:
        raise HTTPException(status_code=404, detail="No app manifest published")
    if len(raw) > MAX_BYTES:
        raise HTTPException(status_code=503, detail="App manifest unavailable")
    try:
        envelope = json.loads(raw)
        payload_bytes = base64.b64decode(envelope["payload"], validate=True)
        payload = json.loads(payload_bytes)
    except (KeyError, TypeError, ValueError, json.JSONDecodeError):
        raise HTTPException(status_code=503, detail="App manifest unavailable")
    if not isinstance(payload, dict) or len(payload_bytes) > MAX_BYTES:
        raise HTTPException(status_code=503, detail="App manifest unavailable")
    return raw, payload


def _trusted_entry_url(value: object) -> str | None:
    if not isinstance(value, str) or len(value) > 2048:
        return None
    parsed = urlparse(value)
    if (
        parsed.scheme != "https"
        or parsed.hostname != _TRUSTED_MODULE_HOST
        or parsed.port not in (None, 443)
        or parsed.username is not None
        or parsed.password is not None
        or parsed.fragment
        or not parsed.path.startswith(_TRUSTED_MODULE_PREFIX)
    ):
        return None
    return value


@router.get("/app-manifest")
def get_app_manifest() -> Response:
    raw, _ = _read_manifest_envelope()
    return Response(
        raw,
        media_type="application/json",
        headers={"Cache-Control": "no-store", "X-Content-Type-Options": "nosniff"},
    )


@router.get("/app-modules/eligibility")
def app_module_eligibility(
    user: User = Depends(get_current_user), db: Session = Depends(get_db)
) -> dict:
    feature_ids = db.scalars(
        select(AppFeatureGrant.feature_id).where(AppFeatureGrant.user_id == user.id)
    ).all()
    return {"code": 0, "message": "ok", "data": {"feature_ids": list(feature_ids)}}


@router.post("/app-modules/session")
def create_app_module_session(
    data: ModuleSessionIn,
    request: Request,
    response: Response,
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> dict:
    _, manifest = _read_manifest_envelope()
    expires_at = manifest.get("expiresAt")
    if not isinstance(expires_at, int) or expires_at <= int(time.time()):
        raise HTTPException(
            status_code=409,
            detail={"code": 40931, "message": "功能清单已过期，请稍后重试"},
        )
    if manifest.get("revision") != data.manifest_revision:
        raise HTTPException(
            status_code=409,
            detail={"code": 40930, "message": "功能清单已更新，请返回后重试"},
        )
    modules = manifest.get("modules")
    if not isinstance(modules, list):
        raise HTTPException(status_code=503, detail="App manifest unavailable")
    module = next(
        (item for item in modules if isinstance(item, dict) and item.get("id") == data.module_id),
        None,
    )
    entry_url = _trusted_entry_url(module.get("entryUrl") if module else None)
    if module is None or entry_url is None:
        raise HTTPException(
            status_code=404,
            detail={"code": 40430, "message": "功能当前不可用"},
        )
    if module.get("audience", "all") == "targeted":
        granted = db.scalar(
            select(AppFeatureGrant.id).where(
                AppFeatureGrant.user_id == user.id,
                AppFeatureGrant.feature_id == data.module_id,
            )
        )
        if granted is None:
            # Do not reveal the existence of an account-targeted module.
            raise HTTPException(
                status_code=404,
                detail={"code": 40430, "message": "功能当前不可用"},
            )
    session_cookie = create_module_token(
        user.id,
        data.module_id,
        current_token_version(db, user.id),
    )
    # The app writes this scoped token into an HttpOnly, Secure, SameSite=Strict
    # WebView cookie before navigation. Account access/refresh tokens are never
    # exposed to hosted JavaScript or put in a URL.
    result = {
        "code": 0,
        "message": "ok",
        "data": {"launch_url": entry_url, "session_cookie": session_cookie},
    }
    # The browser receives the scoped credential only as an HttpOnly cookie.
    # Native clients still need the value to install it in their WebView.
    if request.headers.get("x-web-launch") == "1":
        response.set_cookie(
            "__Host-hanshang_module",
            session_cookie,
            max_age=15 * 60,
            httponly=True,
            secure=True,
            samesite="strict",
            path="/",
        )
        result["data"].pop("session_cookie")
    return result


@router.put(
    "/admin/app-features/{module_id}/targets",
    dependencies=[Depends(require_admin)],
)
def replace_feature_targets(
    module_id: str, data: FeatureTargetsIn, db: Session = Depends(get_db)
) -> dict:
    if not re.fullmatch(r"[a-z][a-z0-9_-]{2,63}", module_id):
        raise HTTPException(status_code=422, detail={"code": 42200, "message": "功能标识无效"})
    _, manifest = _read_manifest_envelope()
    module = next(
        (item for item in manifest.get("modules", []) if isinstance(item, dict) and item.get("id") == module_id),
        None,
    )
    if module is None or module.get("audience", "all") != "targeted":
        raise HTTPException(status_code=404, detail={"code": 40430, "message": "定向功能不存在"})
    accounts = list(dict.fromkeys(value.strip() for value in data.accounts if value.strip()))
    users: list[User] = []
    missing: list[str] = []
    for account in accounts:
        user = db.scalar(select(User).where(or_(User.username == account, User.email == account)))
        (users if user else missing).append(user if user else account)
    if missing:
        raise HTTPException(
            status_code=422,
            detail={"code": 42241, "message": "测试账号不存在", "accounts": missing},
        )
    db.execute(delete(AppFeatureGrant).where(AppFeatureGrant.feature_id == module_id))
    for user in users:
        db.add(AppFeatureGrant(user_id=user.id, feature_id=module_id))
    db.commit()
    return {"code": 0, "message": "ok", "data": {
        "feature_id": module_id,
        "target_user_ids": [user.id for user in users],
    }}
