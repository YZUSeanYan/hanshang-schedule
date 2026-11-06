import pytest
from datetime import date

from app.services.portal_import import (
    PlaywrightPortalImportGateway,
    PreferWebVpnImportGateway,
)
from app.services.webvpn_import import WebVpnImportError


def test_decodes_only_the_embedded_portal_schedule_object():
    script = """
    var page = {token: 'must-not-be-parsed'};
    var kebiao = {"term":"2026-2027-1","weeks":[]};
    if (kebiao.msg == "") { SetKeBiao(kebiao); }
    """
    assert PlaywrightPortalImportGateway._decode_embedded_schedule(script) == {
        "term": "2026-2027-1",
        "weeks": [],
    }


@pytest.mark.parametrize("script", ["var other = {};", "var kebiao = notJson;"])
def test_rejects_missing_or_invalid_embedded_schedule(script):
    with pytest.raises(WebVpnImportError) as captured:
        PlaywrightPortalImportGateway._decode_embedded_schedule(script)
    assert captured.value.code == 50237


@pytest.mark.parametrize(
    "url",
    [
        "http://i.yzu.edu.cn/Login/CasLogin",
        "https://example.com/Login/CasLogin",
        "https://i.yzu.edu.cn/Other",
        "https://i.yzu.edu.cn/Login/CasLogin?next=external",
    ],
)
def test_portal_gateway_rejects_non_fixed_login_url(url):
    with pytest.raises(ValueError):
        PlaywrightPortalImportGateway(login_url=url)


class _RoleLocatorPage:
    def __init__(self):
        self.role = None
        self.name = None
        self.result = object()

    def get_by_role(self, role, *, name):
        self.role = role
        self.name = name
        return type("Locator", (), {"first": self.result})()


def test_portal_login_uses_visible_named_login_button():
    page = _RoleLocatorPage()
    assert PlaywrightPortalImportGateway._login_button(page) is page.result
    assert page.role == "button"
    assert page.name.search("登 录")
    assert not page.name.search("短信验证码")


def test_portal_browser_mode_is_explicit_and_keeps_executable_override():
    gateway = PlaywrightPortalImportGateway(
        login_url="https://i.yzu.edu.cn/Login/CasLogin",
        browser_headless=False,
        browser_executable="/usr/bin/chromium",
    )
    assert gateway._launch_options() == {
        "headless": False,
        "executable_path": "/usr/bin/chromium",
    }


class _Gateway:
    def __init__(self, result=None, error=None):
        self.result = result
        self.error = error
        self.calls = 0

    async def import_schedule(self, **_kwargs):
        self.calls += 1
        if self.error:
            raise self.error
        return self.result


@pytest.mark.anyio
async def test_prefers_webvpn_without_calling_portal():
    portal = _Gateway(result=["portal-course"])
    webvpn = _Gateway(result=["webvpn-course"])
    gateway = PreferWebVpnImportGateway(portal=portal, webvpn=webvpn)
    assert await gateway.import_schedule(student_id="1", password="secret") == ["webvpn-course"]
    assert (portal.calls, webvpn.calls) == (0, 1)


@pytest.mark.anyio
async def test_falls_back_only_for_transient_portal_failure():
    webvpn = _Gateway(error=WebVpnImportError(502, 50230, "webvpn unavailable"))
    portal = _Gateway(result=["portal-course"])
    gateway = PreferWebVpnImportGateway(portal=portal, webvpn=webvpn)
    assert await gateway.import_schedule(student_id="1", password="secret") == ["portal-course"]
    assert (portal.calls, webvpn.calls) == (1, 1)


@pytest.mark.anyio
async def test_does_not_retry_credentials_when_portal_rejects_login():
    webvpn = _Gateway(error=WebVpnImportError(401, 40131, "bad credentials"))
    portal = _Gateway(result=["must-not-run"])
    gateway = PreferWebVpnImportGateway(portal=portal, webvpn=webvpn)
    with pytest.raises(WebVpnImportError) as captured:
        await gateway.import_schedule(student_id="1", password="secret")
    assert captured.value.code == 40131
    assert portal.calls == 0


