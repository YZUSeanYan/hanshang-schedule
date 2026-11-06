"""部署「管理后台注销接口通用 sweep」修复（2026-11-01）。

流程：/opt 源码备份（.bak-deluser-20261101）→ 上传接口+测试 → docker cp →
重启 → 健康检查带重试（重启窗口内 502/连接失败属预期）。
回滚：cp 备份回原名再重启容器。
"""
from __future__ import annotations

import subprocess
import time
from pathlib import Path

KEY = r"C:\path\to\secrets\ssh-runtime\your-ssh-key"
HOST = "deploy@your-server.example"
CONTAINER = "yzu-schedule-api"
ROOT = Path(r"C:\dev\hanshang\server")
BASE = "/opt/yzu-schedule/server"
BACKUP_SUFFIX = ".bak-deluser-20261101"
UPLOADS = [
    "app/api/v1/endpoints/admin_console.py",
    "tests/test_admin_console.py",
]


def ssh(remote: str, check: bool = True) -> subprocess.CompletedProcess:
    return subprocess.run(
        ["ssh", "-o", "BatchMode=yes", "-i", KEY, HOST, remote],
        check=check, capture_output=True, text=True,
    )


def scp(src: Path, dst: str) -> None:
    subprocess.run(
        ["scp", "-o", "BatchMode=yes", "-i", KEY, str(src), f"{HOST}:{dst}"],
        check=True, capture_output=True, text=True,
    )


def main() -> None:
    ssh(" && ".join(
        f"[ ! -f {BASE}/{p} ] || cp -n {BASE}/{p} {BASE}/{p}{BACKUP_SUFFIX}"
        for p in UPLOADS
    ) + " && echo backups-ok")
    print("[1/4] 备份完成")

    for remote in UPLOADS:
        scp(ROOT / remote, f"{BASE}/{remote}")
        if remote.startswith("app/"):  # 测试文件只留 /opt 源码树，不进容器
            ssh(f"docker cp {BASE}/{remote} {CONTAINER}:/code/{remote}")
        print(f"[2/4] 已上传: {remote}")

    ssh(f"docker restart {CONTAINER}")
    print(f"[3/4] 容器 {CONTAINER} 已重启")

    # 4. 健康检查带重试（重启窗口内失败属预期）
    for attempt in range(12):
        time.sleep(5)
        result = ssh(
            "curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8000/api/health",
            check=False,
        )
        code = result.stdout.strip()
        if code == "200":
            print(f"[4/4] health: 200（第 {attempt + 1} 次尝试）")
            logs = ssh(f"docker logs --since 1m {CONTAINER} 2>&1 | tail -4")
            print(logs.stdout.strip())
            return
    raise SystemExit("健康检查 60s 内未通过，需人工查看容器日志")


if __name__ == "__main__":
    main()
