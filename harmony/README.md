# 邗上课表 · HarmonyOS 原生版（harmony/）

Flutter Android 版向 HarmonyOS NEXT 的原生移植（ArkTS + ArkUI），复用现有账号、同步、分享等后端协议；M7 为 Harmony 推送新增了 HMS 平台分发和设备解绑能力。
移植总方案见 `docs/鸿蒙原生移植交接文档.md`，本 README 记录工程现状与构建方法。

## 当前进度（2026-08-17）

| 里程碑 | 状态 | 说明 |
|---|---|---|
| M1 基础（工程+网络+认证） | ✅ 完成 | ApiClient（JWT 自动附带 + 401 单飞刷新重试）、登录/注册/忘记密码、会话恢复（含离线回落） |
| M2 数据层（SQLite+同步） | ✅ 完成 | relationalStore 六表（与 Drift v2 等价）、LWW 推拉同步、墓碑删除、当前学期归一化、500 条分批 |
| **M3 课表 UI** | ✅ 完成 | WeekView(7×12 网格+重叠分栏)、DayView、课程编辑、学期设置、详情/分享底部弹层及页面转场均已完成并在模拟器验证 |
| M4 导入/分享 | ✅ 代码完成 | WebVPN 正式路由、嗅探/解析/预览、手动粘贴和口令导入均已实现；ArkWeb 登录与抓取仍需真机联调 |
| M5 通知/设置 | ✅ 代码完成 | reminderAgent 课前提醒、主题、隐私门禁、通知设置和关于页已实现；提醒触发仍需真机验证 |
| M6 小组件 | ✅ 完成 | 四类服务卡片已实现，模拟器验证过真实课表渲染 |
| M7 推送/收件箱 | 🟨 代码接入完成，真机闭环待验 | 账户消息中心、统一 payload、后端 HMS 通道、`@kit.PushKit` token 获取和远程通知扩展已接入；仍缺 AGC Push 权限/发布签名/profile 和真机送达验证 |
| M8 可执行发布准备 | 🟨 代码与文档完成 | 账号库隔离、真实更新检查边界、0.8.0+8 开发元数据和发布清单已落地；未签名、未备案、未上架、未发布 |

**纯逻辑层（周次计算/作息表/配色/地点格式化/同步编解码、导入解析、通知路由、账号数据库隔离）已用 Node 单测覆盖并全部通过**。
这些是课表正确性和账号隔离的核心，与 Flutter/服务端语义逐条对齐（含负数周向下取整、双周从第 2 周起、
custom_weeks 服务端 CSV ↔ 本地 JSON、墓碑最小合法字段等）。后端全量测试当前为 165 项通过。

## 目录结构

```
harmony/
├── AppScope/                     应用级配置（bundleName=cn.yzu.schedule.yzu_schedule）
├── build-profile.json5           构建配置（compatibleSdkVersion 5.0.0(12)）
├── package.json                  node 单测入口（npm test，与 hvigor 无关）
├── tests/                        纯逻辑单测（.ts，Node ≥ 23.6 直接运行）
└── entry/
    ├── src/main/ets/
    │   ├── common/               AppConfig（API 基址）/ Bootstrap（初始化门闩）
    │   ├── constants/            SectionTimes.ts / CourseColors.ts（纯逻辑，node 可测）
    │   ├── utils/                WeekCalculator.ts / LocationFormatter.ts（纯逻辑）
    │   ├── model/SyncCodecs.ts   行模型 + push/pull 编解码 + 日期字符串转换（纯逻辑）
    │   ├── storage/TokenStore.ets    Preferences 凭据存储
    │   ├── network/ApiClient.ets     HTTP 封装 + JWT 拦截语义
    │   ├── repository/AuthRepository.ets  注册/登录/恢复/忘记密码/退出
    │   ├── data/AppDb.ets            relationalStore 建库（六表+索引）
    │   ├── data/ScheduleDao.ets      DAO（显式级联删除、当前学期容错读取与归一化）
    │   ├── sync/SyncEngine.ets       push/pull LWW 同步引擎
    │   ├── entryability/EntryAbility.ets
    │   └── pages/                Index（启动分流）/ LoginPage / MainPage（三 Tab 骨架）
    └── src/main/resources/       字符串/颜色/图标/页面注册
```

`.ts` = 纯逻辑（零 @ohos 依赖，node 单测直接 import）；`.ets` = 需要 @ohos API 的应用层。

## 构建（已验证的命令行方式，2026-08-16 实测通过）

环境：DevEco Studio 6.1.1（`C:\Program Files\Huawei\DevEco Studio`，SDK=API 24，hvigor 6.24.4，
自带 node 18.20.1 与 JBR 21）。在 **Git Bash** 中：

```bash
cd /c/Users/Public/hanshang-harmony   # 原仓库路径含单引号时，先复制到此处
export DEVECO_SDK_HOME="C:\\Program Files\\Huawei\\DevEco Studio\\sdk"
export JAVA_HOME="C:\\Program Files\\Huawei\\DevEco Studio\\jbr"
export PATH="$JAVA_HOME/bin:$PATH"
NODE="/c/Program Files/Huawei/DevEco Studio/tools/node/node.exe"
HVW="/c/Program Files/Huawei/DevEco Studio/tools/hvigor/bin/hvigorw.js"
"$NODE" "$HVW" --mode module -p product=default -p module=entry@default assembleHap \
  --analyze=normal --parallel --daemon=false
# 产物：entry/build/default/outputs/default/entry-default-unsigned.hap
```

### 已踩过的坑（按出现顺序）

