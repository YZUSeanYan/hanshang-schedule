/**
 * 扬大教务课表解析器(WebView 抓取结果 → 标准课程模型)。
 * 移植自 Flutter 版 lib/import/yzu_parser.dart(策略 1 JSON 嗅探 + 兜底块状文本;
 * HTML 表格/移动卡片策略对 WebView 嗅探场景冗余,首版裁剪)。
 * 纯逻辑:零 @ohos 依赖;仅 import 同为纯逻辑的 TextImportParser(课表模型/精确块格式)。
 */
import { parseBlockList } from './TextImportParser.ts';

/** 解析后的课程(与 TextImportParser.ParsedCourse 结构一致,隔离声明以兼容 node 单测的类型剥离) */
export interface ParsedCourse {
  name: string;
  teacher: string;
  slots: { dayOfWeek: number; startSection: number; endSection: number; weeksType: number; customWeeks: number[]; location: string; weeksText: string }[];
}

export interface ParseResult {
  courses: ParsedCourse[];
  source: string; // json / html / none
  detail: string;
}

export function isParseSuccess(r: ParseResult): boolean {
  return r.courses.length > 0;
}

interface CapturedResponse {
  url: string;
  body: string;
}

interface Capture {
  url: string;
  title: string;
  html: string;
  captured: CapturedResponse[];
  frames: { url: string; title: string; html: string }[];
}

// ==================== 主入口 ====================

/** 解析 WebView 抓取包 JSON 文本:{url,title,captured:[{url,body}],html,frames:[...]} */
export function parseCapture(rawJson: string): ParseResult {
  let capture: Capture;
  try {
    capture = JSON.parse(rawJson) as Capture;
  } catch (e) {
    return failure(['抓取结果不是合法 JSON']);
  }
  if (capture === null || typeof capture !== 'object') {
    return failure(['抓取结果格式异常']);
  }

  // 1. 优先:JSON 接口嗅探
  const captured = Array.isArray(capture.captured) ? capture.captured : [];
  const failMsgs: string[] = [];
  for (const resp of captured) {
    if (typeof resp.body !== 'string' || resp.body.length === 0) {
      continue;
    }
    const courses = tryParseJson(resp.body);
    if (courses !== null) {
      return {
        courses: courses,
        source: 'json',
        detail: `命中接口：${resp.url || '未知'}，解析出 ${courses.length} 门课`
      };
    }
  }
  failMsgs.push(`嗅探到 ${captured.length} 个接口响应，均未识别出课程结构`);

  // 2. 兜底:主页面/iframe 的块状课程清单文本
  const htmlSources: { label: string; html: string }[] = [];
  if (typeof capture.html === 'string' && capture.html.length > 0) {
    htmlSources.push({ label: '主页面', html: capture.html });
  }
  const frames = Array.isArray(capture.frames) ? capture.frames : [];
  for (let i = 0; i < frames.length; i++) {
    const f = frames[i];
    if (f !== null && typeof f.html === 'string' && f.html.length > 0) {
      htmlSources.push({ label: `iframe ${i + 1}`, html: f.html });
    }
  }
  for (const src of htmlSources) {
    const text = htmlToText(src.html);
    // 优先:青果「全部课程清单」精确格式(课名 | 编号 学分 / >>分隔行)
    const precise = parseBlockList(text);
    if (precise.length > 0) {
      return {
        courses: precise,
        source: 'html',
        detail: `在${src.label}命中块状课程清单，解析出 ${precise.length} 门课`
      };
    }
    // 兜底:通用启发式(周x第y-z节 + 地点)
    const block = parseBlockCourses(text);
    if (block.length > 0) {
      return {
        courses: block,
        source: 'html',
        detail: `在${src.label}命中课程文本，解析出 ${block.length} 门课`
      };
    }
  }
  failMsgs.push(`检查 ${htmlSources.length} 个 HTML 文档，均未找到课表结构`);
  return failure(failMsgs);
}

function failure(msgs: string[]): ParseResult {
  return { courses: [], source: 'none', detail: msgs.join('；') };
}

