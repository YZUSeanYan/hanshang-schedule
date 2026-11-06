/*
 * 直接启动微信开发者工具 GUI（CLI 的自动拉起在我们的环境里不生效）。
 *
 * 同样是为绕开中文路径：Node 的 spawn 在 Windows 上走 CreateProcessW，
 * 路径不会经过代码页转换；bash 里带中文的 start/路径参数会被搞坏。
 *
 * 用法：node tools/ide-launch.js            # 启动 IDE 主界面
 *       node tools/ide-launch.js <项目路径>  # 启动并直接打开某个项目
 */
const { spawn } = require("child_process");
const fs = require("fs");

const EXE = "C:\\Program Files (x86)\\Tencent\\微信web开发者工具\\微信开发者工具.exe";
if (!fs.existsSync(EXE)) {
  console.error("找不到微信开发者工具.exe：", EXE);
  process.exit(1);
}

const projectPath = process.argv[2] || "";
const args = projectPath ? ["-o", projectPath] : [];

const child = spawn(EXE, args, { detached: true, stdio: "ignore", windowsHide: false });
child.unref();
console.log(`已启动微信开发者工具${projectPath ? `，项目：${projectPath}` : ""}`);
console.log("PID:", child.pid);
