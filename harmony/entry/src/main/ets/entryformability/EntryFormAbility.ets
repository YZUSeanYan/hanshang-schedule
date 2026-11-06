/**
 * 服务卡片数据层(M6)：FormExtensionAbility。
 * 对应 Flutter 版 4 种桌面小部件(今日课程/下一节课/一周课程/近日课程)。
 *
 * 职责:卡片添加/更新时,从本地课表计算各卡片数据并推送(FormBindingData)。
 * 卡片侧通过 LocalStorage 属性接收;列表类数据序列化为 JSON 字符串。
 */
import { FormExtensionAbility, formBindingData, formProvider, formInfo } from '@kit.FormKit';
import { Want } from '@kit.AbilityKit';
import { Bootstrap } from '../common/Bootstrap';
import { ScheduleDao } from '../data/ScheduleDao';
import { ScheduleRepository } from '../features/schedule/ScheduleRepository';
import { startOf, endOf } from '../constants/SectionTimes';
import { weekNumberOf, occursInWeek, DAY_MS, mondayOfMs } from '../utils/WeekCalculator';
import { jsonToWeeksList } from '../model/SyncCodecs';
import { formatCourseLocation } from '../utils/LocationFormatter';
import { forCourseName, argbToCss } from '../constants/CourseColors';
import { CourseEntry } from '../features/schedule/ScheduleTypes';

/** 单条课程的卡片视图模型 */
interface CardCourse {
  name: string;
  time: string;
  location: string;
  colorHex: string;
}

/** 近期课程按天分组 */
interface CardDay {
  dateLabel: string;
  weekdayLabel: string;
  isToday: boolean;
  courses: CardCourse[];
}

const WEEKDAY_LABELS: string[] = ['一', '二', '三', '四', '五', '六', '日'];

export default class EntryFormAbility extends FormExtensionAbility {
  onAddForm(want: Want): formBindingData.FormBindingData {
    const formId = want.parameters?.[formInfo.FormParam.IDENTITY_KEY] as string;
    // 同步返回占位数据保证卡片立即挂载,随后异步推送真实课表数据
    const placeholder: Record<string, string | number> = {
      'dateLabel': '加载中…',
      'weekLabel': '',
      'todayJson': '[]',
      'nextJson': '',
      'nextIsTomorrow': 0,
      'weekJson': '[]',
      'weekTotal': 0,
      'todayCount': 0,
      'upcomingJson': '[]'
    };
    this.pushData(formId);
    return formBindingData.createFormBindingData(placeholder);
  }

  onUpdateForm(formId: string): void {
    this.pushData(formId);
  }

  onFormEvent(formId: string): void {
    this.pushData(formId);
  }

  private pushData(formId: string): void {
    this.buildData().then((data: Record<string, string | number>) => {
      formProvider.updateForm(formId, formBindingData.createFormBindingData(data)).catch(() => {
      });
    }).catch(() => {
    });
  }

