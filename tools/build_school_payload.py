"""构建 import-runtime schema 2 payload：从拾光课表适配仓库（shiguang_warehouse，MIT）
导入学校目录，与内置名单合并，产出待签名 payload JSON 与收录报告。

学校数据来源（只读 public raw 文件，仅允许 https + 域名白名单）：
  https://raw.githubusercontent.com/XingHeYuZhuan/shiguang_warehouse/main/index/root_index.yaml
  https://raw.githubusercontent.com/XingHeYuZhuan/shiguang_warehouse/main/resources/<folder>/adapters.yaml

用法：
  python build_school_payload.py                     # 拉取 + 生成 payload（不签名不发布）
  python build_school_payload.py --current-rev 11    # 跳过线上查询，指定当前 revision
  python build_school_payload.py --out <dir>         # 输出目录（默认 C:\\dev\\hanshang\\ops\\import-runtime）

产出：<out>/payload-v2-<rev>.json 与 <out>/report-v2-<rev>.md
签名发布用 publish_runtime.py（本目录）。
"""
from __future__ import annotations

import argparse
import base64
import json
import re
import sys
import time
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from urllib.parse import urlparse

# ---- 安全约束：只允许这两个 https 域名（Mimosa/SSRF 红线）----
ALLOWED_HOSTS = {'raw.githubusercontent.com', 'api.seanyan.store'}
RAW_BASE = 'https://raw.githubusercontent.com/XingHeYuZhuan/shiguang_warehouse/main/'

# 拾光索引里的特殊条目（通用教务/工具），不是具体学校，不进目录
SPECIAL_IDS = {'GLOBAL_TOOLS'}
SPECIAL_ID_SUFFIX = '_jiaowu'

# 教务系统标签启发式（与 App 内置标签风格一致）
SYSTEM_KEYWORDS = [
    ('正方', '正方教务'), ('强智', '强智'), ('青果', '青果教务'),
    ('超星', '超星'), ('金智', '金智'), ('URP', 'URP系统'),
]

# 与客户端 ImportRuntime 一致的约束
MAX_SCHOOLS = 400
INITIAL_RE = re.compile(r'^[A-Z]$')


def fetch(url: str, retries: int = 3) -> bytes:
    uri = urlparse(url)
    assert uri.scheme == 'https', url
    assert uri.hostname in ALLOWED_HOSTS, f'host not allowlisted: {uri.hostname}'
    last: Exception | None = None
    for attempt in range(retries):
        try:
            req = urllib.request.Request(url, headers={'User-Agent': 'hanshang-ops/1.0'})
            with urllib.request.urlopen(req, timeout=30) as resp:
                return resp.read()
        except Exception as exc:  # noqa: BLE001
            last = exc
            time.sleep(1.0 + attempt)
    raise RuntimeError(f'fetch failed: {url}: {last}')


def parse_flat_yaml_items(text: str) -> list[dict[str, str]]:
    """解析拾光仓库的扁平 YAML（列表项为缩进 `- ` 开始、键值对在后续行）。

    只支持该仓库实际使用的扁平结构，不做通用 YAML。
    """
    items: list[dict[str, str]] = []
    current: dict[str, str] | None = None
    for raw in text.splitlines():
        line = raw.rstrip()
        if not line or line.lstrip().startswith('#'):
            continue
        stripped = line.strip()
        if stripped.startswith('- '):
            current = {}
            items.append(current)
            stripped = stripped[2:]
        if current is None or ': ' not in stripped and not stripped.endswith(':'):
            continue
        if ': ' in stripped:
            key, _, value = stripped.partition(': ')
        else:
            key, _, value = stripped.partition(':')
        key = key.strip()
        value = value.strip().strip('"').strip("'").split(' #')[0].strip()
        if key:
            current[key] = value
    return items


def derive_system(text: str) -> str:
    for keyword, label in SYSTEM_KEYWORDS:
        if keyword.lower() in text.lower():
            return label
    return ''


def builtin_entries() -> list[dict[str, str]]:
    """从 App 源码提取内置名单（内置条目在其 host 上优先于拾光数据）。"""
    app_file = Path(r'C:\dev\hanshang\app\lib\features\course_import\data\school_directory.dart')
    text = app_file.read_text(encoding='utf-8')
    pattern = re.compile(
        r"SchoolEntry\(\s*name:\s*'([^']+)'\s*,\s*url:\s*'([^']+)'\s*,"
        r"\s*system:\s*'([^']*)'\s*,?\s*\)", re.S)
    out = []
    for name, url, system in pattern.findall(text):
        out.append({'name': name, 'url': url, 'system': system, 'initial': '', 'guide': ''})
    assert out, 'failed to parse builtin school_directory.dart'
    return out


