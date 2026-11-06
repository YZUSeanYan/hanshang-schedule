"""v1 路由聚合：新增业务模块时在这里挂载。"""
from fastapi import APIRouter

from app.api.v1.endpoints import about, admin_console, auth, credential_vault, education_import, health, notifications, push, share, sync, user, version

api_router = APIRouter()
api_router.include_router(health.router)
api_router.include_router(auth.router)
api_router.include_router(user.router)
api_router.include_router(version.router)
api_router.include_router(sync.router)
api_router.include_router(admin_console.router)
api_router.include_router(about.router)
api_router.include_router(credential_vault.router)
api_router.include_router(share.router)
api_router.include_router(education_import.router)
api_router.include_router(push.router)
api_router.include_router(notifications.router)
