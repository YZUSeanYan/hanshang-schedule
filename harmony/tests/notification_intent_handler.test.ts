/** Provider notification payload parser tests. */
import { notificationDestination, parseNotificationPayload } from '../entry/src/main/ets/core/notifications/NotificationRouting.ts';
import assert from 'node:assert/strict';

assert.equal(notificationDestination('notifications'), 'notifications');
assert.equal(notificationDestination(' hanshang://notifications '), 'notifications');
assert.equal(notificationDestination('/NOTIFICATIONS'), 'notifications');
assert.equal(notificationDestination('https://example.com/notifications'), null);

assert.deepEqual(parseNotificationPayload({
  version: '1', type: 'account_notification', destination: 'notifications', notification_id: '42'
}), { destination: 'notifications', notificationId: 42 });
assert.deepEqual(parseNotificationPayload({
  data: JSON.stringify({ version: '1', type: 'account_notification', destination: 'notifications', notification_id: '7' })
}), { destination: 'notifications', notificationId: 7 });
assert.deepEqual(parseNotificationPayload({ extraMap: JSON.stringify({ deeplink: 'hanshang://notifications' }) }),
  { destination: 'notifications', notificationId: null });
assert.deepEqual(parseNotificationPayload({ notification_id: 9 }),
  { destination: 'notifications', notificationId: 9 });
assert.equal(parseNotificationPayload({ version: '2', destination: 'notifications' }), null);
assert.equal(parseNotificationPayload({ type: 'external', destination: 'notifications' }), null);
assert.equal(parseNotificationPayload({ destination: 'notifications', notification_id: '0' }), null);
assert.equal(parseNotificationPayload({ destination: 'notifications', notification_id: '-1' }), null);
assert.equal(parseNotificationPayload({ destination: 'https://example.com' }), null);
assert.equal(parseNotificationPayload({ data: '{broken' }), null);

console.log('notification_intent_handler: all passed');
