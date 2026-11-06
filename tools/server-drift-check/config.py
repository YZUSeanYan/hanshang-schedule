"""全局配置：默认值可全部通过环境变量或 .env 文件覆盖。"""
from functools import lru_cache
from typing import Literal
from urllib.parse import urlparse

from pydantic import model_validator
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    """应用配置（字段名与环境变量一一对应，大小写不敏感）。"""

    model_config = SettingsConfigDict(
        env_file=".env", env_file_encoding="utf-8", extra="ignore"
    )

    # ---- 应用基础信息 ----
    app_name: str = "扬大课表 API"
    app_version: str = "0.1.0"
    api_prefix: str = "/api"
    app_env: Literal["development", "test", "production"] = "development"
    docs_enabled: bool = True

    # ---- JWT 配置 ----
    # 生产环境务必通过 JWT_SECRET_KEY 环境变量覆盖，绝不能把真实密钥写进代码
    jwt_secret_key: str = "dev-only-secret-key-please-change-in-prod"  # ≥32 字节，满足 HS256 建议长度
    jwt_algorithm: str = "HS256"
    access_token_expire_minutes: int = 60             # access token 有效期 1 小时
    refresh_token_expire_minutes: int = 60 * 24 * 90  # refresh token 有效期 90 天（每次刷新滑动续期）

    # ---- 数据库 ----
    # 默认 SQLite（学生机轻量）；推广期改为 MySQL 连接串即可无缝切换，例如：
    # mysql+pymysql://user:password@127.0.0.1:3306/yzu_schedule
    database_url: str = "sqlite:///./yzu_schedule.db"
    uploads_dir: str = "/data/uploads"

    # ---- SMTP（忘记密码验证码邮件；QQ/163 邮箱开授权码后填入）----
    smtp_host: str = ""          # 如 smtp.qq.com；留空则进入开发模式（验证码打印到日志）
    smtp_port: int = 465
    smtp_user: str = ""
    smtp_password: str = ""      # 邮箱 SMTP 授权码（不是登录密码）
    smtp_from: str = ""          # 发件人地址，留空默认同 smtp_user
    smtp_use_ssl: bool = True    # 465 端口 SSL；若用 587 端口则设为 false（走 STARTTLS）

    # ---- 运维管理 ----
    admin_token: str = ""        # 发布新版本等管理接口的 X-Admin-Token；留空则管理接口全部不可用
    admin_console_enabled: bool = False
    admin_username: str = "admin"
    admin_password_hash: str = ""
    admin_password_hash_b64: str = ""
    admin_session_hours: int = 8
    # 公网 HTTPS 部署必须保持 true；仅经 SSH 隧道访问 localhost 时可设 false。
    admin_cookie_secure: bool = True

    # ---- 限流 ----
    auth_rate_limit_per_minute: int = 10  # 登录/注册/重置密码接口：单 IP 每分钟最大次数
    # PWA 只可从明确的 HTTPS 官网 Origin 调用 JWT API。网页持久会话通过官网
    # 同源代理转发 HttpOnly Cookie；公网 API 的 CORS 仍不开放跨域凭据。
    web_allowed_origins: str = "https://hanshang.seanyan.store"

    # ---- 教务系统服务器代抓 ----
    # 必须显式启用；浏览器上下文按请求创建并销毁，不保存教务凭据、Cookie、HAR 或截图。
    education_import_enabled: bool = False
    education_import_portal_url: str = "https://i.yzu.edu.cn/Login/CasLogin"
    education_import_login_url: str = "https://webvpn.yzu.edu.cn/login?cas_login=true"
    education_import_timeout_seconds: int = 45
    # 整个导入请求的硬时限：必须小于 Nginx 默认 60 秒代理超时，否则上游超时
    # 会变成裸 `504 Gateway Time-out` 而不是结构化错误。
    education_import_deadline_seconds: int = 50
    education_import_max_concurrency: int = 1
    education_import_browser_executable: str = ""
    # Headful Chromium under Xvfb matches YZU's interactive CAS page more
    # reliably. Keep the code default headless so development and tests do not
    # unexpectedly require a display; production opts in explicitly.
    education_import_portal_browser_headless: bool = True

    # ---- 教务课表 LLM 解析（本地规则解析失败时的通用兜底）----
    # 必须显式启用并配置 API key；上传的课表 HTML 仅用于单次模型请求，
    # 不落库、不写日志。
    llm_import_enabled: bool = False
    llm_import_base_url: str = "https://token-plan-cn.xiaomimimo.com/v1"
    llm_import_api_key: str = ""
    llm_import_model: str = "mimo-v2.5"
    llm_import_timeout_seconds: int = 45
    # 与教务代抓同理：整个请求的硬时限必须小于 Nginx 默认 60 秒代理超时。
    # 实测 MiMo v2.5 关闭思考后解析延迟约 34 秒，默认 50 秒有余量。
    llm_import_deadline_seconds: int = 50

    # ---- iOS/PWA Web Push ----
    # 私钥仅由服务器 .env 注入；public key 可通过受控 API 公开给订阅客户端。
    web_push_public_key: str = ""
    web_push_private_key: str = ""
    web_push_subject: str = "mailto:admin@hanshang.seanyan.store"

    # ---- Android 原生推送（ECS 实例角色，不保存长期 AccessKey） ----
    aliyun_push_enabled: bool = False
    aliyun_push_app_key: str = ""
    aliyun_push_region: str = "cn-hangzhou"
    aliyun_push_ecs_role_name: str = ""

    # ---- HarmonyOS 推送（HMS Push Kit） ----
    # 凭据只能通过运行环境注入；代码和设备注册接口均不接收客户端密钥。
    hms_push_enabled: bool = False
    hms_push_app_id: str = ""
    hms_push_client_id: str = ""
    hms_push_client_secret: str = ""
    # Native registrations are refreshed by normal app startup/heartbeat registration.
    push_device_expire_days: int = 90

    @property
    def parsed_web_allowed_origins(self) -> list[str]:
        origins = [origin.strip() for origin in self.web_allowed_origins.split(",") if origin.strip()]
        for origin in origins:
            parsed = urlparse(origin)
            if parsed.scheme != "https" or not parsed.netloc or parsed.path not in ("", "/") or parsed.query or parsed.fragment:
                raise ValueError("WEB_ALLOWED_ORIGINS 只能包含完整 HTTPS Origin")
        return [origin.rstrip("/") for origin in origins]

    @model_validator(mode="after")
    def validate_security_settings(self) -> "Settings":
        """生产环境拒绝以示例密钥或不完整管理配置启动。"""
        known_development_secrets = {
            "dev-only-secret-key-please-change-in-prod",
            "dev-only-secret-change-me",
        }
        if self.app_env == "production":
            if (
                self.jwt_secret_key in known_development_secrets
                or len(self.jwt_secret_key.encode("utf-8")) < 32
            ):
                raise ValueError("生产环境必须配置至少 32 字节的随机 JWT_SECRET_KEY")
            if self.docs_enabled:
                raise ValueError("生产环境必须关闭 DOCS_ENABLED，避免公开内部 API 清单")
        if self.admin_console_enabled and not (
            self.admin_password_hash or self.admin_password_hash_b64
        ):
            raise ValueError("启用管理后台前必须配置管理员密码哈希")
        if self.app_env == "production" and not self.parsed_web_allowed_origins:
            raise ValueError("生产环境必须配置 HTTPS WEB_ALLOWED_ORIGINS")
        parsed_import_url = urlparse(self.education_import_login_url)
        if parsed_import_url.scheme != "https" or parsed_import_url.hostname != "webvpn.yzu.edu.cn":
            raise ValueError("EDUCATION_IMPORT_LOGIN_URL 必须是扬大 WebVPN 的 HTTPS 地址")
        parsed_portal_url = urlparse(self.education_import_portal_url)
        if (
            parsed_portal_url.scheme != "https"
            or parsed_portal_url.hostname != "i.yzu.edu.cn"
            or parsed_portal_url.path != "/Login/CasLogin"
            or parsed_portal_url.params
            or parsed_portal_url.query
            or parsed_portal_url.fragment
        ):
            raise ValueError("EDUCATION_IMPORT_PORTAL_URL 必须是一网通办固定 HTTPS 登录地址")
        if not 15 <= self.education_import_timeout_seconds <= 120:
            raise ValueError("EDUCATION_IMPORT_TIMEOUT_SECONDS 必须在 15 到 120 秒之间")
        if not 15 <= self.education_import_deadline_seconds <= 55:
            raise ValueError(
                "EDUCATION_IMPORT_DEADLINE_SECONDS 必须在 15 到 55 秒之间"
                "（必须小于 Nginx 默认 60 秒代理超时）"
            )
        if not 1 <= self.education_import_max_concurrency <= 2:
            raise ValueError("EDUCATION_IMPORT_MAX_CONCURRENCY 必须在 1 到 2 之间")
        parsed_llm_url = urlparse(self.llm_import_base_url)
        if parsed_llm_url.scheme != "https" or not parsed_llm_url.hostname:
            raise ValueError("LLM_IMPORT_BASE_URL 必须是 HTTPS 地址")
        if self.app_env == "production" and self.llm_import_enabled and not self.llm_import_api_key:
            raise ValueError("生产环境启用 LLM 课表解析必须配置 LLM_IMPORT_API_KEY")
        if not 15 <= self.llm_import_timeout_seconds <= 120:
            raise ValueError("LLM_IMPORT_TIMEOUT_SECONDS 必须在 15 到 120 秒之间")
        if not 15 <= self.llm_import_deadline_seconds <= 55:
            raise ValueError(
                "LLM_IMPORT_DEADLINE_SECONDS 必须在 15 到 55 秒之间"
                "（必须小于 Nginx 默认 60 秒代理超时）"
            )
        if bool(self.web_push_public_key) != bool(self.web_push_private_key):
            raise ValueError("WEB_PUSH_PUBLIC_KEY 与 WEB_PUSH_PRIVATE_KEY 必须同时配置")
        if self.web_push_public_key and not (
            self.web_push_subject.startswith("mailto:") or self.web_push_subject.startswith("https://")
        ):
            raise ValueError("WEB_PUSH_SUBJECT 必须是 mailto: 或 HTTPS 地址")
        hms_credentials = (
            self.hms_push_app_id,
            self.hms_push_client_id,
            self.hms_push_client_secret,
        )
        if any(hms_credentials) and not all(hms_credentials):
            raise ValueError("HMS_PUSH_APP_ID、HMS_PUSH_CLIENT_ID 与 HMS_PUSH_CLIENT_SECRET 必须同时配置")
        if self.hms_push_enabled and not all(hms_credentials):
            raise ValueError("启用 HMS 推送前必须完整配置服务端凭据")
        if not 7 <= self.push_device_expire_days <= 365:
            raise ValueError("PUSH_DEVICE_EXPIRE_DAYS 必须在 7 到 365 天之间")
        return self


@lru_cache
def get_settings() -> Settings:
    """缓存配置实例，避免每次重复解析环境变量。"""
    return Settings()
