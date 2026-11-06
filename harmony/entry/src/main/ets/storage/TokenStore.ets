/**
 * 凭据存储：Preferences KV（对应 Flutter 版 flutter_secure_storage 的角色；
 * 鸿蒙应用沙箱内 Preferences 文件仅本应用可读）。
 * 移植自 Flutter 版 core/storage/token_storage.dart。
 */
import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';

const STORE_NAME = 'hanshang_auth';
const KEY_ACCESS = 'access_token';
const KEY_REFRESH = 'refresh_token';
const KEY_CACHED_USER = 'cached_auth_user_v1';
const KEY_LEGACY_DB_OWNER = 'legacy_schedule_db_owner_v1';

export class TokenStore {
  private static store: preferences.Preferences | null = null;

  static async init(context: common.Context): Promise<void> {
    if (TokenStore.store === null) {
      TokenStore.store = await preferences.getPreferences(context, STORE_NAME);
    }
  }

  static async readAccessToken(): Promise<string | null> {
    const s = TokenStore.store;
    if (s === null) {
      return null;
    }
    const v = s.getSync(KEY_ACCESS, '') as string;
    return v.length > 0 ? v : null;
  }

  static async readRefreshToken(): Promise<string | null> {
    const s = TokenStore.store;
    if (s === null) {
      return null;
    }
    const v = s.getSync(KEY_REFRESH, '') as string;
    return v.length > 0 ? v : null;
  }

  static async readCachedUserJson(): Promise<string | null> {
    const s = TokenStore.store;
    if (s === null) {
      return null;
    }
    const v = s.getSync(KEY_CACHED_USER, '') as string;
    return v.length > 0 ? v : null;
  }

  static readCachedUserId(): number | null {
    const s = TokenStore.store;
    if (s === null) {
      return null;
    }
    const raw = s.getSync(KEY_CACHED_USER, '') as string;
    if (raw.length === 0) {
      return null;
    }
    try {
      const parsed = JSON.parse(raw) as Record<string, Object>;
      const id = parsed['id'];
      return typeof id === 'number' && Number.isInteger(id) && id > 0 ? id : null;
    } catch (e) {
      return null;
    }
  }

  static readLegacyDbOwnerId(): number | null {
    const s = TokenStore.store;
    if (s === null) {
      return null;
    }
    const id = s.getSync(KEY_LEGACY_DB_OWNER, 0) as number;
    return Number.isInteger(id) && id > 0 ? id : null;
  }

  static async claimLegacyDbFor(userId: number): Promise<boolean> {
    const s = TokenStore.store;
    if (s === null || userId <= 0) {
      return false;
    }
    const owner = TokenStore.readLegacyDbOwnerId();
    if (owner !== null) {
      return owner === userId;
    }
    s.putSync(KEY_LEGACY_DB_OWNER, userId);
    await s.flush();
    return true;
  }

  static async saveTokens(access: string, refresh: string): Promise<void> {
    const s = TokenStore.store;
    if (s === null) {
      return;
    }
    s.putSync(KEY_ACCESS, access);
    s.putSync(KEY_REFRESH, refresh);
    await s.flush();
  }

  static async saveCachedUserJson(value: string): Promise<void> {
    const s = TokenStore.store;
    if (s === null) {
      return;
    }
    s.putSync(KEY_CACHED_USER, value);
    await s.flush();
  }

  static async clear(): Promise<void> {
    const s = TokenStore.store;
    if (s === null) {
      return;
    }
    s.deleteSync(KEY_ACCESS);
    s.deleteSync(KEY_REFRESH);
    s.deleteSync(KEY_CACHED_USER);
    await s.flush();
  }
}
