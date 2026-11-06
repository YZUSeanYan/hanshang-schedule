/*
 * 微信开发者工具 CLI 的调用包装。
 *
 * 两个坑都是实测踩出来的：
 *  1. 安装路径含中文，从 Git Bash 经 cmd.exe 传递会按本地代码页重新编码成乱码，
 *     报「不是内部或外部命令」。Node 在 Windows 上走 CreateProcessW、参数是
 *     UTF-16，中文路径不会失真，所以统一走 Node。
 *  2. 不能直接 node cli.js —— 它内部要求相对自己目录解析 js/common/cli/index.js，
 *     换工作目录就找不到模块；也不能 spawn .bat 时用 shell:true（路径含空格会被
 *     拆开）。可行组合是 spawnSync("cmd.exe", ["/c", cliBat, ...args])：参数以数组
 *     传入，由 Node 负责 Windows 命令行转义，不经过 shell 解析。
 *
 * 用法：node tools/wxcli.js <cli 参数...>
 *   node tools/wxcli.js islogin
 *   node tools/wxcli.js open --project .
 *   node tools/wxcli.js auto --project . --auto-port 9420
 */
const { spawnSync } = require("child_process");
const fs = require("fs");

const CANDIDATES = [
  "C:\\Program Files (x86)\\Tencent\\微信web开发者工具\\cli.bat",
  "C:\\Program Files\\Tencent\\微信web开发者工具\\cli.bat",
  "D:\\Program Files (x86)\\Tencent\\微信web开发者工具\\cli.bat",
];

function findCli() {
  for (const candidate of CANDIDATES) {
    if (fs.existsSync(candidate)) return candidate;
  }
  throw new Error(`找不到微信开发者工具 CLI，已尝试：\n  ${CANDIDATES.join("\n  ")}`);
}

const cli = findCli();
const args = process.argv.slice(2);
if (!args.length) {
  console.log(`CLI 路径：${cli}`);
  console.log("用法：node tools/wxcli.js <参数...>");
  process.exit(0);
}

const result = spawnSync("cmd.exe", ["/c", cli, ...args], { stdio: "inherit", windowsHide: true });
if (result.error) {
  console.error("调用失败：", result.error.message);
  process.exit(1);
}
process.exit(result.status === null ? 1 : result.status);
