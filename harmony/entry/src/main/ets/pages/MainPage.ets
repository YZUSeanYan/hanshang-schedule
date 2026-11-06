/**
 * 主框架：底部三 Tab（课表 / 导入 / 我的）。
 * 「我的」页对应 Flutter 版 profile_page.dart：
 * 账号卡片、外观(模式+9色板)、云端同步、上课提醒、通知设置、检查更新、关于、退出登录。
 */
import { router } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { notificationManager } from '@kit.NotificationKit';
import { AuthRepository } from '../repository/AuthRepository';
import { SyncEngine } from '../sync/SyncEngine';
import { ScheduleDao } from '../data/ScheduleDao';
import { ApiClient, ApiError } from '../network/ApiClient';
import { AppConfig } from '../common/AppConfig';
import { SchedulePage } from '../features/schedule/SchedulePage';
import { ImportPage } from '../features/course_import/ImportPage';
import { AppTheme, PRESET_SEEDS, ThemeSeed } from '../common/AppTheme';
import { SettingsStore } from '../storage/SettingsStore';
import { rescheduleReminders, cancelAllReminders, validReminderCount, REMIND_AHEAD_OPTIONS } from '../core/notifications/ReminderService';
import { NotificationIntentHandler } from '../core/notifications/NotificationIntentHandler';
import { NotificationRepository } from '../features/notifications/NotificationRepository';

@Entry
@Component
struct MainPage {
  @StorageProp(AppTheme.KEY_BRAND) brandColor: string = '#158A63';
  @StorageProp(AppTheme.KEY_BRAND_TINT) brandTint: string = '#158A631F';
  @StorageProp(AppTheme.KEY_MODE) themeMode: number = 0;
  @StorageProp(AppTheme.KEY_EFFECTIVE_DARK) effectiveDark: boolean = false;
  @StorageLink(NotificationIntentHandler.EVENT_KEY)
  @Watch('consumePendingNotification') pendingNotificationEvent: number = 0;

  @State activeTab: number = 0;
  @State username: string = '';
  @State email: string = '';
  @State offline: boolean = false;

  // 云同步
  @State syncing: boolean = false;
  @State lastSyncText: string = '编辑课程后自动同步，也可手动触发';
  @State checkingUpdate: boolean = false;

  // 上课提醒
  @State reminderOn: boolean = false;
  @State reminderAhead: number = 15;
  @State reminderCount: number = 0;
  @State reminderBusy: boolean = false;
  @State notificationUnread: number = 0;

  private pageColor(): string { return this.effectiveDark ? '#101214' : '#FFFFFF'; }
  private surfaceColor(): string { return this.effectiveDark ? '#1C1F22' : '#F7F8FA'; }
  private primaryText(): string { return this.effectiveDark ? '#F2F3F4' : '#1A1A1A'; }
  private subtleText(): string { return this.effectiveDark ? '#8F969D' : '#999999'; }
  private inputColor(): string { return this.effectiveDark ? '#272B2F' : '#F0F1F3'; }
  private dividerColor(): string { return this.effectiveDark ? '#34383D' : '#F0F0F0'; }
  private iconColor(): string { return this.effectiveDark ? '#D7DADD' : '#333333'; }
  private controlOutlineColor(): string { return this.effectiveDark ? '#454A50' : '#E8E8E8'; }

  aboutToAppear(): void {
    const user = AuthRepository.lastKnownUser();
    if (user !== null) {
      this.username = user.username;
      this.email = user.email;
      this.offline = user.offline;
    }
    this.refreshStatus();
    this.refreshNotificationUnread();
    this.consumePendingNotification();
  }

  onPageShow(): void {
    // 从通知设置页返回时刷新提醒状态
    this.reminderOn = SettingsStore.reminderEnabled();
    this.aheadRefresh();
    this.refreshStatus();
    this.refreshNotificationUnread();
  }

  private async aheadRefresh(): Promise<void> {
    this.reminderAhead = SettingsStore.remindAheadMinutes();
    this.reminderCount = await validReminderCount();
  }

  private consumePendingNotification(): void {
    const intent = NotificationIntentHandler.takePendingIntent();
    if (intent?.destination === 'notifications') {
      const params: Record<string, Object> = {};
      if (intent.notificationId !== null) params['notificationId'] = intent.notificationId;
      router.pushUrl({ url: 'features/notifications/NotificationInboxPage', params: params });
    }
  }

