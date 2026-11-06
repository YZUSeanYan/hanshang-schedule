/**
 * 同步数据编解码：本地数据库行 ↔ 服务端 JSON。
 *
 * 移植自 Flutter 版 features/sync/data/sync_repository.dart 的序列化逻辑。
 * 纯逻辑、零依赖（无 @ohos、无跨文件 import），node 单测覆盖；
 * SyncEngine / ScheduleDao 复用。
 *
 * 约定：
 * - 时间戳：updated_at / deleted_at 为绝对毫秒（Date.now() 基准，跨端一致）；
 * - start_date：数据库存「该日 00:00 UTC 毫秒」，与服务端交互转 'YYYY-MM-DD'；
 * - custom_weeks：服务端为逗号分隔整数（"1,2,3"），本地为 JSON 数组文本；
 * - 墓碑：deleted=true 的记录携带最小合法字段。
 */

// ---------- 日期字符串编解码（本模块自包含，避免跨文件 import） ----------

/** 'YYYY-MM-DD' → UTC 毫秒；非法输入返回 null */
export function dateStrToMs(text: string): number | null {
  const match = /^(\d{4})-(\d{2})-(\d{2})$/.exec(text.trim());
  if (match === null) {
    return null;
  }
  const year = Number(match[1]);
  const month = Number(match[2]);
  const day = Number(match[3]);
  const ms = Date.UTC(year, month - 1, day);
  // Date.UTC 会对溢出日期进位（如 2-31 → 3-3），校验往返一致性
  const d = new Date(ms);
  if (d.getUTCFullYear() !== year || d.getUTCMonth() + 1 !== month || d.getUTCDate() !== day) {
    return null;
  }
  return ms;
}

/** UTC 毫秒 → 'YYYY-MM-DD' */
export function msToDateStr(ms: number): string {
  const d = new Date(ms);
  const year = d.getUTCFullYear();
  const month = d.getUTCMonth() + 1;
  const day = d.getUTCDate();
  const mm = month < 10 ? `0${month}` : `${month}`;
  const dd = day < 10 ? `0${day}` : `${day}`;
  return `${year}-${mm}-${dd}`;
}

// ---------- 本地数据库行（与 Drift v2 schema 一一对应） ----------

export interface SemRow {
  id: number;
  uuid: string;
  name: string;
  startDateMs: number;
  totalWeeks: number;
  isCurrent: boolean;
  updatedAtMs: number;
}

export interface CourseRow {
  id: number;
  uuid: string;
  semesterId: number;
  name: string;
  teacher: string;
  color: number;
  note: string;
  updatedAtMs: number;
}

export interface SchedRow {
  id: number;
  uuid: string;
  courseId: number;
  dayOfWeek: number; // 1=周一 … 7=周日
  startSection: number; // 1-12
  endSection: number;
  weeksType: number; // 0=每周 1=单周 2=双周 3=自定义
  customWeeksJson: string; // 本地 JSON 数组文本，如 "[1,2,3]"
  location: string;
  updatedAtMs: number;
}

export interface PendingDeletionRow {
  id: number;
  entity: string; // 'semester' | 'course' | 'schedule'
  uuid: string;
  parentUuid: string; // semester_uuid / course_uuid（墓碑推送需要）
  deletedAtMs: number;
}

// ---------- 周次字符串编解码 ----------

/**
 * 把服务端周次字符串解析成平铺整数列表；"1-8,10,12" 与 "1,2,3" 均支持。
 * 结果去重升序（与 Flutter 版 _parseWeeksList 一致）。
 */
export function parseWeeksList(raw: string): number[] {
  const result: number[] = [];
  const seen = new Set<number>();
  const pieces = raw.split(',');
  for (const piece of pieces) {
    const trimmed = piece.trim();
    if (trimmed.length === 0) {
      continue;
    }
    const range = trimmed.split('-');
    if (range.length === 2) {
      const start = Number(range[0]);
      const end = Number(range[1]);
      if (!Number.isInteger(start) || !Number.isInteger(end)) {
        continue;
      }
      const low = start < end ? start : end;
      const high = start < end ? end : start;
      for (let week = low; week <= high; week++) {
        if (!seen.has(week)) {
          seen.add(week);
          result.push(week);
        }
      }
    } else {
      const week = Number(trimmed);
      if (Number.isInteger(week) && !seen.has(week)) {
        seen.add(week);
        result.push(week);
      }
    }
  }
  result.sort((a, b) => a - b);
  return result;
}

/** 周次整数列表 → 本地 JSON 数组文本 */
export function weeksListToJson(list: number[]): string {
  return JSON.stringify(list);
}

/** 本地 JSON 数组文本 → 周次整数列表；非法输入返回空列表。
 *  支持两种格式：JSON 数组 [1,2,3] 或逗号分隔 1,2,3 */
export function jsonToWeeksList(json: string): number[] {
  if (!json || json.length === 0) {
    return [];
  }
  // 尝试 JSON 数组格式
  try {
    const parsed = JSON.parse(json) as number[];
    if (Array.isArray(parsed)) {
      return parsed.filter((w) => Number.isInteger(w));
    }
  } catch {
    // 不是 JSON，继续尝试逗号分隔格式
  }
  // 逗号分隔格式：1,2,3,4,5
  const weeks: number[] = [];
  for (const part of json.split(',')) {
    const n = parseInt(part.trim(), 10);
    if (Number.isFinite(n)) {
      weeks.push(n);
    }
  }
  return weeks;
}

