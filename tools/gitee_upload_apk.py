"""把 APK 上传到 Gitee Release（seanyan-dev/hanshang-apk）。

用法：python gitee_upload_apk.py <tag> <apk_path>
- 私人令牌从 C:\\dev\\secrets\\gitee-token.txt 读取，不写进任何源码；
- Release 不存在则自动创建（tag 缺失时基于仓库默认分支自动打 tag）；
- 附件同名已存在时先删后传（幂等）。
"""
import json
import sys
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

TOKEN = Path(r"C:\path\to\secrets\gitee-token.txt").read_text(encoding="utf-8").strip()
OWNER, REPO = "seanyan-dev", "hanshang-apk"
# 目标主机硬编码白名单：仅允许 gitee.com 的 HTTPS API，不接收动态主机输入
ALLOWED_HOST = "gitee.com"
API = f"https://{ALLOWED_HOST}/api/v5/repos/{OWNER}/{REPO}"


def _assert_gitee(url: str) -> None:
    parsed = urllib.parse.urlparse(url)
    assert parsed.scheme == "https", "只允许 HTTPS"
    assert parsed.hostname == ALLOWED_HOST, f"主机不在白名单: {parsed.hostname}"
    assert parsed.path.startswith(f"/api/v5/repos/{OWNER}/{REPO}"), "路径越界"


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


_OPENER = urllib.request.build_opener(_NoRedirect)


def _call(url, data=None, headers=None, method="GET"):
    _assert_gitee(url)
    request = urllib.request.Request(url, data=data, headers=headers or {}, method=method)
    with _OPENER.open(request, timeout=60) as resp:
        return json.loads(resp.read().decode("utf-8"))


def main() -> None:
    tag, apk = sys.argv[1], Path(sys.argv[2])
    if not apk.exists():
        raise SystemExit(f"APK 不存在: {apk}")
    qs = urllib.parse.urlencode({"access_token": TOKEN})

    # 1. 已有 Release？（注意：Gitee 对不存在的 tag 会返回 200 + null body）
    release = None
    try:
        release = _call(f"{API}/releases/tags/{tag}?{qs}")
    except urllib.error.HTTPError as error:
        if error.code != 404:
            raise
    if release is None or not isinstance(release, dict):
        body = json.dumps({
            "access_token": TOKEN,
            "tag_name": tag,
            "name": tag,
            "body": f"邗上课表 {tag} 内测包，详见应用内更新说明。",
            "prerelease": True,
            "target_commitish": "master",
        }).encode()
        release = _call(
            f"{API}/releases",
            data=body,
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        print(f"release created: id={release['id']} tag={tag}")
    else:
        print(f"release exists: id={release['id']}")

    release_id = release["id"]

    # 2. 同名附件先删后传（幂等）
    assets = _call(f"{API}/releases/{release_id}/attach_files?{qs}")
    for asset in assets:
        if asset.get("name") == apk.name or asset.get("file_name") == apk.name:
            _call(
                f"{API}/releases/{release_id}/attach_files/{asset['id']}?{qs}",
                method="DELETE",
            )
            print(f"deleted old attachment: {asset.get('id')}")
            break

    boundary = "----giteeUploadBoundary"
    file_bytes = apk.read_bytes()
    parts = (
        f"--{boundary}\r\n"
        f'Content-Disposition: form-data; name="access_token"\r\n\r\n'
        f"{TOKEN}\r\n"
        f"--{boundary}\r\n"
        f'Content-Disposition: form-data; name="file"; filename="{apk.name}"\r\n'
        f"Content-Type: application/vnd.android.package-archive\r\n\r\n"
    ).encode("utf-8") + file_bytes + f"\r\n--{boundary}--\r\n".encode()
    _call(
        f"{API}/releases/{release_id}/attach_files",
        data=parts,
        headers={"Content-Type": f"multipart/form-data; boundary={boundary}"},
        method="POST",
    )
    size_mb = len(file_bytes) / 1048576
    print(f"uploaded: {apk.name} ({size_mb:.1f} MB)")
    print(f"download url: https://gitee.com/{OWNER}/{REPO}/releases/download/{tag}/{apk.name}")


if __name__ == "__main__":
    main()
