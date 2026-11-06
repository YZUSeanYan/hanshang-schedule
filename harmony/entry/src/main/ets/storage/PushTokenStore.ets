import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';

const STORE_NAME = 'hanshang_push';
const KEY_TOKEN = 'harmony_push_token_v1';
const KEY_REGISTERED_TOKEN = 'harmony_registered_token_v1';

export class PushTokenStore {
  private static store: preferences.Preferences | null = null;
  private static initInFlight: Promise<void> | null = null;

  static init(context: common.Context): Promise<void> {
    if (PushTokenStore.store !== null) {
      return Promise.resolve();
    }
    if (PushTokenStore.initInFlight === null) {
      const task = PushTokenStore.open(context);
      PushTokenStore.initInFlight = task;
      task.then(() => { PushTokenStore.initInFlight = null; }, () => {
        PushTokenStore.initInFlight = null;
      });
    }
    return PushTokenStore.initInFlight;
  }

  static async waitUntilReady(): Promise<void> {
    if (PushTokenStore.store !== null) {
      return;
    }
    const task = PushTokenStore.initInFlight;
    if (task === null) {
      throw new Error('PushTokenStore 尚未开始初始化');
    }
    await task;
  }

  private static async open(context: common.Context): Promise<void> {
    PushTokenStore.store = await preferences.getPreferences(context, STORE_NAME);
  }

  static readToken(): string | null {
    return PushTokenStore.read(KEY_TOKEN);
  }

  static readRegisteredToken(): string | null {
    return PushTokenStore.read(KEY_REGISTERED_TOKEN);
  }

  static async saveToken(token: string): Promise<void> {
    await PushTokenStore.put(KEY_TOKEN, token);
  }

  static async markRegistered(token: string): Promise<void> {
    await PushTokenStore.put(KEY_REGISTERED_TOKEN, token);
  }

  static async clearRegisteredToken(): Promise<void> {
    const store = PushTokenStore.store;
    if (store === null) {
      return;
    }
    store.deleteSync(KEY_REGISTERED_TOKEN);
    await store.flush();
  }

  private static read(key: string): string | null {
    const store = PushTokenStore.store;
    if (store === null) {
      return null;
    }
    const value = store.getSync(key, '') as string;
    return value.length > 0 ? value : null;
  }

  private static async put(key: string, value: string): Promise<void> {
    const store = PushTokenStore.store;
    if (store === null) {
      return;
    }
    store.putSync(key, value);
    await store.flush();
  }
}
