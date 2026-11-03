# 邗上课表 · yzu_schedule

扬州大学专属课表 App（Android）。Flutter 工程。

- **当前版本**：`2.0.4+68`（`versionName+versionCode`，后端版本接口按 `versionCode` 比较）
- **包名**：`cn.yzu.schedule.yzu_schedule`
- **版本控制基线**：2026-09-21 初始化 git，此前无版本控制

---

## 技术栈

| 层 | 选型 |
| --- | --- |
| 框架 | Flutter / Dart SDK `^3.4.0` |
| 状态管理 | `flutter_riverpod` 2.5 |
| 路由 | `go_router` 14 |
| 本地数据库 | `drift` 2.20 + `drift_flutter`（SQLite，含迁移） |
| 网络 | `dio` 5.7（JWT 拦截、自动刷新） |
| 教务导入 | WebView 引导 + 本地规则解析 + 表格/截图智能解析 + 按学校签名配置下发 |
| 安全存储 | `flutter_secure_storage`（Keystore）+ `cryptography`（AES-GCM / PBKDF2） |
| 通知 | `flutter_local_notifications` + `timezone` |
| 桌面小组件 | `home_widget` 0.7 + 原生 Kotlin Provider |
| 语音录入 | `record` 6.1（PCM WAV） |
| 推送 | `plugins/aliyun_push`（本仓库自维护的阿里云推送插件） |
| 原生 | Android Kotlin（14 个文件） |

依赖总数 25（`pubspec.yaml`）。

---

## 当前导入能力与隐私边界

- WebView 登录由用户本人完成；教务账号密码只经过本机与学校系统，不读取密码框、不上传、不同步。
- 支持手动文本、PNG/JPG/WebP 截图及 XLSX/XLS/CSV 表格；复杂表格和分小班课表由服务端规则优先解析，未命中时再使用 AI。
- 页面内容在设备端抹除姓名、学号、手机号等身份信息，服务端再次脱敏；名单工作表不进入大模型，原始上传内容不落库、不写日志。
- 按学校适配配置通过 import-runtime Ed25519 签名通道下发，无需更新 APK；校验失败时 fail-closed 到内置配置或最后一份有效配置。
- 本仓库只公开客户端，不包含后端、运维脚本、真实课表样本、用户数据或任何私钥。

---

## 代码统计（2026-09-21）

| 类别 | 文件数 | 行数 |
| --- | ---: | ---: |
| Dart 业务代码 `lib/`（手写） | 77 | 18,765 |
| Dart 生成代码 `app_database.g.dart`（Drift） | 1 | 4,350 |
| Dart 测试 `test/` | 29 | 4,083 |
| Kotlin 原生 `android/app/src/main/kotlin` | 14 | 1,413 |
| Java 推送插件 `plugins/aliyun_push/android` | 3 | 1,139 |
| Dart 推送插件封装 `plugins/aliyun_push/lib` | 1 | 512 |
| **合计** | **125** | **30,262** |

自有手写代码（剔除 Drift 生成代码与第三方插件示例）合计 **25,914 行**。
结构单元：205 个类 / mixin / enum，约 670 个方法 / 函数，24 个页面与弹层。

---

## 目录结构

```
lib/
├── app.dart
├── core/                         基础设施（约 7,600 行）
│   ├── database/    4,538        Drift 表结构 + 迁移（含 4,350 生成代码）
│   ├── remote_features/  973     远程开关与政策下发（Ed25519 签名清单）
│   ├── notifications/    698     本地通知 + 上课提醒调度
│   ├── router/ 338   theme/ 214   widgets/ 712   utils/ 266
│   └── storage/ settings/ config/ constants/ network/ platform/
├── features/                     业务（约 14,700 行）
│   ├── schedule/            3,274   周视图 / 日程主界面 / 课程详情与编辑
│   ├── course_import/       2,749   教务导入（WebVPN、嗅探、解析、选校）
│   ├── ai_schedule/         2,598   AI 日程（语音录入、事件确认、预览）
│   ├── profile/             1,723   我的 / 设置 / 通知收件箱 / 关于
│   ├── shared_availability/ 1,141   共同空闲时间
│   ├── sync/                  656   离线同步（UUID + 墓碑）
│   ├── auth/ 629   update/ 456   privacy/ 328   share/ 110   watch/ 28
└── import/  991                  教务 HTML 解析器（yzu_parser.dart 866 行）
```

### Android 原生（`android/app/src/main/kotlin/cn/yzu/schedule/yzu_schedule/`）

`MainActivity`、`WidgetData` + **5 个桌面小组件 Provider**（今日 / 两日 / 周 / 大号 / 小号）、
`WatchBleTransfer`（手表 BLE 推课表）、
`ScheduleFilePickerPlugin`、`SchoolTlsPlugin`（校方自签证书信任）、
`BootReceiver`、`NotificationReceiver`、`CourseLiveNotifier`。

### 权限声明

`INTERNET`、`POST_NOTIFICATIONS`、`RECEIVE_BOOT_COMPLETED`、`RECORD_AUDIO`、`SCHEDULE_EXACT_ALARM`。
存储权限与蓝牙/定位权限已按合规要求显式移除（`tools:node="remove"`）。

---

## 构建

构建参数通过 `--dart-define` 注入。缺省时相关功能自动关闭（fail-closed），不会崩溃。

| 参数 | 说明 | 缺省行为 |
| --- | --- | --- |
| `API_BASE_URL` | 后端地址，正式构建必须为 HTTPS | `http://localhost:8000`（仅本机联调） |
| `ALIYUN_PUSH_APP_KEY` | 阿里云推送 AppKey | 空 → 推送不初始化 |
| `ALIYUN_PUSH_APP_SECRET` | 阿里云推送 AppSecret | 空 → 推送不初始化 |
| `REMOTE_FEATURE_PUBLIC_KEY_B64` | 远程特性清单 Ed25519 公钥 | 空 → 清单校验失败关闭 |
| `IOS_APP_STORE_URL` | iOS 检查更新跳转地址 | 空 → 隐藏 iOS 更新入口 |

```bash
# 本地联调
flutter run --dart-define=API_BASE_URL=http://10.0.2.2:8000

# 正式 Release（Android）
flutter build apk --release \
  --dart-define=API_BASE_URL=https://api.seanyan.store/yzu \
  --dart-define=ALIYUN_PUSH_APP_KEY=<key> \
  --dart-define=ALIYUN_PUSH_APP_SECRET=<secret> \
  --dart-define=REMOTE_FEATURE_PUBLIC_KEY_B64=<base64-pubkey>
```

签名配置读 `android/key.properties`（不入库，模板见下），密钥库 `android/yzu-release.jks`（不入库）。

```properties
storePassword=<>
keyPassword=<>
keyAlias=<>
storeFile=<路径>
```

### 测试

```bash
dart analyze lib test
flutter test
```

---

## 未入库的内容

以下文件被 `.gitignore` 排除，需要单独保管，**不能丢失**：

- `android/key.properties`、`android/yzu-release.jks` —— Android 签名凭据
- `sqlite3.dll` —— 测试用原生库，从 pub 缓存提取
- `plugins/aliyun_push/example/` —— 第三方插件自带示例，非本项目代码

---

## 相关文档

- 项目功能、开源范围与隐私说明见[仓库首页](../README.md)。
