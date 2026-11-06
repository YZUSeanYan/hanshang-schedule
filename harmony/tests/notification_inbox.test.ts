import assert from 'node:assert/strict';
import { decodeNotification, decodeNotificationPage } from '../entry/src/main/ets/features/notifications/NotificationCodecs.ts';
import { notificationTimeText } from '../entry/src/main/ets/features/notifications/NotificationTime.ts';

let failed = 0;
function t(name: string, fn: () => void): void {
  try {
    fn();
    console.log(`  PASS ${name}`);
  } catch (error) {
    failed++;
    console.error(`  FAIL ${name}`);
    console.error(`       ${error instanceof Error ? error.message : String(error)}`);
  }
}

console.log('NotificationInbox:');

const unread = {
  id: 42,
  title: '维护提醒',
  body: '今晚 23:00 进行维护',
  delivery_status: 'accepted',
  created_at: '2026-08-16T10:00:00+00:00',
  read_at: null,
};

t('解码完整未读通知', () => {
  assert.deepEqual(decodeNotification(unread), {
    id: 42,
    title: '维护提醒',
    body: '今晚 23:00 进行维护',
    deliveryStatus: 'accepted',
    createdAt: '2026-08-16T10:00:00+00:00',
    readAt: null,
  });
});

t('缺少必填字段或非法 id 的项目被忽略', () => {
  assert.equal(decodeNotification({ ...unread, id: 0 }), null);
  assert.equal(decodeNotification({ ...unread, title: 3 }), null);
  assert.equal(decodeNotification({ ...unread, created_at: '' }), null);
});

t('列表保留合法项目并读取游标', () => {
  const page = decodeNotificationPage({
    items: [unread, { id: 'bad' }],
    unread: 3,
    has_more: true,
    next_before_id: 42,
  });
  assert.equal(page.items.length, 1);
  assert.equal(page.unread, 3);
  assert.equal(page.hasMore, true);
  assert.equal(page.nextBeforeId, 42);
});

t('缺失或非法分页字段使用安全默认值', () => {
  const page = decodeNotificationPage({ items: [], unread: -1, has_more: true });
  assert.equal(page.unread, 0);
  assert.equal(page.hasMore, false);
  assert.equal(page.nextBeforeId, null);
});

t('相对时间边界稳定', () => {
  const now = Date.parse('2026-08-16T12:00:00Z');
  assert.equal(notificationTimeText('2026-08-16T11:59:31Z', now), '刚刚');
  assert.equal(notificationTimeText('2026-08-16T11:45:00Z', now), '15 分钟前');
  assert.equal(notificationTimeText('2026-08-16T09:00:00Z', now), '3 小时前');
  assert.equal(notificationTimeText('2026-08-14T12:00:00Z', now), '2 天前');
  assert.equal(notificationTimeText('not-a-date', now), '');
});

if (failed > 0) {
  console.error(`notification_inbox: ${failed} 个用例失败`);
  process.exit(1);
}
console.log('notification_inbox: 全部通过');
