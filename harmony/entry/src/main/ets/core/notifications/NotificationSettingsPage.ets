/**
 * 通知设置页(我的 → 通知设置 二级菜单)。
 * 移植自 Flutter 版 notifications/settings 页面,按鸿蒙能力裁剪：
 * - 课前提醒总开关 + 提前量选择(reminderAgent)
 * - 系统通知开启引导(requestEnableNotification)
 * - 发送测试通知(notificationManager)
 */
import { common } from '@kit.AbilityKit';
import { router } from '@kit.ArkUI';
import { notificationManager } from '@kit.NotificationKit';
import { SettingsStore } from '../../storage/SettingsStore';
import { AppTheme } from '../../common/AppTheme';
import { rescheduleReminders, cancelAllReminders, validReminderCount, REMIND_AHEAD_OPTIONS } from './ReminderService';

const BRAND: string = '#158A63';

@Entry
@Component
struct NotificationSettingsPage {
  @StorageProp(AppTheme.KEY_BRAND) brandColor: string = '#158A63';
  @StorageProp(AppTheme.KEY_EFFECTIVE_DARK) effectiveDark: boolean = false;
  @State reminderOn: boolean = false;
  @State aheadMinutes: number = 15;
  @State contentMode: number = 0;
  @State count: number = 0;
  @State notifEnabled: boolean = true;
  @State applying: boolean = false;

  aboutToAppear(): void {
    this.reminderOn = SettingsStore.reminderEnabled();
    this.aheadMinutes = SettingsStore.remindAheadMinutes();
    this.contentMode = SettingsStore.notifContentMode();
    this.refreshCount();
    this.checkNotifStatus();
  }

  private async refreshCount(): Promise<void> {
    this.count = await validReminderCount();
  }

  private async checkNotifStatus(): Promise<void> {
    try {
      this.notifEnabled = await notificationManager.isNotificationEnabled();
    } catch (e) {
      this.notifEnabled = false;
    }
  }

  /** 开/关课前提醒 */
  private async toggleReminder(on: boolean): Promise<void> {
    this.reminderOn = on;
    await SettingsStore.saveReminderSettings(on, this.aheadMinutes);
    if (on) {
      // 需要系统通知授权
      const granted = await this.ensureNotification();
      if (!granted) {
        this.notifEnabled = false;
        return; // 保持开关状态但提示未授权
      }
      this.notifEnabled = true;
      this.applying = true;
      const n = await rescheduleReminders(this.aheadMinutes);
      this.applying = false;
      this.count = n;
      this.toast(`已设置 ${n} 条课前提醒(未来 7 天)`);
    } else {
      await cancelAllReminders();
      this.count = 0;
      this.toast('已关闭课前提醒');
    }
  }

  /** 切换提前量并重排 */
  private async changeAhead(minutes: number): Promise<void> {
    this.aheadMinutes = minutes;
    await SettingsStore.saveReminderSettings(this.reminderOn, minutes);
    if (this.reminderOn) {
      const granted = await this.ensureNotification();
      if (!granted) {
        this.notifEnabled = false;
        this.toast('通知权限未开启，请在下方「系统通知」重新允许');
        return;
      }
      this.applying = true;
      const n = await rescheduleReminders(minutes);
      this.applying = false;
      this.count = n;
      if (n === 0) {
        this.toast('未来 7 天暂无可提醒的课程');
      } else {
        this.toast(`已按提前 ${minutes} 分钟重排 ${n} 条提醒`);
      }
    }
  }

  /** 切换通知内容显示模式并重排提醒 */
  private async changeContentMode(mode: number): Promise<void> {
    this.contentMode = mode;
    await SettingsStore.saveNotifContentMode(mode);
    if (this.reminderOn) {
      this.applying = true;
      const n = await rescheduleReminders(this.aheadMinutes);
      this.applying = false;
      this.count = n;
      this.toast(n > 0 ? '提醒内容已更新' : '');
    }
  }

