"""定向内测发布：邗上课表 2.0.3+65 → TARGET_ACCOUNT 指定的测试账号可见 + 推送邀请。

用法：TOKEN=$(ADMIN_TOKEN) TARGET_ACCOUNT=your-test-account python publish_v203_test65.py
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
    "version_code": 65,
    "apk_url": "https://api.seanyan.store/yzu-apk/hanshang-schedule-v2.0.3-test65.apk",
    "sha256": "01ffb0ec6d989420d00335df085ad68faeadc519fe8dd6107241fb77c58e8541",
    "is_force_update": False,
    "target_accounts": [TARGET_ACCOUNT],
    "notify_targets": True,
    "release_notes": (
        "内测版（test65）：本轮全量代码审查修复后的第一个测试包。\n"
        "\n"
        "主要修复：\n"
        "· 数据安全：账号切换串号、同步删除丢失、旧墓碑误删新修改、同秒内两次修改丢失、超大课表同步漏传、老版本数据库迁移失败等 9 个 P0\n"
        "· 提醒：定时提醒到点不响的问题已修；重启后恢复统一走系统链路，App 内关闭提醒后不再误响\n"
        "· 课表：双周课错排到单周；调休变化即时联动提醒/小组件/其他设备；冲突展开层嵌套分栏修正\n"
        "· 小组件：放假/补课显示与 App 一致；跨午夜自动更新日期和课程\n"
        "· 导入：SPA 切学期后不再导入旧学期；上传前脱敏覆盖密码/token 字段；节次越界不再崩溃\n"
        "· 其他：断网恢复后自动补同步；刷新 token 后的业务报错不再误登出\n"
        "\n"
        "请重点验收：\n"
        "1. 直接覆盖安装，检查课表/日程/调休数据是否完整\n"
        "2. 排一个 2 分钟后的课前提醒，杀进程和重启各验一次是否送达\n"
        "3. 桌面小组件放置跨午夜，看日期和课程是否自动翻页\n"
        "4. 断网改一条日程，恢复联网后看是否自动同步\n"
        "5. 教务网页切换学期后再用 AI 兜底导入，确认导入的是当前学期"
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
