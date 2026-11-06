"""pytest 公共配置：必须在导入 app 之前设置测试环境变量。

- 使用独立临时 SQLite 库，不污染开发数据；
- 配置固定的管理令牌与 JWT 密钥；
- SMTP 留空；需要验证码的测试会替换邮件发送函数，数据库只检查摘要。
"""
import os
import tempfile
import bcrypt

_TMPDIR = tempfile.mkdtemp(prefix="yzu-test-")

os.environ["DATABASE_URL"] = f"sqlite:///{_TMPDIR}/test.db"
os.environ["UPLOADS_DIR"] = f"{_TMPDIR}/uploads"
os.environ["JWT_SECRET_KEY"] = "pytest-secret-key-not-for-production-use!!"
os.environ["APP_ENV"] = "test"
os.environ["ADMIN_TOKEN"] = "test-admin-token"
os.environ["SMTP_HOST"] = ""  # 开发模式
os.environ["AUTH_RATE_LIMIT_PER_MINUTE"] = "1000"  # 测试环境放宽限流，避免误伤测试用例
os.environ["ADMIN_CONSOLE_ENABLED"] = "true"
os.environ["ADMIN_USERNAME"] = "admin"
os.environ["ADMIN_PASSWORD_HASH"] = bcrypt.hashpw(
    b"test-admin-password", bcrypt.gensalt(rounds=4)
).decode("utf-8")
os.environ["ADMIN_COOKIE_SECURE"] = "false"