  /** 请求系统通知授权(系统弹窗,用户选择) */
  private async ensureNotification(): Promise<boolean> {
    try {
      await notificationManager.requestEnableNotification(getContext(this) as common.UIAbilityContext);
      return true;
    } catch (e) {
      return false;
    }
  }

  /** 发送测试通知 */
  private async sendTest(): Promise<void> {
    const ok = await this.ensureNotification();
    if (!ok) {
      this.toast('请先允许通知权限');
      this.notifEnabled = false;
      return;
    }
    this.notifEnabled = true;
    try {
      await notificationManager.publish({
        id: 999,
        content: {
          notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
          normal: {
            title: '邗上课表',
            text: '这是一条测试通知,提醒将以此形式送达',
            additionalText: '课前提醒'
          }
        }
      });
      this.toast('测试通知已发送');
    } catch (e) {
      this.toast('发送失败');
    }
  }

  private toast(msg: string): void {
    this.getUIContext().getPromptAction().showToast({ message: msg, duration: 2500 });
  }

  private pageColor(): string { return this.effectiveDark ? '#101214' : '#FFFFFF'; }
  private surfaceColor(): string { return this.effectiveDark ? '#1C1F22' : '#F7F8FA'; }
  private controlColor(): string { return this.effectiveDark ? '#292D31' : '#F0F0F0'; }
  private primaryText(): string { return this.effectiveDark ? '#F2F3F4' : '#1A1A1A'; }
  private secondaryText(): string { return this.effectiveDark ? '#B8BDC2' : '#666666'; }
  private mutedText(): string { return this.effectiveDark ? '#8F969D' : '#999999'; }
  private dividerColor(): string { return this.effectiveDark ? '#34383D' : '#E5E7EA'; }

