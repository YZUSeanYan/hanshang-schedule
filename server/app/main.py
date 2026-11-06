"""FastAPI 应用入口。

启动方式：
- 开发：uvicorn app.main:app --reload
- 生产：见 server/Dockerfile 与 docker-compose.yml
Swagger 文档：/docs
"""
from fastapi import FastAPI, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import FileResponse, JSONResponse, RedirectResponse
from fastapi.staticfiles import StaticFiles
from fastapi.middleware.cors import CORSMiddleware
from pathlib import Path
from sqlalchemy import inspect, text
from starlette.exceptions import HTTPException as StarletteHTTPException

from app import models  # noqa: F401  导入即注册全部模型到 Base.metadata
from app.api.v1.router import api_router
from app.core.config import get_settings
from app.db.base import Base
from app.db.session import engine

settings = get_settings()


def _migrate_notification_targets() -> None:
    """Idempotent v1.0.21 migration for existing production databases."""
    columns = {column["name"] for column in inspect(engine).get_columns("user_notifications")}
    additions = {
        "target_type": "VARCHAR(16) NOT NULL DEFAULT 'ACCOUNT'",
        "target_device_id": "VARCHAR(192)",
        "target_label": "VARCHAR(160) NOT NULL DEFAULT '全部设备'",
    }
    with engine.begin() as connection:
        for name, definition in additions.items():
            if name not in columns:
                connection.execute(text(
                    f"ALTER TABLE user_notifications ADD COLUMN {name} {definition}"
                ))


def _migrate_sync_overrides_table() -> None:
    """Idempotent migration: 调休同步表（老库补建）。"""
    if "sync_overrides" not in inspect(engine).get_table_names():
        Base.metadata.tables["sync_overrides"].create(bind=engine)


def _migrate_sync_courses_short_name() -> None:
    """Idempotent migration: sync_courses 新增课程简称列。"""
    columns = {column["name"] for column in inspect(engine).get_columns("sync_courses")}
    if "short_name" not in columns:
        with engine.begin() as connection:
            connection.execute(text(
                "ALTER TABLE sync_courses ADD COLUMN short_name VARCHAR(16) NOT NULL DEFAULT ''"
            ))


def _migrate_users_avatar() -> None:
    """Idempotent migration: users 新增头像列。"""
    columns = {column["name"] for column in inspect(engine).get_columns("users")}
    if "avatar_media" not in columns:
        with engine.begin() as connection:
            connection.execute(text(
                "ALTER TABLE users ADD COLUMN avatar_media VARCHAR(64) NOT NULL DEFAULT ''"
            ))


def _migrate_sync_events_short_title() -> None:
    """Idempotent v2.0.x migration: sync_events 新增 AI 简写列。"""
    columns = {column["name"] for column in inspect(engine).get_columns("sync_events")}
    if "short_title" not in columns:
        with engine.begin() as connection:
            connection.execute(text(
                "ALTER TABLE sync_events ADD COLUMN short_title VARCHAR(16) NOT NULL DEFAULT ''"
            ))


def create_app() -> FastAPI:
    """应用工厂：便于测试与多环境复用。"""
    app = FastAPI(
        title=settings.app_name,
        version=settings.app_version,
        docs_url="/docs" if settings.docs_enabled else None,
        openapi_url="/openapi.json" if settings.docs_enabled else None,
    )

    # 开发期自动建表；正式上线后引入 Alembic 做迁移管理（TODO 阶段 1）
    Base.metadata.create_all(bind=engine)
    _migrate_notification_targets()
    _migrate_sync_events_short_title()
    _migrate_users_avatar()
    _migrate_sync_courses_short_name()
    _migrate_sync_overrides_table()

    # Browser companion uses Bearer tokens for direct cross-origin API calls.
    # Persistent web sessions travel only through the official same-origin
    # reverse proxy, so cross-origin cookies stay disabled here.
    app.add_middleware(
        CORSMiddleware,
        allow_origins=settings.parsed_web_allowed_origins,
        allow_credentials=False,
        allow_methods=["GET", "POST", "PUT", "DELETE", "OPTIONS"],
        allow_headers=["Authorization", "Content-Type", "X-App-Module"],
        max_age=600,
    )

    app.include_router(api_router, prefix=settings.api_prefix)

    if settings.admin_console_enabled:
        admin_dir = Path(__file__).resolve().parent.parent / "admin"
        app.mount("/admin/assets", StaticFiles(directory=admin_dir / "assets"), name="admin-assets")

        @app.get("/admin", include_in_schema=False)
        def admin_redirect():
            return RedirectResponse(url="admin/", status_code=307)

        @app.get("/admin/", include_in_schema=False)
        def admin_index():
            return FileResponse(admin_dir / "index.html", headers={"Cache-Control": "no-store"})

    @app.middleware("http")
    async def admin_security_headers(request: Request, call_next):
        response = await call_next(request)
        response.headers["X-Content-Type-Options"] = "nosniff"
        response.headers["Referrer-Policy"] = "no-referrer"
        if request.url.scheme == "https":
            response.headers["Strict-Transport-Security"] = "max-age=31536000; includeSubDomains"
        if request.url.path.startswith("/admin") or request.url.path.startswith("/api/admin-console"):
            response.headers["Cache-Control"] = "no-store"
            response.headers["X-Frame-Options"] = "DENY"
            response.headers["Permissions-Policy"] = "camera=(), microphone=(), geolocation=()"
            response.headers["Content-Security-Policy"] = (
                "default-src 'self'; script-src 'self'; style-src 'self'; "
                "img-src 'self' data:; connect-src 'self'; frame-ancestors 'none'; "
                "base-uri 'none'; form-action 'self'"
            )
        return response

    # ---- 统一错误格式 {code, message} ----

    @app.exception_handler(StarletteHTTPException)
    async def http_exception_handler(request: Request, exc: StarletteHTTPException):
        # 业务错误若已在 detail 中携带 {code, message} 则原样透传
        if isinstance(exc.detail, dict) and "code" in exc.detail:
            body = exc.detail
        else:
            body = {"code": exc.status_code, "message": str(exc.detail)}
        return JSONResponse(status_code=exc.status_code, content=body)

    @app.exception_handler(RequestValidationError)
    async def validation_exception_handler(request: Request, exc: RequestValidationError):
        # 生产响应不暴露 Pydantic 模型结构、字段类型和内部校验上下文。
        return JSONResponse(
            status_code=422,
            content={"code": 42200, "message": "请求参数格式不正确"},
        )

    return app


app = create_app()
