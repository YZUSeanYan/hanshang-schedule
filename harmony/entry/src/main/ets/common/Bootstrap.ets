/**
 * 应用初始化门闩：Preferences 与数据库就绪后放行。
 * EntryAbility.onCreate 提前预热；页面 aboutToAppear 再 ensure 一次幂等兜底。
 */
import { common } from '@kit.AbilityKit';
import { TokenStore } from '../storage/TokenStore';
import { PushTokenStore } from '../storage/PushTokenStore';
import { SettingsStore } from '../storage/SettingsStore';
import { AppDb } from '../data/AppDb';
import { AppTheme } from './AppTheme';

export class Bootstrap {
  private static readyPromise: Promise<void> | null = null;

  static ensure(context: common.Context, systemDark: boolean = false): Promise<void> {
    if (Bootstrap.readyPromise === null) {
      Bootstrap.readyPromise = Bootstrap.initialize(context, systemDark);
    }
    return Bootstrap.readyPromise;
  }

  static async waitUntilReady(): Promise<void> {
    const task = Bootstrap.readyPromise;
    if (task === null) {
      throw new Error('Bootstrap 尚未开始初始化');
    }
    await task;
  }

  private static async initialize(context: common.Context, systemDark: boolean): Promise<void> {
    await Promise.all([
      TokenStore.init(context),
      PushTokenStore.init(context),
      SettingsStore.init(context)
    ]);
    AppTheme.initFromSettings(systemDark);
    await AppDb.init(context, TokenStore.readCachedUserId());
  }
}
