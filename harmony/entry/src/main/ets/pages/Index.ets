/**
 * 启动引导页：隐私门禁 → 恢复登录状态 → 主框架 / 登录页。
 * （对应 Flutter 版 privacyGateProvider + go_router 路由守卫语义。）
 */
import { router } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { Bootstrap } from '../common/Bootstrap';
import { AuthRepository } from '../repository/AuthRepository';
import { SettingsStore } from '../storage/SettingsStore';
import { AppTheme } from '../common/AppTheme';

@Entry
@Component
struct Index {
  @State message: string = '正在启动…';
  @StorageProp(AppTheme.KEY_EFFECTIVE_DARK) effectiveDark: boolean = false;

  aboutToAppear(): void {
    this.boot();
  }

  private async boot(): Promise<void> {
    try {
      const ctx = getContext(this) as common.UIAbilityContext;
      await Bootstrap.ensure(ctx);
      // 首次启动:先过隐私政策门禁
      if (!SettingsStore.hasConsentedPrivacy()) {
        router.replaceUrl({ url: 'features/privacy/PrivacyGatePage' });
        return;
      }
      const user = await AuthRepository.restore();
      if (user !== null) {
        router.replaceUrl({ url: 'pages/MainPage' });
      } else {
        router.replaceUrl({ url: 'pages/LoginPage' });
      }
    } catch (e) {
      this.message = '初始化失败，请重启应用';
      console.error(`[Index] 启动失败: ${e}`);
    }
  }

  build() {
    Column({ space: 16 }) {
      LoadingProgress().width(48).height(48).color('#158A63')
      Text(this.message)
        .fontSize(14)
        .fontColor(this.effectiveDark ? '#A8A8A8' : '#666666')
    }
    .justifyContent(FlexAlign.Center)
    .width('100%')
    .height('100%')
    .backgroundColor(this.effectiveDark ? '#121212' : '#FFFFFF')
  }
}
