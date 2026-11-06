/**
 * 首次启动隐私政策门禁(金标联盟/应用商店合规)。
 * 移植自 Flutter 版 features/privacy/presentation/privacy_gate_view.dart。
 * 未同意前不进入业务页面;不同意则二次确认后退出应用。
 */
import { router } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { SettingsStore } from '../../storage/SettingsStore';
import { Bootstrap } from '../../common/Bootstrap';
import { AppTheme } from '../../common/AppTheme';
import { AuthRepository } from '../../repository/AuthRepository';

const BRAND_GREEN: string = '#158A63';

@Entry
@Component
struct PrivacyGatePage {
  @StorageProp(AppTheme.KEY_EFFECTIVE_DARK) effectiveDark: boolean = false;
  @State showDisagreeConfirm: boolean = false;

  private async agree(): Promise<void> {
    await SettingsStore.agreePrivacy();
    // 同意后走正常启动分流(恢复登录 → 主框架/登录页)
    try {
      const user = await AuthRepository.restore();
      if (user !== null) {
        router.replaceUrl({ url: 'pages/MainPage' });
      } else {
        router.replaceUrl({ url: 'pages/LoginPage' });
      }
    } catch (e) {
      router.replaceUrl({ url: 'pages/LoginPage' });
    }
  }

  private quitApp(): void {
    const ctx = getContext(this) as common.UIAbilityContext;
    ctx.terminateSelf();
  }

  private pageColor(): string { return this.effectiveDark ? '#101214' : '#FFFFFF'; }
  private dialogColor(): string { return this.effectiveDark ? '#1C1F22' : '#FFFFFF'; }
  private primaryText(): string { return this.effectiveDark ? '#F2F3F4' : '#1A1A1A'; }
  private bodyText(): string { return this.effectiveDark ? '#C6CBD0' : '#444444'; }
  private secondaryText(): string { return this.effectiveDark ? '#AAB0B6' : '#666666'; }
  private mutedText(): string { return this.effectiveDark ? '#8F969D' : '#888888'; }
  private dividerColor(): string { return this.effectiveDark ? '#34383D' : '#E5E7EA'; }

  build() {
    Stack() {
      Column() {
        // 顶部标题栏
        Text('欢迎使用邗上课表')
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.primaryText())
          .width('100%')
          .height(52)
          .textAlign(TextAlign.Center);

        Scroll() {
          Column() {
            Text('隐私政策提示')
              .fontSize(20)
              .fontWeight(FontWeight.Bold)
              .fontColor(this.primaryText())
              .margin({ top: 8 });
            Text('欢迎使用邗上课表。在使用前，请你仔细阅读并了解《邗上课表隐私政策》（点击下方链接查看全文）。为提供账号登录、课表导入与同步、课程提醒等服务，我们需要处理：')
              .fontSize(14)
              .fontColor(this.bodyText())
              .margin({ top: 12 })
              .lineHeight(22);
            Text('• 账号信息：用户名、邮箱与登录会话；\n• 课表数据：你主动创建或导入的学期、课程与时间安排；\n• 设备信息：在你同意本政策并登录后，系统可通过 Huawei Push Kit 获取推送标识，用于账户消息送达；推送标识会绑定到当前账号，退出登录时尝试解除绑定；\n• 教务登录：WebVPN 登录在应用内网页中由你本人完成，应用不读取或保存密码输入框内容。')
              .fontSize(14)
              .fontColor(this.bodyText())
              .margin({ top: 8 })
              .lineHeight(22);
            Text('我们不会索取通讯录、定位、相机或麦克风权限，不出售你的个人信息。你可以随时在「我的-关于」中查看完整隐私政策，退出登录即可清除登录状态。')
              .fontSize(14)
              .fontColor(this.bodyText())
              .margin({ top: 8 })
              .lineHeight(22);
          }
          .alignItems(HorizontalAlign.Start)
          .width('100%')
          .padding({ left: 20, right: 20, top: 12, bottom: 12 });
        }
        .layoutWeight(1)
        .scrollBar(BarState.Off)
        .align(Alignment.TopStart);

        Column() {
          Text('查看《邗上课表隐私政策》全文')
            .fontSize(14)
            .fontColor(BRAND_GREEN)
            .margin({ top: 4 });
          Button('同意并继续')
            .width('100%')
            .height(46)
            .fontSize(16)
            .backgroundColor(BRAND_GREEN)
            .margin({ top: 12 })
            .onClick(() => { this.agree(); });
          Text('不同意并退出')
            .fontSize(14)
            .fontColor(this.mutedText())
            .height(44)
            .margin({ top: 4 })
            .onClick(() => { this.showDisagreeConfirm = true; });
        }
        .width('100%')
        .padding({ left: 20, right: 20, bottom: 16 });
      }
      .width('100%')
      .height('100%')
      .backgroundColor(this.pageColor());

      // 不同意二次确认弹窗
      if (this.showDisagreeConfirm) {
        Column() {
          Column()
            .width('100%').height('100%')
            .backgroundColor('rgba(0,0,0,0.4)')
            .onClick(() => { this.showDisagreeConfirm = false; });
          Column() {
            Text('确定不同意吗？')
              .fontSize(17).fontWeight(FontWeight.Bold).fontColor(this.primaryText()).margin({ top: 20 });
            Text('不同意隐私政策将无法使用邗上课表。你可以随时退出后重新安装再次选择。')
              .fontSize(14).fontColor(this.secondaryText())
              .margin({ top: 12, left: 16, right: 16 })
              .lineHeight(21);
            Divider().color(this.dividerColor()).margin({ top: 16 });
            Row() {
              Text('再想想')
                .fontSize(15).fontColor(this.secondaryText()).layoutWeight(1).height(46)
                .textAlign(TextAlign.Center)
                .onClick(() => { this.showDisagreeConfirm = false; });
              Divider().vertical(true).color(this.dividerColor()).height(46);
              Text('不同意并退出')
                .fontSize(15).fontColor(BRAND_GREEN).layoutWeight(1).height(46)
                .textAlign(TextAlign.Center)
                .onClick(() => { this.quitApp(); });
            }.width('100%');
          }
          .width('78%')
          .borderRadius(16)
          .backgroundColor(this.dialogColor());
        }
        .width('100%').height('100%')
        .justifyContent(FlexAlign.Center);
      }
    }
    .width('100%')
    .height('100%');
  }
}
