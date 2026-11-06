# 教务适配 · 免 APK 运维手册（import-runtime v2）

> 2026-10-02 起，学校导入适配走「签名 payload 免发版下发」。本文是唯一 SOP。

## 一、机制概览

```
tools/build_school_payload.py   生成 payload（拉拾光仓库数据 + 内置名单合并）
        ↓
tools/publish_runtime.py        本地 Ed25519 签名 → SSH 原子发布到服务器
        ↓
/api/import-runtime（公网）      客户端 2.0.4+（build ≥68）验签后按 host 生效
```

- **私钥**：`~/.ssh/your-import-runtime-signing-key.pem`（本机，服务器上刻意没有）。
  公钥 = 客户端硬编码 `PP6R0zkQiz3nyU0lLDlJdBo2yP4Uui9ok7btmu5e8Yw=`。
- **服务器**：`deploy@your-server.example`（密钥 `~/.ssh/your-ssh-key`），文件
  `/data/import-runtime-v1.json`（容器 yzu-schedule-api 内），历史版本自动归档
  `/data/import-runtime-history/<rev>.json`，**拒绝 revision 回退**。
- **安全模型**：仅声明式数据（无远程代码）；urlHints 白名单正则防 JS 注入；
  任一条目非法 → 客户端整体拒绝并保留 last-known-good；老客户端（build<68）
  不认 schema 2，自动继续用旧缓存，互不影响。

## 二、加一所学校（标准流程）

1. 编辑 `<开发目录>/ops/import-runtime/payload-v2-<最新rev>.json` 的 `schools`，
   增加条目：

   ```json
   { "name": "某某大学", "url": "https://jw.xxx.edu.cn/",
     "system": "正方教务", "initial": "M",
     "guide": "登录后进入个人课表页再点抓取",
     "urlHints": ["xskb"], "fieldAliases": {"kcmc": "courseName"} }
   ```

   字段约束（客户端与服务端双重校验，违反任一整体拒绝发布）：
   | 字段 | 约束 |
   |---|---|
   | name | 必填，1-80 字 |
   | url | 必填 https、无 fragment/userInfo、端口 443；host 全局唯一（去重键） |
   | system | ≤32 字，展示标签（正方教务/强智/青果教务/URP系统/超星/金智） |
   | initial | 可选，单个 A-Z（目录分组用；客户端内置拼音表只覆盖少量汉字，**远程名单必填**） |
   | guide | ≤600 字，专属导入引导（有 guide/hints/aliases 任一即标「已适配」） |
   | urlHints | ≤8 条，`[a-zA-Z0-9_/.-]+` 且 ≥3 字符（嗅探 URL 关键词） |
   | fieldAliases | ≤16 条，键 `[a-zA-Z][a-zA-Z0-9_]{0,63}`，值必须是 canonical 字段（courseName/teacherName/location/dayOfWeek/startSection/endSection/weeksText/timeAndPlaceList） |
   | intermediates | ≤2 张 base64 DER 中间证书（≤16KB/张，TLS 链补全用） |

2. `revision` 改成当前值 +1（可先 `curl https://api.seanyan.store/yzu/api/import-runtime`
   看当前 revision）。
3. 发布：`python tools/publish_runtime.py <payload.json> --publish`
   （不加 `--publish` 只签名不发布，产物 `tools/import-runtime-v1.json`）。
4. 验证：`curl https://api.seanyan.store/yzu/api/import-runtime` 确认 revision 与
   schools 数；App 侧冷启动后「其他学校教务」应出现新条目。

只改 urlHints/fieldAliases/guide（不动目录）＝同样的流程，改动即时对全体
2.0.4+ 用户生效，无需发版。

## 三、批量重建种子目录

```bash
python tools/build_school_payload.py            # 拉拾光仓库 + 合并内置名单
python tools/build_school_payload.py --current-rev 3   # 跳过线上查询
```

- 数据源：XingHeYuZhuan/shiguang_warehouse（MIT License）的 root_index.yaml 与
  各校 adapters.yaml，仅取 https 的 import_url 做目录数据；**不含其任何 JS 脚本**。
- 合并规则：内置 27 校 host 优先；拾光按索引顺序补齐；SPA `#` 片段自动剥除；
  无 https 地址的学校进报告不进 payload。
- 产出：`ops/import-runtime/payload-v2-<rev>.json` + `report-v2-<rev>.md`。
- 2026-10-02 首次种子：收录 188 所（revision 3）。

## 四、事故处置

- **发布错内容**：不能回退 revision——修正内容后用更高 revision 重发。
- **签名私钥丢失**：对应下发通道将无法继续签发，只能冻结并更换机制。
  私钥务必备份在密码管理器/离线介质，不要只留本机一份。
- **客户端表现异常**：客户端对坏 payload fail-closed，最多回退到内置默认
  （扬大 WebVPN 入口 + 基础嗅探），不会白屏或崩溃；先 curl 线上 payload
  自查 JSON 是否合法、host 是否重复。

## 五、与其它通道的边界

| 通道 | 状态 | 用途 |
|---|---|---|
| import-runtime（本文） | ✅ 活跃 | 学校目录 + 每校导入适配 |
| app-manifest（schoolDirectory/modules） | ❌ 冻结（不再使用） | 客户端只在远程 revision ≥ 内置时才采纳；加学校请一律走本文通道 |
| 版本发布（admin/versions） | ✅ 活跃 | APK 定向/全量发版 |
