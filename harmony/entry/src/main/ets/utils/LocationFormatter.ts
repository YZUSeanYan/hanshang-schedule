/**
 * 地点智能排版：把最需要扫读的「楼+教室」放最前，校区作为补充信息放后。
 * 移植自 Flutter 版 app/lib/core/utils/location_formatter.dart，与网页端
 * displayLocation 行为保持一致。纯逻辑（无 @ohos 依赖），node 单测覆盖。
 */

export function formatCourseLocation(raw: string): string {
  const value = raw.trim().replace(/^[@\s]+/, '');
  if (value.length === 0) {
    return '';
  }

  // 教务复制文本的"校区>>楼>>教室"（或 →→ 箭头）分隔格式
  const arrowParts = value
    .split(/>>|→→|＞＞|->|→/)
    .map((part) => part.trim())
    .filter((part) => part.length > 0);
  if (arrowParts.length >= 3) {
    return `${arrowParts.slice(1).join('')} · ${arrowParts[0]}`;
  }
  if (arrowParts.length === 2) {
    return `${arrowParts[1]} · ${arrowParts[0]}`;
  }

  const parts = value
    .split(/\s*(?:@|·|，|,|\/|\|)\s*/)
    .map((part) => part.trim())
    .filter((part) => part.length > 0);

  if (parts.length > 1) {
    parts.sort((a, b) => locationScore(b) - locationScore(a));
    const seen = new Set<string>();
    const deduped: string[] = [];
    for (const p of parts) {
      if (!seen.has(p)) {
        seen.add(p);
        deduped.push(p);
      }
    }
    return deduped.join(' · ');
  }

  // 教务处常返回"校区+教学楼+教室"的无分隔格式。
  const campusEnd = value.lastIndexOf('校区');
  if (campusEnd >= 0) {
    const splitAt = campusEnd + '校区'.length;
    const campus = value.substring(0, splitAt).trim();
    const room = value.substring(splitAt).replace(/^[\s:：-]+/, '').trim();
    if (campus.length > 0 && room.length > 0) {
      return `${room} · ${campus}`;
    }
  }

  return value;
}

function locationScore(value: string): number {
  let score = 0;
  if (/(楼|馆|中心|实验室)/.test(value)) {
    score += 4;
  }
  if (/[A-Za-z]?\d{2,4}[A-Za-z]?$/.test(value)) {
    score += 5;
  }
  if (value.includes('校区')) {
    score -= 2;
  }
  return score;
}
