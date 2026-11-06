"""Short-lived WebVPN import boundary.

This module is intentionally independent from database models: education-system
credentials and WebVPN cookies belong only to one request-scoped browser/session
driver and must never be written to the application's database or logs.
"""
from __future__ import annotations

import asyncio
import base64
import html
import json
import logging
import re
from http.cookiejar import CookieJar
from contextlib import suppress
from typing import Any, Protocol
from urllib.parse import urlencode, urljoin, urlsplit, urlunsplit
from urllib.request import (
    HTTPCookieProcessor,
    HTTPRedirectHandler,
    Request,
    build_opener,
)
from urllib.error import HTTPError

from cryptography.hazmat.primitives import padding
from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes

from app.services.academic_schedule_parser import (
    AcademicScheduleCourse,
    parse_academic_schedule,
)

logger = logging.getLogger(__name__)


class WebVpnImportError(RuntimeError):
    """A safe, user-facing upstream import failure."""

    def __init__(self, status_code: int, code: int, message: str):
        self.status_code = status_code
        self.code = code
        self.message = message
        super().__init__(message)


class WebVpnImportGateway(Protocol):
    """A request-scoped implementation; it must close upstream state itself."""

    async def import_schedule(
        self, *, student_id: str, password: str
    ) -> list[AcademicScheduleCourse]: ...


class UnavailableWebVpnImportGateway:
    """Safe default until the browser worker is explicitly provisioned."""

    async def import_schedule(
        self, *, student_id: str, password: str
    ) -> list[AcademicScheduleCourse]:
        del student_id, password
        raise WebVpnImportError(
            503,
            50330,
            "教务代抓服务暂未就绪，请稍后再试或使用 Android 本地导入",
        )


class _SameOriginRedirectHandler(HTTPRedirectHandler):
    """Reject any login redirect that leaves the fixed HTTPS WebVPN origin."""

    def __init__(self, allowed_origin: str) -> None:
        super().__init__()
        self._allowed_origin = allowed_origin

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        resolved = urljoin(req.full_url, newurl)
        parsed = urlsplit(resolved)
        if (
            parsed.scheme != "https"
            or parsed.hostname != "webvpn.yzu.edu.cn"
            or parsed.port not in (None, 443)
        ):
            raise WebVpnImportError(502, 50240, "学校登录跳转地址异常")
        return super().redirect_request(req, fp, code, msg, headers, resolved)