  build() {
    Column() {
      // 顶栏
      Row() {
        Text('‹').fontSize(26).fontColor(this.primaryText()).padding(12)
          .onClick(() => router.back());
        Text('通知设置').fontSize(17).fontWeight(FontWeight.Bold).fontColor(this.primaryText());
      }
      .width('100%').height(52);

      Scroll() {
        Column() {
          // ---- 课前提醒卡片 ----
          Column() {
            Row() {
              Column() {
                Text('课前提醒').fontSize(16).fontWeight(FontWeight.Medium).fontColor(this.primaryText());
                Text(this.reminderOn
                  ? `提前 ${this.aheadMinutes} 分钟 · 当前 ${this.count} 条(未来 7 天)`
                  : '按课表提前提醒,应用被杀后仍由系统准时送达')
                  .fontSize(12).fontColor(this.mutedText()).margin({ top: 4 });
              }
              .alignItems(HorizontalAlign.Start).layoutWeight(1);
              Toggle({ type: ToggleType.Switch, isOn: this.reminderOn })
                .selectedColor(this.brandColor)
                .onChange((on: boolean) => { this.toggleReminder(on); });
            }.width('100%');

            if (this.reminderOn) {
              Divider().color(this.dividerColor()).margin({ top: 14, bottom: 14 });
              Text('提前提醒时间').fontSize(14).fontColor(this.secondaryText());
              Row({ space: 8 }) {
                ForEach(REMIND_AHEAD_OPTIONS, (m: number) => {
                  Text(`${m} 分钟`)
                    .fontSize(13)
                    .fontColor(m === this.aheadMinutes ? Color.White : this.secondaryText())
                    .padding({ left: 14, right: 14, top: 7, bottom: 7 })
                    .borderRadius(16)
                    .backgroundColor(m === this.aheadMinutes ? this.brandColor : this.controlColor())
                    .onClick(() => { this.changeAhead(m); });
                }, (m: number) => `ahead-${m}`);
              }
              .width('100%')
              .margin({ top: 10 });

              if (this.applying) {
                Row({ space: 8 }) {
                  LoadingProgress().width(16).height(16).color(this.brandColor);
                  Text('正在重排提醒…').fontSize(12).fontColor(this.mutedText());
                }.margin({ top: 12 });
              }
            }
          }
          .padding(16)
          .borderRadius(14)
          .backgroundColor(this.surfaceColor())
          .width('100%');

          // ---- 通知内容显示卡片 ----
          Column() {
            Text('通知内容显示').fontSize(16).fontWeight(FontWeight.Medium).fontColor(this.primaryText());
            Text('在公共场合保护位置隐私：仅课程名模式下，提醒不显示教室与时间。')
              .fontSize(12).fontColor(this.mutedText()).margin({ top: 6 });
            Row({ space: 8 }) {
              Text('完整内容')
                .fontSize(13)
                .fontColor(this.contentMode === 0 ? Color.White : this.secondaryText())
                .padding({ left: 16, right: 16, top: 8, bottom: 8 })
                .borderRadius(18)
                .backgroundColor(this.contentMode === 0 ? this.brandColor : this.controlColor())
                .onClick(() => { this.changeContentMode(0); });
              Text('仅课程名')
                .fontSize(13)
                .fontColor(this.contentMode === 1 ? Color.White : this.secondaryText())
                .padding({ left: 16, right: 16, top: 8, bottom: 8 })
                .borderRadius(18)
                .backgroundColor(this.contentMode === 1 ? this.brandColor : this.controlColor())
                .onClick(() => { this.changeContentMode(1); });
            }
            .width('100%')
            .margin({ top: 12 });
          }
          .padding(16)
          .borderRadius(14)
          .backgroundColor(this.surfaceColor())
          .width('100%')
          .margin({ top: 12 });

          // ---- 账户通知入口 ----
          Row({ space: 12 }) {
            SymbolGlyph($r('sys.symbol.bell'))
              .fontSize(22).fontColor([this.brandColor]).width(30).height(30);
            Column() {
              Text('账户通知').fontSize(16).fontWeight(FontWeight.Medium).fontColor(this.primaryText());
              Text('查看消息、标记已读或清理通知').fontSize(12).fontColor(this.mutedText()).margin({ top: 4 });
            }
            .alignItems(HorizontalAlign.Start).layoutWeight(1);
            SymbolGlyph($r('sys.symbol.chevron_right')).fontSize(18).fontColor([this.mutedText()]);
          }
          .padding(16)
          .borderRadius(8)
          .backgroundColor(this.surfaceColor())
          .width('100%')
          .margin({ top: 12 })
          .onClick(() => { router.pushUrl({ url: 'features/notifications/NotificationInboxPage' }); });

          // ---- 系统通知卡片 ----
          Column() {
            Text('系统通知').fontSize(16).fontWeight(FontWeight.Medium).fontColor(this.primaryText());
            Text('课前提醒与账户消息都通过系统通知送达;关闭后将收不到任何提醒。')
              .fontSize(12).fontColor(this.mutedText()).margin({ top: 6 });
            Row() {
              Text('通知权限状态').fontSize(14).fontColor(this.secondaryText());
              Blank();
              Text(this.notifEnabled ? '已开启' : '未开启')
                .fontSize(13)
                .fontColor(this.notifEnabled ? this.brandColor : '#D03A2B');
            }.width('100%').margin({ top: 12 });
            Button('发送测试通知')
              .width('100%').height(40).fontSize(14)
              .backgroundColor(this.brandColor)
              .margin({ top: 10 })
              .onClick(() => { this.sendTest(); });
          }
          .padding(16)
          .borderRadius(14)
          .backgroundColor(this.surfaceColor())
          .width('100%')
          .margin({ top: 12 });

          // ---- 说明 ----
          Text('提示:若收不到提醒,请在系统「设置 → 应用 → 邗上课表 → 通知」中确认允许通知,并在电池设置中允许后台运行。')
            .fontSize(12)
            .fontColor(this.mutedText())
            .lineHeight(18)
            .margin({ top: 16, left: 4, right: 4 });
        }
        .width('100%')
        .padding(16);
      }
      .layoutWeight(1)
      .scrollBar(BarState.Off);
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.pageColor());
  }
}