// ==================== 策略 1:JSON 嗅探 ====================

const NAME_KEYS: string[] = ['kcmc', 'kcm', 'KCM', 'courseName', 'course_name', 'kcName', 'name', 'title', 'courseTitle'];
const TEACHER_KEYS: string[] = ['jsxm', 'jsm', 'JSXM', 'teacherName', 'attendClassTeacher', 'teacher_name', 'teacher', 'jsmc', 'teachers', 'SKJS'];
const LOCATION_KEYS: string[] = ['jxcdm', 'jxcd', 'roomName', 'room_name', 'location', 'cdmc', 'CDMC', 'place', 'room', 'classroom', 'jsmc_location', 'skdd', 'SKDD'];
const DAY_KEYS: string[] = ['xqj', 'skxq', 'XQI', 'weekDay', 'week_day', 'dayOfWeek', 'classDay', 'day', 'xq', 'xingqi'];
const SECTIONS_KEYS: string[] = ['jcs', 'jcdm', 'sections', 'sectionText', 'jc', 'nodes', 'jiec', 'JC', 'time'];
const START_KEYS: string[] = ['startSection', 'sectionStart', 'start_section', 'ksjc', 'startNode', 'classSessions'];
const END_KEYS: string[] = ['endSection', 'sectionEnd', 'end_section', 'jsjc', 'endNode'];
const WEEKS_KEYS: string[] = ['zcd', 'zcsm', 'ZCD', 'weeksText', 'weeks', 'zc', 'skzc', 'weekText', 'zcs', 'weekStr', 'weekDescription'];

type JsonMap = Record<string, Object>;

/** 尝试把一段 JSON 文本解析为课程列表;识别不了返回 null */
export function tryParseJson(body: string): ParsedCourse[] | null {
  let decoded: Object;
  try {
    decoded = JSON.parse(body) as Object;
  } catch (e) {
    return null;
  }
  const list = findCourseList(decoded);
  if (list === null || list.length === 0) {
    return null;
  }

  const courses = new Map<string, ParsedCourse>();
  for (const item of list) {
    const name = pickString(item, NAME_KEYS);
    if (name === null || name.length === 0) {
      continue;
    }
    const teacher = pickString(item, TEACHER_KEYS) ?? '';
    const nestedSlots = item['timeAndPlaceList'];
    let usedNested = false;
    if (Array.isArray(nestedSlots)) {
      for (const value of nestedSlots) {
        if (value !== null && typeof value === 'object' && !Array.isArray(value)) {
          if (appendJsonSlot(courses, name, teacher, value as JsonMap)) {
            usedNested = true;
          }
        }
      }
    }
    if (!usedNested) {
      appendJsonSlot(courses, name, teacher, item);
    }
  }
  if (courses.size === 0) {
    return null;
  }
  return Array.from(courses.values());
}

function appendJsonSlot(courses: Map<string, ParsedCourse>, name: string, teacher: string, slot: JsonMap): boolean {
  const day = parseDay(slot);
  const sections = parseSections(slot);
  if (day === null || sections === null) {
    return false;
  }
  const weeksText = pickString(slot, WEEKS_KEYS) ?? '';
  const weeks = parseWeeksText(weeksText);
  const key = `${name}|${teacher}`;
  let course = courses.get(key);
  if (course === undefined) {
    course = { name: name, teacher: teacher, slots: [] };
    courses.set(key, course);
  }
  course.slots.push({
    dayOfWeek: day,
    startSection: sections[0],
    endSection: sections[1],
    weeksType: weeks[0],
    customWeeks: weeks[1],
    location: parseLocation(slot),
    weeksText: weeksText
  });
  return true;
}

