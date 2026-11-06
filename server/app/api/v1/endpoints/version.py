"""版本更新端点：App 启动时检查更新；管理员发布新版本。"""
from fastapi import APIRouter, Depends, HTTPException, Query, Request
from sqlalchemy import exists, or_, select
from sqlalchemy.orm import Session

from app.api.deps import get_optional_current_user, require_admin
from app.db.session import get_db
from app.models.app_version import AppVersion
from app.models.release_target import AppVersionTarget
from app.models.user import User
from app.schemas.version import VersionInfoOut, VersionPublishIn
from app.services.version_release import publish_version as release_publish


def _record_client_version(db: Session, user_id: int, current_code: int) -> None:
    """记下这个账号现在跑的是哪个 versionCode（每账号一行，重复上报覆盖）。

    **用独立 session**，不要 commit/rollback 调用方传进来的那个：它属于整个
    请求，早提交会把别的待写入一起落库、异常回滚也会连带撤销别人的改动。
    """
    from app.db.session import SessionLocal
    from app.models.client_version import ClientVersion

    own = SessionLocal()
    try:
        row = own.scalar(select(ClientVersion).where(ClientVersion.user_id == user_id))
        if row is None:
            own.add(ClientVersion(user_id=user_id, current_code=current_code))
        elif row.current_code != current_code:
            row.current_code = current_code
        own.commit()
    except Exception:
        # 版本检查绝不能因为记版本而失败
        own.rollback()
    finally:
        own.close()


router = APIRouter(tags=["版本"])


@router.get("/version/latest", summary="检查最新版本")
def latest_version(
    request: Request,
    current_code: int = Query(0, description="客户端当前 versionCode"),
    current_user: User | None = Depends(get_optional_current_user),
    db: Session = Depends(get_db),
) -> dict:
    has_any_target = exists(
        select(AppVersionTarget.id).where(AppVersionTarget.version_id == AppVersion.id)
    )
    visibility = ~has_any_target
    if current_user is not None:
        visibility = or_(
            visibility,
            exists(
                select(AppVersionTarget.id).where(
                    AppVersionTarget.version_id == AppVersion.id,
                    AppVersionTarget.user_id == current_user.id,
                )
            ),
        )
    # 记录每个账号最近一次上报的 versionCode：给「更新提醒」提供定向依据，
    # 只提醒落后的用户，不骚扰已升级的（App 内提示条够不到老版本，见模型注释）。
    if current_user is not None and current_code > 0:
        _record_client_version(db, current_user.id, current_code)

    latest = db.scalar(
        select(AppVersion)
        .where(visibility)
        .order_by(AppVersion.version_code.desc())
    )
    if latest is None:
        info = VersionInfoOut(has_update=False)
    else:
        # is_force_update 全量强制；force_codes 只强制列出的旧版本（逗号分隔），
        # 用于"某个有严重问题的版本必须升级，但更老/更新版本不必打扰"的场景。
        forced_codes = {
            int(code) for code in (latest.force_codes or "").split(",") if code.strip().isdigit()
        }
        # 旧版 App（API host 是 IP api.seanyan.store）时，apk_url 域名替换为 IP，保证 trustedApkUri 同源校验通过
        host = request.headers.get('host', '')
        apk_url = latest.apk_url
        if host.split(':')[0] == 'api.seanyan.store' and latest.apk_url.startswith('https://api.seanyan.store/yzu-apk/'):
            apk_url = latest.apk_url.replace('api.seanyan.store', 'api.seanyan.store', 1)
        info = VersionInfoOut(
            has_update=latest.version_code > current_code,
            version_name=latest.version_name,
            version_code=latest.version_code,
            apk_url=apk_url,
            sha256=latest.sha256,
            release_notes=latest.release_notes,
            is_force_update=latest.is_force_update
            or (current_code > 0 and current_code in forced_codes),
        )
    return {"code": 0, "message": "ok", "data": info.model_dump()}


@router.post(
    "/admin/versions",
    summary="发布新版本（管理接口，需 X-Admin-Token）",
    dependencies=[Depends(require_admin)],
)
def publish_version(data: VersionPublishIn, db: Session = Depends(get_db)) -> dict:
    result = release_publish(db, data)
    return {"code": 0, "message": "ok", "data": result}
