# 邗上课表 · 微信小程序

由本仓库网页版 PWA（`web/`，v60）移植而来的原生小程序。
与 Flutter App、网页版共用同一个后端（`https://hanshang.seanyan.store/web-api`），
课表数据通过 `/api/sync/pull` / `/api/sync/push` 三端同步。

## 快速开始

1. 打开微信开发者工具 → 导入项目 → 目录选本仓库的 `miniprogram/`
2. AppID 一栏填你自己的小程序 AppID；暂时没有就点「测试号」
   （`project.config.json` 里预置的是 `touristappid`，即游客/测试号模式）
3. 编译运行。首屏即可用：没有登录时是**本机课表**，可以手动建课表、加课程、看周/日视图

## 上架前必须做的平台配置

| 事项 | 位置 | 说明 |
|---|---|---|
| request 合法域名 | 公众平台 → 开发管理 → 服务器域名 | 加 `https://hanshang.seanyan.store`（已 ICP 备案） |
| uploadFile 合法域名 | 同上，另一个列表 | 同一个域名也要加进这一项，否则 AI 导入不能上传 |
| 用户隐私保护指引 | 公众平台 → 设置 → 服务内容声明 | 需声明「相册（仅写入）」「选择文件」用途，否则选图会被拦 |
| 订阅消息模板 | 公众平台 → 功能 → 订阅消息 | 按类目申请一次性订阅模板，把模板 ID 填进 `utils/config.js` 的 `SUBSCRIBE_TEMPLATE_ID` |
| 服务类目 | 公众平台 → 基本设置 | 建议「工具 > 效率」；教育类目部分需资质 |
| 小程序备案 | 公众平台 → 设置 → 基本设置 | 个人主体走平台代提交，约 1-3 周，是发布的关键路径。**注意：初审通过后 12381 短信必须在 24 小时内完成核验，否则自动驳回** |
| 服务器端（可选） | 后端仓库 | 订阅消息的**发送**需要服务端用 openid + 模板 ID 调用微信接口，并按作息扫课。本次未实现 |

备案材料请按微信公众平台的最新要求准备；个人表单与内部材料不随源码公开。

## 目录结构

```
app.js / app.json / app.wxss      入口、页面注册、全局设计系统（M3 令牌与全部组件样式）
custom-tab-bar/                   自定义底栏（原生 tabBar 只认 PNG，这里要复用 SVG 图标并跟随主题）
utils/
  config.js        接口基址、存储键、订阅模板 ID
  api.js           wx.request 封装：Bearer + body 刷新令牌 + 401 自动重放
  store.js         本地存储 + 全局状态（订阅式，替代网页版的显式 render 调用）
  sync.js          按游客/登录分流到本机或云端的统一读写入口
  schedule.js      周次计算、排课筛选、地点解析、重叠分栏
  colors.js        课程配色（与安卓 ARGB、网页版同一套）
  section-times.js 作息时间（与网页版同一份存储格式）
  format.js        日期、uuid、周次文本解析
  icons.js         66 个 Material Symbols path（由脚本从网页版抽取）
  theme.js         JS 侧调色板（图标取色用，与 app.wxss 对应）
  ui.js privacy.js subscribe.js
components/        icon / sheet / course-form / semester-form / course-detail /
                   section-time / notification-inbox / about-sheet / privacy-sheet
pages/             schedule（周/日视图）、import（AI 识别与口令导入）、
                   profile（设置）、login、couple（共同空闲）
tools/             自检与测试脚本（见下）
```

## 自检与测试

```bash
# —— 静态检查（不需要开发者工具）——
node tools/check.js          # 结构自检：页面登记、组件路径、图标名（含动态表达式）、
                             # require 路径、WXML 事件绑定是否有对应方法（112 处）
node tools/parity-test.js    # 与网页版逐函数比对（118 项）
node tools/logic-test.js     # 集成测试：游客建课→落盘→周视图取数（27 项）
node tools/extract-from-web.js   # 网页版改版后重跑，同步图标与色板

# —— 运行时测试（需要开发者工具，见下）——
# 注意：自动化脚本与它的 node_modules 放在项目**外面**的 <自动化工具目录>，
# 不能放进项目目录（原因见下方「踩过的坑」）
node tools/wxcli.js islogin                 # 确认 CLI 能连上 IDE
node tools/wxcli.js auto --project <项目目录>/miniprogram --auto-port 9424
                                            # 常驻自动化服务（单独一个终端跑，别 kill）

cd <自动化工具目录>
# 五个运行时套件，互相独立，可单独跑也可连跑（连跑共 77 项断言）
node verify-grid.js 9424                    # 建课表→加课程→校验周网格（19 项）
node preflight.js 9424                      # 持久化/深色令牌/各弹层/真实后端登录（16 项）
node preflight2.js 9424                     # 边界/滑动/游客门禁/表单校验（20 项）
node preflight3.js 9424                     # 删除/主题持久化/信息密度/多课表（14 项）
node check-semester-switch.js 9424          # 切课表不丢课程、网格不空白（8 项）
node cleanup.js 9424                        # 清掉测试数据，恢复干净状态
# 诊断与辅助
node style-check.js 9424                    # 核对实际生效的配色与字号（不依赖画面）
node clamp-test.js 9424                     # 量高度判断多行截断是否生效
node diag-grid.js 9424                      # 周网格白屏的中间状态诊断
node inspect.js 9424                        # 查节点是否在 wxml 树里
node geometry.js 9424                       # 量元素真实 size/offset
node goto.js schedule 9424                  # 切到某个 tab 停住，便于人工看
node restart-ide.js <项目目录>/miniprogram # 干净重启 IDE（清残留锁 + 拉起）
powershell -File capture-window.ps1 -Out shot.png
                                            # 截 IDE 窗口（PrintWindow，不抢焦点）
powershell -File resize-window.ps1          # 拉宽 IDE 窗口（不激活）
```

