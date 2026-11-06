const MINUTE_MS: number = 60 * 1000;
const HOUR_MS: number = 60 * MINUTE_MS;
const DAY_MS: number = 24 * HOUR_MS;

function two(value: number): string {
  return value < 10 ? `0${value}` : `${value}`;
}

export function notificationTimeText(isoText: string, nowMs: number = Date.now()): string {
  const timestamp = Date.parse(isoText);
  if (!Number.isFinite(timestamp)) {
    return '';
  }
  const delta = Math.max(0, nowMs - timestamp);
  if (delta < MINUTE_MS) {
    return '刚刚';
  }
  if (delta < HOUR_MS) {
    return `${Math.floor(delta / MINUTE_MS)} 分钟前`;
  }
  if (delta < DAY_MS) {
    return `${Math.floor(delta / HOUR_MS)} 小时前`;
  }
  if (delta < 7 * DAY_MS) {
    return `${Math.floor(delta / DAY_MS)} 天前`;
  }
  const date = new Date(timestamp);
  const now = new Date(nowMs);
  if (date.getFullYear() === now.getFullYear()) {
    return `${date.getMonth() + 1}月${date.getDate()}日 ${two(date.getHours())}:${two(date.getMinutes())}`;
  }
  return `${date.getFullYear()}年${date.getMonth() + 1}月${date.getDate()}日`;
}