  private async refreshNotificationUnread(): Promise<void> {
    if (NotificationRepository.currentAccountId() === null) {
      this.notificationUnread = 0;
      return;
    }
    try {
      const page = await NotificationRepository.list(null, 1);
      this.notificationUnread = page.unread;
    } catch (e) {
      // 首页角标静默失败，消息中心提供完整错误与重试。
    }
  }

  private async refreshStatus(): Promise<void> {
    this.lastSyncText = await SyncEngine.lastSyncAtText();
    this.reminderOn = SettingsStore.reminderEnabled();
    this.reminderAhead = SettingsStore.remindAheadMinutes();
    this.reminderCount = await validReminderCount();
  }

  private async doSync(): Promise<void> {
    if (this.syncing) {
      return;
    }
    this.syncing = true;
    try {
      const summary = await SyncEngine.sync();
      this.toast(summary);
      this.lastSyncText = await SyncEngine.lastSyncAtText();
    } catch (e) {
      if (e instanceof ApiError) {
        this.toast((e as ApiError).message);
      } else {
        this.toast('同步失败，请稍后重试');
      }
    } finally {
      this.syncing = false;
    }
  }

  private async checkUpdate(): Promise<void> {
    if (this.checkingUpdate) {
      return;
    }
    this.checkingUpdate = true;
    try {
      const data = await ApiClient.get(
        `/api/version/latest?current_code=${AppConfig.VERSION_CODE}`) as Record<string, Object>;
      const versionName = data['version_name'];
      const artifactUrl = data['apk_url'];
      if (typeof artifactUrl === 'string' && artifactUrl.length > 0) {
        const label = typeof versionName === 'string' && versionName.length > 0
          ? `（服务端最新 Android ${versionName}）` : '';
        this.toast(`已完成在线检查${label}，HarmonyOS 发布渠道尚未配置`);
      } else {
        this.toast('已完成在线检查，服务端暂无可用发布记录');
      }
    } catch (e) {
      if (e instanceof ApiError) {
        this.toast(`无法完成更新检查：${(e as ApiError).message}`);
      } else {
        this.toast('无法完成更新检查，请稍后重试');
      }
    } finally {
      this.checkingUpdate = false;
    }
  }

  /** 上课提醒开关(对应 Flutter ReminderSettingsTile) */
  private async toggleReminder(on: boolean): Promise<void> {
    this.reminderOn = on;
    this.reminderBusy = true;
    await SettingsStore.saveReminderSettings(on, this.reminderAhead);
    if (on) {
      const granted = await this.ensureNotification();
      if (!granted) {
        this.reminderBusy = false;
        this.toast('需要先在通知设置中允许通知');
        return;
      }
      const n = await rescheduleReminders(this.reminderAhead);
      this.reminderCount = n;
      this.toast(`已设置 ${n} 条课前提醒（未来 7 天）`);
    } else {
      await cancelAllReminders();
      this.reminderCount = 0;
      this.toast('已关闭课前提醒');
    }
    this.reminderBusy = false;
  }

  /** 提前量切换并重排 */
  private async changeAhead(m: number): Promise<void> {
    this.reminderAhead = m;
    this.reminderBusy = true;
    await SettingsStore.saveReminderSettings(this.reminderOn, m);
    if (this.reminderOn) {
      const granted = await this.ensureNotification();
      if (!granted) {
        this.reminderBusy = false;
        this.toast('通知权限未开启，提醒无法送达，请在通知设置中开启');
        return;
      }
      const n = await rescheduleReminders(m);
      this.reminderCount = n;
      if (n === 0) {
        this.toast('未来 7 天暂无可提醒的课程');
      }
    }
    this.reminderBusy = false;
  }

  private async ensureNotification(): Promise<boolean> {
    try {
      await notificationManager.requestEnableNotification(getContext(this) as common.UIAbilityContext);
      return true;
    } catch (e) {
      return false;
    }
  }

  private async logout(): Promise<void> {
    await AuthRepository.logout();
    router.replaceUrl({ url: 'pages/LoginPage' });
  }

  private modeLabel(): string {
    if (this.themeMode === 1) {
      return '浅色';
    }
    if (this.themeMode === 2) {
      return '深色';
    }
    return '跟随系统';
  }

