"""Short-lived import through YZU's public one-stop student portal."""
from __future__ import annotations

import asyncio
import json
import re
from contextlib import suppress
from datetime import date
from typing import Any
from urllib.parse import urlsplit

from app.services.academic_schedule_parser import (
    AcademicScheduleCourse,
    extract_portal_term_start_year,
    is_acceptable_term_start_year,
    parse_portal_schedule,
)
from app.services.webvpn_import import (
    PlaywrightWebVpnImportGateway,
    WebVpnImportError,
    WebVpnImportGateway,
)


class PlaywrightPortalImportGateway:
    """Import the server-rendered timetable from ``i.yzu.edu.cn/Student``."""

    _STUDENT_URL = re.compile(r"^https://i\.yzu\.edu\.cn/Student(?:[/?#].*)?$")
    _SCHEDULE_MARKER = re.compile(r"\bvar\s+kebiao\s*=\s*")

    def __init__(
        self,
        *,
        login_url: str,
        timeout_seconds: int = 45,
        max_concurrency: int = 1,
        browser_executable: str = "",
        browser_headless: bool = True,
        playwright_factory: Any | None = None,
    ) -> None:
        parsed = urlsplit(login_url)
        if (
            parsed.scheme != "https"
            or parsed.hostname != "i.yzu.edu.cn"
            or parsed.port not in (None, 443)
            or parsed.path != "/Login/CasLogin"
            or parsed.query
            or parsed.fragment
        ):
            raise ValueError("一网通办登录地址必须是固定 HTTPS 地址")
        self._login_url = login_url
        self._timeout_ms = timeout_seconds * 1000
        self._browser_executable = browser_executable or None
        self._browser_headless = browser_headless
        self._semaphore = asyncio.Semaphore(max_concurrency)
        self._playwright_factory = playwright_factory

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
            async with factory() as playwright:
                try:
                    browser = await playwright.chromium.launch(**self._launch_options())
                    context = await browser.new_context(
                        accept_downloads=False,
                        ignore_https_errors=False,
                        java_script_enabled=True,
                        locale="zh-CN",
                    )
                    page = await context.new_page()
                    page.set_default_timeout(self._timeout_ms)
                    response = await page.goto(self._login_url, wait_until="domcontentloaded")
                    self._ensure_entry_access(response)
                    await self._submit_login(page, student_id=student_id, password=password)
                    await self._wait_for_student_portal(page)
                    payload = await self._extract_embedded_schedule(page)
                    courses = parse_portal_schedule(payload)
                    if not courses:
                        raise WebVpnImportError(
                            409,
                            40933,
                            "一网通办当前学期暂无课表，请稍后重试或使用 VPN 手动导入",
                        )
                    self._ensure_current_term(payload)
                    return courses
                finally:
                    if context is not None:
                        with suppress(Exception):
                            await context.close()
                    if browser is not None:
                        with suppress(Exception):
                            await browser.close()
        except WebVpnImportError:
            raise
        except asyncio.TimeoutError as exc:
            raise WebVpnImportError(504, 50432, "一网通办响应超时，请稍后重试") from exc
        except Exception as exc:
            if exc.__class__.__name__ == "TimeoutError":
                raise WebVpnImportError(504, 50432, "一网通办响应超时，请稍后重试") from exc
            raise WebVpnImportError(502, 50234, "暂时无法连接一网通办，请稍后重试") from exc

    def _launch_options(self) -> dict[str, Any]:
        options: dict[str, Any] = {"headless": self._browser_headless}
        if self._browser_executable:
            options["executable_path"] = self._browser_executable
        return options

    @staticmethod
    def _ensure_entry_access(response: Any | None) -> None:
        if response is None:
            return
        if response.status in (401, 403):
            raise WebVpnImportError(503, 50332, "学校一网通办当前拒绝服务器访问")
        if response.status >= 400:
            raise WebVpnImportError(502, 50235, "学校一网通办入口暂时不可用")

    async def _submit_login(self, page: Any, *, student_id: str, password: str) -> None:
        username_input = page.locator('input[name="username"]').first
        # 统一认证（sso.yzu.edu.cn）的真实密码框没有 name 属性；页面上的
        # input[name="password"] 是 JS 在提交时写入加密值的隐藏字段，等它
        # visible 会一直超时。填写可见密码框后点击提交，Angular 提交处理器
        # 会完成加密并携带隐藏字段。
        password_input = page.locator('input[type="password"]').first
        await username_input.wait_for(state="visible")
        await password_input.wait_for(state="visible")
        await username_input.fill(student_id)
        await password_input.fill(password)
        if await PlaywrightWebVpnImportGateway._has_visible_challenge(page):
            raise WebVpnImportError(409, 40931, "当前登录需要验证码，请使用 VPN 手动导入")
        # YZU's current CAS page renders the visible action as a JavaScript
        # button without ``type=submit``.  Selecting by type can click an
        # unrelated hidden control and leave the page waiting until timeout.
        submit = self._login_button(page)
        await submit.click()

    @staticmethod
    def _login_button(page: Any) -> Any:
        return page.get_by_role("button", name=re.compile(r"登\s*录")).first

    async def _wait_for_student_portal(self, page: Any) -> None:
        deadline = asyncio.get_running_loop().time() + self._timeout_ms / 1000
        while asyncio.get_running_loop().time() < deadline:
            if self._STUDENT_URL.match(page.url):
                await page.wait_for_load_state("domcontentloaded")
                return
            if await PlaywrightWebVpnImportGateway._has_visible_secondary_auth(page):
                raise WebVpnImportError(409, 40932, "当前登录需要短信或二次验证，服务器代抓暂不支持")
            if await PlaywrightWebVpnImportGateway._has_visible_challenge(page):
                raise WebVpnImportError(409, 40931, "当前登录需要验证码，请使用 VPN 手动导入")
            if await PlaywrightWebVpnImportGateway._has_visible_login_error(page):
                raise WebVpnImportError(401, 40131, "教务账号或密码错误")
            await page.wait_for_timeout(250)
        raise WebVpnImportError(504, 50432, "打开一网通办学生首页超时，请稍后重试")

    async def _extract_embedded_schedule(self, page: Any) -> Any:
        if not self._STUDENT_URL.match(page.url):
            raise WebVpnImportError(502, 50236, "一网通办跳转地址异常")
        locator = page.locator("script:not([src])").filter(has_text=self._SCHEDULE_MARKER).first
        try:
            # 门户改版后登录首页不再内嵌 kebiao；假期/开学前课表数据未开放
            # 时页面也没有该脚本。短等待后快速失败并给出明确提示，而不是
            # 消耗剩余时限后笼统报"响应超时"。
            await locator.wait_for(state="attached", timeout=15000)
        except Exception as exc:
            if exc.__class__.__name__ == "TimeoutError":
                raise WebVpnImportError(
                    409,
                    40937,
                    "教务系统暂未开放课表（假期内暂不可用），开学后自动恢复，或使用 VPN 手动导入",
                ) from None
            raise
        text = await locator.text_content()
        return self._decode_embedded_schedule(text or "")

    @classmethod
    def _decode_embedded_schedule(cls, script_text: str) -> Any:
        marker = cls._SCHEDULE_MARKER.search(script_text)
        if marker is None:
            raise WebVpnImportError(502, 50237, "一网通办未返回课表数据")
        try:
            payload, _ = json.JSONDecoder().raw_decode(script_text[marker.end() :])
        except json.JSONDecodeError as exc:
            raise WebVpnImportError(502, 50237, "一网通办课表数据格式异常") from exc
        return payload

    @staticmethod
    def _ensure_current_term(payload: Any, *, today: date | None = None) -> None:
        """Reject portal data that cannot be proven to be the current semester.

        The portal has been observed serving a two-year-old semester; parsing
        such a payload successfully must never be reported as the student's
        current timetable.
        """
        term = payload.get("term") if isinstance(payload, dict) else None
        start_year = extract_portal_term_start_year(term)
        if start_year is None:
            raise WebVpnImportError(
                409,
                40936,
                "一网通办未返回可识别的学期，无法确认课表是否为当前学期，请稍后重试或使用 VPN 手动导入",
            )
        if not is_acceptable_term_start_year(start_year, today=today):
            raise WebVpnImportError(
                409,
                40935,
                "一网通办课表仍停留在旧学期，请使用 VPN 手动导入当前学期课表",
            )


