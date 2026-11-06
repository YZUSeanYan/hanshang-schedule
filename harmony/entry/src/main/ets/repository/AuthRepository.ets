/**
 * 认证仓库：注册/登录/会话恢复/忘记密码/退出。
 * 移植自 Flutter 版 features/auth/data/auth_repository.dart。
 *
 * 会话语义（与服务端 v1.0.25 线上一致）：
 * - access token 短期；refresh token 90 天滑动续期、不轮换；
 * - restore() 网络故障时回落缓存用户（离线模式），服务器明确拒绝才注销。
 */
import { ApiClient, ApiError } from '../network/ApiClient';
import { TokenStore } from '../storage/TokenStore';
import { HarmonyPushService } from '../core/notifications/HarmonyPushService';
import { PushKitAdapter } from '../core/notifications/PushKitAdapter';
import { AppDb } from '../data/AppDb';
import { SyncEngine } from '../sync/SyncEngine';

export class AuthUser {
  readonly id: number;
  readonly username: string;
  readonly email: string;
  /** 离线会话标记：断网时用缓存用户顶住，联网后自动恢复 */
  readonly offline: boolean;

  constructor(id: number, username: string, email: string, offline: boolean) {
    this.id = id;
    this.username = username;
    this.email = email;
    this.offline = offline;
  }

  static fromJson(map: Record<string, Object>): AuthUser {
    return new AuthUser(map['id'] as number, map['username'] as string,
      map['email'] as string, false);
  }

  static offlineFallback(): AuthUser {
    return new AuthUser(0, '离线模式', '联网后将自动恢复账号信息', true);
  }

  toJson(): Record<string, Object> {
    const out: Record<string, Object> = {
      'id': this.id,
      'username': this.username,
      'email': this.email
    };
    return out;
  }
}

export class AuthRepository {
  /** 最近一次已知的登录用户（进程内缓存，页面直接取用） */
  private static lastUser: AuthUser | null = null;

  static lastKnownUser(): AuthUser | null {
    return AuthRepository.lastUser;
  }

  /** 启动恢复会话：有 refresh token 则换新并拉取个人信息，否则视为未登录 */
  static async restore(): Promise<AuthUser | null> {
    const refresh = await TokenStore.readRefreshToken();
    if (refresh === null) {
      return null;
    }
    const cached = await AuthRepository.readCachedUser();
    if (cached !== null && cached.id > 0) {
      await AppDb.activateAccount(cached.id);
    }
    try {
      const body: Record<string, Object> = { 'refresh_token': refresh };
      const data = await ApiClient.post('/api/auth/refresh', body) as Record<string, Object>;
      const access = data['access_token'];
      const newRefresh = data['refresh_token'];
      if (typeof access === 'string' && typeof newRefresh === 'string') {
        await TokenStore.saveTokens(access, newRefresh);
      }
      const user = await AuthRepository.fetchProfile();
      await AppDb.activateAccount(user.id);
      await TokenStore.saveCachedUserJson(JSON.stringify(user.toJson()));
      AuthRepository.lastUser = user;
      HarmonyPushService.onAuthenticated();
      PushKitAdapter.syncTokenIfAllowed();
      return user;
    } catch (e) {
      if (e instanceof ApiError) {
        const err = e as ApiError;
        if (err.isDefinitiveAuthFailure()) {
          await TokenStore.clear();
          await AppDb.activateGuest();
          AuthRepository.lastUser = null;
          return null;
        }
        if (err.isTransient()) {
          const fallback = cached !== null ? cached : AuthUser.offlineFallback();
          AuthRepository.lastUser = fallback;
          return fallback;
        }
      }
      return null;
    }
  }

  static async login(account: string, password: string): Promise<AuthUser> {
    const body: Record<string, Object> = { 'account': account, 'password': password };
    const data = await ApiClient.post('/api/auth/login', body) as Record<string, Object>;
    return AuthRepository.completeLogin(data);
  }

  static async register(username: string, email: string, password: string): Promise<AuthUser> {
    const body: Record<string, Object> = {
      'username': username, 'email': email, 'password': password
    };
    const data = await ApiClient.post('/api/auth/register', body) as Record<string, Object>;
    return AuthRepository.completeLogin(data);
  }

  /** 发送重置密码验证码（失败抛 ApiError） */
  static async sendResetCode(email: string): Promise<void> {
    const body: Record<string, Object> = { 'email': email };
    await ApiClient.post('/api/auth/forgot-password', body);
  }

  /** 凭验证码重置密码（失败抛 ApiError） */
  static async resetPassword(email: string, code: string, newPassword: string): Promise<void> {
    const body: Record<string, Object> = {
      'email': email, 'code': code, 'new_password': newPassword
    };
    await ApiClient.post('/api/auth/reset-password', body);
  }

  /** 退出登录：先收敛同步和推送登记，再切回不含账号课表的访客库。 */
  static async logout(): Promise<void> {
    HarmonyPushService.beginAccountTransition();
    await SyncEngine.beginAccountTransition();
    try {
      await HarmonyPushService.unregisterForLogout();
      await TokenStore.clear();
      await AppDb.activateGuest();
      AuthRepository.lastUser = null;
    } finally {
      HarmonyPushService.endAccountTransition();
      SyncEngine.endAccountTransition();
    }
  }

  private static async fetchProfile(): Promise<AuthUser> {
    const data = await ApiClient.get('/api/user/profile') as Record<string, Object>;
    return AuthUser.fromJson(data);
  }

  private static async persistLogin(data: Record<string, Object>): Promise<AuthUser> {
    const access = data['access_token'];
    const refresh = data['refresh_token'];
    if (typeof access !== 'string' || access.length === 0
      || typeof refresh !== 'string' || refresh.length === 0) {
      throw new Error('登录响应缺少有效凭据');
    }
    const userRaw = data['user'];
    if (userRaw === null || typeof userRaw !== 'object') {
      throw new Error('登录响应缺少用户信息');
    }
    const userMap = userRaw as Record<string, Object>;
    const id = userMap['id'];
    const username = userMap['username'];
    const email = userMap['email'];
    if (typeof id !== 'number' || !Number.isInteger(id) || id <= 0
      || typeof username !== 'string' || username.length === 0
      || typeof email !== 'string' || email.length === 0) {
      throw new Error('登录响应中的用户信息无效');
    }
    const user = AuthUser.fromJson(userMap);
    await TokenStore.saveTokens(access, refresh);
    await TokenStore.saveCachedUserJson(JSON.stringify(user.toJson()));
    return user;
  }

  private static async completeLogin(data: Record<string, Object>): Promise<AuthUser> {
    HarmonyPushService.beginAccountTransition();
    await SyncEngine.beginAccountTransition();
    let user: AuthUser | null = null;
    try {
      user = await AuthRepository.persistLogin(data);
      await AppDb.activateAccount(user.id);
      AuthRepository.lastUser = user;
      return user;
    } finally {
      HarmonyPushService.endAccountTransition();
      SyncEngine.endAccountTransition();
      if (user !== null) {
        HarmonyPushService.onAuthenticated();
        PushKitAdapter.syncTokenIfAllowed();
      }
    }
  }

  private static async readCachedUser(): Promise<AuthUser | null> {
    const raw = await TokenStore.readCachedUserJson();
    if (raw === null) {
      return null;
    }
    try {
      const map = JSON.parse(raw) as Record<string, Object>;
      return AuthUser.fromJson(map);
    } catch (e) {
      return null;
    }
  }
}
