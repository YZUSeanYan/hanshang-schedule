/**
 * 扬大教务课表块状解析器(手动粘贴导入用)。
 * 移植自 Flutter 版 app/lib/import/yzu_parser.dart 的 parseBlockList。
 *
 * 解析"本学期课表-全部课程清单"页的复制文本(块状结构)：
 *   课程名 | 编号_学分
 *   教师行（含 *）
 *   节次行 1-18周>>星期四>>6-8节
 *   地点行 校区>>楼宇>>教室（按序与节次行一一对应）
 *
 * 纯逻辑(无 @ohos 依赖)。
 */
import { parseCustomWeeks } from '../../utils/WeekCalculator.ts';

/** 解析后的课程 */
export interface ParsedCourse {
  name: string;
  teacher: string;
  slots: ParsedSlot[];
}

/** 解析后的时间段 */
export interface ParsedSlot {
  dayOfWeek: number; // 1=周一 … 7=周日
  startSection: number;
  endSection: number;
  weeksType: number; // 0=每周 1=单周 2=双周 3=自定义
  customWeeks: number[];
  location: string;
  weeksText: string;
}

const DAY_MAP: Record<string, number> = {
  '一': 1, '二': 2, '三': 3, '四': 4, '五': 5, '六': 6, '日': 7
};

/**
 * 解析块状课程清单文本。
 * 样本格式：
 *   大学物理Ⅳ | 080601_4 4学分
 *   教师A*
 *   1-16周>>星期四>>1-2节
 *   扬子津东校区>>文津楼>>N107
 */
export function parseBlockList(text: string): ParsedCourse[] {
  const lines = text
    .split(/\r?\n/)
    .map((l) => l.trim())
    .filter((l) => l.length > 0);

  // 块起始行：课程名 | 编号_学分
  const blockRe = RegExp("^(.+?)\\s*\\|\\s*[0-9A-Za-z]+_\\d+\\s*\\d*学分$");
  if (!lines.some((l) => blockRe.test(l))) {
    return [];
  }

  const slotRe = RegExp("^(\\d+(?:-\\d+)?周)>>星期([一二三四五六日])>>(\\d+)-(\\d+)节$");
  const locRe = RegExp("^(.+?)(?:>>|→→|＞＞)(.+?)(?:>>|→→|＞＞)(.+)$");

  const courses: ParsedCourse[] = [];
  let i = 0;
  while (i < lines.length) {
    const match = blockRe.exec(lines[i]);
    if (match === null) {
      i++;
      continue;
    }
    const name = match[1].trim();
    i++;

    // 收集块内行(直到下一个块起始或实习/实验安排)
    const block: string[] = [];
    while (i < lines.length &&
    !blockRe.test(lines[i]) &&
    !/^(实习课安排|实验课安排)/.test(lines[i])) {
      block.push(lines[i]);
      i++;
    }

    // 教师：含 * 的行
    let teacher = '';
    for (const line of block) {
      if (line.includes('*')) {
        teacher = line
          .replace(/\*/g, '')
          .split(/\s+/)
          .filter((s) => s.length > 0)
          .join(' ');
        break;
      }
    }

    // 节次行 + 地点行
    const slotMatches: RegExpExecArray[] = [];
    const locLines: string[] = [];
    for (const line of block) {
      const m = slotRe.exec(line);
      if (m !== null) {
        slotMatches.push(m);
      } else if (locRe.test(line) && !line.includes('周') && !line.includes('节')) {
        locLines.push(line);
      }
    }

    const slots: ParsedSlot[] = [];
    for (let idx = 0; idx < slotMatches.length; idx++) {
      const m = slotMatches[idx];
      const weeksText = m[1];
      const dayChar = m[2];
      const startSection = Number(m[3]);
      const endSection = Number(m[4]);
      const weeksInfo = parseWeeksText(weeksText);
      slots.push({
        dayOfWeek: DAY_MAP[dayChar] ?? 1,
        startSection: startSection,
        endSection: endSection,
        weeksType: weeksInfo.weeksType,
        customWeeks: weeksInfo.customWeeks,
        location: idx < locLines.length ? locLines[idx] : '',
        weeksText: weeksText
      } as ParsedSlot);
    }

    if (slots.length > 0) {
      courses.push({ name: name, teacher: teacher, slots: slots } as ParsedCourse);
    }
  }
  return courses;
}

/** 解析周次文本："1-16周"→{每周}, "1,3,5周"→{自定义}, "单周"→{单周} */
function parseWeeksText(text: string): { weeksType: number, customWeeks: number[] } {
  const trimmed = text.replace(/周$/, '').trim();
  if (trimmed === '每周') {
    return { weeksType: 0, customWeeks: [] };
  }
  if (trimmed === '单周') {
    return { weeksType: 1, customWeeks: [] };
  }
  if (trimmed === '双周') {
    return { weeksType: 2, customWeeks: [] };
  }
  // 范围或列表："1-16" 或 "1,3,5"
  const customWeeks = parseCustomWeeks(trimmed);
  if (customWeeks.length > 0) {
    return { weeksType: 3, customWeeks: customWeeks };
  }
  return { weeksType: 0, customWeeks: [] };
}
