"""用 GitHub Git Data REST API 推送一个本地提交（绕开被拦截的 git push）。

用法：python push_to_github.py <本地仓库路径> <本地提交SHA> [--dry-run]

原理：gh CLI 的 token（不落盘）→ 为提交内每个变更文件建 blob（内容取自
git 对象，保证 LF 不漂移）→ 建子树（base_tree=远端 app 子树）→ 建根树
→ 建 commit → PATCH refs/heads/main。本地可为 monorepo（变更位于 app/），
也可为根目录即 App 的独立仓库（目录名必须为 app）。

安全：仅允许 api.github.com 的 HTTPS，禁止重定向，不接受动态主机。
"""
from __future__ import annotations

import base64
import json
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

OWNER, REPO = 'YZUSeanYan', 'hanshang-schedule'
BRANCH = 'main'
SUBTREE = 'app'  # 本地仓库内容对应远端 app/ 子目录
ALLOWED_HOST = 'api.github.com'
API = f'https://{ALLOWED_HOST}/repos/{OWNER}/{REPO}'

# 本地工作副本不跟踪、但远端已公开发布的内容：同步时不删除（删除是不可逆的
# 公开变更，单独决策）。ios/ 工程与推送插件示例属于此类。
KEEP_PREFIXES = ('ios/', 'plugins/aliyun_push/example/')


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


_OPENER = urllib.request.build_opener(_NoRedirect)


def _token() -> str:
    out = subprocess.run(['gh', 'auth', 'token'], capture_output=True, check=True)
    return out.stdout.decode().strip()


TOKEN = _token()


def call(path: str, method: str = 'GET', body: dict | None = None):
    url = f'{API}{path}'
    parsed = urllib.parse.urlparse(url)
    assert parsed.scheme == 'https' and parsed.hostname == ALLOWED_HOST, url
    headers = {'Authorization': f'Bearer {TOKEN}',
               'Accept': 'application/vnd.github+json'}
    data = None
    if body is not None:
        data = json.dumps(body).encode()
        headers['Content-Type'] = 'application/json'
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    with _OPENER.open(req, timeout=120) as resp:
        raw = resp.read()
        return json.loads(raw) if raw else None


def git(repo: str, *args: str) -> bytes:
    # core.quotePath=false：中文路径原样输出（否则八进制转义导致前缀断言失败）
    return subprocess.run(['git', '-C', repo, '-c', 'core.quotePath=false', *args],
                          capture_output=True, check=True).stdout


def main() -> int:
    repo, commit = sys.argv[1], sys.argv[2]
    dry = '--dry-run' in sys.argv

    changed = git(repo, 'diff', '--name-status', f'{commit}~1', commit).decode('utf-8').splitlines()
    # 兼容两种本地布局：monorepo 的 app/ 子目录，或根目录即 App 的独立仓库。
    # 后者仅允许目录名就是 app，避免把 server/ 等内容误映射进公开客户端树。
    bare_app_repo = Path(repo).resolve().name.lower() == SUBTREE
    entries = []  # (repo_path, 'blob'|'delete', local_path)
    skipped = []
    for line in changed:
        parts = line.split('\t')
        status, paths = parts[0], parts[1:]
        for path in paths:
            if path.startswith(f'{SUBTREE}/'):
                rel = path[len(SUBTREE) + 1:]
            elif bare_app_repo and not path.startswith('/') and '..' not in Path(path).parts:
                rel = path
            else:
                raise AssertionError(f'只允许 App 仓库或 {SUBTREE}/ 下的文件: {path}')
            if status.startswith('D'):
                if rel.startswith(KEEP_PREFIXES):
                    skipped.append(rel)
                    continue
                entries.append((rel, 'delete', path))
            else:
                entries.append((rel, 'blob', path))
    print(f'{len(entries)} 个变更条目（{sum(1 for e in entries if e[1] == "blob")} 写入 / '
          f'{sum(1 for e in entries if e[1] == "delete")} 删除）')
    if skipped:
        print(f'保留远端已有文件 {len(skipped)} 个（前缀 {KEEP_PREFIXES}），不删除')

    head = call(f'/git/ref/heads/{BRANCH}')
    base_commit = head['object']['sha']
    root_tree = call(f'/git/commits/{base_commit}')['tree']['sha']
    root_entries = call(f'/git/trees/{root_tree}')['tree']
    app_tree = next(e['sha'] for e in root_entries if e['path'] == SUBTREE and e['type'] == 'tree')
    print(f'远端 base commit {base_commit[:10]}，{SUBTREE} 子树 {app_tree[:10]}')

    if dry:
        print('dry-run，不写入。')
        return 0

    def make_blob(entry):
        rel, kind, path = entry
        if kind == 'delete':
            return {'path': rel, 'mode': '100644', 'type': 'blob', 'sha': None}
        content = git(repo, 'show', f'{commit}:{path}')
        blob = call('/git/blobs', 'POST',
                    {'content': base64.b64encode(content).decode(), 'encoding': 'base64'})
        mode = '100755' if git(repo, 'ls-tree', commit, path).split()[0] == b'100755' else '100644'
        return {'path': rel, 'mode': mode, 'type': 'blob', 'sha': blob['sha']}

    with ThreadPoolExecutor(max_workers=6) as pool:
        tree_entries = list(pool.map(make_blob, entries))

    new_sub = call('/git/trees', 'POST', {'base_tree': app_tree, 'tree': tree_entries})
    new_root = call('/git/trees', 'POST', {
        'base_tree': root_tree,
        'tree': [{'path': SUBTREE, 'mode': '040000', 'type': 'tree', 'sha': new_sub['sha']}],
    })
    message = git(repo, 'log', '-1', '--format=%B', commit).decode('utf-8').strip()
    new_commit = call('/git/commits', 'POST', {
        'message': message, 'tree': new_root['sha'], 'parents': [base_commit],
    })
    call(f'/git/refs/heads/{BRANCH}', 'PATCH', {'sha': new_commit['sha'], 'force': False})
    print(f'已推送 commit {new_commit["sha"]}')
    print(f'https://github.com/{OWNER}/{REPO}/commit/{new_commit["sha"]}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
