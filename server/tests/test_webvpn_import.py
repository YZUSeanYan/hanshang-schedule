import base64
import json
import urllib.error

import pytest
from cryptography.hazmat.primitives import padding
from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes

from app.services.webvpn_import import (
    PlaywrightWebVpnImportGateway,
    WebVpnImportError,
    _SameOriginRedirectHandler,
)


def test_builds_timetable_url_without_retaining_ticket_or_query():
    url = PlaywrightWebVpnImportGateway._build_timetable_url(
        "https://webvpn.yzu.edu.cn/https/runtime-token/home?ticket=secret"
    )
    assert url == (
        "https://webvpn.yzu.edu.cn/https/runtime-token"
        "/student/courseSelect/thisSemesterCurriculum/index"
    )
    assert "secret" not in url


def test_builds_timetable_url_for_http_upstream_proxy_used_by_student_system():
    url = PlaywrightWebVpnImportGateway._build_timetable_url(
        "https://webvpn.yzu.edu.cn/http/runtime-token/home?ticket=secret"
    )
    assert url == (
        "https://webvpn.yzu.edu.cn/http/runtime-token"
        "/student/courseSelect/thisSemesterCurriculum/index"
    )
    assert "secret" not in url


@pytest.mark.parametrize(
    "current_url",
    [
        "http://webvpn.yzu.edu.cn/https/token/",
        "https://example.com/https/token/",
        "https://webvpn.yzu.edu.cn/login",
    ],
)
def test_rejects_non_proxy_student_urls(current_url):
    with pytest.raises(WebVpnImportError) as captured:
        PlaywrightWebVpnImportGateway._build_timetable_url(current_url)
    assert captured.value.code == 50233


def test_decodes_json_and_jsonp_callbacks():
    payload = {"data": [{"kcmc": "高等数学"}]}
    raw = json.dumps(payload, ensure_ascii=False)
    assert PlaywrightWebVpnImportGateway._decode_callback(raw) == payload
    assert PlaywrightWebVpnImportGateway._decode_callback(f"callback({raw});") == payload


def test_extracts_and_encrypts_current_sso_bootstrap_fields():
    document = """
    <p id="current-login-type">UsernamePassword</p>
    <p id="login-croypto">MDEyMzQ1Njc4OWFiY2RlZg==</p>
    <p id="login-page-flowkey">flow-token</p>
    """
    key = PlaywrightWebVpnImportGateway._extract_login_field(
        document, "login-croypto"
    )
    encrypted = PlaywrightWebVpnImportGateway._encrypt_login_value(key, "secret")
    decryptor = Cipher(
        algorithms.AES(base64.b64decode(key)), modes.ECB()
    ).decryptor()
    padded = decryptor.update(base64.b64decode(encrypted)) + decryptor.finalize()
    unpadder = padding.PKCS7(algorithms.AES.block_size).unpadder()
    assert (unpadder.update(padded) + unpadder.finalize()).decode() == "secret"
    assert PlaywrightWebVpnImportGateway._extract_login_field(
        document, "login-page-flowkey"
    ) == "flow-token"


def test_rejects_login_redirect_outside_webvpn_origin():
    handler = _SameOriginRedirectHandler("https://webvpn.yzu.edu.cn")
    request = type("Request", (), {"full_url": "https://webvpn.yzu.edu.cn/login"})()
    with pytest.raises(WebVpnImportError) as captured:
        handler.redirect_request(
            request, None, 302, "Found", {}, "https://example.com/callback"
        )
    assert captured.value.code == 50240


def test_timetable_response_requires_exact_https_webvpn_origin():
    valid = (
        "https://webvpn.yzu.edu.cn/https/runtime-token"
        "/student/courseSelect/thisSemesterCurriculum/ajaxStudentSchedule/callback"
    )
    assert PlaywrightWebVpnImportGateway._is_timetable_response(valid) is True
    assert PlaywrightWebVpnImportGateway._is_timetable_response(valid.replace("/https/", "/http/")) is True
    assert PlaywrightWebVpnImportGateway._is_timetable_response(valid.replace("https://", "http://")) is False
    assert PlaywrightWebVpnImportGateway._is_timetable_response(valid.replace("webvpn.yzu.edu.cn", "example.test")) is False


def test_public_error_does_not_include_browser_diagnostics():
    error = WebVpnImportError(502, 50230, "暂时无法连接教务系统，请稍后重试")
    assert "password" not in error.message
    assert "ticket" not in error.message


class _ErrorOpener:
    def __init__(self, error):
        self.error = error

    def open(self, *_args, **_kwargs):
        raise self.error


def _http_error(status):
    return urllib.error.HTTPError(
        "https://webvpn.yzu.edu.cn/login?cas_login=true",
        status,
        "upstream error",
        {},
        None,
    )


def test_bootstrap_maps_http_403_to_structured_server_access_denied(monkeypatch):
    monkeypatch.setattr(
        "app.services.webvpn_import.build_opener",
        lambda *_args, **_kwargs: _ErrorOpener(_http_error(403)),
    )
    gateway = PlaywrightWebVpnImportGateway(
        login_url="https://webvpn.yzu.edu.cn/login?cas_login=true"
    )
    with pytest.raises(WebVpnImportError) as captured:
        gateway._bootstrap_webvpn_cookies(student_id="1", password="secret")
    assert captured.value.status_code == 503
    assert captured.value.code == 50331
    assert "VPN 手动导入" in captured.value.message