**写断言时的两条经验**（都踩过，导致过整片误报）：

- **相对断言，不要写死数值**。滑动/翻周/删除这类操作的结果取决于当前状态，
  写死"应该在第 2 周"会在前置状态不同时全错。先读当前值，再断言增量。
- **套件要自给自足**。不要假设"上一轮留下了合适的数据"——`helpers.js` 的
  `ensureCourse()` 负责把课表与课程准备好；测完自己建的课表要自己删掉。

**模拟器面板关着时，一切截图都是空白**——包括 `automator.screenshot()` 与 IDE 窗口截图，
因为渲染面根本没合成。此时布局与样式仍可读（`geometry.js` / `style-check.js` 照常工作），
先靠它们定位问题，别对着空白截图猜。要把面板打开：菜单栏 **界面 → 模拟器**。

`parity-test.js` 会直接从网页版 `app.js` / `couple.js` / `section-times.js` 里
抽取同名函数执行，所以它能发现「看起来对、算出来不一样」的偏差。开发时请保持它全绿：
课程配色、周次筛选、地点解析任意一处与网页版不一致，都会造成同一份数据在两端显示不同。

### 运行时测试的前置条件

1. 微信开发者工具已启动并登录，项目已打开
2. **设置 → 安全设置 → 服务端口** 已开启（该开关改完要重启 IDE 才生效）
3. `cli auto` 必须常驻——它一退出，IDE 那边的自动化会话就变成死会话，
   之后所有连接都会 timeout。自动化会话本身较脆，建议「一轮跑一个脚本」，
   别在一个连接里做太多操作。

### 踩过的坑（写下来免得重复踩）

- 开发者工具装在含中文和空格的路径下，从 Git Bash 经 cmd.exe 调用会被按本地代码页
  重编码成乱码。统一用 Node 起子进程（`tools/wxcli.js`），参数以数组传入。
- `automator.launch()` 内部直接 spawn cliPath，同样会因中文路径失败，报
  "Failed to launch wechat web devTools"。所以改成自己起 `cli auto` 再 `connect`。
- `automator.screenshot()` 抓的是页面 webview，在这个环境里**始终不重绘**，
  截出来是空白；只有自定义 tabBar（独立 webview）能看到。要看画面得截 IDE 窗口。
  不要因为截图空白就以为页面没渲染——用 `geometry.js` 量一下就知道布局在不在。
- 连不上时先怀疑 `.cli` 旁边缺 `.ide`：`.ide` 由 IDE 在启动时写，如果 IDE 是在
  服务端口开启之前启动的，它就不会写，CLI 会一直等到超时。重启 IDE 即可。
- **不要把带 `node_modules` 的测试工具放进项目目录**。DevTools 检测到项目里有
  可执行内容会弹「您信任此项目并运行模拟器吗」的模态框，挡住模拟器，自动化与
  截图全部失效。所以自动化脚本放在项目外的 `<自动化工具目录>`。
- 不要用「找 `%APPDATA%` 下所有 `lockfile`」这类宽泛匹配去清锁：Electron 系应用
  普遍都有这个文件，ZCode、WPS 灵犀、SodaMusic 目录下各有一个，误删会波及无关应用。
  只处理开发者工具自己那一个。

## 与网页版的差异（都是平台限制导致的）

**功能降级**

1. **课前自动提醒** —— 小程序没有 Web Push，也没有后台定时。降级为微信订阅消息：
   用户每点一次攒一条发送额度，且必须由用户点击触发。客户端的授权与额度已实现，
   **发送侧需要后端新增接口与定时任务**（见上表）。模板未配置时，界面会如实说明，
   不显示一个点了没反应的按钮。
2. **导出系统日历** —— 网页版生成 `.ics` 后触发浏览器下载；小程序没有下载目录，
   且 `.ics` 不在 `wx.openDocument` 支持列表里，改为写文件后 `wx.shareFileMessage`
   发到聊天，用户在聊天里点开交给系统日历。
3. **官网链接** —— 个人主体小程序不能用 `web-view`，关于页的官网链接改为点按复制链接。

**交互实现差异**

4. **周视图不用 CSS Grid** —— 网页版靠 `grid-row: span` 跨行；小程序部分内核的 CSS Grid
   对隐式行与跨行支持不一致，改为 JS 算好像素绝对定位，重叠分栏的 `lane/laneCount`
   直接变成 `left/width` 百分比。