1. **单引号路径**：原仓库路径含单引号时，hvigor/ArkTS 工具链会出错；必须复制到
   `C:\Users\Public\hanshang-harmony\` 构建（改完源码记得双向同步）。
2. **ArkTS 严格模式**（首建 35 错，3 类）：
   - `throw` 只能抛 `Error` 子类 → `ApiError extends Error`；
   - 新 SDK ResultSet API 是 `getColumnIndex`（不是 `getColumnIndexForName`）；
   - `@State tabIndex` 与组件内置属性重名 → 改 `activeTab`。
3. **`spawn java ENOENT`**：打包需要 java。设好 PATH 后仍失败的原因是**首次失败构建留下的
   hvigor daemon（旧环境无 java）**——先 `"$NODE" "$HVW" --stop-daemon` 再构建即可。
   （`--daemon=false` 只是本次不用，不会杀已存在的旧 daemon。）
4. 警告 118 条全非阻塞：113 条「Function may throw exceptions」lint 噪音（KV 同步方法），
   `router.replaceUrl`/`getContext` 弃用提示（M3 换 Navigation 时一并处理），
   以及 targetSdkVersion 未显式设置的建议。

### 首次跑在模拟器上（需要 GUI 操作，一次性）

1. DevEco Studio → 首次启动登录华为开发者账号（个人免费）。
2. Tools → Device Manager → 下载模拟器镜像 → 新建手机模拟器并启动。
3. File → Project Structure → Signing Configs → 勾选 **Automatically generate signature**
   （生成调试证书，写入 build-profile.json5 的 signingConfigs）。
4. 之后即可 CLI 签名构建 + 安装：
   ```bash
   # 重跑 assembleHap 得到签名包，然后：
   HDC="/c/Program Files/Huawei/DevEco Studio/sdk/default/openharmony/toolchains/hdc.exe"
   "$HDC" install -r entry/build/default/outputs/default/entry-default-signed.hap
   "$HDC" shell aa start -a EntryAbility -b cn.yzu.schedule.yzu_schedule
   ```

## M8 发布执行清单

当前 Harmony 元数据为 `0.8.0` / `versionCode 8`，表示 M8 开发准备基线，不表示正式版、已签名包或商店版本。

### 签名与构建

- [ ] 在 AGC 确认最终 Harmony 应用、`bundleName` 与开发者主体；若变更包名，同步备案、推送和升级策略。
- [ ] 由发布负责人在 DevEco/AGC 配置真实发布证书和 profile；证书、私钥、口令不得写入本目录或文档。
- [ ] 保留 `signingConfigs: []`，直到真实材料到位；本轮只允许构建 unsigned HAP。
- [ ] 从干净 ASCII 路径构建 release，记录 HAP 文件名、字节数、SHA-256、`versionName/versionCode` 和证书指纹。
- [ ] 真机验证冷启动、隐私拒绝/同意、登录、离线恢复、双账号切换、同步、提醒、卡片和导入；模拟器结果不能替代真机。

### 备案与隐私

- [ ] 向主体/接入商确认 Harmony 应用备案要求和最终备案号，不复用 Android 签名指纹作为 Harmony 签名材料。
- [ ] 备案通过后再在关于页和分发页面展示真实备案号；当前不得填写占位号。
- [x] 已使用系统 `@kit.PushKit` 接入 token 获取和远程通知扩展，隐私政策已披露华为、处理目的和推送标识。
- [x] Push Kit token 仅在隐私同意且登录完成后获取；拒绝或无 AGC 权限时静默降级，本地课表仍可使用。
- [ ] 在正式隐私政策中补充 Huawei Push Kit 官方隐私链接，并用真实发布签名/profile 完成 AGC 权限与真机送达验证。

### 升级

- [ ] 现有 `/api/version/latest` 只描述 APK，Harmony 端仅把它作为在线检查边界，不下载、不安装、不宣称 Android 记录是 Harmony 更新。
- [ ] 正式发布前扩展后端为按平台查询，或接入 AppGallery 官方升级能力，并为 Harmony HAP/AppGallery 记录独立版本、链接和哈希。
- [ ] 用相同发布证书验证 `N-1 -> N` 覆盖安装，确认账号各自数据库、离线会话、提醒与卡片不丢失且不串号。
- [ ] `versionCode` 只能递增；版本名、应用元数据、UI 显示和推送登记值必须一致。

### 回滚

- [ ] 发布前归档上一个已签名可安装包、证书指纹、哈希、后端版本记录和数据库兼容说明。
- [ ] 代码回滚只能发布更高 `versionCode` 的修复包，不能用较低版本覆盖；不得更换发布证书。
- [ ] 若仅更新检查/分发记录错误，先撤下 Harmony 发布记录或商店版本，不修改 Android APK 记录。
- [ ] 若账号隔离异常，立即停止发布和同步入口；保留各账号数据库，不清库，修复后用原账号恢复验证。

## 单测（本机即可跑，无需 DevEco）

```bash
cd harmony
npm test        # 或 node tests/run.mjs，需 Node ≥ 23.6（本机 v24.14 ✅）
```

## 与服务端的约定（已在线上稳定，勿改）

- Base URL：`https://api.seanyan.store/yzu`（`/api/...` 拼接后与 Android 版一致）；禁止回退 HTTP。
- refresh token 90 天滑动续期、**不轮换**；401 时刷新后重放一次。
- custom_weeks：服务端逗号分隔（"1,2,3"），本地 JSON 数组文本；范围写法（"1-18"）解码时展开。
- cursor 为服务端 time_ns（超过 JS 2^53），按字符串存取、纳秒级误差幂等无害（与网页版一致）。
- 周次/节次/周类型语义必须与 `utils/WeekCalculator.ts`、`constants/SectionTimes.ts` 完全一致。