  build() {
    Tabs({ barPosition: BarPosition.End, index: this.activeTab }) {
      TabContent() {
        this.scheduleTab()
      }
      .tabBar(this.tabBarBuilder('课表', 0))

      TabContent() {
        this.importTab()
      }
      .tabBar(this.tabBarBuilder('导入', 1))

      TabContent() {
        this.profileTab()
      }
      .tabBar(this.tabBarBuilder('我的', 2))
    }
    .scrollable(false)
    .barMode(BarMode.Fixed)
    .onChange((index: number) => {
      this.activeTab = index;
    })
    .width('100%')
    .height('100%')
    .backgroundColor(this.pageColor())
  }

  @Builder
  tabBarBuilder(label: string, index: number) {
    Column({ space: 3 }) {
      Circle()
        .width(index === this.activeTab ? 20 : 0)
        .height(4)
        .fill(this.brandColor)
        .borderRadius(2)
        .margin({ top: index === this.activeTab ? 0 : 8 });
      Text(label)
        .fontSize(14)
        .fontColor(index === this.activeTab ? this.brandColor : this.subtleText())
        .fontWeight(index === this.activeTab ? FontWeight.Medium : FontWeight.Normal);
    }
    .width('100%')
    .height(52)
    .justifyContent(FlexAlign.Center);
  }

  @Builder
  scheduleTab() {
    SchedulePage();
  }

  @Builder
  importTab() {
    ImportPage();
  }

