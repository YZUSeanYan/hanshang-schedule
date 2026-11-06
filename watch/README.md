# 邗上课表 - 小米 Vela 穿戴版（hanshang-watch）

面向 **Xiaomi Watch S5 46mm（主目标机，圆屏 480×480）** 及其他 HyperOS/Vela 穿戴
（Redmi Watch 6 等矩形屏）的课表快应用（Vela QuickApp），后端复用
`https://hanshang.seanyan.store/yzu/api`，手机端数据零改动。

S5 46mm 深度适配蓝图（调研结论 + 圆屏几何规则）：`docs/S5-46mm-深度适配蓝图.md`。

## 功能

- **登录**：6 位配对码（手机 App/PWA「我的 → 手表配对」生成，后端 `device-pair/claim`）
- **蓝牙导入**：手机「发送课表到手表」→ 手表 BLE 接收快照，**完全离线**（蓝牙网络无外网路由时的主通道）
- **分享码导入**：输入 6 位口令 -> 预览 -> 领取，同名课表需确认覆盖
- **今日课表**：周次 / 日期 / 下一节课提示（上课中、距上课 X 分钟）
- **本周课表**：星期条点选 + 左右滑动切换日期
- **到点提醒**：应用存活时，到上课时间振动 + Toast
  - ⚠️ Vela 三方应用**无系统通知通道**，应用被杀后无法提醒（框架能力上限，非 bug）
- **多课表**：设置页循环切换学期
- **设备诊断**：设备画像（机型/分辨率/形状/DPR/apiLevel）+ 网络连通性测试
- 静默后台刷新（>10 分钟自动拉取），缓存秒开

## 屏幕适配（单 rpk 通吃圆屏/矩形屏）

- `designWidth: "device-width"`（px＝物理像素；S5 323PPI 与 RW6 324PPI 同密度，字号物理尺寸不变）
- 形状感知几何集中在 `app.ux` 的 `def.metrics()`：圆屏头部居中列、卡片内缩 36px、
  底部导航悬浮胶囊（336×62 @ y=348..410 圆弧安全带内）、星期条限宽 320px、键盘压紧
- 页面用 `{{isRound ? 'xxx-round' : ''}}` 运行时 class 变体（不依赖编译器 @media 支持）
- 设备画像并入启动就绪序列（`sessionReady` 即画像就绪，消除高度计算竞态）

## 构建（无需 GUI IDE）

依赖 Node.js（>=12，已用 v24 验证）+ npm（走 npmmirror 镜像）：

```bash
npm install          # 安装 aiot-toolkit（已在 .npmrc 配置 npmmirror 源）
npm run release      # = aiot release，产物在 dist/*.rpk
```

如需签名证书（release 首次会要求，或用 AIoT-IDE 发布按钮自动生成）：

```bash
mkdir -p sign
openssl req -newkey rsa:2048 -nodes -keyout sign/private.pem \
  -x509 -days 3650 -out sign/certificate.pem
```

（MSYS/Git Bash 下 openssl 命令需加 `MSYS_NO_PATHCONV=1`。）

## 安装到手表

用户自备第三方侧载工具安装 `dist/` 下的 `.rpk`（表盘自定义工具 / AstroBox 等，
本应用不上架，无需小米商务对接）。安装后用手机端生成的**配对码**登录，
或直接走「蓝牙导入课表」离线获取。

## 调试

- 模拟器：AIoT-IDE（VS Code 扩展版）打开项目 -> 模拟器 -> 运行
- 真机日志：小米运动健康 App -> 我的 -> 关于 -> Debug -> 拉取固件日志
- 适配核对：真机打开「设置 → …」或诊断页，核对机型/分辨率/形状与蓝图一致

## 目录结构

```
├── package.json          # aiot-toolkit 构建工具
├── docs/                 # S5 46mm 适配蓝图等
├── src/
│   ├── manifest.json     # 包名 com.hanshang.schedule.watch
│   ├── app.ux            # 全局状态：会话 / 课表缓存 / 设备画像 / metrics()
│   ├── common/scripts/
│   │   ├── api.js        # 后端 API 封装（fetch + 401 自动刷新，单域名）
│   │   ├── ble.js        # BLE 课表接收（GATT Client 分片组包）
│   │   └── schedule.js   # 周次/节次/作息（与手机 App 规则一致）
│   └── pages/
│       ├── logo/         # 启动路由
│       ├── login/        # 配对码登录
│       ├── import/       # 分享码导入
│       ├── bleimport/    # 蓝牙导入（离线通道）
│       ├── today/        # 今日课表（主屏）+ 提醒调度
│       ├── week/         # 本周课表
│       ├── settings/     # 学期切换 / 同步 / 提醒开关 / 退出
│       └── diag/         # 设备诊断
```

## 数据规则（与手机 App 严格一致）

- `weeks_type`: 0 每周 / 1 单周 / 2 双周 / 3 自定义（int）
- `custom_weeks`: 逗号平铺列表（兼容范围写法 "1-18"）
- `day_of_week`: 1=周一 … 7=周日
- 节次：12 小节，5-9 月春夏季、其余秋冬季（`section_times.dart` 同源）
- 学期 `start_date` 已归一化为第 1 周周一

## 已知平台限制

- 三方快应用在 `bluetooth` 网络类型下**无外网路由**（RW6 真机实测）；S5 蓝牙版预期同限制，
  eSIM 版可能有蜂窝直连。双通道并存：在线直连 + BLE 离线导入。
- 无系统通知 API → 提醒仅应用存活时有效；S5 后台保活待真机实测。
- 手表无系统输入法 → 所有输入页自绘键盘。

## 待办

- [x] 后端 `/auth/device-pair` + `/auth/device-pair/claim` —— 2026-08-13 已部署生产
- [x] 手机端「生成配对码」入口：PWA 已上线
- [x] S5 46mm 深度适配（圆屏几何 + 设备画像 + 诊断页）—— 2026-10-17 实施
- [ ] 真机验收（S5 46mm 逐页目检，清单见蓝图第五节）
- [ ] BLE 真机联调（手机发送 → 手表接收）
- [ ] 提醒后台保活真机实测