/** 递归寻找"课程列表":元素为对象且含课程名键 + (星期字段或嵌套时间段) */
function findCourseList(node: Object): JsonMap[] | null {
  if (Array.isArray(node)) {
    const arr = node as Object[];
    if (arr.length > 0 && arr.every(isJsonMap)) {
      const maps = arr as JsonMap[];
      const hit = maps.some((m) =>
        hasAnyKey(m, NAME_KEYS) && (parseDay(m) !== null || hasNestedSchedule(m)));
      if (hit) {
        return maps;
      }
    }
    for (const e of arr) {
      const found = findCourseList(e);
      if (found !== null) {
        return found;
      }
    }
  } else if (isJsonMap(node)) {
    const map = node as JsonMap;
    for (const key of Object.keys(map)) {
      const found = findCourseList(map[key]);
      if (found !== null) {
        return found;
      }
    }
  }
  return null;
}

function hasNestedSchedule(item: JsonMap): boolean {
  const values = item['timeAndPlaceList'];
  if (!Array.isArray(values)) {
    return false;
  }
  return values.some((v) => isJsonMap(v) && parseDay(v as JsonMap) !== null);
}

function isJsonMap(v: Object): boolean {
  return v !== null && typeof v === 'object' && !Array.isArray(v);
}

function hasAnyKey(map: JsonMap, keys: string[]): boolean {
  for (const k of keys) {
    if (map[k] !== undefined) {
      return true;
    }
  }
  return false;
}

function pickString(map: JsonMap, keys: string[]): string | null {
  for (const k of keys) {
    const v = map[k];
    if (typeof v === 'string' && v.trim().length > 0) {
      return v.trim();
    }
    if (typeof v === 'number') {
      return `${v}`;
    }
  }
  return null;
}

function pickNum(map: JsonMap, keys: string[]): number | null {
  for (const k of keys) {
    const v = map[k];
    if (typeof v === 'number') {
      return Math.trunc(v);
    }
    if (typeof v === 'string') {
      const n = parseInt(v.trim(), 10);
      if (Number.isFinite(n)) {
        return n;
      }
    }
  }
  return null;
}

/** 本体 + 嵌套 id 字段两层(扬大 URP 把 skxq/skjc 放在 id 里) */
function itemAndIdFields(item: JsonMap): JsonMap[] {
  const result: JsonMap[] = [item];
  const id = item['id'];
  if (isJsonMap(id)) {
    result.push(id as JsonMap);
  }
  return result;
}

/** 星期几:数字 / "3" / "周三" / "星期三" */
function parseDay(item: JsonMap): number | null {
  const cn: string[] = ['一', '二', '三', '四', '五', '六', '日'];
  for (const fields of itemAndIdFields(item)) {
    for (const k of DAY_KEYS) {
      const v = fields[k];
      if (v === undefined || v === null) {
        continue;
      }
      if (typeof v === 'number' && v >= 1 && v <= 7) {
        return Math.trunc(v);
      }
      if (typeof v === 'string') {
        const n = parseInt(v.trim(), 10);
        if (Number.isFinite(n) && n >= 1 && n <= 7) {
          return n;
        }
        for (let i = 0; i < cn.length; i++) {
          if (v.includes(cn[i])) {
            return i + 1;
          }
        }
      }
    }
  }
  return null;
}

/** 节次:"3,4" / "3-4" / [3,4] / 分字段 start/end;扬大 URP: id.skjc 起始 + cxjc 节数 */
function parseSections(item: JsonMap): [number, number] | null {
  for (const k of SECTIONS_KEYS) {
    const v = item[k];
    if (v === undefined || v === null) {
      continue;
    }
    if (Array.isArray(v)) {
      const nums = (v as Object[]).map(numOf).filter((n): n is number => n !== null);
      if (nums.length > 0) {
        nums.sort((a, b) => a - b);
        return [nums[0], nums[nums.length - 1]];
      }
    }
    if (typeof v === 'number') {
      return [Math.trunc(v), Math.trunc(v)];
    }
    if (typeof v === 'string') {
      const nums = matchInts(v);
      if (nums.length > 0) {
        nums.sort((a, b) => a - b);
        return [nums[0], nums[nums.length - 1]];
      }
    }
  }
  const id = item['id'];
  const idFields = isJsonMap(id) ? id as JsonMap : {};
  const start = pickNum(item, START_KEYS) ?? pickNum(idFields, START_KEYS.concat(['skjc']));
  const end = pickNum(item, END_KEYS) ?? pickNum(idFields, END_KEYS);
  if (start !== null && end !== null && end >= start) {
    return [start, end];
  }
  const count = pickNum(item, ['cxjc', 'continuingSession', 'sectionCount', 'duration'])
    ?? pickNum(idFields, ['cxjc', 'continuingSession', 'sectionCount', 'duration']);
  if (start !== null && count !== null && count > 0) {
    return [start, start + count - 1];
  }
  return null;
}

