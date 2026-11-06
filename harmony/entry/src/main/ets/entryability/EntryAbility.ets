import {
  AbilityConstant,
  Configuration,
  ConfigurationConstant,
  UIAbility,
  Want
} from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { Bootstrap } from '../common/Bootstrap';
import { AppTheme } from '../common/AppTheme';
import { NotificationIntentHandler } from '../core/notifications/NotificationIntentHandler';
import { PushKitAdapter } from '../core/notifications/PushKitAdapter';

export default class EntryAbility extends UIAbility {
  private mainWindow: window.Window | null = null;

  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    const systemDark = this.isSystemDark(this.context.config);
    Bootstrap.ensure(this.context, systemDark).then(() => {
      AppTheme.setEffectiveDarkListener((dark: boolean) => {
        this.applySystemBars(dark);
      });
    }).catch((error: Error) => {
      console.error(`[EntryAbility] bootstrap failed: ${error.message}`);
    });
    NotificationIntentHandler.capture(want);
  }

  onNewWant(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    NotificationIntentHandler.capture(want);
  }

  onConfigurationUpdate(newConfig: Configuration): void {
    AppTheme.updateSystemDark(this.isSystemDark(newConfig));
  }

  onDestroy(): void {
    AppTheme.setEffectiveDarkListener(null);
    this.mainWindow = null;
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    windowStage.getMainWindow().then((mainWindow: window.Window) => {
      this.mainWindow = mainWindow;
      this.applySystemBars(AppTheme.isEffectiveDark());
    }).catch((error: Error) => {
      console.error(`[EntryAbility] getMainWindow failed: ${error.message}`);
    });
    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        console.error(`[EntryAbility] loadContent failed: ${JSON.stringify(err)}`);
      }
    });
  }

  onForeground(): void {
    this.applySystemBars(AppTheme.isEffectiveDark());
    PushKitAdapter.syncTokenIfAllowed();
  }

  onBackground(): void {
  }

  private isSystemDark(config: Configuration): boolean {
    return config.colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
  }

  private applySystemBars(dark: boolean): void {
    const mainWindow = this.mainWindow;
    if (mainWindow === null) {
      return;
    }
    mainWindow.setWindowSystemBarProperties({
      statusBarColor: dark ? '#121212' : '#FFFFFF',
      navigationBarColor: dark ? '#121212' : '#FFFFFF',
      isStatusBarLightIcon: dark,
      isNavigationBarLightIcon: dark
    }).catch((error: Error) => {
      console.error(`[EntryAbility] apply system bars failed: ${error.message}`);
    });
  }
}
