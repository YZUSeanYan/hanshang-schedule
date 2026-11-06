"""邮件发送：SMTP 直发（QQ/163 邮箱授权码）。

未配置 SMTP 时进入开发模式：邮件内容打印到服务端日志，方便本地调试。
"""
import logging
import smtplib
import ssl
from email.header import Header
from email.mime.text import MIMEText

from app.core.config import get_settings

logger = logging.getLogger("yzu.mail")


def send_mail(to: str, subject: str, text: str) -> bool:
    """发送纯文本邮件。返回是否真正通过 SMTP 发出（开发模式返回 False）。"""
    settings = get_settings()
    if not settings.smtp_host:
        if settings.app_env in {"development", "test"}:
            logger.warning("SMTP 未配置，开发模式。发往 %s 的邮件内容：\n%s", to, text)
        else:
            logger.error("SMTP 未配置，生产环境未发送密码重置邮件")
        return False

    msg = MIMEText(text, "plain", "utf-8")
    msg["Subject"] = Header(subject, "utf-8")
    from_addr = settings.smtp_from or settings.smtp_user
    # 带上显示名：否则收件人看到的是裸邮箱地址（2026-09-23 用户反馈过这点）
    if settings.smtp_from_name:
        msg["From"] = f"{Header(settings.smtp_from_name, 'utf-8').encode()} <{from_addr}>"
    else:
        msg["From"] = from_addr
    msg["To"] = to

    if settings.smtp_use_ssl:
        # 465 端口：SSL 直连
        with smtplib.SMTP_SSL(
            settings.smtp_host, settings.smtp_port,
            context=ssl.create_default_context(), timeout=15,
        ) as server:
            server.login(settings.smtp_user, settings.smtp_password)
            server.sendmail(from_addr, [to], msg.as_string())
    else:
        # 587 端口：STARTTLS
        with smtplib.SMTP(settings.smtp_host, settings.smtp_port, timeout=15) as server:
            server.starttls(context=ssl.create_default_context())
            server.login(settings.smtp_user, settings.smtp_password)
            server.sendmail(from_addr, [to], msg.as_string())
    return True