  @Builder
  profileTab() {
    Scroll() {
      Column() {
        // ---- 账号卡片(ListTile 风格) ----
        Row({ space: 14 }) {
          Column() {
            Text(this.avatarChar())
              .fontSize(22)
              .fontColor(Color.White)
              .fontWeight(FontWeight.Medium);
          }
          .width(52)
          .height(52)
          .borderRadius(26)
          .backgroundColor(this.brandColor)
          .justifyContent(FlexAlign.Center);
          Column() {
            Text(this.username.length > 0 ? this.username : '未登录')
              .fontSize(18)
              .fontWeight(FontWeight.Bold)
              .fontColor(this.primaryText());
            Text(this.offline ? '离线模式 · 联网后自动恢复' : this.email)
              .fontSize(12)
              .fontColor(this.subtleText())
              .margin({ top: 3 });
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1);
        }
        .width('100%')
        .padding({ left: 4, right: 4, top: 16, bottom: 14 });

        Divider().color(this.dividerColor());

        // ---- 外观 ----
        Text('外观')
          .fontSize(13)
          .fontColor(this.subtleText())
          .width('100%')
          .margin({ top: 12, bottom: 8 });

        // 模式分段控件
        Row() {
          this.modeSegment('跟随系统', 0);
          this.modeSegment('浅色', 1);
          this.modeSegment('深色', 2);
        }
        .width('100%')
        .height(38)
        .borderRadius(19)
        .backgroundColor(this.inputColor());

        // 主题色板(9 色)
        Flex({ wrap: FlexWrap.Wrap }) {
          ForEach(PRESET_SEEDS, (seed: ThemeSeed) => {
            Column() {
              if (seed.hex === this.brandColor) {
                Text('✓')
                  .fontSize(15)
                  .fontColor(Color.White)
                  .fontWeight(FontWeight.Bold);
              }
            }
            .width(36)
            .height(36)
            .borderRadius(18)
            .backgroundColor(seed.hex)
            .border({
              width: seed.hex === this.brandColor ? 2.5 : 0,
              color: this.controlOutlineColor()
            })
            .margin(6)
            .justifyContent(FlexAlign.Center)
            .onClick(() => { AppTheme.applySeed(seed.hex); });
          }, (seed: ThemeSeed) => seed.hex);
        }
        .width('100%')
        .margin({ top: 12 });

        Divider().color(this.dividerColor()).margin({ top: 16 });

        // ---- 功能入口 ----
        Column() {
          // 云端同步
          Row({ space: 12 }) {
            SymbolGlyph($r('sys.symbol.cloud'))
              .fontSize(20)
              .fontColor([this.iconColor()])
              .width(24)
              .height(24);
            Column() {
              Text('云端同步').fontSize(15).fontColor(this.primaryText());
              Text(this.lastSyncText)
                .fontSize(12).fontColor(this.subtleText()).margin({ top: 2 })
                .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis });
            }
            .alignItems(HorizontalAlign.Start).layoutWeight(1);
            if (this.syncing) {
              LoadingProgress().width(20).height(20).color(this.brandColor);
            } else {
              SymbolGlyph($r('sys.symbol.chevron_right'))
                .fontSize(18)
                .fontColor([this.subtleText()])
                .width(20)
                .height(20);
            }
          }
          .width('100%')
          .padding({ top: 13, bottom: 13, left: 4, right: 4 })
          .stateStyles({ pressed: { .opacity(0.7) }, normal: { .opacity(1) } })
          .onClick(() => { this.doSync(); });

          Divider().color(this.dividerColor());

          // 上课提醒
          Column() {
            Row({ space: 12 }) {
              SymbolGlyph($r('sys.symbol.alarm'))
                .fontSize(20)
                .fontColor([this.iconColor()])
                .width(24)
                .height(24);
              Column() {
                Text('上课提醒').fontSize(15).fontColor(this.primaryText());
                Text(this.reminderOn
                  ? `提前 ${this.reminderAhead} 分钟 · 已设 ${this.reminderCount} 条（未来 7 天）`
                  : '关闭中')
                  .fontSize(12).fontColor(this.subtleText()).margin({ top: 2 });
              }
              .alignItems(HorizontalAlign.Start).layoutWeight(1);
              Toggle({ type: ToggleType.Switch, isOn: this.reminderOn })
                .selectedColor(this.brandColor)
                .onChange((on: boolean) => { this.toggleReminder(on); });
            }
            .width('100%');

            if (this.reminderOn) {
              Row({ space: 8 }) {
                ForEach(REMIND_AHEAD_OPTIONS, (m: number) => {
                  Text(`${m} 分钟`)
                    .fontSize(12)
                    .fontColor(m === this.reminderAhead ? Color.White : this.primaryText())
                    .padding({ left: 12, right: 12, top: 6, bottom: 6 })
                    .borderRadius(14)
                    .backgroundColor(m === this.reminderAhead ? this.brandColor : this.inputColor())
                    .onClick(() => { this.changeAhead(m); });
                }, (m: number) => `m-${m}`);
              }
              .width('100%')
              .margin({ top: 10, left: 32 });

              if (this.reminderBusy) {
                Row({ space: 6 }) {
                  LoadingProgress().width(14).height(14).color(this.brandColor);
                  Text('正在重排提醒…').fontSize(11).fontColor(this.subtleText());
                }.margin({ top: 8, left: 32 });
              }
            }
          }
          .width('100%')
          .padding({ top: 13, bottom: 13, left: 4, right: 4 });

          Divider().color(this.dividerColor());

          // 消息中心
          Row({ space: 12 }) {
            SymbolGlyph($r('sys.symbol.bell'))
              .fontSize(20).fontColor([this.iconColor()]).width(24).height(24);
            Column() {
              Text('消息中心').fontSize(15).fontColor(this.primaryText());
              Text(this.offline ? '离线模式下不可用'
                : this.notificationUnread > 0 ? `${this.notificationUnread} 条未读消息` : '查看账户通知')
                .fontSize(12)
                .fontColor(this.notificationUnread > 0 ? this.brandColor : this.subtleText())
                .margin({ top: 2 });
            }
            .alignItems(HorizontalAlign.Start).layoutWeight(1);
            if (this.notificationUnread > 0) {
              Text(this.notificationUnread > 99 ? '99+' : `${this.notificationUnread}`)
                .fontSize(11).fontColor(Color.White).fontWeight(FontWeight.Medium)
                .height(20).padding({ left: 7, right: 7 }).borderRadius(10)
                .backgroundColor('#D03A2B');
            }
            SymbolGlyph($r('sys.symbol.chevron_right'))
              .fontSize(18).fontColor([this.subtleText()]).width(20).height(20);
          }
          .width('100%')
          .padding({ top: 13, bottom: 13, left: 4, right: 4 })
          .enabled(!this.offline && this.username.length > 0)
          .opacity(!this.offline && this.username.length > 0 ? 1 : 0.55)
          .onClick(() => { router.pushUrl({ url: 'features/notifications/NotificationInboxPage' }); });

          Divider().color(this.dividerColor());

          // 通知设置
          Row({ space: 12 }) {
            SymbolGlyph($r('sys.symbol.bell'))
              .fontSize(20)
              .fontColor([this.iconColor()])
              .width(24)
              .height(24);
            Column() {
              Text('通知设置').fontSize(15).fontColor(this.primaryText());
              Text('课前提醒 · 测试通知 · 权限状态').fontSize(12).fontColor(this.subtleText()).margin({ top: 2 });
            }
            .alignItems(HorizontalAlign.Start).layoutWeight(1);
            SymbolGlyph($r('sys.symbol.chevron_right'))
              .fontSize(18)
              .fontColor([this.subtleText()])
              .width(20)
              .height(20);
          }
          .width('100%')
          .padding({ top: 13, bottom: 13, left: 4, right: 4 })
          .onClick(() => { router.pushUrl({ url: 'core/notifications/NotificationSettingsPage' }); });

          Divider().color(this.dividerColor());

          // 检查更新
          Row({ space: 12 }) {
            SymbolGlyph($r('sys.symbol.download'))
              .fontSize(20)
              .fontColor([this.iconColor()])
              .width(24)
              .height(24);
            Column() {
              Text('检查更新').fontSize(15).fontColor(this.primaryText());
              Text(`当前版本 ${AppConfig.VERSION_NAME}`).fontSize(12).fontColor(this.subtleText()).margin({ top: 2 });
            }
            .alignItems(HorizontalAlign.Start).layoutWeight(1);
            if (this.checkingUpdate) {
              LoadingProgress().width(20).height(20).color(this.brandColor);
            } else {
              SymbolGlyph($r('sys.symbol.chevron_right'))
                .fontSize(18)
                .fontColor([this.subtleText()])
                .width(20)
                .height(20);
            }
          }
          .width('100%')
          .padding({ top: 13, bottom: 13, left: 4, right: 4 })
          .onClick(() => { this.checkUpdate(); });

          Divider().color(this.dividerColor());

          // 关于
          Row({ space: 12 }) {
            SymbolGlyph($r('sys.symbol.info_circle'))
              .fontSize(20)
              .fontColor([this.iconColor()])
              .width(24)
              .height(24);
            Column() {
              Text('关于邗上课表').fontSize(15).fontColor(this.primaryText());
              Text(`当前主题模式：${this.modeLabel()}`).fontSize(12).fontColor(this.subtleText()).margin({ top: 2 });
            }
            .alignItems(HorizontalAlign.Start).layoutWeight(1);
            SymbolGlyph($r('sys.symbol.chevron_right'))
              .fontSize(18)
              .fontColor([this.subtleText()])
              .width(20)
              .height(20);
          }
          .width('100%')
          .padding({ top: 13, bottom: 13, left: 4, right: 4 })
          .onClick(() => { router.pushUrl({ url: 'features/profile/AboutPage' }); });
        }
        .width('100%');

        Divider().color(this.dividerColor()).margin({ top: 4 });

        // ---- 退出登录 ----
        if (this.username.length > 0) {
          Text('退出登录')
            .fontSize(15)
            .fontColor('#D03A2B')
            .width('100%')
            .height(46)
            .textAlign(TextAlign.Center)
            .borderRadius(23)
            .backgroundColor(this.surfaceColor())
            .border({ width: 1, color: this.controlOutlineColor() })
            .margin({ top: 24, bottom: 32 })
            .onClick(() => { this.logout(); });
        } else {
          Row().height(32);
        }
      }
      .padding({ left: 16, right: 16 })
      .width('100%');
    }
    .scrollBar(BarState.Off)
    .width('100%')
    .height('100%')
    .backgroundColor(this.pageColor())
    .edgeEffect(EdgeEffect.Spring);
  }

  @Builder
  modeSegment(label: string, mode: number) {
    Text(label)
      .fontSize(13)
      .fontColor(this.themeMode === mode ? Color.White : this.primaryText())
      .layoutWeight(1)
      .height(30)
      .textAlign(TextAlign.Center)
      .borderRadius(15)
      .backgroundColor(this.themeMode === mode ? this.brandColor : Color.Transparent)
      .margin(4)
      .onClick(() => { AppTheme.applyMode(mode); });
  }

  private avatarChar(): string {
    if (this.username.length > 0) {
      return this.username.charAt(0).toUpperCase();
    }
    return '?';
  }

  private toast(msg: string): void {
    this.getUIContext().getPromptAction().showToast({ message: msg, duration: 2000 });
  }
}
