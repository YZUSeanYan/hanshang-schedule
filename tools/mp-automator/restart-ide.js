/*
 * 干净重启微信开发者工具。
 *
 * 两个必须点名的坑（都踩过）：
 *
 * 1. 残留的单实例锁会让后续启动直接退出并打印「已有运行中的实例」，而进程其实
 *    已经不在了。锁文件在 %APPDATA%\<应用名>\lockfile。
 * 2. **绝不能按 "找 %APPDATA% 下所有 lockfile" 来删**——Electron 系应用普遍都有
 *    这个文件，ZCode、WPS 灵犀、SodaMusic 目录下各有一个。曾经这么写过，扫描
 *    结果里包含 ZCode 自己的锁，只因为正被占用才没删掉。所以这里路径写死，
 *    只处理开发者工具那一个。
 *
 * 路径含中文，所以文件操作全走 Node（fs 用 UTF-16 系统调用），不经过 shell。
 *
 * 用法：node tools/automator/restart-ide.js [项目路径]
 */
const fs = require("fs");
const path = require("path");
const { spawn } = require("child_process");

const DEVTOOLS_DIR = "C:\\Program Files (x86)\\Tencent\\微信web开发者工具";
const EXE = path.join(DEVTOOLS_DIR, "微信开发者工具.exe");
const ROAMING = path.join(process.env.APPDATA, "微信开发者工具");
const LOCK = path.join(ROAMING, "lockfile");

const projectPath = process.argv[2] || "";

if (!fs.existsSync(EXE)) {
  console.error("找不到可执行文件：", EXE);
  process.exit(1);
}

// 清锁：只有在确实位于开发者工具目录下时才动手
if (LOCK.startsWith(ROAMING) && fs.existsSync(LOCK)) {
  try {
    fs.unlinkSync(LOCK);
    console.log("已删除残留锁：", LOCK);
  } catch (error) {
    console.log(`锁文件未能删除（${error.code}）——多半还有进程占用，先关掉开发者工具再试`);
  }
} else {
  console.log("没有残留锁需要处理");
}

const child = spawn(EXE, projectPath ? ["-o", projectPath] : [], {
  cwd: DEVTOOLS_DIR,
  detached: true,
  stdio: "ignore",
  windowsHide: false,
});
child.unref();
console.log("已启动开发者工具，PID:", child.pid);
