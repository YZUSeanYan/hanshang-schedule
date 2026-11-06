import { http } from '@kit.NetworkKit';
import { ApiClient } from '../../network/ApiClient';
import { SettingsStore } from '../../storage/SettingsStore';
import { TokenStore } from '../../storage/TokenStore';
import { PushTokenStore } from '../../storage/PushTokenStore';
import { AppConfig } from '../../common/AppConfig';
import { Bootstrap } from '../../common/Bootstrap';
import { AppDb } from '../../data/AppDb';

const PLATFORM = 'harmony';
const DEFAULT_LABEL = 'HarmonyOS device';
const MIN_TOKEN_LENGTH = 8;
const MAX_TOKEN_LENGTH = 192;

/**
 * Provider-neutral push lifecycle. AGC must call onTokenUpdated after privacy
 * consent; without an AGC adapter this service remains a network-free no-op.
 */
export class HarmonyPushService {
  private static syncInFlight: Promise<void> | null = null;
  private static lifecycleGeneration: number = 0;
  private static accountTransitioning: boolean = false;

  static onAuthenticated(): Promise<void> {
    return HarmonyPushService.bestEffortSync();
  }

  static beginAccountTransition(): void {
    HarmonyPushService.accountTransitioning = true;
    HarmonyPushService.lifecycleGeneration++;
  }

  static endAccountTransition(): void {
    HarmonyPushService.accountTransitioning = false;
  }

  static async onTokenUpdated(rawToken: string): Promise<void> {
    await Bootstrap.waitUntilReady();
    await PushTokenStore.waitUntilReady();
    if (!SettingsStore.hasConsentedPrivacy()) {
      return;
    }
    const token = rawToken.trim();
    if (!HarmonyPushService.isValidToken(token)) {
      return;
    }
    await PushTokenStore.saveToken(token);
    await HarmonyPushService.bestEffortSync();
  }

  static async unregisterForLogout(): Promise<void> {
    const activeSync = HarmonyPushService.syncInFlight;
    if (activeSync !== null) {
      await activeSync;
    }
    const registered = PushTokenStore.readRegisteredToken();
    if (registered === null || await TokenStore.readAccessToken() === null) {
      return;
    }
    if (await HarmonyPushService.bestEffortUnregister(registered)) {
      await PushTokenStore.clearRegisteredToken();
    }
  }

  private static bestEffortSync(): Promise<void> {
    if (HarmonyPushService.syncInFlight !== null) {
      return HarmonyPushService.syncInFlight;
    }
    const task = HarmonyPushService.syncRegistration();
    HarmonyPushService.syncInFlight = task;
    task.then(() => {
      HarmonyPushService.syncInFlight = null;
    }, () => {
      HarmonyPushService.syncInFlight = null;
    });
    return task;
  }

  private static async syncRegistration(): Promise<void> {
    try {
      if (HarmonyPushService.accountTransitioning || !SettingsStore.hasConsentedPrivacy()) {
        return;
      }
      const token = PushTokenStore.readToken();
      const accountId = AppDb.activeUserId();
      const generation = HarmonyPushService.lifecycleGeneration;
      if (token === null || !HarmonyPushService.isValidToken(token) || accountId === null
        || TokenStore.readCachedUserId() !== accountId
        || await TokenStore.readAccessToken() === null) {
        return;
      }
      const registered = PushTokenStore.readRegisteredToken();
      if (registered !== null && registered !== token) {
        if (!await HarmonyPushService.bestEffortUnregister(registered)) {
          return;
        }
        await PushTokenStore.clearRegisteredToken();
      }
      const body: Record<string, Object> = {
        'device_id': token,
        'label': DEFAULT_LABEL,
        'platform': PLATFORM,
        'app_version': AppConfig.VERSION_NAME
      };
      await ApiClient.post('/api/notifications/devices', body);
      if (!HarmonyPushService.accountTransitioning
        && generation === HarmonyPushService.lifecycleGeneration
        && AppDb.activeUserId() === accountId
        && TokenStore.readCachedUserId() === accountId
        && await TokenStore.readAccessToken() !== null) {
        await PushTokenStore.markRegistered(token);
      } else if (!await HarmonyPushService.bestEffortUnregister(token)) {
        await PushTokenStore.markRegistered(token);
      }
    } catch (e) {
      console.warn(`[HarmonyPushService] registration deferred: ${e}`);
    }
  }

  private static async bestEffortUnregister(token: string): Promise<boolean> {
    try {
      await ApiClient.request(http.RequestMethod.DELETE,
        `/api/notifications/devices/${encodeURIComponent(token)}`, null);
      return true;
    } catch (e) {
      console.warn(`[HarmonyPushService] unregistration deferred: ${e}`);
      return false;
    }
  }

  private static isValidToken(token: string): boolean {
    return token.length >= MIN_TOKEN_LENGTH && token.length <= MAX_TOKEN_LENGTH;
  }
}