function numOf(v: Object): number | null {
  if (typeof v === 'number') {
    return Math.trunc(v);
  }
  if (typeof v === 'string') {
    const n = parseInt(v.trim(), 10);
    if (Number.isFinite(n)) {
      return n;
    }
  }
  return null;
}

function matchInts(text: string): number[] {
  const out: number[] = [];
  const re = /\d+/g;
  let m = re.exec(text);
  while (m !== null) {
    out.push(parseInt(m[0], 10));
    m = re.exec(text);
  }
  return out;
}

/** 扬大 URP 把校区/教学楼/教室拆三字段 */
function parseLocation(item: JsonMap): string {
  const split = [
    pickString(item, ['xqm', 'campusName']) ?? '',
    pickString(item, ['jxlm', 'teachingBuildingName', 'buildingName']) ?? '',
    pickString(item, ['jasm', 'classroomName', 'roomName']) ?? ''
  ].filter((p) => p.length > 0).join('');
  if (split.length > 0) {
    return split;
  }
  return pickString(item, LOCATION_KEYS) ?? '';
}

// ==================== 周次文本解析 ====================

/**
 * "1-16周"→custom[1..16];"1-15周单"→单数;"2-16周双"→双数;
 * "1,3,5-7周"→custom;裸"单周"/"双周"→odd/even;空→every
 */
export function parseWeeksText(raw: string): [number, number[]] {
  const text = raw.replace(/\s/g, '');
  if (text.length === 0) {
    return [0, []];
  }
  const isOdd = text.includes('单');
  const isEven = text.includes('双');

  const weeks = new Set<number>();
  const re = /(\d+)(?:[-~—](\d+))?/g;
  let m = re.exec(text);
  while (m !== null) {
    const a = parseInt(m[1], 10);
    const b = m[2] !== undefined ? parseInt(m[2], 10) : a;
    for (let i = a; i <= b && i <= 60; i++) {
      weeks.add(i);
    }
    m = re.exec(text);
  }
  const list = Array.from(weeks).sort((x, y) => x - y);

  if (list.length === 0) {
    if (isOdd) {
      return [1, []];
    }
    if (isEven) {
      return [2, []];
    }
    return [0, []];
  }
  if (isOdd) {
    return [3, list.filter((w) => w % 2 === 1)];
  }
  if (isEven) {
    return [3, list.filter((w) => w % 2 === 0)];
  }
  return [3, list];
}

// ==================== 策略 2:块状课程清单(HTML→文本) ====================

