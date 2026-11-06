"""邗上课表隐私政策单一事实来源。

从同一份分节文本生成三端产物：
  1. 官网 privacy.html 的正文块
  2. 网页版 index.html 的 privacy-dialog / privacy-consent-dialog
  3. App 的 bundledPrivacyPolicy.body 与 privacy_policy_page.dart 分节

改政策时只改本文件的 SECTIONS / VERSION，然后跑：
    python tools/privacy_policy.py --check      # 校验三端是否与本文本一致
    python tools/privacy_policy.py --write      # 写回三端
"""

from __future__ import annotations

import argparse
import html
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

VERSION = 7
EFFECTIVE_DATE = "2026 年 9 月 22 日"
SUMMARY = (
    "统一 App、网页版与官网的政策文本：补充网页版 AI 日程的文字与图片录入说明，"
    "订正共同空闲的用户名搜索描述，合并此前分散的说明。"
)
POLICY_ID = f"privacy-v{VERSION}"

CN_NUMS = "一二三四五六七八九十十一十二十三十四十五".replace("十一", "十一")


def _cn(index: int) -> str:
    """1 -> 一, 11 -> 十一"""
    nums = "一二三四五六七八九十"
    if index <= 10:
        return nums[index - 1]
    if index < 20:
        return "十" + nums[index - 11]
    return "二十" + (nums[index - 21] if index > 20 else "")


