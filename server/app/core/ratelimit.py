"""轻量内存限流器（滑动窗口），用于登录/注册/重置密码接口防爆破。

单机部署足够；未来多实例部署时应替换为 Redis 计数（接口保持不变）。
"""
import threading
import time
from collections import defaultdict, deque

from fastapi import HTTPException, Request


class RateLimiter:
    """滑动窗口限流：同一 key 在 period 秒内最多允许 max_calls 次。"""

    def __init__(self, max_calls: int, period_seconds: int):
        self.max_calls = max_calls
        self.period = period_seconds
        self._hits: dict[str, deque[float]] = defaultdict(deque)
        self._lock = threading.Lock()

    def allow(self, key: str) -> bool:
        now = time.monotonic()
        with self._lock:
            q = self._hits[key]
            while q and now - q[0] > self.period:
                q.popleft()
            if len(q) >= self.max_calls:
                return False
            q.append(now)
            return True


def make_rate_limit_dependency(limiter: RateLimiter, tag: str):
    """生成 FastAPI 依赖：按 客户端IP+接口标签 限流，超限返回统一格式 429。"""

    def _check(request: Request) -> None:
        client_ip = request.client.host if request.client else "unknown"
        if not limiter.allow(f"{tag}:{client_ip}"):
            raise HTTPException(
                status_code=429,
                detail={"code": 42900, "message": "操作过于频繁，请稍后再试"},
            )

    return _check
