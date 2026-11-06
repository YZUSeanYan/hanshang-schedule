/**
 * 课前提醒服务(M5)：使用 @ohos.reminderAgentManager 系统代理提醒。
 * 移植自 Flutter 版 core/notifications/reminder_service.dart。
 *
 * 功能：
 * - 根据课表为未来 7 天的课程设置系统日历提醒(提前 N 分钟)
 * - 提醒内容：课程名 + 教室 + 起止时间
 * - 重排：课程变更后重新计算全部提醒
 *
 * 注意：publishReminder 前需保证通知已授权(设置页负责 requestEnableNotification)。
 */
import { reminderAgentManager } from '@kit.BackgroundTasksKit';
import { notificationManager } from '@kit.NotificationKit';
import { ScheduleRepository } from '../../features/schedule/ScheduleRepository';
import { ScheduleDao } from '../../data/ScheduleDao';
import { startOf, endOf } from '../../constants/SectionTimes';
import { weekNumberOf, occursInWeek, DAY_MS, mondayOfMs, ymdOfMs, Ymd } from '../../utils/WeekCalculator';
import { jsonToWeeksList } from '../../model/SyncCodecs';
import { SettingsStore } from '../../storage/SettingsStore';
import { formatCourseLocation } from '../../utils/LocationFormatter';

/** 提前提醒分钟数选项 */
export const REMIND_AHEAD_OPTIONS: number[] = [5, 10, 15, 30];

/** 重排全部课前提醒(课程变更/设置变化后调用)。返回排上的条数。 */
export async function rescheduleReminders(aheadMinutes: number): Promise<number> {
  await cancelAllReminders();

  const sem = await ScheduleDao.findCurrentSemester();
  if (sem === null) {
    return 0;
  }

  const entries = await ScheduleRepository.loadCourseEntries(sem.id);
  const now = Date.now();
  const currentWeek = weekNumberOf(sem.startDateMs, now);
  if (currentWeek < 1 || currentWeek > sem.totalWeeks) {
    return 0;
  }

  let count = 0;
  // 为未来 7 天的每一天排提醒(第 0 天=今天,而非本周一)
  const todayStart = mondayOfMs(now) + (weekdayOf(now) - 1) * DAY_MS;
  for (let dayOffset = 0; dayOffset < 7; dayOffset++) {
    const dateMs = todayStart + dayOffset * DAY_MS;
    const dateYmd = ymdOfMs(dateMs);
    const week = weekNumberOf(sem.startDateMs, dateMs);
    if (week < 1 || week > sem.totalWeeks) {
      continue;
    }
    const weekday = weekdayOf(dateMs);

    for (const entry of entries) {
      for (const slot of entry.slots) {
        if (slot.dayOfWeek !== weekday) {
          continue;
        }
        const weeks = jsonToWeeksList(slot.customWeeksJson);
        if (!occursInWeek(slot.weeksType, weeks, week)) {
          continue;
        }

        const startTime = startOf(slot.startSection, dateYmd.month);
        const endTime = endOf(slot.endSection, dateYmd.month);
        const parts = startTime.split(':');
        const sh = Number(parts[0]);
        const sm = Number(parts[1]);

        // 提醒时刻 = 上课时间 - 提前量(按当天日期拼 UTC ms)
        const remindMs = msOfDate(dateYmd, sh, sm) - aheadMinutes * 60000;
        if (remindMs <= now) {
          continue; // 已过期跳过
        }

        const location = formatCourseLocation(slot.location);
        // 通知内容显示模式:0=完整(教室+时间) 1=仅课程名(隐私,公共场合不暴露位置)
        const content = SettingsStore.notifContentMode() === 1
          ? '该上课了'
          : `${location.length > 0 ? location + ' · ' : ''}${startTime}-${endTime}`;
        const ok = await publishOne(entry.course.name, content, dateYmd, remindMs, count);
        if (ok) {
          count++;
        }
      }
    }
  }
  return count;
}

/** 取消全部由本应用发布的代理提醒 */
export async function cancelAllReminders(): Promise<void> {
  try {
    const infos = await reminderAgentManager.getValidReminders();
    for (const info of infos) {
      const id = (info as object as reminderAgentManager.ReminderInfo).reminderId;
      await reminderAgentManager.cancelReminder(id);
    }
  } catch (e) {
    // 忽略(未授权或无提醒)
  }
}

/** 查询当前有效提醒数(设置页显示用) */
export async function validReminderCount(): Promise<number> {
  try {
    const infos = await reminderAgentManager.getValidReminders();
    return infos.length;
  } catch (e) {
    return 0;
  }
}

/** 发布单条日历型提醒 */
async function publishOne(title: string, content: string, dateYmd: Ymd, remindMs: number, index: number): Promise<boolean> {
  const d = new Date(remindMs);
  try {
    const reminder: reminderAgentManager.ReminderRequestCalendar = {
      reminderType: reminderAgentManager.ReminderType.REMINDER_TYPE_CALENDAR,
      dateTime: {
        year: dateYmd.year,
        month: dateYmd.month,
        day: dateYmd.day,
        hour: d.getUTCHours(),
        minute: d.getUTCMinutes(),
        second: 0
      },
      title: title,
      content: content,
      notificationId: 1000 + index,
      slotType: notificationManager.SlotType.SOCIAL_COMMUNICATION
    };
    await reminderAgentManager.publishReminder(reminder);
    return true;
  } catch (e) {
    return false; // 单条失败(数量上限/权限)不阻塞其余
  }
}

/** UTC ms → 星期几(1=周一 … 7=周日) */
function weekdayOf(ms: number): number {
  const d = new Date(ms).getUTCDay();
  return d === 0 ? 7 : d;
}

/** Ymd + 时分 → UTC ms(与 startOf 返回的 HH:mm 对应) */
function msOfDate(dateYmd: Ymd, hour: number, minute: number): number {
  return Date.UTC(dateYmd.year, dateYmd.month - 1, dateYmd.day, hour, minute, 0, 0);
}
