"""定向内测发布：邗上课表 2.0.3+66（test66）→ TARGET_ACCOUNT 指定的测试账号+ 推送邀请。

用法：TOKEN=$(ADMIN_TOKEN) TARGET_ACCOUNT=your-test-account python publish_v203_test66.py
"""
import json
import os
import urllib.error
import urllib.parse
import urllib.request

TOKEN = os.environ.get("TOKEN", "")
if not TOKEN:
    print("missing TOKEN env")
    raise SystemExit(2)
TARGET_ACCOUNT = os.environ.get("TARGET_ACCOUNT", "")
if not TARGET_ACCOUNT:
    print("missing TARGET_ACCOUNT env")
    raise SystemExit(2)

# 目标地址硬编码 + 白名单校验（协议/主机/路径前缀），不接收任何动态输入。
# 公网经 nginx 映射：https://api.seanyan.store/yzu/ → 后端 /api/
ALLOWED_HOST = "api.seanyan.store"
ALLOWED_PREFIX = "/yzu/api/admin/"
URL = "https://api.seanyan.store/yzu/api/admin/versions"
parsed = urllib.parse.urlparse(URL)
assert parsed.scheme == "https", "只允许 HTTPS"
assert parsed.hostname == ALLOWED_HOST, "主机不在白名单"
assert parsed.path.startswith(ALLOWED_PREFIX), "路径前缀不合法"


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    """管理员接口不应跟随重定向（防止凭据被带去别处）。"""

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


opener = urllib.request.build_opener(_NoRedirect)

payload = {
    "version_name": "2.0.3",
    "version_code": 66,
    "apk_url": "https://api.seanyan.store/yzu-apk/hanshang-schedule-v2.0.3-test66.apk",
    "sha256": "b27c7226130b2760e09461a86ad888b62f60aa21b4e101e6fbd20ae52e7bf267",
    "is_force_update": False,
    "target_accounts": [TARGET_ACCOUNT],
    "notify_targets": True,
    "release_notes": (
        "内测版（test66）：恢复共同空闲入口 + 支持作者二级页。\n"
        "\n"
        "本次改动：\n"
        "· 修复：「我的」页共同空闲入口恢复。根因是功能入口此前依赖远程"
        "功能清单下发，而清单签发通道已冻结，2.0.1 起新装/升级设备不再"
        "采纳它。现在共同空闲作为全原生功能内置在客户端，不再依赖远程签发\n"
        "· 新增：「关于邗上课表 → 支持作者」二级页，两种支持方式——扫码"
        "支持（收款码弹层）与看广告支持\n"
        "· 优化：头像与收款码本地缓存，重进关于页不再重新下载，省流量\n"
        "\n"
        "验收点：\n"
        "1. 「我的」页应重新出现「共同空闲」入口，点进去功能正常\n"
        "2. 关于页进两次：第二次头像应立即显示（不重新加载）\n"
        "3. 支持作者页：扫码弹层正常显示收款码；看广告入口按构建配置出现"
    ),
}

data = json.dumps(payload).encode("utf-8")
request = urllib.request.Request(
    URL,
    data=data,
    headers={"Content-Type": "application/json", "X-Admin-Token": TOKEN},
    method="POST",
)
try:
    with opener.open(request, timeout=30) as resp:
        print(json.dumps(json.loads(resp.read().decode("utf-8")), ensure_ascii=False, indent=2))
except urllib.error.HTTPError as error:
    print("HTTP", error.code, error.read().decode("utf-8", "replace")[:800])
    raise SystemExit(1)
