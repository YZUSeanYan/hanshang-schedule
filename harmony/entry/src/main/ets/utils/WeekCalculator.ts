/**
 * 周次计算核心逻辑：纯函数、无 @ohos 依赖，可用 node 单测直接验证。
 *
 * 移植自 Flutter 版 app/lib/core/utils/week_calculator.dart。
 * 这是整个 App 最容易出错的地方，所有周次相关判断都必须经过本文件，
 * 禁止在 UI 里另写一套。
 *
 * 日期表示约定：全部使用「UTC 毫秒时间戳」承载「年/月/日」三元组
 * （即某日期 00:00 UTC 的毫秒数）。这样天差运算精确、跨平台确定性，
 * 也避开本地时区/夏令时干扰（中国无夏令时，但统一 UTC 更稳）。
 * 与服务端交互的 'YYYY-MM-DD' 字符串由 dateStrToMs / msToDateStr 转换。
 */

/** 课程周次类型（数据库存整数，顺序与 Flutter 版 enum 下标一致，不许变） */
export const WEEKS_TYPE_EVERY = 0;
export const WEEKS_TYPE_ODD = 1;
export const WEEKS_TYPE_EVEN = 2;
export const WEEKS_TYPE_CUSTOM = 3;

export interface Ymd {
  year: number;
  month: number; // 1-12
  day: number; // 1-31
}

export const DAY_MS = 86400000;
export const WEEK_MS = 7 * DAY_MS;

/** UTC 毫秒 → 年月日三元组 */
export function ymdOfMs(ms: number): Ymd {
  const d = new Date(ms);
  return { year: d.getUTCFullYear(), month: d.getUTCMonth() + 1, day: d.getUTCDate() };
}

/** 年月日三元组 → UTC 毫秒（该日 00:00 UTC） */
export function msOfYmd(year: number, month: number, day: number): number {
  return Date.UTC(year, month - 1, day);
}

/** 取日期所在周的周一（时间分量清零，UTC 基准）。 */
export function mondayOfMs(ms: number): number {
  const midnight = msOfYmd(ymdOfMs(ms).year, ymdOfMs(ms).month, ymdOfMs(ms).day);
  const weekday = new Date(midnight).getUTCDay(); // 0=周日 … 6=周六
  const shift = (weekday + 6) % 7; // 周一=0 … 周日=6
  return midnight - shift * DAY_MS;
}

/**
 * 计算 target 是学期的第几周（1 起）。
 *
 * startMondayMs 为开学第一周的周一。开学前返回 ≤ 0；
 * 超过学期总周数时照常返回（由 UI 决定如何展示）。
 * 必须用向下取整除法：天差为负（开学前）时朝零截断会错算成第 1 周。
 */
export function weekNumberOf(startMondayMs: number, targetMs: number): number {
  const target = msOfYmd(ymdOfMs(targetMs).year, ymdOfMs(targetMs).month, ymdOfMs(targetMs).day);
  const days = Math.round((target - startMondayMs) / DAY_MS);
  return Math.floor(days / 7) + 1;
}

/**
 * 判断某课程安排是否在 [week] 这一周上课。
 *
 * week ≤ 0（还没开学）时一律返回 false。
 */
export function occursInWeek(weeksType: number, customWeeks: number[], week: number): boolean {
  if (week < 1) {
    return false;
  }
  if (weeksType === WEEKS_TYPE_EVERY) {
    return true;
  }
  if (weeksType === WEEKS_TYPE_ODD) {
    return week % 2 === 1;
  }
  if (weeksType === WEEKS_TYPE_EVEN) {
    return week >= 2; // 双周从第 2 周起（第 1 周不是双周）
  }
  if (weeksType === WEEKS_TYPE_CUSTOM) {
    return customWeeks.includes(week);
  }
  return false;
}

/**
 * 解析自定义周次输入，支持逗号/空格/顿号分隔与区间：
 * "1,3,5-8，12" → [1, 3, 5, 6, 7, 8, 12]
 *
 * 非法片段直接忽略；结果去重并升序。
 */
export function parseCustomWeeks(input: string): number[] {
  const weeks = new Set<number>();
  const parts = input.split(/[,，、\s]+/);
  for (const part of parts) {
    if (part.length === 0) {
      continue;
    }
    const range = part.split(/[-~—]/);
    if (range.length === 1) {
      const v = Number(range[0]);
      if (Number.isInteger(v) && v > 0) {
        weeks.add(v);
      }
    } else if (range.length === 2) {
      const a = Number(range[0]);
      const b = Number(range[1]);
      if (Number.isInteger(a) && Number.isInteger(b) && a > 0 && b >= a) {
        for (let i = a; i <= b; i++) {
          weeks.add(i);
        }
      }
    }
  }
  const list = Array.from(weeks);
  list.sort((x, y) => x - y);
  return list;
}

/** 周次的人类可读描述，用于课程详情/编辑页。 */
export function describeWeeks(weeksType: number, customWeeks: number[]): string {
  if (weeksType === WEEKS_TYPE_EVERY) {
    return '每周';
  }
  if (weeksType === WEEKS_TYPE_ODD) {
    return '单周';
  }
  if (weeksType === WEEKS_TYPE_EVEN) {
    return '双周';
  }
  if (customWeeks.length === 0) {
    return '未设置周次';
  }
  return `第 ${customWeeks.join('、')} 周`;
}

/**
 * 把 UI 选择的周（可能超出学期范围）收敛到可展示区间。
 * 返回 null 表示学期尚未开始或已结束（假期中）。
 */
export function clampWeek(rawWeek: number, totalWeeks: number): number | null {
  if (rawWeek < 1 || rawWeek > totalWeeks) {
    return null;
  }
  return rawWeek;
}
