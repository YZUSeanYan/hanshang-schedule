# 邗上课表（hanshang-schedule）

邗上课表是一套面向扬州大学学生的课表管理项目，包含 Flutter Android App、FastAPI 后端、PWA 网页版、官网、管理端及手表/鸿蒙/iOS 移植工程。

**当前 Android 版本：2.0.4+68** · **License：MIT**

## 主要功能

- 周视图、日视图、今日课程、单双周、自定义周次与节假日调课
- 上课提醒、云端同步、桌面小组件、分享码与共同空闲
- App 内 WebView 教务导入、手动文本、课表截图及 Excel/CSV 表格导入
- 复杂表格与分小班课表：规则解析优先，未识别时再使用 AI 辅助解析
- 多学校适配：通过 Ed25519 签名通道下发按校配置，无需更新 APK

## 仓库结构

| 目录 | 内容 |
| --- | --- |
| `app/` | Flutter Android 主 App |
| `server/` | FastAPI、SQLAlchemy 后端与管理接口 |
| `web/` | PWA 网页版 |
| `site/` | 官网静态站点 |
| `admin-web/` | 管理后台网页源码 |
| `admin-app/` | Flutter 管理端 |
| `watch/` | 小米 Vela 手表端 |
| `watch-bridge/` | 手表助手 Android 工程 |
| `harmony/` | 鸿蒙 ArkTS 工程 |
| `ios-port/` | iOS 移植准备工程，尚未完成 Mac 端首次编译 |
| `tools/` | 开发、解析、发布与隐私政策同步工具 |
| `ops/` | 脱敏后的部署与运维脚本示例 |
| `docs/` | 可公开的项目文档；真实教务快照不公开，仅保留全合成样本 |

## 快速开始

### Android App

```bash
cd app
flutter pub get
flutter test --no-pub
flutter run --dart-define=API_BASE_URL=http://127.0.0.1:8000
```

正式构建必须通过 `--dart-define` 注入 HTTPS API 地址及需要的推送/远程配置参数。签名文件和密钥库不入库。

### 后端

```bash
cd server
python -m venv .venv
# 激活虚拟环境后安装依赖
pip install -r requirements.txt
```

后端所需环境变量由部署环境注入；仓库不包含生产 `.env`、数据库或任何真实凭据。

### PWA / 官网

`web/` 与 `site/` 均为静态前端，可由普通静态 Web 服务器托管。部署前请按自己的环境配置 API 地址，不要使用他人生产服务。

## 隐私与安全边界

- 不接收、不传输、不存储教务系统密码；学校登录只发生在用户设备与学校服务器之间。
- 智能解析前在设备端与服务端分别脱敏；名单工作表不进入大模型，原始上传内容不写入业务数据库或日志。
- 远程适配配置使用 Ed25519 签名，校验失败时回退到内置配置或最后一份有效配置。
- 生产密钥、签名文件、访问令牌、用户数据库、真实课表/名单、私人联系方式和内部备份一律不公开。
- 仓库中的地址、账号、密钥字段均为文档示例或占位符，不可用于连接生产环境。

项目联系：<hanshangdeveloper@163.com>。

## 免责声明

本项目为个人学习项目，与扬州大学无关。教务导入仅用于用户主动发起的本人课表导入，不批量采集、不查询成绩等其他数据。请遵守学校信息化管理规定。

## License

[MIT](LICENSE)。第三方插件、图标与外部数据遵循各自原始许可；使用时请保留相应归属说明。