def test_bootstrap_maps_other_http_errors_to_entry_unavailable(monkeypatch):
    monkeypatch.setattr(
        "app.services.webvpn_import.build_opener",
        lambda *_args, **_kwargs: _ErrorOpener(_http_error(502)),
    )
    gateway = PlaywrightWebVpnImportGateway(
        login_url="https://webvpn.yzu.edu.cn/login?cas_login=true"
    )
    with pytest.raises(WebVpnImportError) as captured:
        gateway._bootstrap_webvpn_cookies(student_id="1", password="secret")
    assert captured.value.code == 50231


def test_login_access_denial_fails_immediately_with_actionable_message():
    response = type("Response", (), {"status": 403})()
    with pytest.raises(WebVpnImportError) as captured:
        PlaywrightWebVpnImportGateway._ensure_login_access(response)
    assert captured.value.status_code == 503
    assert captured.value.code == 50331
    assert "VPN 手动导入" in captured.value.message


class _Locator:
    def __init__(self, page, kind, visible=False):
        self.page = page
        self.kind = kind
        self.visible = visible

    @property
    def first(self):
        return self

    async def wait_for(self, **_kwargs):
        return None

    async def fill(self, value):
        self.page.filled[self.kind] = value

    async def click(self):
        if self.kind == "submit":
            self.page.portal_ready = True
        elif self.kind == "student-link":
            self.page.context.pages.append(self.page.context.student_page)

    async def is_visible(self):
        if self.kind == "student-link":
            return self.page.portal_ready
        return self.visible

    async def count(self):
        return 1 if self.visible else 0

    def nth(self, _index):
        return self


class _Response:
    status = 200

    async def text(self):
        return json.dumps(
            [{"kcmc": "高等数学", "jsxm": "王老师", "xqj": 1, "jcs": "1-2节"}],
            ensure_ascii=False,
        )


class _ResponseInfo:
    @property
    def value(self):
        async def resolve():
            return _Response()

        return resolve()


class _ResponseContext:
    async def __aenter__(self):
        return _ResponseInfo()

    async def __aexit__(self, *_args):
        return None


class _Page:
    def __init__(self, context, url):
        self.context = context
        self.url = url
        self.filled = {}
        self.portal_ready = False

    def set_default_timeout(self, _timeout):
        return None

    async def goto(self, url, **_kwargs):
        self.url = url
        if url == "https://webvpn.yzu.edu.cn/":
            self.portal_ready = True
        return type("Response", (), {"status": 200})()

    def locator(self, selector):
        if selector == 'input[name="username"]':
            return _Locator(self, "username")
        if selector == 'input[name="password"]':
            return _Locator(self, "password")
        if "submit" in selector:
            return _Locator(self, "submit")
        return _Locator(self, "other")

    async def evaluate(self, _script, url):
        assert url == PlaywrightWebVpnImportGateway._ACADEMIC_ENTRY_URL
        self.context.pages.append(self.context.student_page)

    def get_by_text(self, value, **_kwargs):
        if value == "教务系统学生端":
            return _Locator(self, "student-link")
        return _Locator(self, "text")

    async def wait_for_timeout(self, _timeout):
        return None

    async def wait_for_load_state(self, _state):
        return None

    async def wait_for_url(self, _url, **_kwargs):
        return None

    def expect_response(self, predicate, **_kwargs):
        assert predicate(type("Response", (), {"url": self.url + PlaywrightWebVpnImportGateway._CALLBACK_MARKER})())
        return _ResponseContext()


class _Context:
    def __init__(self):
        self.closed = False
        self.portal_page = _Page(self, "about:blank")
        self.student_page = _Page(self, "https://webvpn.yzu.edu.cn/https/runtime-token/")
        self.pages = [self.portal_page]
        self.cookies = []

    async def add_cookies(self, cookies):
        self.cookies = cookies

    async def new_page(self):
        return self.portal_page

    async def close(self):
        self.closed = True


class _Browser:
    def __init__(self):
        self.context = _Context()
        self.closed = False

    async def new_context(self, **_kwargs):
        return self.context

    async def close(self):
        self.closed = True


class _Chromium:
    def __init__(self, browser):
        self.browser = browser

    async def launch(self, **_kwargs):
        return self.browser


class _Playwright:
    def __init__(self, browser):
        self.chromium = _Chromium(browser)


class _PlaywrightContext:
    def __init__(self, browser):
        self.playwright = _Playwright(browser)

    async def __aenter__(self):
        return self.playwright

    async def __aexit__(self, *_args):
        return None


@pytest.mark.anyio
async def test_blank_portal_uses_fixed_allowlisted_student_anchor():
    context = _Context()
    gateway = PlaywrightWebVpnImportGateway(
        login_url="https://webvpn.yzu.edu.cn/login?cas_login=true"
    )
    page = await gateway._open_student_system(context, context.portal_page)
    assert page is context.student_page


@pytest.mark.anyio
async def test_full_state_machine_closes_ephemeral_context_and_browser():
    browser = _Browser()
    gateway = PlaywrightWebVpnImportGateway(
        login_url="https://webvpn.yzu.edu.cn/login?cas_login=true",
        playwright_factory=lambda: _PlaywrightContext(browser),
        cookie_bootstrapper=lambda **_kwargs: [
            {
                "name": "session",
                "value": "ephemeral",
                "domain": "webvpn.yzu.edu.cn",
                "path": "/",
                "secure": True,
            }
        ],
    )

    courses = await gateway.import_schedule(student_id="12345678", password="one-request-only")

    assert courses[0].name == "高等数学"
    assert browser.context.cookies[0]["name"] == "session"
    assert browser.context.portal_page.filled == {}
    assert browser.context.closed is True
    assert browser.closed is True
