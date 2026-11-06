export type NotificationDestination = 'notifications';

export interface NotificationTapIntent {
  destination: NotificationDestination;
  notificationId: number | null;
}

export function notificationDestination(value: string): NotificationDestination | null {
  const normalized = value.trim().toLowerCase();
  if (normalized === 'notifications'
    || normalized === 'hanshang://notifications'
    || normalized === '/notifications') {
    return 'notifications';
  }
  return null;
}

function parseNested(value: Object | undefined): Record<string, Object> | null {
  if (typeof value !== 'string' || value.length === 0) return null;
  try {
    const parsed = JSON.parse(value) as Object;
    if (parsed !== null && typeof parsed === 'object' && !Array.isArray(parsed)) {
      return parsed as Record<string, Object>;
    }
  } catch (e) {
  }
  return null;
}

function positiveId(value: Object | undefined): number | null {
  let text = '';
  if (typeof value === 'string') text = value.trim();
  if (typeof value === 'number' && Number.isSafeInteger(value)) text = `${value}`;
  if (!/^[1-9][0-9]{0,14}$/.test(text)) return null;
  const id = Number(text);
  return Number.isSafeInteger(id) && id > 0 ? id : null;
}

export function parseNotificationPayload(input: Record<string, Object>): NotificationTapIntent | null {
  const merged: Record<string, Object> = {};
  const nestedData = parseNested(input['data']);
  const nestedExtra = parseNested(input['extraMap']);
  if (nestedData !== null) Object.assign(merged, nestedData);
  if (nestedExtra !== null) Object.assign(merged, nestedExtra);
  Object.assign(merged, input);

  const version = merged['version'] ?? merged['v'];
  const type = merged['type'];
  const modern = version !== undefined || type !== undefined || merged['destination'] !== undefined;
  if (modern) {
    if (version !== undefined && version !== '1') return null;
    if (type !== undefined && type !== 'account_notification') return null;
  }

  const candidates: Object[] = [
    merged['destination'], merged['deeplink'], merged['deep_link'],
    merged['url'], merged['target']
  ];
  let destination: NotificationDestination | null = null;
  for (const candidate of candidates) {
    if (typeof candidate === 'string') {
      destination = notificationDestination(candidate);
      if (destination !== null) break;
    }
  }
  const notificationId = positiveId(merged['notification_id']);
  if (destination === null && notificationId !== null) destination = 'notifications';
  if (destination === null) return null;
  if (merged['notification_id'] !== undefined && notificationId === null) return null;
  return { destination: destination, notificationId: notificationId };
}
