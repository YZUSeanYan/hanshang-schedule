"""令牌版本、刷新会话滑动续期与整体撤销。"""
from datetime import datetime, timedelta, timezone

from sqlalchemy import delete, select, update
from sqlalchemy.orm import Session

from app.core.config import get_settings
from app.core.security import hash_token_identifier
from app.models.token_session import RefreshTokenSession, UserTokenState


def utcnow_naive() -> datetime:
    return datetime.now(timezone.utc).replace(tzinfo=None)


def current_token_version(db: Session, user_id: int) -> int:
    row = db.scalar(select(UserTokenState).where(UserTokenState.user_id == user_id))
    return row.version if row else 0


def register_refresh_session(
    db: Session,
    *,
    user_id: int,
    token_version: int,
    token_identifier: str,
) -> None:
    # 只在签发新会话时顺手清理已过期记录，避免长期运行后会话表无限增长。
    db.execute(
        delete(RefreshTokenSession).where(
            RefreshTokenSession.expires_at <= utcnow_naive()
        )
    )
    db.add(
        RefreshTokenSession(
            user_id=user_id,
            token_hash=hash_token_identifier(token_identifier),
            token_version=token_version,
            expires_at=utcnow_naive()
            + timedelta(minutes=get_settings().refresh_token_expire_minutes),
        )
    )


def consume_refresh_session(
    db: Session,
    *,
    user_id: int,
    token_version: int,
    token_identifier: str,
    legacy: bool,
) -> bool:
    """校验刷新会话并滑动续期（2026-08-12 起不再单次轮换）。

    会话在有效期内可重复使用；每次成功刷新把 expires_at 顺延一个完整
    周期——用户只要在有效期内打开过一次就一直保持登录。每次登录/注册
    创建独立会话行，多浏览器/多设备各自持有、互不顶掉；登出删除对应
    会话行（revoke_refresh_session），改密/重置提升 token_version 使
    全部会话失效。
    """
    token_hash = hash_token_identifier(token_identifier)
    now = utcnow_naive()
    if legacy:
        row = db.scalar(
            select(RefreshTokenSession).where(
                RefreshTokenSession.token_hash == token_hash
            )
        )
        if row is None:
            # 旧版无 jti 令牌首次使用：登记为正常会话（可重复使用至 JWT 自身过期）。
            db.add(
                RefreshTokenSession(
                    user_id=user_id,
                    token_hash=token_hash,
                    token_version=token_version,
                    expires_at=now
                    + timedelta(minutes=get_settings().refresh_token_expire_minutes),
                )
            )
            return True
        # 已有记录则落入下方统一的滑动续期校验。
    # 单条原子 UPDATE：校验（未撤销/未过期/版本匹配）+ 滑动续期一步完成，
    # 并发刷新互不冲突，不存在竞态输家。
    result = db.execute(
        update(RefreshTokenSession)
        .where(
            RefreshTokenSession.token_hash == token_hash,
            RefreshTokenSession.user_id == user_id,
            RefreshTokenSession.token_version == token_version,
            RefreshTokenSession.revoked_at.is_(None),
            RefreshTokenSession.expires_at > now,
        )
        .values(
            expires_at=now
            + timedelta(minutes=get_settings().refresh_token_expire_minutes)
        )
    )
    return (result.rowcount or 0) == 1


def revoke_refresh_session(
    db: Session,
    *,
    token_identifier: str,
) -> None:
    """登出撤销：直接删除会话行。

    删除后该设备/浏览器的刷新凭据立即失效（重放必 401），
    不影响同一账号在其他设备上的独立会话。
    """
    db.execute(
        delete(RefreshTokenSession).where(
            RefreshTokenSession.token_hash == hash_token_identifier(token_identifier)
        )
    )


def invalidate_user_tokens(db: Session, user_id: int) -> int:
    state = db.scalar(select(UserTokenState).where(UserTokenState.user_id == user_id))
    if state is None:
        state = UserTokenState(user_id=user_id, version=1)
        db.add(state)
        version = 1
    else:
        state.version += 1
        version = state.version
    db.execute(
        update(RefreshTokenSession)
        .where(
            RefreshTokenSession.user_id == user_id,
            RefreshTokenSession.revoked_at.is_(None),
        )
        .values(revoked_at=utcnow_naive())
    )
    return version