// ---------- push 编码（本地行 → 服务端 JSON） ----------

export type PushItem = Record<string, Object>;

export function semesterToPush(s: SemRow): PushItem {
  return {
    'uuid': s.uuid,
    'name': s.name,
    'start_date': msToDateStr(s.startDateMs),
    'total_weeks': s.totalWeeks,
    'is_current': s.isCurrent,
    'updated_at': s.updatedAtMs,
    'deleted': false,
  };
}

export function courseToPush(c: CourseRow, semesterUuid: string): PushItem {
  return {
    'uuid': c.uuid,
    'semester_uuid': semesterUuid,
    'name': c.name,
    'teacher': c.teacher,
    'color': c.color,
    'note': c.note,
    'updated_at': c.updatedAtMs,
    'deleted': false,
  };
}

export function scheduleToPush(s: SchedRow, courseUuid: string): PushItem {
  return {
    'uuid': s.uuid,
    'course_uuid': courseUuid,
    'day_of_week': s.dayOfWeek,
    'start_section': s.startSection,
    'end_section': s.endSection,
    'weeks_type': s.weeksType,
    'custom_weeks': jsonToWeeksList(s.customWeeksJson).join(','),
    'location': s.location,
    'updated_at': s.updatedAtMs,
    'deleted': false,
  };
}

/** 墓碑：按实体类型生成最小合法载荷 */
export function tombstoneFor(d: PendingDeletionRow): PushItem | null {
  const base: PushItem = {
    'uuid': d.uuid,
    'updated_at': d.deletedAtMs,
    'deleted': true,
  };
  if (d.entity === 'semester') {
    base['name'] = '';
    base['start_date'] = '1970-01-01';
    base['total_weeks'] = 20;
    base['is_current'] = false;
    return base;
  }
  if (d.entity === 'course') {
    base['semester_uuid'] = d.parentUuid;
    base['name'] = '';
    base['teacher'] = '';
    base['color'] = 0;
    base['note'] = '';
    return base;
  }
  if (d.entity === 'schedule') {
    base['course_uuid'] = d.parentUuid;
    base['day_of_week'] = 1;
    base['start_section'] = 1;
    base['end_section'] = 1;
    base['weeks_type'] = 0;
    base['custom_weeks'] = '';
    base['location'] = '';
    return base;
  }
  return null;
}

// ---------- pull 解码（服务端 JSON → 宽松字段读取） ----------

/** 宽松字段读取助手（服务端字段可能缺失或类型放宽） */
export function readString(map: Record<string, Object>, key: string): string {
  const v = map[key];
  return typeof v === 'string' ? v : '';
}

export function readNumber(map: Record<string, Object>, key: string): number {
  const v = map[key];
  if (typeof v === 'number') {
    return v;
  }
  return 0;
}

export function readBool(map: Record<string, Object>, key: string): boolean {
  const v = map[key];
  return v === true;
}

/** 服务端 pull 记录解码结果（id/外键 id 由本地数据库解析后回填） */
export interface PullSemesterRow extends SemRow {
  deletedMark: boolean;
}

export interface PullCourseRow extends CourseRow {
  deletedMark: boolean;
  semesterUuid: string;
}

export interface PullScheduleRow extends SchedRow {
  deletedMark: boolean;
  courseUuid: string;
}

/** 服务端 pull 记录 → 本地学期行（id=0 占位，入库时由数据库分配） */
export function semesterFromPull(map: Record<string, Object>): PullSemesterRow {
  const startMs = dateStrToMs(readString(map, 'start_date'));
  return {
    id: 0,
    uuid: readString(map, 'uuid'),
    name: readString(map, 'name'),
    startDateMs: startMs !== null ? startMs : 0,
    totalWeeks: readNumber(map, 'total_weeks'),
    isCurrent: readBool(map, 'is_current'),
    updatedAtMs: readNumber(map, 'updated_at'),
    deletedMark: readBool(map, 'deleted'),
  };
}

export function courseFromPull(map: Record<string, Object>): PullCourseRow {
  return {
    id: 0,
    uuid: readString(map, 'uuid'),
    semesterId: 0,
    semesterUuid: readString(map, 'semester_uuid'),
    name: readString(map, 'name'),
    teacher: readString(map, 'teacher'),
    color: readNumber(map, 'color'),
    note: readString(map, 'note'),
    updatedAtMs: readNumber(map, 'updated_at'),
    deletedMark: readBool(map, 'deleted'),
  };
}

export function scheduleFromPull(map: Record<string, Object>): PullScheduleRow {
  return {
    id: 0,
    uuid: readString(map, 'uuid'),
    courseId: 0,
    courseUuid: readString(map, 'course_uuid'),
    dayOfWeek: readNumber(map, 'day_of_week'),
    startSection: readNumber(map, 'start_section'),
    endSection: readNumber(map, 'end_section'),
    weeksType: readNumber(map, 'weeks_type'),
    customWeeksJson: weeksListToJson(parseWeeksList(readString(map, 'custom_weeks'))),
    location: readString(map, 'location'),
    updatedAtMs: readNumber(map, 'updated_at'),
    deletedMark: readBool(map, 'deleted'),
  };
}