def fetch_live_payload() -> dict:
    """取线上当前 payload：全局槽位字段原样沿用，revision 用于自增。"""
    try:
        raw = fetch('https://api.seanyan.store/yzu/api/import-runtime', retries=2)
        envelope = json.loads(raw.decode('utf-8'))
        payload = json.loads(base64.b64decode(envelope['payload']).decode('utf-8'))
        print(f"live payload: schema={payload.get('schema')} revision={payload.get('revision')}")
        return payload
    except Exception as exc:  # noqa: BLE001
        print(f'WARN: 无法读取线上 payload（{exc}），全局槽位将使用内置扬大默认值')
        return {}


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument('--current-rev', type=int, default=0, help='跳过线上查询直接指定当前 revision')
    parser.add_argument('--out', default=r'C:\dev\hanshang\ops\import-runtime')
    args = parser.parse_args()

    out_dir = Path(args.out)
    out_dir.mkdir(parents=True, exist_ok=True)

    # 1. 学校索引
    index_items = parse_flat_yaml_items(
        fetch(RAW_BASE + 'index/root_index.yaml').decode('utf-8'))
    schools_index = [
        it for it in index_items
        if it.get('id') and it['id'] not in SPECIAL_IDS
        and not it['id'].endswith(SPECIAL_ID_SUFFIX)
    ]
    print(f'root_index: {len(index_items)} 条，其中学校 {len(schools_index)} 所')

    # 2. 并发拉取各校 adapters.yaml，提取 https 的 import_url 与系统标签
    def load_school(entry: dict[str, str]) -> dict:
        folder = entry.get('resource_folder') or entry['id']
        try:
            adapters = parse_flat_yaml_items(
                fetch(RAW_BASE + f'resources/{folder}/adapters.yaml').decode('utf-8'))
        except Exception as exc:  # noqa: BLE001
            return {'entry': entry, 'urls': [], 'error': str(exc)}
        urls: list[str] = []
        label = ''
        for adapter in adapters:
            url = adapter.get('import_url', '')
            if not url:
                continue
            parsed = urlparse(url)
            if parsed.scheme != 'https' or not parsed.hostname:
                continue
            if parsed.fragment:
                # SPA hash 路由（如 https://jw.x.com/#/login）→ 只留站点根
                url = url.split('#', 1)[0]
            parsed = urlparse(url)
            if parsed.port not in (None, 443) or parsed.username or parsed.password:
                continue
            if not urls:
                urls.append(url)
                label = derive_system(
                    adapter.get('adapter_name', '') + ' ' + adapter.get('description', ''))
        return {'entry': entry, 'urls': urls, 'label': label}

    results = []
    with ThreadPoolExecutor(max_workers=8) as pool:
        for result in pool.map(load_school, schools_index):
            results.append(result)
            name = result['entry'].get('name', result['entry'].get('id', '?'))
            status = 'ok' if result['urls'] else ('error' if 'error' in result else 'no-https')
            print(f"  [{status}] {name}")

    # 3. 合并：内置名单优先（host 去重），拾光按索引顺序补齐
    merged: list[dict] = []
    seen_hosts: set[str] = set()
    skipped_http: list[str] = []
    skipped_no_https: list[str] = []
    builtin_overlap: list[str] = []

    def host_of(url: str) -> str:
        return (urlparse(url).hostname or '').lower()

    for item in builtin_entries():
        host = host_of(item['url'])
        if host and host not in seen_hosts:
            seen_hosts.add(host)
            merged.append(item)

    for result in results:
        entry = result['entry']
        name = entry.get('name') or entry.get('id', '')
        initial = entry.get('initial', '')
        if not INITIAL_RE.match(initial):
            initial = ''
        if not result['urls']:
            if 'error' in result:
                skipped_no_https.append(f'{name}（adapters.yaml 拉取失败）')
            else:
                skipped_no_https.append(f'{name}（无 https 教务地址）')
            continue
        url = result['urls'][0]
        if host_of(url) in seen_hosts:
            builtin_overlap.append(name)
            continue
        seen_hosts.add(host_of(url))
        merged.append({
            'name': name,
            'url': url,
            'system': result.get('label', ''),
            'initial': initial,
            'guide': '',
        })
        if len(merged) >= MAX_SCHOOLS:
            print(f'WARN: 达到 {MAX_SCHOOLS} 条上限，剩余学校未收录')
            break

    # 4. 沿用线上全局槽位，revision 自增
    live = fetch_live_payload() if not args.current_rev else {}
    revision = (args.current_rev or int(live.get('revision', 0))) + 1
    now = int(time.time())
    payload = {
        'schema': 2,
        'revision': revision,
        'minBuild': 68,
        'maxBuild': 999,
        'issuedAt': now,
        'expiresAt': now + 30 * 86400,
        'entryUrl': live.get('entryUrl', 'https://webvpn.yzu.edu.cn/'),
        'enabled': live.get('enabled', True),
        'guide': live.get('guide', ''),
        'urlHints': live.get('urlHints', []),
        'fieldAliases': live.get('fieldAliases', {}),
        'intermediates': live.get('intermediates', []),
        'schools': merged,
    }

    payload_path = out_dir / f'payload-v2-{revision}.json'
    payload_path.write_text(
        json.dumps(payload, ensure_ascii=False, separators=(',', ':')),
        encoding='utf-8')

    # 5. 报告
    report = [
        '# import-runtime v2 学校目录收录报告', '',
        f'- payload: `{payload_path.name}`，revision {revision}',
        f'- 索引学校总数：{len(schools_index)}',
        f'- 收录（含内置 {len(builtin_entries())} 所）：{len(merged)}',
        f'- 与内置名单 host 重叠跳过：{len(builtin_overlap)}',
        f'- 未收录（无 https 地址/拉取失败）：{len(skipped_no_https)}',
        f'- 规模上限：{MAX_SCHOOLS}', '',
        '## 未收录清单',
        *[f'- {n}' for n in (skipped_no_https or ['（无）'])],
        '', '## 数据来源与许可',
        '- 学校/URL/首字母数据来自 XingHeYuZhuan/shiguang_warehouse（MIT License），',
        '  仅作目录数据使用，不含其任何 JS 适配脚本。',
    ]
    report_path = out_dir / f'report-v2-{revision}.md'
    report_path.write_text('\n'.join(report), encoding='utf-8')
    print(f'\npayload → {payload_path}')
    print(f'report  → {report_path}')
    print(f'收录 {len(merged)} 所学校')
    return 0


if __name__ == '__main__':
    sys.exit(main())
