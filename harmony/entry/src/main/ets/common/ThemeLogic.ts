export const THEME_MODE_SYSTEM: number = 0;
export const THEME_MODE_LIGHT: number = 1;
export const THEME_MODE_DARK: number = 2;
export const DEFAULT_THEME_SEED: string = '#158A63';

export interface ThemeSnapshot {
  mode: number;
  seed: string;
}

export function normalizeThemeMode(mode: number): number {
  if (mode === THEME_MODE_LIGHT || mode === THEME_MODE_DARK) {
    return mode;
  }
  return THEME_MODE_SYSTEM;
}

export function normalizeThemeSeed(seed: string): string {
  const value = seed.trim().toUpperCase();
  return /^#[0-9A-F]{6}$/.test(value) ? value : DEFAULT_THEME_SEED;
}

export function normalizeThemeSnapshot(snapshot: ThemeSnapshot): ThemeSnapshot {
  return {
    mode: normalizeThemeMode(snapshot.mode),
    seed: normalizeThemeSeed(snapshot.seed)
  };
}

export function effectiveDark(mode: number, systemDark: boolean): boolean {
  const normalized = normalizeThemeMode(mode);
  if (normalized === THEME_MODE_DARK) {
    return true;
  }
  if (normalized === THEME_MODE_LIGHT) {
    return false;
  }
  return systemDark;
}

export function serializeThemeSnapshot(snapshot: ThemeSnapshot): string {
  return JSON.stringify(normalizeThemeSnapshot(snapshot));
}

export function deserializeThemeSnapshot(raw: string, fallback: ThemeSnapshot): ThemeSnapshot {
  const normalizedFallback = normalizeThemeSnapshot(fallback);
  if (raw.length === 0) {
    return normalizedFallback;
  }
  try {
    const parsed = JSON.parse(raw) as ThemeSnapshot;
    if (typeof parsed.mode !== 'number' || typeof parsed.seed !== 'string') {
      return normalizedFallback;
    }
    return normalizeThemeSnapshot(parsed);
  } catch (_) {
    return normalizedFallback;
  }
}
