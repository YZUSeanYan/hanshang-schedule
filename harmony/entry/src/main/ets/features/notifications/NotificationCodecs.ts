import type { InboxNotification, NotificationPage } from './NotificationTypes.ts';

function asRecord(value: Object | null | undefined): Record<string, Object> | null {
  return value !== null && value !== undefined && typeof value === 'object'
    ? value as Record<string, Object>
    : null;
}

function positiveInteger(value: Object | undefined): number | null {
  return typeof value === 'number' && Number.isInteger(value) && value > 0 ? value : null;
}

function nonNegativeInteger(value: Object | undefined): number {
  return typeof value === 'number' && Number.isInteger(value) && value >= 0 ? value : 0;
}

function nullableString(value: Object | undefined): string | null {
  return typeof value === 'string' && value.length > 0 ? value : null;
}

export function decodeNotification(value: Object): InboxNotification | null {
  const map = asRecord(value);
  if (map === null) {
    return null;
  }
  const id = positiveInteger(map['id']);
  const title = map['title'];
  const body = map['body'];
  const createdAt = map['created_at'];
  if (id === null || typeof title !== 'string' || typeof body !== 'string'
    || typeof createdAt !== 'string' || createdAt.length === 0) {
    return null;
  }
  const status = map['delivery_status'];
  return {
    id,
    title,
    body,
    deliveryStatus: typeof status === 'string' ? status : '',
    createdAt,
    readAt: nullableString(map['read_at'])
  };
}

export function decodeNotificationPage(value: Object): NotificationPage {
  const map = asRecord(value);
  if (map === null) {
    throw new Error('通知列表响应格式无效');
  }
  const items: InboxNotification[] = [];
  const rawItems = map['items'];
  if (Array.isArray(rawItems)) {
    rawItems.forEach((raw: Object) => {
      const decoded = decodeNotification(raw);
      if (decoded !== null) {
        items.push(decoded);
      }
    });
  }
  const nextBeforeId = positiveInteger(map['next_before_id']);
  return {
    items,
    unread: nonNegativeInteger(map['unread']),
    hasMore: map['has_more'] === true && nextBeforeId !== null,
    nextBeforeId
  };
}
