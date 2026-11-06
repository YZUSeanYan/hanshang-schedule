"""安全部署「分小班课表识别」服务端修复（2026-10-26）。

流程（先备份、可回滚）：
  1. 服务器 /opt 源码树两份被改文件 cp -n 备份（.bak-splitclass-20261026）
  2. 上传 llm_schedule_import.py + endpoints/llm_schedule_import.py（含测试与样本）
  3. docker cp 进容器 /code 并重启（运行中进程还是旧代码，必须重启）
  4. 验证：health 200 + 容器内导入烟测 + 路由存在性
回滚：把 .bak-splitclass-20261026 文件 cp 回原名再重启容器。
"""
from __future__ import annotations

import subprocess
from pathlib import Path

KEY = r"C:\path\to\secrets\ssh-runtime\your-ssh-key"  # 撇号目录的无撇号暂存副本
HOST = "deploy@your-server.example"
CONTAINER = "yzu-schedule-api"
ROOT = Path(r"C:\dev\hanshang\server")

# (本地相对路径, 服务器相对 /opt/yzu-schedule/server 的路径)
UPLOADS = [
    ("app/services/llm_schedule_import.py", "app/services/llm_schedule_import.py"),
    ("app/services/file_schedule_import.py", "app/services/file_schedule_import.py"),
    ("app/api/v1/endpoints/llm_schedule_import.py", "app/api/v1/endpoints/llm_schedule_import.py"),
    ("tests/test_file_parse_timetable.py", "tests/test_file_parse_timetable.py"),
    ("tests/fixtures/yzu-split-class-timetable-202610.xlsx",
     "tests/fixtures/yzu-split-class-timetable-202610.xlsx"),
]
BACKUP_SUFFIX = ".bak-splitclass-20261026"


def ssh(remote: str, check: bool = True) -> subprocess.CompletedProcess:
    return subprocess.run(
        ["ssh", "-o", "BatchMode=yes", "-i", KEY, HOST, remote],
        check=check, capture_output=True, text=True)


def scp(src: Path, dst: str) -> None:
    subprocess.run(
        ["scp", "-o", "BatchMode=yes", "-i", KEY, str(src), f"{HOST}:{dst}"],
        check=True, capture_output=True, text=True)


def main() -> None:
    base = "/opt/yzu-schedule/server"
    # 1. 备份（远端可能还没有该文件——仅备份已存在的）
    cmds = []
    for _, remote in UPLOADS:
        if remote.endswith(".py"):
            cmds.append(
                f"[ ! -f {base}/{remote} ] || cp -n {base}/{remote} {base}/{remote}{BACKUP_SUFFIX}"
            )
    ssh(" && ".join(cmds) + " && echo backups-ok")
    print("[1/4] 备份完成（.bak-splitclass-20261026）")

    # 2. 上传
    for local, remote in UPLOADS:
        target_dir = f"{base}/{remote.rsplit('/', 1)[0]}"
        ssh(f"mkdir -p {target_dir}")
        scp(ROOT / local, f"{base}/{remote}")
        print(f"[2/4] 已上传 {remote}")

    # 3. 容器内更新 + 重启（运行进程是旧代码，重启才生效；测试文件不进容器）
    for local, remote in UPLOADS:
        if not remote.endswith(".py") or not remote.startswith("app/"):
            continue
        ssh(f"docker cp {base}/{remote} {CONTAINER}:/code/{remote}")
    ssh(f"docker restart {CONTAINER}")
    print(f"[3/4] 容器 {CONTAINER} 已更新并重启")

    # 4. 验证
    health = ssh("curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8000/api/health")
    print(f"[4/4] health: {health.stdout.strip()}")
    smoke = ssh(
        f"docker exec {CONTAINER} python -c \""
        "from app.api.v1.router import api_router; "
        "from app.services.llm_schedule_import import extract_class_grid_schedule, extract_structured_table; "
        "print('import-ok, routes:', sum(1 for r in api_router.routes))"
        "\""
    )
    print("[4/4] 容器内烟测:", smoke.stdout.strip())
    logs = ssh(f"docker logs --since 1m {CONTAINER} 2>&1 | tail -5")
    print("[4/4] 启动日志尾部:")
    print(logs.stdout.strip())


if __name__ == "__main__":
    main()
