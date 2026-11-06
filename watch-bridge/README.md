# 邗上课表 · 手表助手（watch-bridge）

单功能独立 App：**登录 → 取课表快照 → BLE 广播 → 手表「蓝牙导入」接收**。
从主 App 的「发送课表到手表」拆出（主 App 入口保持隐藏、代码不动）。
包名 `cn.yzu.schedule.watchbridge`，纯 Kotlin + 系统控件（零第三方依赖），侧载自用、不上架。

设计蓝图：`docs/手表助手-蓝图.md`。

## 使用流程

1. 手机安装 `app-release.apk`，用「邗上课表」同一账号登录
2. 手表端（邗上课表手表版）打开「蓝牙导入课表 → 开始接收」
3. 手机点「发送到手表」→ 日志区实时显示 广播 → 连接 → 帧进度 → 完成
4. 手表自动保存并显示课表（完全离线，不依赖手表网络）

## 构建

```bash
export JAVA_HOME=<JDK17>
GRADLE_USER_HOME=C:/dev/gradle-home ./gradlew :app:assembleDebug :app:assembleRelease
```

- 工具链与主 App 同版：AGP 9.0.1 + Kotlin 2.3.20 + Gradle 9.1.0（wrapper 自主 App 复制）
- 签名：独立 keystore `release.jks`（凭据在 `keystore.properties`，不入库、不复用主 App 备案签名）
- 产物：`app/build/outputs/apk/release/app-release.apk`

## 演示模式（截图/录屏用）

```bash
adb shell am start -n cn.yzu.schedule.watchbridge/.MainActivity --ez demo true
```

只展示静态示例布局，不联网不取数。

## 数据与协议

- 服务端：`https://api.seanyan.store/yzu/api`（登录 /sync/pull /share/create /share/{code}）
- 快照取服务端 `share preview` 的 payload（权威结构，与手表 `applySnapshot` 同构）
- BLE 协议与手表 `ble.js` 约定一致：GATT Server + Service `8F2A0001` / Char `8F2A0002`，
  分片帧 `[seq][len][data≤180B]` + `0xFF` 结束帧（两端不得单独改动）
- 安全：仅 https、请求前校验 host（拒环回/私网/保留地址）；token 存应用私有存储

## 已知边界

- 模拟器无 BLE，点发送会提示蓝牙不可用（属预期）
- 全链路（登录→快照→手表接收）需真机联调验收