# 每节 = (标题, [段落, ...])；段落 = [行, ...]，行在 HTML 里用 <br> 连，在 App 里用 \n 连。
SECTIONS: list[tuple[str, list[list[str]]]] = [
    (
        "我们处理的信息",
        [
            [
                "为提供账号登录、课表导入与同步、课程与日程提醒、账户通知、共同空闲和安全保障，我们处理以下必要信息：",
            ],
            [
                "① <b>账号信息</b>：你主动提供的用户名和邮箱，用于登录、找回密码、用户名邀请和识别通知归属。登录密码只以 bcrypt 不可逆哈希存储，包括管理员在内的任何人都无法取得明文；",
                "② <b>课表数据</b>：你主动创建或导入的学期、课程、周次、地点与时间安排，用于展示、提醒、多设备同步和你主动使用的分享功能；",
                "③ <b>日程数据</b>：你通过文字、图片、语音或手动创建并确认保存的个人日程（标题、时间、地点），用于展示、提醒与多设备同步；在「共同空闲」中日程只以「忙碌/空闲」状态参与计算，配对对象看不到日程内容；",
                "④ <b>共同空闲数据</b>：邀请、连接关系和每节课的忙闲结果；",
                "⑤ <b>账户通知</b>：通知标题、正文、业务类型、发送与读取状态，供 App 和网页版收件箱展示；",
                "⑥ <b>安全与会话信息</b>：登录刷新令牌、受限功能会话凭证以及必要的访问时间、请求大小、耗时和错误码等安全运行日志。",
            ],
        ],
    ),
    (
        "教务账号与密码",
        [
            [
                "我们不接收、不传输、不存储你的教务系统账号和密码。你在网页或 App 内登录学校系统时，账号密码只经过你的设备与学校系统服务器；我们的服务器没有接收教务密码的接口。",
            ],
        ],
    ),
    (
        "截图、表格与页面 AI 导入",
        [
            ["AI 解析仅在你主动选择文件或主动确认解析后触发，每用户每天限 10 次。"],
            [
                "① <b>课表截图</b>：截图会经服务器转交第三方大模型小米 MiMo 作一次识别。截图无法在上传前可靠自动遮盖身份信息，请先裁掉姓名、学号等与课表无关的区域；",
                "② <b>Excel/CSV 表格</b>：XLSX、XLS、CSV 文件只读解析。服务器只提取有界的单元格文本，并对姓名、学号、手机号等常见身份信息脱敏后，再交给 MiMo；",
                "③ <b>课表页面兜底解析</b>：仅在本地解析失败且你主动确认后使用。设备端先移除常见身份字段和长数字串，服务器收到后再次脱敏，只提取课表结构用于一次解析；",
                "④ <b>不留存原始内容</b>：原始文件、页面原文、提取文本和模型响应不写入数据库或业务日志，处理完成后从内存丢弃；日志只记录文件类型、大小、数量、耗时和错误码等运行元数据。",
            ],
            ["不使用相应的 AI 导入功能，就不会上传上述截图、表格或页面内容。"],
        ],
    ),
    (
        "AI 日程与文字、图片、语音录入",
        [
            [
                "AI 日程仅在你主动输入文字、选择图片（拍照或相册）或按住麦克风说话后触发，每用户每天限 30 次。语音录入目前仅在 Android App 提供，网页版支持文字与图片。",
            ],
            [
                "① <b>语音即转即删</b>：录音在你松手后上传服务器一次，经小米 MiMo 语音识别转写为文字；音频与转写文本不写入数据库、不写入日志，识别完成即从内存丢弃；",
                "② <b>图片与文字</b>：你选择的图片经压缩后上传服务器一次，与输入的文字一样交由小米 MiMo 识别为结构化日程；图片、文字与识别结果不写入数据库、不写入日志，识别完成即从内存丢弃。选择图片前页面会请你确认已核对内容；",
                "③ <b>文本理解</b>：转写文本、输入文字或图片识别结果，经与本政策第三节相同的身份脱敏规则处理后，交由小米 MiMo 大模型提取时间、地点与事项。为正确理解「周三」「下周」「那节课」，请求会附带当天日期、你当前学期的周次与课程名列表作为上下文，除此之外不包含任何身份信息；",
                "④ <b>确认后才保存</b>：识别结果在预览页展示，由你确认或修改后才保存为日程；",
                "⑤ <b>麦克风权限</b>：仅语音录入需要，拒绝授权不影响文字与图片输入及其他全部功能。",
            ],
        ],
    ),
    (
        "共同空闲与用户名搜索",
        [
            [
                "共同空闲用于连接同学、朋友或小组成员的课表，查找双方都没有课程的节次。你可以直接输入用户名发送邀请，也可以输入至少 2 个字符进行用户名开头匹配；每次最多返回 5 个结果，结果中只包含用户名，不提供邮箱、用户编号或其他账号资料。搜索和邀请接口均设置频率限制。",
            ],
            [
                "你也可以生成 8 位、15 分钟有效的邀请码。服务器只保存邀请码的不可逆摘要，原码只在生成方当前页面中短暂显示。对方明确接受用户名邀请或主动输入邀请码后才建立连接。",
            ],
            [
                "连接建立后，服务器只向连接双方提供每节课的忙闲结果和用户名，不提供课程名、教师、教室或备注。邀请可撤回或拒绝，连接可由任一方随时解除，解除后立即停止共享。",
            ],
        ],
    ),
    (
        "通知、更新提醒与第三方 SDK",
        [
            [
                "通知仅在你授权后启用。Android App 使用杭州阿里云智能科技有限公司提供的 EMAS 移动推送 SDK，网页版使用浏览器 Web Push；相关服务可能按其规则处理设备标识、应用信息、网络信息和推送日志。拒绝通知不影响课表基本功能。",
            ],
            [
                "新版本默认通过一条账户通知或系统通知告知，由你主动打开详情并决定是否更新，不因一般功能更新强制遮挡课表界面。账户通知可以在收件箱中标记已读或删除。",
            ],
            [
                "激励视频广告仅在你进入「支持作者」并主动确认后初始化穿山甲广告联盟 SDK；广告由第三方投放，播放过程中 SDK 可能处理设备标识、应用信息和网络信息。不观看广告不影响任何课表功能。",
            ],
        ],
    ),
    (
        "设备权限",
        [
            [
                "网络权限用于登录、导入和同步；通知、开机恢复提醒、闹钟、唤醒锁、振动和前台服务能力用于你主动开启的提醒与推送。文件通过系统选择器获得单个文件的一次性访问授权，不申请读写全部外部存储，也不索取通讯录、定位、相机或蓝牙权限。",
                "麦克风仅在你于 Android App「AI 日程」页按住说话时用于录音，录音实时转写后即删、不保存音频；网页版不申请麦克风权限。选择图片时由系统文件选择器或浏览器相机接管，我们同样只获得你选中的那一张图片。拒绝授权不影响文字输入与其他功能。",
            ],
        ],
    ),
    (
        "远程功能与安全",
        [
            [
                "服务器签名的功能清单可以启用当前 APK 已允许的原生入口或受限网页模块，但不能下载并执行新的 Dart 或原生代码。原生功能使用账号访问令牌；网页模块使用仅限单个功能、15 分钟有效的会话凭证。",
            ],
            [
                "不同账号的数据按用户标识隔离，服务端对每次读取和写入重新鉴权。共同空闲、通知和课表接口只返回当前账号有权访问的数据。",
            ],
        ],
    ),
    (
        "保存、共享与跨设备同步",
        [
            [
                "账号、课表与日程数据存储于境内的阿里云服务器，用于多设备同步和你主动使用的分享功能，仅在提供功能及安全审计所需期限内保存。网页版会在本机保存当前账号的课表，供断网时查看，退出登录时清除这份缓存。我们不出售个人信息；除上述云服务基础设施、小米 MiMo、推送和广告服务（处理范围以本政策为限），以及法律法规要求外，不向无关第三方共享。",
            ],
            ["账号注销后，除依法需要保留的安全日志外，其余关联数据会删除。"],
        ],
    ),
    (
        "你的权利",
        [
            [
                "你可以退出登录、关闭通知、删除账户通知、撤销邀请或连接，并通过 <a href=\"mailto:hanshangdeveloper@163.com\">hanshangdeveloper@163.com</a> 联系管理员查询、更正或删除账号及云端数据。",
            ],
        ],
    ),
    (
        "政策更新",
        [
            [
                f"政策发生重大变化时，我们会通过 App 内提示、网站公告或推送告知，并在法律要求或处理目的发生重大变化时请求你重新同意。",
            ],
            [
                f"本次第 {VERSION} 版把 App、网页版与官网的政策统一为同一份文本：补充网页版 AI 日程的文字与图片录入说明，订正共同空闲的用户名搜索描述，并合并此前分散的说明。本次不新增处理目的、不新增系统权限，已同意用户无需再次确认。",
            ],
        ],
    ),
]