class PreferWebVpnImportGateway:
    """Use the current WebVPN timetable and keep the portal as a fallback."""

    # Deterministic WebVPN failures that re-trying the legacy portal cannot fix
    # and that would only burn the request's total time budget: bad credentials,
    # captcha/secondary-auth/empty-semester, an abnormal same-origin redirect, a
    # missing browser worker and WebVPN timeouts (the request has already spent
    # most of its 50 s deadline).  The university rejecting the server's egress
    # (HTTP 403, code 50331) is NOT here: the portal is an independent system
    # reachable from the server, and its result is still guarded by the current-
    # semester check, so falling back after a fast 403 is worthwhile.
    _NO_FALLBACK_CODES = {
        40131,
        40931,
        40932,
        40933,
        50240,
        50330,
        50430,
        50431,
    }

    def __init__(self, *, portal: WebVpnImportGateway, webvpn: WebVpnImportGateway) -> None:
        self._portal = portal
        self._webvpn = webvpn

    async def import_schedule(
        self, *, student_id: str, password: str
    ) -> list[AcademicScheduleCourse]:
        try:
            return await self._webvpn.import_schedule(student_id=student_id, password=password)
        except WebVpnImportError as webvpn_error:
            if webvpn_error.code in self._NO_FALLBACK_CODES:
                raise
            try:
                return await self._portal.import_schedule(student_id=student_id, password=password)
            except WebVpnImportError as portal_error:
                # 一网通办已经实际尝试过；透传它的错误（如验证码、旧学期、
                # 账号密码错误）比笼统的 WebVPN 出口错误更贴近用户现状。
                raise portal_error from None