5. **滑动翻周不跟手** —— 网页版用 Pointer 事件实时改 transform；小程序要跟手得用 WXS
   在渲染层改样式才不掉帧，这里退一步改成「松手后按方向提交翻页 + CSS 滑入动画」。
   手感略不同，实现稳定得多。
6. **弹层自绘** —— 网页版的 `<dialog>` 提供了焦点陷阱、Esc 关闭、`::backdrop`，
   小程序没有对应物，用 fixed 遮罩 + 面板实现，保留点遮罩关闭、内容区独立滚动、
   动作按钮固定底部三条行为。

**新增能力**

7. **游客模式** —— 网页版是「先登录才能看到课表」，小程序首屏就是课表，未登录时写本机
   （`hanshang-mp-guest-schedule-v1`），登录后切到云端。这既是审核要求（不允许强制登录），
   也让「就想记个课」的用户零门槛可用。游客本机课表不会上传。
8. **分享升级** —— 小程序可以在「我的」页直接生成口令，也能用微信原生的转发卡片分享，
   比网页版的复制口令顺。

## 安全边界

- access token 只存内存，不落盘；refresh token 存本地存储（后端该令牌不轮换、有效期固定）
- 未登录时不发起任何需要账号的请求，游客数据只在本机
- AI 导入沿用网页版口径：文件仅用于本次识别，服务端不落库；上传前建议裁掉姓名学号
- 课程详情不再用字符串拼 HTML，改为数据驱动渲染，顺带消掉了网页版必须手写 `esc()` 的那类风险

## 验证状态（2026-09-20）

**已在真实渲染环境验证通过的**

- 首屏可用、**游客模式默认进入**（不强制登录）、自绘顶栏正确避让状态栏与胶囊
  （实测 `statusBarHeight=47`、`navBarHeight=40`、`tabBarHeight=90`）
- 空课表空状态、导入页**肉眼核对过截图**：M3 配色、图标、按钮主次态、
  禁用态（未选文件时「AI 识别并预览」半透明）、底部导航选中态都正确
- 建课表 → 加课程 → 周视图全流程：网格 12 节 × 7 天 = 84 格、节次栏 12 行、
  表头 7 天且标出今天、课程块落位与配色正确、**重叠课程自动并排分栏**
  （3 门同时间课分成 3 栏，各占 1/3 宽）、信息层级为「课名 > 教室 > 楼名」且
  教师/校区默认收起、日视图卡片带起止时刻与教室
- 全程**无运行时异常与 console.error**

**修掉的三个真实 Bug（都是静态检查与数据断言都发现不了的）**

1. **页面主体被底栏整块遮住**：自定义 tabBar 的根节点套了 `.app-root`，而该类带
   `min-height:100vh` 与不透明底色，于是底栏变成一层全屏遮罩。症状是页面主体全白、
   只剩底栏可见，但**布局测量一切正常**（元素尺寸位置都对），极难从代码看出来。
   修法：把令牌类与 `tabbar-scope` 一起挂在底栏节点本身，不再留多余的全屏外层。

2. **多行截断的前提没成立**：课名的 `-webkit-line-clamp` 与 `-webkit-box-orient` 都生效了，
   但计算样式里 `display` 是 `flow-root` 而不是 `-webkit-box`——三者必须同时成立才有
   截断效果。已把 `<text>` 换成 `<view>`，并把 display 那三条一并以内联样式写入。
   父块另有 `overflow:hidden` 兜底，最坏情况是"硬裁而非省略号"。

3. **切回有课的课表，周视图是空的**：周网格要靠实测尺寸才算得出来，而 `.week-host`
   只在「有课 + 周视图」时渲染。新建一个空课表会让它被 `wx:if` 拿掉，重测就查不到元素；
   等切回有课的课表时 `buildGrid` 因缺尺寸返回 null，**且没有任何东西会再触发测量**——
   界面停在空白，手动切一次日/周视图才恢复。修法是在 `setData` 的**回调里**补测
   （在 `render` 里直接测没用：那时 DOM 还是上一次的数据，选择器必然查不到）。

**计算样式核对（不依赖画面）**

`style-check.js` 直接读渲染层算出的最终值，确认 M3 令牌真的落到界面上：
眉题 `rgb(32,106,78)`＝primary、标题 `rgb(23,29,26)`＝on-surface、游客条与分段控件
底色分别等于 secondary-container / surface-container、课程块底色为课程色 16% 透明、
左条为实色、文字为混色。字号经 rpx 换算后取整（44rpx → 22px）。

**尚未肉眼确认的**

界面截图只覆盖了空状态与导入页。以下数据层已验、但没看过最终像素，需要时用
`goto.js` 切过去 + `capture-ide.ps1` 截一张即可：

- 周视图课程块的实际观感（字号 9.3–11.2px 是否偏小、多栏时文字是否被截断）
- 深色模式下各页配色
- 「我的」页、登录页、共同空闲页
- 各弹层（课程表单、课表管理、课程详情、作息、通知、关于、隐私）
- 真机上的选文件与 AI 识别全流程、隐私授权弹窗