def _strip_tags(text: str) -> str:
    return re.sub(r"<[^>]+>", "", text)


# ---------- 产物 1：官网 privacy.html 正文 ----------

def render_site_body() -> str:
    out = []
    for i, (title, paras) in enumerate(SECTIONS, 1):
        out.append(f"    <h2>{_cn(i)}、{title}</h2>")
        for para in paras:
            joined = "<br>\n    ".join(para)
            out.append(f"    <p>{joined}</p>")
        out.append("")
    return "\n".join(out).rstrip() + "\n"


# ---------- 产物 2：网页版弹层 ----------

def render_pwa_dialog() -> str:
    parts = [
        "<h2>邗上课表隐私政策</h2>"
        '<button type="button" class="dialog-close" data-close="privacy-dialog" '
        'aria-label="关闭"><svg class="icon" aria-hidden="true"><use href="#i-close"/></svg></button>'
        "</div>"
        f"<p><b>生效日期：{EFFECTIVE_DATE}（第 {VERSION} 版）</b></p>"
    ]
    for title, paras in SECTIONS:
        parts.append(f"<h3>{title}</h3>")
        for para in paras:
            text = "".join(_strip_tags(line) for line in para)
            parts.append(f"<p>{text}</p>")
    return "".join(parts) + "</div></dialog>"