class PlaywrightWebVpnImportGateway:
    """Run one WebVPN login in an isolated, short-lived Chromium context."""

    _TIMETABLE_PATH = "/student/courseSelect/thisSemesterCurriculum/index"
    _CALLBACK_MARKER = "/student/courseSelect/thisSemesterCurriculum/ajaxStudentSchedule/callback"
    _WEBVPN_ORIGIN = "https://webvpn.yzu.edu.cn"
    _ACADEMIC_ENTRY_URL = "http://ydjwxs.yzu.edu.cn/sigin"
    # 登录页可能是 /login（直接访问）或 /https/<session-token>（wengine 302
    # 到代理会话 URL）；两者都必须接受。
    _LOGIN_PAGE_PATH = re.compile(r"^/(?:https|http)/[^/]+(?:/login)?$")

    def __init__(
        self,
        *,
        login_url: str,
        timeout_seconds: int = 45,
        max_concurrency: int = 1,
        browser_executable: str = "",
        playwright_factory: Any | None = None,
        cookie_bootstrapper: Any | None = None,
    ) -> None:
        self._login_url = login_url
        self._timeout_ms = timeout_seconds * 1000
        self._browser_executable = browser_executable or None
        self._network_timeout_seconds = max(8, min(20, timeout_seconds // 2))
        self._semaphore = asyncio.Semaphore(max_concurrency)
        self._playwright_factory = playwright_factory
        self._cookie_bootstrapper = cookie_bootstrapper or self._bootstrap_webvpn_cookies

    async def import_schedule(
        self, *, student_id: str, password: str
    ) -> list[AcademicScheduleCourse]:
        async with self._semaphore:
            return await self._run_once(student_id=student_id, password=password)

    async def _run_once(
        self, *, student_id: str, password: str
    ) -> list[AcademicScheduleCourse]:
        factory = self._playwright_factory
        if factory is None:
            try:
                from playwright.async_api import async_playwright
            except ImportError as exc:
                raise WebVpnImportError(503, 50330, "教务代抓浏览器组件尚未就绪") from exc
            factory = async_playwright

        browser = None
        context = None
        try:
            cookies = await asyncio.wait_for(
                asyncio.to_thread(
                    self._cookie_bootstrapper,
                    student_id=student_id,
                    password=password,
                ),
                timeout=min(self._timeout_ms / 1000, 30),
            )
            logger.warning("webvpn_import.stage=bootstrap_ok")
            async with factory() as playwright:
                try:
                    launch_options: dict[str, Any] = {"headless": True}
                    if self._browser_executable:
                        launch_options["executable_path"] = self._browser_executable
                    browser = await playwright.chromium.launch(**launch_options)
                    context = await browser.new_context(
                        accept_downloads=False,
                        ignore_https_errors=False,
                        java_script_enabled=True,
                        locale="zh-CN",
                    )
                    await context.add_cookies(cookies)
                    page = await context.new_page()
                    page.set_default_timeout(self._timeout_ms)
                    portal_response = await page.goto(
                        self._WEBVPN_ORIGIN + "/", wait_until="domcontentloaded"
                    )
                    self._ensure_login_access(portal_response)
                    logger.warning("webvpn_import.stage=portal_loaded")
                    student_page = await self._open_student_system(context, page)
                    payload = await self._fetch_timetable_payload(student_page)
                    logger.warning("webvpn_import.stage=timetable_response")
                    return parse_academic_schedule(payload)
                finally:
                    # Explicitly close before Playwright's driver connection is
                    # stopped; this is the credential/cookie destruction boundary.
                    if context is not None:
                        with suppress(Exception):
                            await context.close()
                    if browser is not None:
                        with suppress(Exception):
                            await browser.close()
        except WebVpnImportError:
            raise
        except asyncio.TimeoutError as exc:
            raise WebVpnImportError(504, 50430, "教务系统响应超时，请稍后重试") from exc
        except Exception as exc:
            # Playwright's own TimeoutError does not inherit asyncio.TimeoutError
            # on all supported releases. Never include its URL-rich text here.
            if exc.__class__.__name__ == "TimeoutError":
                raise WebVpnImportError(504, 50430, "教务系统响应超时，请稍后重试") from exc
            raise WebVpnImportError(502, 50230, "暂时无法连接教务系统，请稍后重试") from exc

    def _bootstrap_webvpn_cookies(
        self, *, student_id: str, password: str
    ) -> list[dict[str, Any]]:
        jar = CookieJar()
        opener = build_opener(
            HTTPCookieProcessor(jar),
            _SameOriginRedirectHandler(self._WEBVPN_ORIGIN),
        )
        headers = {
            "User-Agent": (
                "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
                "AppleWebKit/537.36 Chrome/140.0.0.0 Safari/537.36"
            ),
            "Accept-Language": "zh-CN,zh;q=0.9",
        }
        try:
            try:
                with opener.open(
                    Request(self._login_url, headers=headers),
                    timeout=self._network_timeout_seconds,
                ) as response:
                    login_url = response.geturl()
                    login_html = response.read(128 * 1024).decode("utf-8", "replace")
            except HTTPError as exc:
                self._raise_bootstrap_http_error(exc)
            parsed_login = urlsplit(login_url)
            if (
                parsed_login.scheme != "https"
                or parsed_login.hostname != "webvpn.yzu.edu.cn"
                or not self._LOGIN_PAGE_PATH.match(parsed_login.path)
            ):
                raise WebVpnImportError(503, 50331, "学校 WebVPN 登录入口当前不可用")

            execution = self._extract_login_field(login_html, "login-page-flowkey")
            crypto_key = self._extract_login_field(login_html, "login-croypto")
            login_type = self._extract_login_field(login_html, "current-login-type")
            if login_type != "UsernamePassword" or not execution or not crypto_key:
                raise WebVpnImportError(502, 50238, "学校登录页面格式已变化，请稍后重试")
            if len(execution) > 20_000:
                raise WebVpnImportError(502, 50238, "学校登录页面格式已变化，请稍后重试")

            encrypted_password = self._encrypt_login_value(crypto_key, password)
            encrypted_captcha_payload = self._encrypt_login_value(crypto_key, "{}")
            form = urlencode(
                {
                    "username": student_id,
                    "type": login_type,
                    "_eventId": "submit",
                    "geolocation": "",
                    "execution": execution,
                    "captcha_code": "",
                    "croypto": crypto_key,
                    "password": encrypted_password,
                    "captcha_payload": encrypted_captcha_payload,
                }
            ).encode("ascii")
            request = Request(
                login_url,
                data=form,
                headers={**headers, "Content-Type": "application/x-www-form-urlencoded"},
                method="POST",
            )
            try:
                with opener.open(request, timeout=self._network_timeout_seconds) as response:
                    final_url = response.geturl()
                    response.read(64 * 1024)
            except HTTPError as exc:
                self._raise_bootstrap_http_error(exc)
            parsed_final = urlsplit(final_url)
            if (
                parsed_final.scheme != "https"
                or parsed_final.hostname != "webvpn.yzu.edu.cn"
                or parsed_final.path != "/"
            ):
                raise WebVpnImportError(
                    409,
                    40934,
                    "学校登录未完成，账号可能需要验证码、额外验证或重新确认密码",
                )
            cookies = self._cookies_for_playwright(jar)
            if not cookies:
                raise WebVpnImportError(502, 50239, "学校 WebVPN 未建立有效会话")
            return cookies
        finally:
            jar.clear()

    @staticmethod
    def _raise_bootstrap_http_error(exc: HTTPError) -> None:
        """Map an upstream HTTP error to a structured user-facing failure.

        The university currently answers cloud egress with HTTP 403; that is a
        deterministic "server access denied" condition, not a transient
        connection failure, so it must not trigger the legacy portal fallback.
        """
        if exc.code == 403:
            raise WebVpnImportError(
                503,
                50331,
                "学校 WebVPN 当前拒绝服务器访问，请使用 VPN 手动导入",
            ) from None
        raise WebVpnImportError(502, 50231, "学校 WebVPN 入口暂时不可用，请稍后重试") from None

    @staticmethod
    def _extract_login_field(document: str, field_id: str) -> str:
        match = re.search(
            rf'<[^>]+id=["\']{re.escape(field_id)}["\'][^>]*>(.*?)</',
            document,
            re.IGNORECASE | re.DOTALL,
        )
        if match is None:
            return ""
        return html.unescape(re.sub(r"<[^>]+>", "", match.group(1)).strip())

    @staticmethod
    def _encrypt_login_value(key_base64: str, value: str) -> str:
        try:
            key = base64.b64decode(key_base64, validate=True)
        except (ValueError, TypeError) as exc:
            raise WebVpnImportError(502, 50238, "学校登录加密参数无效") from exc
        if len(key) not in (16, 24, 32):
            raise WebVpnImportError(502, 50238, "学校登录加密参数无效")
        padder = padding.PKCS7(algorithms.AES.block_size).padder()
        padded = padder.update(value.encode("utf-8")) + padder.finalize()
        encryptor = Cipher(algorithms.AES(key), modes.ECB()).encryptor()
        encrypted = encryptor.update(padded) + encryptor.finalize()
        return base64.b64encode(encrypted).decode("ascii")

    @staticmethod
    def _cookies_for_playwright(jar: CookieJar) -> list[dict[str, Any]]:
        cookies: list[dict[str, Any]] = []
        for cookie in jar:
            domain = cookie.domain.lstrip(".").lower()
            if domain != "webvpn.yzu.edu.cn":
                continue
            item: dict[str, Any] = {
                "name": cookie.name,
                "value": cookie.value,
                "domain": cookie.domain,
                "path": cookie.path or "/",
                "secure": True,
            }
            if cookie.expires is not None:
                item["expires"] = cookie.expires
            cookies.append(item)
        return cookies

    async def _login(self, page: Any, *, student_id: str, password: str) -> None:
        username_input = page.locator('input[name="username"]').first
        password_input = page.locator('input[name="password"]').first
        await username_input.wait_for(state="visible")
        await password_input.wait_for(state="visible")
        await username_input.fill(student_id)
        await password_input.fill(password)

        if await self._has_visible_challenge(page):
            raise WebVpnImportError(409, 40931, "当前登录需要验证码，请稍后重试或使用 Android 本地导入")

        submit = page.locator('button[type="submit"], input[type="submit"]').first
        await submit.click()
        await self._wait_for_portal(page)

    @staticmethod
    def _ensure_login_access(response: Any | None) -> None:
        """Fail immediately when the university rejects server-side access."""
        if response is None:
            return
        if response.status in (401, 403):
            raise WebVpnImportError(
                503,
                50331,
                "学校 WebVPN 当前拒绝服务器访问，请使用 VPN 手动导入",
            )
        if response.status >= 400:
            raise WebVpnImportError(
                502,
                50231,
                "学校 WebVPN 入口暂时不可用，请稍后重试",
            )

    async def _wait_for_portal(self, page: Any) -> None:
        deadline = asyncio.get_running_loop().time() + self._timeout_ms / 1000
        while asyncio.get_running_loop().time() < deadline:
            if await self._has_visible_secondary_auth(page):
                raise WebVpnImportError(409, 40932, "当前登录需要短信或二次验证，服务器代抓暂不支持")
            if await self._has_visible_challenge(page):
                raise WebVpnImportError(409, 40931, "当前登录需要验证码，请稍后重试或使用 Android 本地导入")
            student_link = page.get_by_text("教务系统学生端", exact=True).first
            if await student_link.is_visible():
                return
            if await self._has_visible_login_error(page):
                raise WebVpnImportError(401, 40131, "教务账号或密码错误")
            await page.wait_for_timeout(250)
        raise WebVpnImportError(504, 50430, "教务系统响应超时，请稍后重试")

    async def _open_student_system(self, context: Any, portal_page: Any) -> Any:
        link = portal_page.get_by_text("教务系统学生端", exact=True).first
        ydjwxs_link = portal_page.locator('a[href*="ydjwxs"], a:has-text("ydjwxs")').first
        known_pages = list(context.pages)
        if await link.is_visible():
            logger.warning("webvpn_import.stage=visible_link")
            await link.click()
        elif await ydjwxs_link.count() and await ydjwxs_link.is_visible():
            # 门户公告中的教务入口可能只显示域名（ydjwxs.yzu.edu.cn）
            logger.warning("webvpn_import.stage=ydjwxs_link")
            await ydjwxs_link.click()
        else:
            # The WebVPN portal app is occasionally blank in server Chromium,
            # while its official URL-rewriter still loads.  Creating a fixed,
            # allowlisted anchor lets that script generate the per-session
            # HTTPS proxy URL without reproducing its private encoding.
            script = portal_page.locator(
                'script[src*="/wengine-vpn/js/main.js"]'
            ).first
            await script.wait_for(state="attached")
            logger.warning("webvpn_import.stage=rewriter_ready")
            await portal_page.wait_for_timeout(500)
            await portal_page.evaluate(
                """
                (url) => {
                  const link = document.createElement('a');
                  link.href = url;
                  link.target = '_blank';
                  link.rel = 'noopener';
                  document.body.appendChild(link);
                  link.click();
                  link.remove();
                }
                """,
                self._ACADEMIC_ENTRY_URL,
            )
            logger.warning("webvpn_import.stage=anchor_dispatched")
        deadline = asyncio.get_running_loop().time() + self._timeout_ms / 1000
        while asyncio.get_running_loop().time() < deadline:
            new_pages = [candidate for candidate in context.pages if candidate not in known_pages]
            if new_pages:
                page = new_pages[-1]
                await page.wait_for_url(
                    re.compile(r"^https://webvpn\.yzu\.edu\.cn/(?:https|http)/[^/]+(?:/.*)?$"),
                    timeout=self._timeout_ms,
                    wait_until="domcontentloaded",
                )
                logger.warning("webvpn_import.stage=proxy_page_opened")
                return page
            if portal_page.url != self._login_url and "/login" not in portal_page.url:
                await portal_page.wait_for_url(
                    re.compile(r"^https://webvpn\.yzu\.edu\.cn/(?:https|http)/[^/]+(?:/.*)?$"),
                    timeout=self._timeout_ms,
                    wait_until="domcontentloaded",
                )
                logger.warning("webvpn_import.stage=proxy_page_opened")
                return portal_page
            await portal_page.wait_for_timeout(200)
        raise WebVpnImportError(504, 50431, "打开教务系统学生端超时，请稍后重试")

    async def _fetch_timetable_payload(self, page: Any) -> Any:
        timetable_url = self._build_timetable_url(page.url)
        async with page.expect_response(
            lambda response: self._is_timetable_response(response.url),
            timeout=self._timeout_ms,
        ) as response_info:
            await page.goto(timetable_url, wait_until="domcontentloaded")
        response = await response_info.value
        if response.status != 200:
            raise WebVpnImportError(502, 50232, "教务系统课表接口暂不可用")
        return self._decode_callback(await response.text())

    @classmethod
    def _is_timetable_response(cls, response_url: str) -> bool:
        parsed = urlsplit(response_url)
        return (
            parsed.scheme == "https"
            and parsed.hostname == "webvpn.yzu.edu.cn"
            and parsed.port in (None, 443)
            and re.match(r"^/(?:https|http)/[^/]+", parsed.path) is not None
            and cls._CALLBACK_MARKER in parsed.path
        )

    @classmethod
    def _build_timetable_url(cls, current_url: str) -> str:
        parsed = urlsplit(current_url)
        match = re.match(r"^(/(?:https|http)/[^/]+)", parsed.path)
        if (
            parsed.scheme != "https"
            or parsed.hostname != "webvpn.yzu.edu.cn"
            or parsed.port not in (None, 443)
            or match is None
        ):
            raise WebVpnImportError(502, 50233, "教务系统跳转地址异常")
        return urlunsplit((parsed.scheme, parsed.netloc, match.group(1) + cls._TIMETABLE_PATH, "", ""))

    @staticmethod
    def _decode_callback(text: str) -> Any:
        value = text.strip()
        try:
            return json.loads(value)
        except json.JSONDecodeError:
            match = re.fullmatch(r"[A-Za-z_$][\w.$]*\s*\((.*)\)\s*;?", value, re.DOTALL)
            if match is None:
                return value
            try:
                return json.loads(match.group(1))
            except json.JSONDecodeError:
                return value

    @staticmethod
    async def _any_visible(page: Any, selector: str) -> bool:
        locator = page.locator(selector)
        count = await locator.count()
        for index in range(min(count, 8)):
            if await locator.nth(index).is_visible():
                return True
        return False

    @classmethod
    async def _has_visible_challenge(cls, page: Any) -> bool:
        return await cls._any_visible(
            page,
            'input[name="captcha_code"], input[name*="captcha" i], img[alt*="验证码"]',
        )

    @classmethod
    async def _has_visible_secondary_auth(cls, page: Any) -> bool:
        return await cls._any_visible(
            page,
            'input[name*="otp" i], input[name*="sms" i], input[autocomplete="one-time-code"]',
        )

    @classmethod
    async def _has_visible_login_error(cls, page: Any) -> bool:
        locator = page.get_by_text(re.compile(r"(账号|用户名|密码).{0,12}(错误|不正确|失败)"))
        return await locator.first.is_visible()
