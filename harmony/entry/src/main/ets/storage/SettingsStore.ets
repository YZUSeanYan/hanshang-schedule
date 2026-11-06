/**
 * 应用设置存储：Preferences KV。
 * 移植自 Flutter 版 shared_preferences 用法（隐私同意/提醒设置/外观主题）。
 */
import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import {
  DEFAULT_THEME_SEED,
  deserializeThemeSnapshot,
  normalizeThemeSnapshot,
  serializeThemeSnapshot,
  ThemeSnapshot
} from '../common/ThemeLogic';

const STORE_NAME = 'hanshang_settings';

// 键名与 Flutter 版对齐,便于语义对照
const KEY_PRIVACY_CONSENTED_AT = 'privacy_consented_at';
const KEY_REMINDER_ENABLED = 'reminder_enabled';
const KEY_REMIND_AHEAD_MINUTES = 'remind_ahead_minutes';
const KEY_THEME_MODE = 'theme_mode'; // 旧版键,仅用于迁移
const KEY_THEME_SEED = 'theme_seed'; // 旧版键,仅用于迁移
const KEY_THEME_SNAPSHOT = 'theme_snapshot_v1';
const KEY_NOTIF_CONTENT = 'notif_content_mode'; // 0=完整(课名+教室+时间) 1=仅课程名(隐私)

export class SettingsStore {
  private static store: preferences.Preferences | null = null;

  static async init(context: common.Context): Promise<void> {
    if (SettingsStore.store === null) {
      SettingsStore.store = await preferences.getPreferences(context, STORE_NAME);
    }
  }

  private static num(key: string, def: number): number {
    const s = SettingsStore.store;
    if (s === null) {
      return def;
    }
    return s.getSync(key, def) as number;
  }

  private static str(key: string, def: string): string {
    const s = SettingsStore.store;
    if (s === null) {
      return def;
    }
    return s.getSync(key, def) as string;
  }

  // ---- 隐私门禁 ----

  /** 是否已同意隐私政策(无记录 = 首次启动) */
  static hasConsentedPrivacy(): boolean {
    return SettingsStore.num(KEY_PRIVACY_CONSENTED_AT, 0) > 0;
  }

  static async agreePrivacy(): Promise<void> {
    const s = SettingsStore.store;
    if (s === null) {
      return;
    }
    await s.put(KEY_PRIVACY_CONSENTED_AT, Date.now());
    await s.flush();
  }

  // ---- 课前提醒 ----

  static reminderEnabled(): boolean {
    return SettingsStore.num(KEY_REMINDER_ENABLED, 0) === 1;
  }

  static remindAheadMinutes(): number {
    return SettingsStore.num(KEY_REMIND_AHEAD_MINUTES, 15);
  }

  static async saveReminderSettings(enabled: boolean, aheadMinutes: number): Promise<void> {
    const s = SettingsStore.store;
    if (s === null) {
      return;
    }
    await s.put(KEY_REMINDER_ENABLED, enabled ? 1 : 0);
    await s.put(KEY_REMIND_AHEAD_MINUTES, aheadMinutes);
    await s.flush();
  }

  // ---- 通知内容显示 ----

  /** 0=完整(课名+教室+时间) 1=仅课程名(隐私模式,公共场合不暴露位置) */
  static notifContentMode(): number {
    return SettingsStore.num(KEY_NOTIF_CONTENT, 0);
  }

  static async saveNotifContentMode(mode: number): Promise<void> {
    const s = SettingsStore.store;
    if (s === null) {
      return;
    }
    await s.put(KEY_NOTIF_CONTENT, mode);
    await s.flush();
  }

  // ---- 外观主题 ----

  /** 0=跟随系统 1=浅色 2=深色 */
  static themeMode(): number {
    return SettingsStore.themeSnapshot().mode;
  }

  static themeSeed(): string {
    return SettingsStore.themeSnapshot().seed;
  }

  static themeSnapshot(): ThemeSnapshot {
    const legacy: ThemeSnapshot = {
      mode: SettingsStore.num(KEY_THEME_MODE, 0),
      seed: SettingsStore.str(KEY_THEME_SEED, DEFAULT_THEME_SEED)
    };
    return deserializeThemeSnapshot(SettingsStore.str(KEY_THEME_SNAPSHOT, ''), legacy);
  }

  static async saveTheme(mode: number, seed: string): Promise<void> {
    const s = SettingsStore.store;
    if (s === null) {
      return;
    }
    const snapshot = normalizeThemeSnapshot({ mode, seed });
    await s.put(KEY_THEME_SNAPSHOT, serializeThemeSnapshot(snapshot));
    await s.flush();
  }
}