def render_pwa_consent() -> str:
    return (
        "<h2>欢迎使用邗上课表</h2></div>"
        '<p>使用前请阅读并同意<a href="#" id="privacy-consent-link">《邗上课表隐私政策》</a>。'
        f"<b>政策已于 {EFFECTIVE_DATE} 更新至第 {VERSION} 版，{SUMMARY}"
        "已同意用户无需再次确认。</b>"
        "我们仅为提供账号登录、课表导入与同步、课程提醒处理必要信息，不出售个人信息。</p>"
        '<p class="security-note">首次同意前不会发起业务网络请求，也不会写入登录 Cookie。</p>'
        '<div class="dialog-actions"><button id="privacy-consent-decline" class="btn-text" '
        'type="button">不同意</button><button id="privacy-consent-accept" class="btn" '
        'type="button">同意并继续</button></div></div></dialog>'
    )


# ---------- 产物 3：App Dart ----------

def _dart_escape(text: str) -> str:
    plain = _strip_tags(text).replace("'", r"\'")
    return plain


def render_dart_body() -> str:
    """bundledPrivacyPolicy.body 的 Dart 字面量（标题由调用方 body: 前缀给出）。"""
    lines = [
        f"      '生效日期：{EFFECTIVE_DATE}（第 {VERSION} 版）\\n\\n'",
    ]
    for i, (title, paras) in enumerate(SECTIONS, 1):
        lines.append(f"      '{_cn(i)}、{title}\\n'")
        for para in paras:
            for j, line in enumerate(para):
                suffix = "\\n" if j < len(para) - 1 else "\\n\\n"
                lines.append(f"      '{_dart_escape(line)}{suffix}'")
    return "\n".join(lines)


def render_dart_sections() -> str:
    """privacy_policy_page.dart 的 const sections 列表。"""
    out = ["    const sections = <(String, String)>[", f"      ('生效日期', '{EFFECTIVE_DATE}（第 {VERSION} 版）'),"]
    for title, paras in SECTIONS:
        # 段内用 \n 断行，段间空一行，保持网页版的可读层次
        para_texts = ["\\n".join(_dart_escape(line) for line in para) for para in paras]
        joined = "\\n\\n".join(para_texts)
        out.append("      (")
        out.append(f"        '{title}',")
        out.append(f"        '{joined}'")
        out.append("      ),")
    out.append("    ];")
    return "\n".join(out)


# ---------- 写回 ----------

SITE_HTML = ROOT / "site" / "privacy.html"
PWA_HTML = ROOT / "web" / "index.html"
DART_MANIFEST = ROOT / "app" / "lib" / "core" / "remote_features" / "remote_feature_manifest.dart"
DART_PAGE = ROOT / "app" / "lib" / "features" / "privacy" / "presentation" / "privacy_policy_page.dart"


def patch_site(write: bool) -> list[str]:
    original = SITE_HTML.read_text(encoding="utf-8")
    text = original
    # 正文块：从第一个 <h2> 到 </div>\n</main>
    start = text.index("    <h2>")
    end = text.index("  </div>\n</main>")
    new = render_site_body()
    updated = text[:start] + new + text[end:]
    updated = re.sub(
        r'<span class="date">生效日期：[^<]*</span>',
        f'<span class="date">生效日期：{EFFECTIVE_DATE}（第 {VERSION} 版）</span>',
        updated,
    )
    updated = re.sub(
        r'<meta name="description" content="[^"]*">',
        '<meta name="description" content="邗上课表隐私政策：完整说明账号、课表同步、'
        "AI 日程与文字图片语音录入、截图与表格智能导入、共同空闲、通知和第三方服务的数据处理规则。\">",
        updated,
    )
    if write:
        SITE_HTML.write_text(updated, encoding="utf-8")
    elif updated != original:
        return ["site/privacy.html 与单一事实来源不一致"]
    return []


