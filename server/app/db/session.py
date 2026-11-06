"""数据库引擎与会话工厂。

SQLite 与 MySQL 的差异通过连接参数隔离，业务代码无感知。
"""
from sqlalchemy import create_engine
from sqlalchemy.orm import Session, sessionmaker

from app.core.config import get_settings

_settings = get_settings()

# SQLite 单文件库需要关闭同线程检查；MySQL 等网络库不需要该参数
_connect_args = (
    {"check_same_thread": False} if _settings.database_url.startswith("sqlite") else {}
)

engine = create_engine(
    _settings.database_url,
    connect_args=_connect_args,
    pool_pre_ping=True,  # 取用连接前先探活，避免长时间空闲后拿到断开的连接
)

# 请求级会话工厂：配合 api/deps.py 的 get_db 使用
SessionLocal = sessionmaker(bind=engine, autoflush=False, autocommit=False)


def get_db():
    """FastAPI 依赖：提供一个请求级数据库会话，用完自动关闭。"""
    db: Session = SessionLocal()
    try:
        yield db
    finally:
        db.close()