/** HTML → 纯文本(去标签,块级元素断行) */
export function htmlToText(html: string): string {
  return html
    .replace(/<script[\s\S]*?<\/script>/gi, '')
    .replace(/<style[\s\S]*?<\/style>/gi, '')
    .replace(/<br\s*\/?>/gi, '\n')
    .replace(/<\/(tr|p|div|li|h[1-6]|table|tbody|thead)>/gi, '\n')
    .replace(/<\/t[dh]>/gi, '\t')
    .replace(/<[^>]+>/g, '')
    .replace(/&nbsp;/g, ' ')
    .replace(/&amp;/g, '&')
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .replace(/&quot;/g, '"')
    .replace(/&#39;/g, "'")
    .replace(/[ \t]+/g, ' ')
    .replace(/\n\s*\n+/g, '\n')
    .trim();
}

/**
 * 块状课程清单:每门课一块,
 * 首行含课程名,后续行含 "周x第y-z节" + 地点,教师随行。
 */
export function parseBlockCourses(text: string): ParsedCourse[] {
  const lines = text.split('\n').map((l) => l.trim()).filter((l) => l.length > 0);
  if (lines.length === 0) {
    return [];
  }
  const timeRe = /(周[一二三四五六日天]|星期[一二三四五六日天])\D*?(\d+)\s*[-–—~]\s*(\d+)\s*节/;
  const weeksRe = /((?:\d+\s*[-–—~]?\s*\d*[,,]?\s*)+)周|单周|双周|每周|单|双/;

  const courses = new Map<string, ParsedCourse>();
  let current: ParsedCourse | null = null;

  for (const line of lines) {
    const tm = timeRe.exec(line);
    if (tm === null) {
      // 没有时间格式的行:可能是新课开始(课程名行)
      if (current === null || looksLikeCourseName(line)) {
        const name = cleanName(line);
        if (name.length >= 2 && name.length <= 40 && !isNoise(name)) {
          const teacher = extractTeacher(line);
          const key = `${name}|${teacher}`;
          let c = courses.get(key);
          if (c === undefined) {
            c = { name: name, teacher: teacher, slots: [] };
            courses.set(key, c);
          }
          current = c;
        }
      }
      continue;
    }
    if (current === null) {
      continue;
    }
    // 时间行:解析星期/节次/周次/地点
    const day = dayOfCn(tm[1]);
    if (day === null) {
      continue;
    }
    const start = parseInt(tm[2], 10);
    const end = parseInt(tm[3], 10);
    if (start < 1 || end < start || end > 14) {
      continue;
    }
    const wm = weeksRe.exec(line);
    const weeks = parseWeeksText(wm !== null ? wm[0] : '');
    current.slots.push({
      dayOfWeek: day,
      startSection: start,
      endSection: end,
      weeksType: weeks[0],
      customWeeks: weeks[1],
      location: extractLocation(line),
      weeksText: wm !== null ? wm[0] : ''
    });
  }
  const result = Array.from(courses.values()).filter((c) => c.slots.length > 0);
  return result;
}

function looksLikeCourseName(line: string): boolean {
  // 课程名行一般较短且不含"节"
  return line.length <= 40 && !timeDayHint(line);
}

function timeDayHint(line: string): boolean {
  return /(周[一二三四五六日天]|星期[一二三四五六日天])/.test(line);
}

function isNoise(text: string): boolean {
  const noise = ['课表', '查询', '学期', '班级', '打印', '导出', '首页', '返回', '登录', '菜单', '当前位置'];
  for (const n of noise) {
    if (text.includes(n)) {
      return true;
    }
  }
  return /^\d+$/.test(text);
}

function cleanName(line: string): string {
  // 去掉行内可能的教师括号
  return line.replace(/[（(]\s*[^）)]{1,20}\s*[）)]\s*$/, '').trim();
}

function extractTeacher(line: string): string {
  const m = /[（(]\s*([^）)]{1,20})\s*[）)]\s*$/.exec(line);
  return m !== null ? m[1].trim() : '';
}

function dayOfCn(cn: string): number | null {
  const chars: string[] = ['一', '二', '三', '四', '五', '六', '日', '天'];
  for (let i = 0; i < chars.length; i++) {
    if (cn.includes(chars[i])) {
      return chars[i] === '天' ? 7 : i + 1;
    }
  }
  return null;
}

function extractLocation(line: string): string {
  // "…节 后面的剩余部分"里的地点(含楼/室/区字样)
  const after = line.split('节').pop() ?? '';
  const lm = /([A-Za-z0-9\u4e00-\u9fa5]{2,20}(?:楼|室|区|馆|中心|教室)[A-Za-z0-9\u4e00-\u9fa5-]{0,12})/.exec(after);
  if (lm !== null) {
    return lm[1];
  }
  const seg = after.replace(/^[^\u4e00-\u9fa5A-Za-z0-9]+/, '').trim();
  return seg.length > 0 && seg.length <= 24 ? seg : '';
}