def patch_pwa(write: bool) -> list[str]:
    original = PWA_HTML.read_text(encoding="utf-8")
    text = original

    # privacy-dialog
    dlg_start = text.index('<dialog id="privacy-dialog">')
    body_start = text.index('<div class="dialog-form privacy-sheet">', dlg_start)
    head_end = text.index("<h2>邗上课表隐私政策</h2>", body_start)
    dlg_end = text.index("</dialog>", head_end) + len("</dialog>")
    new_dlg = (
        '<dialog id="privacy-dialog"><div class="dialog-form privacy-sheet">'
        + render_pwa_dialog()
    )
    text = text[:dlg_start] + new_dlg + text[dlg_end:]

    # privacy-consent-dialog
    c_start = text.index('<dialog id="privacy-consent-dialog">')
    c_head = text.index("<h2>欢迎使用邗上课表</h2>", c_start)
    c_end = text.index("</dialog>", c_head) + len("</dialog>")
    new_c = (
        '<dialog id="privacy-consent-dialog"><div class="dialog-form">'
        + render_pwa_consent()
    )
    text = text[:c_start] + new_c + text[c_end:]

    if write:
        PWA_HTML.write_text(text, encoding="utf-8")
    elif text != original:
        return ["web/index.html 与单一事实来源不一致"]
    return []


def patch_dart(write: bool) -> list[str]:
    problems: list[str] = []

    original_m = DART_MANIFEST.read_text(encoding="utf-8")
    m = original_m
    start = m.index("/// 内置政策")
    end = m.index(");\n", m.index("body: '邗上课表隐私政策")) + len(");\n")
    new_block = (
        f"/// 内置政策 v{VERSION}（{EFFECTIVE_DATE}）：{SUMMARY}\n"
        "/// 全文须与 privacy_policy_page.dart 的分节内容保持一致；\n"
        "/// 由 tools/privacy_policy.py 生成，勿手改。\n"
        "const bundledPrivacyPolicy = RemotePrivacyPolicy(\n"
        f"  id: bundledPrivacyPolicyId,\n"
        f"  revision: {VERSION},\n"
        f"  effectiveDate: '{EFFECTIVE_DATE}',\n"
        f"  summary: '{SUMMARY}',\n"
        "  body: '邗上课表隐私政策\\n\\n'\n"
        + render_dart_body()
        + "\n);\n"
    )
    m = m[:start] + new_block + m[end:]
    m = m.replace(
        "const bundledPrivacyPolicyId = 'privacy-v4';",
        f"const bundledPrivacyPolicyId = '{POLICY_ID}';",
    )
    if write:
        DART_MANIFEST.write_text(m, encoding="utf-8")
    elif m != original_m:
        problems.append("remote_feature_manifest.dart 与单一事实来源不一致")

    original_p = DART_PAGE.read_text(encoding="utf-8")
    p = original_p
    s_start = p.index("    const sections = <(String, String)>[")
    s_end = p.index("    ];", s_start) + len("    ];")
    p = p[:s_start] + render_dart_sections() + p[s_end:]
    if write:
        DART_PAGE.write_text(p, encoding="utf-8")
    elif p != original_p:
        problems.append("privacy_policy_page.dart 与单一事实来源不一致")

    return problems


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--write", action="store_true", help="写回三端")
    ap.add_argument("--check", action="store_true", help="只校验")
    args = ap.parse_args()

    problems: list[str] = []
    if args.write:
        problems += patch_site(True)
        problems += patch_pwa(True)
        problems += patch_dart(True)
        print(f"已写回三端（v{VERSION} / {EFFECTIVE_DATE}）")
        for p in problems:
            print("  ! 仍不一致:", p)
        return 1 if problems else 0

    problems += patch_site(False)
    problems += patch_pwa(False)
    problems += patch_dart(False)
    if problems:
        print("不一致:")
        for p in problems:
            print("  -", p)
        return 1
    print(f"三端一致：v{VERSION} / {EFFECTIVE_DATE}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
