"""每日活跃打点：任意已认证请求即记活跃。

历史上只在刷新令牌路径写 daily_activity，access token 有效期内的使用完全
漏计，次周留存被系统性低估。现在由 get_current_user_id 统一调用本模块；
幂等依赖 (user_id, activity_date) 唯一约束 + INSERT OR IGNORE。

进程内以 (user_id, today) 做当日缓存：命中即跳过 DB，每个用户每天最多
一次轻量写入。打点失败绝不影响主流程。
"""
import threading
from datetime import date

from sqlalchemy import text as sa_text
from sqlalchemy.orm import Session

_lock = threading.Lock()
_recorded: set[tuple[int, str]] = set()
_MAX_CACHE = 20000  # 防御性上限：Campus 量级远到不了，真到顶直接清


def record_daily_activity(db: Session, user_id: int) -> None:
    today = str(date.today())
    key = (user_id, today)
    with _lock:
        if key in _recorded:
            return
    try:
        db.execute(
            sa_text(
                "INSERT OR IGNORE INTO daily_activity (user_id, activity_date, created_at) "
                "VALUES (:uid, :d, datetime('now'))"
            ),
            {"uid": user_id, "d": today},
        )
        db.commit()
    except Exception:
        db.rollback()
        return
    with _lock:
        if len(_recorded) >= _MAX_CACHE:
            _recorded.clear()
        _recorded.add(key)
