/**
 * Theme state shared through AppStorage.
 * Mode values: 0 follows system, 1 light, 2 dark.
 */
import { SettingsStore } from '../storage/SettingsStore';
import {
  effectiveDark,
  normalizeThemeSnapshot,
  ThemeSnapshot
} from './ThemeLogic';

export interface ThemeSeed {
  hex: string;
  name: string;
}

export const PRESET_SEEDS: ThemeSeed[] = [
  { hex: '#158A63', name: '邗上绿' },
  { hex: '#3A7BD5', name: '清爽蓝' },
  { hex: '#43A047', name: '竹青绿' },
  { hex: '#8E24AA', name: '葡萄紫' },
  { hex: '#E53935', name: '枫叶红' },
  { hex: '#FB8C00', name: '蜜柑橙' },
  { hex: '#00ACC1', name: '湖水青' },
  { hex: '#5C6BC0', name: '靛蓝' },
  { hex: '#EC407A', name: '樱粉' }
];

export function tintOf(hex: string): string {
  return `${hex}1F`;
}

export class AppTheme {
  static readonly KEY_BRAND: string = 'brandColor';
  static readonly KEY_BRAND_TINT: string = 'brandTint';
  static readonly KEY_MODE: string = 'themeMode';
  static readonly KEY_EFFECTIVE_DARK: string = 'effectiveDark';
  static readonly KEY_SCHEDULE_REV: string = 'scheduleRev';

  private static snapshot: ThemeSnapshot = { mode: 0, seed: '#158A63' };
  private static systemDark: boolean = false;
  private static saveQueue: Promise<void> = Promise.resolve();
  private static effectiveDarkListener: ((dark: boolean) => void) | null = null;

  static notifyScheduleChanged(): void {
    const current = AppStorage.get(AppTheme.KEY_SCHEDULE_REV) as number ?? 0;
    AppStorage.set(AppTheme.KEY_SCHEDULE_REV, current + 1);
  }

  static initFromSettings(systemDark: boolean): void {
    AppTheme.systemDark = systemDark;
    AppTheme.snapshot = SettingsStore.themeSnapshot();
    AppStorage.setOrCreate(AppTheme.KEY_BRAND, AppTheme.snapshot.seed);
    AppStorage.setOrCreate(AppTheme.KEY_BRAND_TINT, tintOf(AppTheme.snapshot.seed));
    AppStorage.setOrCreate(AppTheme.KEY_MODE, AppTheme.snapshot.mode);
    AppStorage.setOrCreate(AppTheme.KEY_EFFECTIVE_DARK,
      effectiveDark(AppTheme.snapshot.mode, AppTheme.systemDark));
    AppStorage.setOrCreate(AppTheme.KEY_SCHEDULE_REV, 0);
  }

  static setEffectiveDarkListener(listener: ((dark: boolean) => void) | null): void {
    AppTheme.effectiveDarkListener = listener;
    if (listener !== null) {
      listener(AppTheme.isEffectiveDark());
    }
  }

  static updateSystemDark(systemDark: boolean): void {
    AppTheme.systemDark = systemDark;
    AppTheme.publishEffectiveDark();
  }

  static isEffectiveDark(): boolean {
    return effectiveDark(AppTheme.snapshot.mode, AppTheme.systemDark);
  }

  static applySeed(hex: string): void {
    AppTheme.applySnapshot({ mode: AppTheme.snapshot.mode, seed: hex });
  }

  static applyMode(mode: number): void {
    AppTheme.applySnapshot({ mode, seed: AppTheme.snapshot.seed });
  }

  private static applySnapshot(snapshot: ThemeSnapshot): void {
    AppTheme.snapshot = normalizeThemeSnapshot(snapshot);
    AppStorage.set(AppTheme.KEY_BRAND, AppTheme.snapshot.seed);
    AppStorage.set(AppTheme.KEY_BRAND_TINT, tintOf(AppTheme.snapshot.seed));
    AppStorage.set(AppTheme.KEY_MODE, AppTheme.snapshot.mode);
    AppTheme.publishEffectiveDark();
    const saved = AppTheme.snapshot;
    AppTheme.saveQueue = AppTheme.saveQueue
      .then(() => SettingsStore.saveTheme(saved.mode, saved.seed))
      .catch((error: Error) => {
        console.error(`[AppTheme] save failed: ${error.message}`);
      });
  }

  private static publishEffectiveDark(): void {
    const dark = AppTheme.isEffectiveDark();
    AppStorage.set(AppTheme.KEY_EFFECTIVE_DARK, dark);
    const listener = AppTheme.effectiveDarkListener;
    if (listener !== null) {
      listener(dark);
    }
  }
}
