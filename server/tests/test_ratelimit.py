"""限流器单元测试。"""
import time

from app.core.ratelimit import RateLimiter


def test_窗口内限流():
    limiter = RateLimiter(max_calls=3, period_seconds=60)
    assert limiter.allow("ip1")
    assert limiter.allow("ip1")
    assert limiter.allow("ip1")
    assert not limiter.allow("ip1")  # 第 4 次被拒
    assert limiter.allow("ip2")      # 不同 key 互不影响


def test_窗口滑动后恢复():
    limiter = RateLimiter(max_calls=1, period_seconds=1)
    assert limiter.allow("ip1")
    assert not limiter.allow("ip1")
    time.sleep(1.1)
    assert limiter.allow("ip1")
