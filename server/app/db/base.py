"""SQLAlchemy 声明式模型基类。"""
from sqlalchemy.orm import DeclarativeBase


class Base(DeclarativeBase):
    """所有数据模型的公共基类。"""
