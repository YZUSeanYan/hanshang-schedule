# 邗上课表（hanshang-schedule）· Android App

面向扬州大学学生的课表管理 Android App：简洁清爽、无广告，支持教务课表导入、上课提醒、云端同步、桌面小组件与原生推送。

- **框架**：Flutter（Dart，Material 3）
- **数据**：Drift（SQLite）本地存储 + 服务端云同步（FastAPI 后端）
- **通知**：flutter_local_notifications 原生通知 + 阿里云移动推送（可选）
- **教务导入**：App 内 WebView 引导 / 服务器安全代抓 / 手动文本解析

## 功能

- 周视图 / 日视图 / 今日课程，单双周与自定义周次，春夏/秋冬两套作息自动切换
- 上课提醒（提前 5/10/15/30 分钟可选），重启后自动重挂闹钟
- 教务课表导入：App 内 WebView 引导抓取、服务器短时代抓、教务文本手动导入三种方式
- 云端同步：多端课表一致（LWW 冲突合并、增量拉取、删除墓碑）
- 桌面小组件：今日课程 / 周课表 / 双日 / 单日，支持多尺寸与深色模式
- 分享码：6 位口令分享课表给他人，同名覆盖需确认
- 深色模式、8 色主题、隐私门（首次启动展示数据说明）

## 快速开始

```bash
flutter pub get
# Drift 代码生成（改了表结构后重跑）
dart run build_runner build --delete-conflicting-outputs
flutter test --no-pub

# 本地联调（HTTP 仅限 debug 构建）
flutter run --dart-define=API_BASE_URL=http://127.0.0.1:8000

# 正式构建必须注入 HTTPS 线上地址
flutter build apk --release --dart-define=API_BASE_URL=https://your-api-host/yzu
```

> 代码默认 API 地址为 `http://localhost:8000`（仅本地开发）。正式版禁止 HTTP，请通过 `--dart-define` 注入 HTTPS 地址。后端仓库（FastAPI）与 PWA/手表端为独立仓库，不在此仓库内。

## 教务课表导入

App 支持三种导入方式：

1. **App 内 WebView 引导**：在 App 内打开教务登录页，用户亲自登录后抓取当前页面课表
2. **服务器安全代抓**：后端用 Playwright 短时隔离上下文代用户抓取当学期课表
3. **手动导入**：粘贴教务页面文本，块状解析后写入本地

安全设计（代码层面强制）：

- 教务密码只用于单次 HTTPS 请求与短时隔离浏览器上下文，不写数据库、日志、HAR、截图或浏览器持久化
- 遇到验证码、短信或其他二次认证立即停止，不自动重试、不绕过
- 凭据保险库（实验性，默认关闭）：用户明确同意后，学号密码 AES-256-GCM 加密后同步，服务端只存密文与脱敏学号，任何管理员不可读
- 正式构建只允许 HTTPS API；Android 主清单无明文流量例外；APK 更新地址必须与 API 同源、HTTPS 且带 SHA-256 校验

## 项目结构

```
app/
├── android/          # Android 平台工程（签名配置不入库）
├── lib/
│   ├── core/         # 配置、数据库、通知、路由、主题、存储
│   ├── features/     # auth / schedule / course_import / sync / share / update / watch / profile / privacy
│   └── import/       # WebView 嗅探脚本与教务课表解析器
├── plugins/          # 本地第三方插件（aliyun_push）
└── test/             # 单元与组件测试
```

## 安全说明

- 密码一律 bcrypt 哈希（服务端）；JWT 带版本可撤销
- 签名密钥（`.jks` / `key.properties`）、`.env` 绝不入库（见 `.gitignore`）
- 教务凭据、令牌等敏感数据只在内存中流转，退出即销毁

## 免责声明

本项目为个人学习项目，与扬州大学无关。教务导入功能仅用于用户主动发起的**本人**当学期课表导入，不批量采集、不查询成绩等其他数据。请遵守学校信息化管理规定。项目作者不对使用本项目产生的任何后果承担责任。

## License

[MIT](LICENSE)
