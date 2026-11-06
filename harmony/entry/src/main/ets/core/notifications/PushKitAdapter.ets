import { pushService } from '@kit.PushKit';
import { AuthRepository } from '../../repository/AuthRepository';
import { SettingsStore } from '../../storage/SettingsStore';
import { HarmonyPushService } from './HarmonyPushService';

/** Consent-gated bridge from the system Push Kit token API to account binding. */
export class PushKitAdapter {
  private static requestInFlight: Promise<void> | null = null;

  static syncTokenIfAllowed(): Promise<void> {
    if (PushKitAdapter.requestInFlight !== null) return PushKitAdapter.requestInFlight;
    const task = PushKitAdapter.requestToken();
    PushKitAdapter.requestInFlight = task;
    task.then(() => { PushKitAdapter.requestInFlight = null; },
      () => { PushKitAdapter.requestInFlight = null; });
    return task;
  }

  private static async requestToken(): Promise<void> {
    if (!SettingsStore.hasConsentedPrivacy()) return;
    const user = AuthRepository.lastKnownUser();
    if (user === null || user.offline || user.id <= 0) return;
    try {
      const token = await pushService.getToken();
      await HarmonyPushService.onTokenUpdated(token);
    } catch (e) {
      // Push rights/AGC identity may be unavailable on development builds.
      console.warn('[PushKitAdapter] token unavailable; remote push remains disabled');
    }
  }
}
