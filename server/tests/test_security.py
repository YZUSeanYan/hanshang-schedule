"""安全工具单元测试：JWT 与密码哈希。"""
import time

import jwt
import pytest

from app.core.security import (
    create_access_token,
    create_refresh_token,
    decode_token,
    hash_password,
    verify_password,
)


def test_密码哈希可校验且每次盐不同():
    h1 = hash_password("my-secret-pwd")
    h2 = hash_password("my-secret-pwd")
    assert h1 != h2  # 随机盐：同明文不同哈希
    assert verify_password("my-secret-pwd", h1)
    assert not verify_password("wrong-pwd", h1)


def test_access_token_签发与解码往返():
    token = create_access_token(42)
    payload = decode_token(token, expected_type="access")
    assert payload["sub"] == "42"
    assert payload["type"] == "access"
    assert payload["exp"] > time.time()


def test_refresh_token_不能当_access_用():
    token = create_refresh_token(42)
    with pytest.raises(jwt.PyJWTError):
        decode_token(token, expected_type="access")


def test_篡改的_token_校验失败():
    token = create_access_token(42)
    # 改掉 payload 段的一个字符，签名必然失效
    parts = token.split(".")
    bad = f"{parts[0]}.{parts[1][:-1]}{'A' if parts[1][-1] != 'A' else 'B'}.{parts[2]}"
    with pytest.raises(jwt.PyJWTError):
        decode_token(bad)
