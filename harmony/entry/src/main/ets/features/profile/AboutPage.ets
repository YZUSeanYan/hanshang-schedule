/**
 * 关于页(我的 → 关于邗上课表)。
 * 移植自 Flutter 版 about_page.dart:
 * /api/about 动态介绍(名称/头像/官网/简介) + 隐私政策全文 + 支持作者收款码。
 * 隐私政策文本与鸿蒙版一致(EMAS 部分替换为鸿蒙推送说明)。
 */
import { router } from '@kit.ArkUI';
import { AppTheme } from '../../common/AppTheme';
import { AppConfig } from '../../common/AppConfig';
import { ApiClient } from '../../network/ApiClient';

interface AboutContent {
  displayName: string;
  intro: string;
  websiteUrl: string;
  avatarMedia: string;
  paymentQrMedia: string;
}

interface PolicySection {
  title: string;
  body: string;
}

@Entry
@Component
struct AboutPage {
  @StorageProp(AppTheme.KEY_BRAND) brandColor: string = '#158A63';
  @StorageProp(AppTheme.KEY_BRAND_TINT) brandTint: string = '#158A631F';
  @StorageProp(AppTheme.KEY_MODE) themeMode: number = 0;
  @StorageProp(AppTheme.KEY_EFFECTIVE_DARK) effectiveDark: boolean = false;
  @State showPolicy: boolean = false;
  @State loading: boolean = true;
  @State loadFailed: boolean = false;
  @State content: AboutContent = {
    displayName: '邗上课表',
    intro: '',
    websiteUrl: 'https://hanshang.seanyan.store',
    avatarMedia: '',
    paymentQrMedia: ''
  };

  aboutToAppear(): void {
    this.load();
  }

  private async load(): Promise<void> {
    this.loading = true;
    this.loadFailed = false;
    try {
      // ApiClient.parseSuccess 已解包外层 {code,message,data},这里拿到的就是内层对象
      const inner = await ApiClient.get('/api/about') as Record<string, Object>;
      if (inner !== undefined) {
        this.content = {
          displayName: strOf(inner, 'display_name', '邗上课表'),
          intro: strOf(inner, 'intro', ''),
          websiteUrl: strOf(inner, 'website_url', 'https://hanshang.seanyan.store'),
          avatarMedia: strOf(inner, 'avatar_media', ''),
          paymentQrMedia: strOf(inner, 'payment_qr_media', '')
        };
      }
      this.loading = false;
    } catch (e) {
      this.loading = false;
      this.loadFailed = true;
    }
  }