@pytest.mark.parametrize(
    "code", [40131, 40931, 40932, 40933, 50240, 50330, 50430, 50431]
)
@pytest.mark.anyio
async def test_no_portal_fallback_for_deterministic_webvpn_failures(code):
    # WebVPN 超时（50430/50431）、同源跳转异常（50240）、浏览器缺失
    # （50330）等确定性故障必须立即返回结构化错误，不得再消耗剩余时限
    # 回退一网通办。
    webvpn = _Gateway(error=WebVpnImportError(503, code, "deterministic failure"))
    portal = _Gateway(result=["must-not-run"])
    gateway = PreferWebVpnImportGateway(portal=portal, webvpn=webvpn)
    with pytest.raises(WebVpnImportError) as captured:
        await gateway.import_schedule(student_id="1", password="secret")
    assert captured.value.code == code
    assert portal.calls == 0


@pytest.mark.anyio
async def test_portal_error_is_passed_through_after_webvpn_403():
    # WebVPN 403 回退一网通办后，portal 的真实失败（验证码等）必须透传，
    # 而不是笼统返回 WebVPN 的出口错误。
    webvpn = _Gateway(error=WebVpnImportError(503, 50331, "egress denied"))
    portal = _Gateway(error=WebVpnImportError(409, 40931, "captcha required"))
    gateway = PreferWebVpnImportGateway(portal=portal, webvpn=webvpn)
    with pytest.raises(WebVpnImportError) as captured:
        await gateway.import_schedule(student_id="1", password="secret")
    assert captured.value.code == 40931
    assert (portal.calls, webvpn.calls) == (1, 1)


@pytest.mark.parametrize(
    "code", [50230, 50231, 50238, 50239, 40934, 50331]
)
@pytest.mark.anyio
async def test_portal_fallback_kept_for_transient_webvpn_failures(code):
    # 瞬时连接故障、WebVPN 登录结构问题以及学校拒绝服务器出口（50331，
    # 一网通办是独立系统、结果仍有学期校验兜底）均允许回退。
    webvpn = _Gateway(error=WebVpnImportError(502, code, "transient failure"))
    portal = _Gateway(result=["portal-course"])
    gateway = PreferWebVpnImportGateway(portal=portal, webvpn=webvpn)
    assert await gateway.import_schedule(student_id="1", password="secret") == ["portal-course"]
    assert (portal.calls, webvpn.calls) == (1, 1)


def test_portal_import_accepts_current_term():
    PlaywrightPortalImportGateway._ensure_current_term(
        {"term": "2026-2027-1", "weeks": []}, today=date(2026, 8, 11)
    )


def test_portal_import_rejects_stale_term_with_structured_error():
    with pytest.raises(WebVpnImportError) as captured:
        PlaywrightPortalImportGateway._ensure_current_term(
            {"term": "2024-2025第2学期", "weeks": []}, today=date(2026, 8, 11)
        )
    assert captured.value.status_code == 409
    assert captured.value.code == 40935
    assert "VPN" in captured.value.message


class _TimeoutLocator:
    def filter(self, **_kwargs):
        return self

    @property
    def first(self):
        return self

    async def wait_for(self, **_kwargs):
        raise TimeoutError("kebiao script never appeared")


class _NoKebiaoPage:
    url = "https://i.yzu.edu.cn/Student"

    def locator(self, _selector):
        return _TimeoutLocator()


def test_extract_fails_fast_with_holiday_hint_when_kebiao_missing():
    # 门户改版/假期未开放时页面没有 kebiao 脚本：必须快速返回明确提示
    # （40937），而不是消耗剩余时限后笼统报"响应超时"。
    import asyncio
    from app.services.portal_import import PlaywrightPortalImportGateway as G

    async def run():
        gateway = G(login_url="https://i.yzu.edu.cn/Login/CasLogin")
        try:
            await gateway._extract_embedded_schedule(_NoKebiaoPage())
            raise AssertionError("should have raised")
        except WebVpnImportError as exc:
            return exc

    exc = asyncio.run(run())
    assert exc.status_code == 409
    assert exc.code == 40937
    assert "假期" in exc.message


@pytest.mark.parametrize("payload", [{"weeks": []}, {"term": "不明学期", "weeks": []}])
def test_portal_import_rejects_unrecognized_term(payload):
    with pytest.raises(WebVpnImportError) as captured:
        PlaywrightPortalImportGateway._ensure_current_term(
            payload, today=date(2026, 8, 11)
        )
    assert captured.value.code == 40936
