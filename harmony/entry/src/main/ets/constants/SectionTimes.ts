/**
 * 扬大节次作息表（春夏 / 秋冬两套）。
 *
 * 移植自 Flutter 版 app/lib/core/constants/section_times.dart。
 * 数据来源（2026-08）：
 * - 春夏季：全部 12 小节时间取自真实教务课表页面样本，可靠；
 * - 秋冬季：上午沿用官方已确认时间；下午/晚上按同一规律前移推得，
 *   ⚠️ 2026-09 开学后需用班级课表表头核对整套秋冬时间。
 *
 * 结构：12 小节，下标 0 = 第 1 小节。大节 = 相邻小节（1-2、3-4，最多 6-8 三节连排）。
 * 纯逻辑（无 @ohos 依赖），node 单测覆盖。
 */

export interface SectionTime {
  start: string; // 'HH:MM'
  end: string;
}

export const SECTION_COUNT = 12;

/** 春夏季（大致 5 月 - 9 月）：✅ 真实样本提取，可靠 */
export const SPRING_SUMMER: SectionTime[] = [
  { start: '08:00', end: '08:45' },
  { start: '08:55', end: '09:40' },
  { start: '09:55', end: '10:40' },
  { start: '10:50', end: '11:35' },
  { start: '11:45', end: '12:30' },
  { start: '14:30', end: '15:15' },
  { start: '15:25', end: '16:10' },
  { start: '16:20', end: '17:05' },
  { start: '17:15', end: '18:00' },
  { start: '18:10', end: '18:55' },
  { start: '19:30', end: '20:15' },
  { start: '20:25', end: '21:10' },
];

/** 秋冬季（大致 10 月 - 次年 4 月）：下午第 6 节 14:00 起（用户确认），晚 11 节 19:00 起（⚠️ 待核对） */
export const AUTUMN_WINTER: SectionTime[] = [
  { start: '08:00', end: '08:45' },
  { start: '08:55', end: '09:40' },
  { start: '09:55', end: '10:40' },
  { start: '10:50', end: '11:35' },
  { start: '11:45', end: '12:30' },
  { start: '14:00', end: '14:45' },
  { start: '14:55', end: '15:40' },
  { start: '15:50', end: '16:35' },
  { start: '16:45', end: '17:30' },
  { start: '17:40', end: '18:25' },
  { start: '19:00', end: '19:45' },
  { start: '19:50', end: '20:35' },
];

/** 按月份取适用的一套（5-9 月视为春夏季）。month: 1-12 */
export function sectionTimesForMonth(month: number): SectionTime[] {
  return month >= 5 && month <= 9 ? SPRING_SUMMER : AUTUMN_WINTER;
}

/** 当前月份适用的作息表 */
export function currentSectionTimes(): SectionTime[] {
  return sectionTimesForMonth(new Date().getMonth() + 1);
}

/** 第 section 小节（1-12）的开始时间 */
export function startOf(section: number, month: number = new Date().getMonth() + 1): string {
  return sectionTimesForMonth(month)[section - 1].start;
}

/** 第 section 小节（1-12）的结束时间 */
export function endOf(section: number, month: number = new Date().getMonth() + 1): string {
  return sectionTimesForMonth(month)[section - 1].end;
}