  private mediaUrl(name: string): string {
    return `${AppConfig.API_BASE_URL}/api/about/media/${encodeURIComponent(name)}`;
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

  private policySections(): PolicySection[] {
    const list: PolicySection[] = [];
    list.push({ title: '生效日期', body: '2026 年 8 月 13 日' });
    list.push({
      title: '我们处理的信息',
      body: '为提供账号登录、课表导入与同步、课程提醒、账户通知和安全保障，我们处理用户名、邮箱、加密会话以及你主动创建或导入的学期、课程与时间安排。'
    });
    list.push({
      title: '教务凭据',
      body: 'WebVPN 登录由校方网页处理，应用不会读取或保存密码输入框内容。课表抓取只处理你主动打开的课表页面响应。'
    });
    list.push({
      title: '通知与第三方 SDK',
      body: '课程提醒使用系统本地提醒能力。账户消息可通过 Huawei Push Kit 送达；仅在你同意本政策并登录后申请推送标识，将其绑定到当前账号，退出时尝试解除绑定。拒绝或服务不可用不影响课表基本功能。'
    });
    list.push({
      title: '权限、保存和共享',
      body: '网络权限用于登录与同步，通知权限用于课程和账户消息。我们不会索取通讯录、定位、相机或麦克风权限。数据仅在实现功能和安全审计所需期限内保存，不出售个人信息；除云服务基础设施及依法要求外，不向无关第三方共享。'
    });
    list.push({
      title: '你的权利',
      body: '你可以退出登录、关闭通知，并联系管理员查询、更正或删除账号及云端数据。注销后依法需保留的安全日志除外，其余关联数据会删除。'
    });
    return list;
  }

  private pageColor(): string { return this.effectiveDark ? '#101214' : '#FFFFFF'; }
  private surfaceColor(): string { return this.effectiveDark ? '#1C1F22' : '#F7F8FA'; }
  private primaryText(): string { return this.effectiveDark ? '#F2F3F4' : '#1A1A1A'; }
  private secondaryText(): string { return this.effectiveDark ? '#B8BDC2' : '#555555'; }
  private mutedText(): string { return this.effectiveDark ? '#8F969D' : '#999999'; }
  private faintText(): string { return this.effectiveDark ? '#717880' : '#BBBBBB'; }
  private dividerColor(): string { return this.effectiveDark ? '#34383D' : '#E5E7EA'; }

  build() {
    Column() {
      // 顶栏
      Row() {
        Text('‹').fontSize(26).fontColor(this.primaryText()).padding(12)
          .onClick(() => router.back());
        Text('关于邗上课表').fontSize(17).fontWeight(FontWeight.Bold).fontColor(this.primaryText());
      }
      .width('100%').height(52);

      if (this.loading) {
        Column() {
          LoadingProgress().width(36).height(36).color(this.brandColor);
          Text('正在加载介绍内容…').fontSize(13).fontColor(this.mutedText()).margin({ top: 10 });
        }
        .layoutWeight(1)
        .width('100%')
        .justifyContent(FlexAlign.Center);
      } else {
        Scroll() {
          Column() {
            // 头像(服务器图或 App 图标兜底)
            if (this.content.avatarMedia.length > 0) {
              Image(this.mediaUrl(this.content.avatarMedia))
                .width(96)
                .height(96)
                .borderRadius(48)
                .backgroundColor(this.brandTint)
                .alt($r('app.media.app_icon'));
            } else {
              Image($r('app.media.app_icon'))
                .width(96)
                .height(96)
                .borderRadius(48);
            }
            Text(this.content.displayName)
              .fontSize(22)
              .fontWeight(FontWeight.Bold)
              .fontColor(this.brandColor)
              .margin({ top: 14 });
            Text(`HarmonyOS 版 · v${AppConfig.VERSION_NAME}`)
              .fontSize(12)
              .fontColor(this.faintText())
              .margin({ top: 4 });

            // 简介(服务器)
            if (this.content.intro.length > 0) {
              Text(this.content.intro)
                .fontSize(13)
                .fontColor(this.secondaryText())
                .lineHeight(21)
                .padding(16)
                .borderRadius(14)
                .backgroundColor(this.surfaceColor())
                .margin({ top: 18 });
            }

            // 信息列表
            Column() {
              this.aboutRow('官方网站', this.content.websiteUrl);
              Divider().color(this.dividerColor());
              this.aboutRow('当前主题模式', this.modeLabel());
              Divider().color(this.dividerColor());
              Row() {
                Column() {
                  Text('隐私政策').fontSize(15);
                  Text('生效日期：2026 年 8 月 13 日').fontSize(12).fontColor(this.mutedText()).margin({ top: 2 });
                }
                .alignItems(HorizontalAlign.Start).layoutWeight(1);
                Text(this.showPolicy ? '收起 ▴' : '查看全文 ▾')
                  .fontSize(13).fontColor(this.brandColor)
                  .onClick(() => { this.showPolicy = !this.showPolicy; });
              }
              .width('100%')
              .padding(14);

              if (this.showPolicy) {
                Divider().color(this.dividerColor());
                Column() {
                  ForEach(this.policySections(), (s: PolicySection, idx: number) => {
                    Text(s.title)
                      .fontSize(15)
                      .fontWeight(FontWeight.Bold)
                      .fontColor(this.primaryText())
                      .margin({ top: idx === 0 ? 4 : 14 });
                    Text(s.body)
                      .fontSize(13)
                      .fontColor(this.secondaryText())
                      .lineHeight(20)
                      .margin({ top: 4 });
                  }, (s: PolicySection) => s.title);
                }
                .alignItems(HorizontalAlign.Start)
                .width('100%')
                .padding(14);
              }
            }
            .borderRadius(14)
            .backgroundColor(this.surfaceColor())
            .width('100%')
            .margin({ top: 14 });

            // 支持作者(收款码,服务器图)
            if (this.content.paymentQrMedia.length > 0) {
              Column() {
                Text('支持作者')
                  .fontSize(15)
                  .fontWeight(FontWeight.Medium)
                  .width('100%');
                Column() {
                  Image(this.mediaUrl(this.content.paymentQrMedia))
                    .width('100%')
                    .constraintSize({ maxHeight: 340 })
                    .objectFit(ImageFit.Contain)
                    .alt($r('app.media.app_icon'));
                  Text('请在确认收款人信息后自愿支持')
                    .fontSize(11)
                    .fontColor(this.mutedText())
                    .margin({ top: 8 });
                }
                .padding(12)
                .borderRadius(12)
                .backgroundColor(this.surfaceColor())
                .margin({ top: 10 });
              }
              .alignItems(HorizontalAlign.Start)
              .width('100%')
              .margin({ top: 20 });
            }

            if (this.loadFailed) {
              Text('介绍内容加载失败，显示本地信息')
                .fontSize(11)
                .fontColor(this.faintText())
                .margin({ top: 12 })
                .onClick(() => { this.load(); });
            }

            Text('本 App 与扬州大学官方无任何隶属或授权关系，「扬州大学教务系统」字样仅用于描述功能适配对象。')
              .fontSize(11)
              .fontColor(this.faintText())
              .lineHeight(17)
              .padding({ left: 4, right: 4 })
              .margin({ top: 24 });
            Text('© 2026 邗上课表 · 独立开发')
              .fontSize(12)
              .fontColor(this.faintText())
              .margin({ top: 8, bottom: 24 });
          }
          .width('100%')
          .padding({ left: 16, right: 16 });
        }
        .layoutWeight(1)
        .scrollBar(BarState.Off);
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.pageColor());
  }

  @Builder
  aboutRow(title: string, value: string) {
    Row() {
      Text(title).fontSize(15).fontColor(this.primaryText());
      Blank();
      Text(value).fontSize(13).fontColor(this.mutedText())
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .constraintSize({ maxWidth: 220 });
    }
    .width('100%')
    .padding(14);
  }
}

function strOf(map: Record<string, Object>, key: string, def: string): string {
  const v = map[key];
  if (typeof v === 'string' && v.length > 0) {
    return v;
  }
  return def;
}
