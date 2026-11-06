import { RemoteNotificationExtensionAbility, pushCommon } from '@kit.PushKit';
import { parseNotificationPayload } from './NotificationRouting';

export default class RemoteNotificationAbility extends RemoteNotificationExtensionAbility {
  async onReceiveMessage(info: pushCommon.RemoteNotificationInfo):
    Promise<pushCommon.RemoteNotificationContent> {
    const parsed = parseNotificationPayload({ 'data': info.data });
    const parameters: Record<string, Object> = {};
    if (parsed !== null) {
      parameters['version'] = '1';
      parameters['type'] = 'account_notification';
      parameters['destination'] = parsed.destination;
      if (parsed.notificationId !== null) {
        parameters['notification_id'] = `${parsed.notificationId}`;
      }
    }
    return {
      wantAgent: {
        abilityName: 'EntryAbility',
        parameters: parameters
      }
    };
  }
}