  /** 汇总计算全部卡片共用的一份数据 */
  private async buildData(): Promise<Record<string, string | number>> {
    await Bootstrap.ensure(this.context);
    const data: Record<string, string | number> = {};

    const sem = await ScheduleDao.findCurrentSemester();
    if (sem === null) {
      data.dateLabel = '尚未创建课表';
      data.weekLabel = '';
      data.todayJson = '[]';
      data.nextJson = '';
      data.weekJson = '[]';
      data.upcomingJson = '[]';
      return data;
    }

    const entries = await ScheduleRepository.loadCourseEntries(sem.id);
    const now = Date.now();
    const week = weekNumberOf(sem.startDateMs, now);
    const inTerm = week >= 1 && week <= sem.totalWeeks;

    // 日期标签
    const nowDate = new Date(now);
    const weekday = nowDate.getUTCDay() === 0 ? 7 : nowDate.getUTCDay();
    data.dateLabel = `${nowDate.getUTCMonth() + 1}月${nowDate.getUTCDate()}日 周${WEEKDAY_LABELS[weekday - 1]}`;
    data.weekLabel = inTerm ? `第 ${week} 周 · ${sem.name}` : `${sem.name}(假期)`;

    // ---- 今日课程 ----
    const todayCourses = coursesOfDate(entries, sem.startDateMs, sem.totalWeeks, now, weekday);
    data.todayJson = JSON.stringify(todayCourses);
    data.todayCount = todayCourses.length;

    // ---- 下一节课 ----
    let next: CardCourse | null = null;
    const nowMinutes = nowDate.getUTCHours() * 60 + nowDate.getUTCMinutes();
    for (const c of todayCourses) {
      const endMinutes = minutesOf(c.time.split('-')[1]);
      if (endMinutes > nowMinutes) {
        next = c;
        break;
      }
    }
    // 今天没有了,找明天第一节
    if (next === null && inTerm) {
      const tomorrowMs = mondayOfMs(now) + weekday * DAY_MS;
      const nextWeek = weekNumberOf(sem.startDateMs, tomorrowMs);
      const tomorrowWeekday = weekday === 7 ? 1 : weekday + 1;
      const tomorrowCourses = nextWeek >= 1 && nextWeek <= sem.totalWeeks
        ? coursesOfDate(entries, sem.startDateMs, sem.totalWeeks, tomorrowMs, tomorrowWeekday)
        : [];
      if (tomorrowCourses.length > 0) {
        next = tomorrowCourses[0];
        data.nextIsTomorrow = 1;
      }
    }
    data.nextJson = next === null ? '' : JSON.stringify(next);

    // ---- 一周概览(本周每天课程数) ----
    const weekCounts: number[] = [];
    if (inTerm) {
      for (let d = 1; d <= 7; d++) {
        const dateMs = mondayOfMs(now) + (d - 1) * DAY_MS;
        weekCounts.push(coursesOfDate(entries, sem.startDateMs, sem.totalWeeks, dateMs, d).length);
      }
    }
    data.weekJson = JSON.stringify(weekCounts);
    data.weekTotal = weekCounts.reduce((a: number, b: number) => a + b, 0);

    // ---- 近 3 天课程(今天起) ----
    const days: CardDay[] = [];
    for (let i = 0; i < 3; i++) {
      const dateMs = mondayOfMs(now) + (weekday - 1 + i) * DAY_MS;
      const wd = ((weekday - 1 + i) % 7) + 1;
      const d = new Date(dateMs);
      const label = `${d.getUTCMonth() + 1}/${d.getUTCDate()}`;
      const w = weekNumberOf(sem.startDateMs, dateMs);
      const courses = (w >= 1 && w <= sem.totalWeeks)
        ? coursesOfDate(entries, sem.startDateMs, sem.totalWeeks, dateMs, wd)
        : [];
      days.push({
        dateLabel: label,
        weekdayLabel: `周${WEEKDAY_LABELS[wd - 1]}`,
        isToday: i === 0,
        courses: courses.slice(0, 3)
      });
    }
    data.upcomingJson = JSON.stringify(days);

    return data;
  }
}

/** 指定日期(weekday)的全部课程,按节次排序 */
function coursesOfDate(entries: CourseEntry[], startMondayMs: number, totalWeeks: number,
  dateMs: number, weekday: number): CardCourse[] {
  const week = weekNumberOf(startMondayMs, dateMs);
  if (week < 1 || week > totalWeeks) {
    return [];
  }
  const month = new Date(dateMs).getUTCMonth() + 1;
  const result: CardCourse[] = [];
  for (const entry of entries) {
    for (const slot of entry.slots) {
      if (slot.dayOfWeek !== weekday) {
        continue;
      }
      const weeks = jsonToWeeksList(slot.customWeeksJson);
      if (!occursInWeek(slot.weeksType, weeks, week)) {
        continue;
      }
      result.push({
        name: entry.course.name,
        time: `${startOf(slot.startSection, month)}-${endOf(slot.endSection, month)}`,
        location: formatCourseLocation(slot.location),
        colorHex: argbToCss(forCourseName(entry.course.name))
      });
    }
  }
  result.sort((a: CardCourse, b: CardCourse) => a.time.localeCompare(b.time));
  return result;
}

/** 'HH:mm' → 分钟数 */
function minutesOf(hhmm: string): number {
  const parts = hhmm.split(':');
  return Number(parts[0]) * 60 + Number(parts[1]);
}
