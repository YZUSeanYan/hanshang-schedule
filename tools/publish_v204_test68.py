"""定向内测发布：邗上课表 2.0.4+68（test68）→ TARGET_ACCOUNT 指定的测试账号+ 推送邀请。

用法：TOKEN=$(ADMIN_TOKEN) TARGET_ACCOUNT=your-test-account python publish_v204_test68.py
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
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


opener = urllib.request.build_opener(_NoRedirect)

payload = {
    "version_name": "2.0.4",
    "version_code": 68,
    "apk_url": "https://api.seanyan.store/yzu-apk/hanshang-schedule-v2.0.4-test68.apk",
    "sha256": "eb23bec357b8a8322b3a785162a61bcef8d611cfcaad47ac18e66322a15eada0",
    "is_force_update": False,
    "target_accounts": [TARGET_ACCOUNT],
    "notify_targets": True,
    "release_notes": (
        "内测版（test68）：教务适配引擎 + 全国学校目录。\n"
        "\n"
        "本次改动：\n"
        "· 新增：教务适配引擎——服务器签名下发每所学校的导入配置\n"
        "  （入口网址、引导文案、嗅探关键词、字段解析规则、证书链），\n"
        "  以后新增/修正学校支持不再需要发版\n"
        "· 「其他学校教务」名单从 27 所扩充到 190 所（目录数据参考\n"
        "  拾光课表开源适配仓库，MIT 许可），搜索找你的学校更快\n"
        "· 带有针对性适配的学校会显示「已适配」标签，进入后展示\n"
        "  该校专属引导；导航白名单、账号密码不出本机的红线不变\n"
        "· 全部配置走 Ed25519 签名通道，验签失败自动回退上一份可用配置\n"
        "\n"
        "验收点：\n"
        "1. 添加 → 其他学校教务：列表显著变多（按字母分组），部分学校带\n"
        "   「已适配」小标签\n"
        "2. 随便选一所「已适配」学校进入，引导条显示该校专属文案\n"
        "3. 通用教务导入（手输网址）依然可用；扬州大学导入不受影响\n"
        "4. 断网冷启动后学校列表仍在（配置已缓存）"
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
