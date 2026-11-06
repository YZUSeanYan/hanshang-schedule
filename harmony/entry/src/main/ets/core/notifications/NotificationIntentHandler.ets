import { Want } from '@kit.AbilityKit';
import { NotificationTapIntent, parseNotificationPayload } from './NotificationRouting';

/** Validates provider metadata before exposing a deferred UI navigation intent. */
export class NotificationIntentHandler {
  static readonly STORAGE_KEY: string = 'pending_notification_intent';
  static readonly EVENT_KEY: string = 'pending_notification_event';
  private static pendingIntent: NotificationTapIntent | null = null;

  static capture(want: Want): void {
    const parameters = want.parameters;
    if (parameters === undefined) return;
    const source: Record<string, Object> = {};
    Object.keys(parameters).forEach((key: string) => {
      const value = parameters[key];
      if (value !== undefined) source[key] = value;
    });
    const intent = parseNotificationPayload(source);
    if (intent === null) return;
    NotificationIntentHandler.publish(intent);
  }

  static publish(intent: NotificationTapIntent): void {
    NotificationIntentHandler.pendingIntent = intent;
    AppStorage.setOrCreate(NotificationIntentHandler.STORAGE_KEY, JSON.stringify(intent));
    const previous = AppStorage.get(NotificationIntentHandler.EVENT_KEY) as number ?? 0;
    AppStorage.setOrCreate(NotificationIntentHandler.EVENT_KEY, previous + 1);
  }

  static takePendingIntent(): NotificationTapIntent | null {
    const stored = AppStorage.get(NotificationIntentHandler.STORAGE_KEY) as string ?? '';
    let intent = NotificationIntentHandler.pendingIntent;
    if (stored.length > 0) {
      try {
        const parsed = JSON.parse(stored) as Record<string, Object>;
        intent = parseNotificationPayload(parsed);
      } catch (e) {
        intent = null;
      }
    }
    NotificationIntentHandler.pendingIntent = null;
    AppStorage.setOrCreate(NotificationIntentHandler.STORAGE_KEY, '');
    return intent;
  }
}
