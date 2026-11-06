"""定向内测发布：邗上课表 2.0.3+67（test67）→ TARGET_ACCOUNT 指定的测试账号+ 推送邀请。

用法：TOKEN=$(ADMIN_TOKEN) TARGET_ACCOUNT=your-test-account python publish_v203_test67.py
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
    "version_name": "2.0.3",
    "version_code": 67,
    "apk_url": "https://api.seanyan.store/yzu-apk/hanshang-schedule-v2.0.3-test67.apk",
    "sha256": "412d7002ecd0a87c8542c30339679a08d5675049caeced6f899d0ada02354662",
    "is_force_update": False,
    "target_accounts": [TARGET_ACCOUNT],
    "notify_targets": True,
    "release_notes": (
        "内测版（test67）：课表显示设置 + 体验打磨。\n"
        "\n"
        "本次改动：\n"
        "· 新增：周视图「课表显示」设置——可收起晚间空白（默认只显示 1-8 节，"
        "有晚课或晚间日程时自动延长）、可隐藏周六周日（周末有安排时保留一键"
        "展开入口，不会漏掉任何课程或日程）\n"
        "· 优化：课表页右上角按钮升级为「课表显示与学期设置」弹层，学期设置"
        "入口挪进去了\n"
        "· 承接 test66：共同空闲入口恢复、支持作者页（我的→支持作者，扫码"
        "支持）、头像与收款码本地缓存、审查修复 33 项全部在内\n"
        "\n"
        "验收点：\n"
        "1. 课表页右上角新弹层：开关「收起晚间空白」「显示周六周日」即时生效\n"
        "2. 隐藏周末后，如果周末有课/日程，表头出现展开按钮，点开能看全\n"
        "3. 有晚课时行高自动延长到对应节次，提醒不受显示设置影响\n"
        "4. 回归 test66 的验收点（共同空闲入口、关于页缓存、支持作者页）"
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
