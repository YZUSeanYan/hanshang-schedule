/**
 * 课表业务仓库：学期与课程的读写入口,含墓碑同步逻辑。
 * 移植自 Flutter 版 features/schedule/data/schedule_repository.dart。
 */
import { AppDb } from '../../data/AppDb';
import { ScheduleDao, SemInsert } from '../../data/ScheduleDao';
import { mondayOfMs } from '../../utils/WeekCalculator';
import { forCourseName } from '../../constants/CourseColors';
import { CourseEntry, SlotDraft, Semester } from './ScheduleTypes';

/** 通过课程 id 查找的返回类型 */
interface CourseUuidInfo {
  uuid: string;
  semesterUuid: string;
}

/** 简易 v4 UUID 生成(无原生依赖) */
function generateUuid(): string {
  const hex = '0123456789abcdef';
  let uuid = '';
  for (let i = 0; i < 36; i++) {
    if (i === 8 || i === 13 || i === 18 || i === 23) {
      uuid += '-';
    } else if (i === 14) {
      uuid += '4';
    } else if (i === 19) {
      uuid += hex.charAt((Math.random() * 4) | 8);
    } else {
      uuid += hex.charAt((Math.random() * 16) | 0);
    }
  }
  return uuid;
}

/** 通过课程 id 查找(内部辅助) */
async function findCourseById(courseId: number): Promise<CourseUuidInfo | null> {
  const all = await ScheduleDao.listAllCourses();
  const course = all.find((c) => c.id === courseId) ?? null;
  if (course === null) return null;
  const sems = await ScheduleDao.listSemesters();
  const semRow = sems.find((s) => s.id === course.semesterId);
  const info: CourseUuidInfo = { uuid: course.uuid, semesterUuid: semRow?.uuid ?? '' };
  return info;
}

export class ScheduleRepository {
  /** 加载某学期全部课程及其时间段 */
  static async loadCourseEntries(semesterId: number): Promise<CourseEntry[]> {
    const courses = await ScheduleDao.listCoursesOfSemester(semesterId);
    const entries: CourseEntry[] = [];
    for (const course of courses) {
      const slots = await ScheduleDao.listSchedulesOfCourse(course.id);
      entries.push({ course: course, slots: slots });
    }
    return entries;
  }

  // ---------- 学期 ----------

  /** 新建学期并设为当前学期(自动取消旧当前学期) */
  static async createSemester(name: string, startMonday: number, totalWeeks: number = 20): Promise<number> {
    const monday = mondayOfMs(startMonday);
    const now = Date.now();
    await AppDb.execSql(
      'UPDATE semesters SET is_current = 0, updated_at = ? WHERE is_current = 1',
      [now]
    );
    const insertData: SemInsert = {
      uuid: generateUuid(),
      name: name,
      startDateMs: monday,
      totalWeeks: totalWeeks,
      isCurrent: true,
      updatedAtMs: now
    };
    return ScheduleDao.insertSemester(insertData);
  }

  static async updateSemester(semester: Semester): Promise<void> {
    const now = Date.now();
    await ScheduleDao.updateSemesterByUuid(semester.uuid, semester.name,
      semester.startDateMs, semester.totalWeeks, semester.isCurrent, now);
  }

  static async setCurrentSemester(semesterId: number): Promise<void> {
    const now = Date.now();
    await AppDb.execSql(
      `UPDATE semesters
       SET is_current = CASE WHEN id = ? THEN 1 ELSE 0 END,
           updated_at = CASE WHEN is_current != CASE WHEN id = ? THEN 1 ELSE 0 END THEN ? ELSE updated_at END
       WHERE EXISTS (SELECT 1 FROM semesters WHERE id = ?)`,
      [semesterId, semesterId, now, semesterId]
    );
  }

  static async deleteSemester(uuid: string): Promise<void> {
    const sem = await ScheduleDao.findSemesterByUuid(uuid);
    if (sem === null) return;
    await ScheduleDao.deleteSemesterCascade(sem);
  }

  // ---------- 课程 ----------

  static async createCourse(semesterId: number, name: string, teacher: string,
    color: number, note: string, slots: SlotDraft[]): Promise<number> {
    const now = Date.now();
    const actualColor = color < 0 ? forCourseName(name) : color;
    const courseId = await ScheduleDao.insertCourse({
      uuid: generateUuid(),
      semesterId: semesterId,
      name: name,
      teacher: teacher,
      color: actualColor,
      note: note,
      updatedAtMs: now
    });
    for (const slot of slots) {
      await ScheduleDao.insertSchedule({
        uuid: generateUuid(),
        courseId: courseId,
        dayOfWeek: slot.dayOfWeek,
        startSection: slot.startSection,
        endSection: slot.endSection,
        weeksType: slot.weeksType,
        customWeeks: slot.customWeeks,
        location: slot.location,
        updatedAtMs: now
      });
    }
    return courseId;
  }

  static async updateCourse(courseId: number, name: string, teacher: string,
    color: number, note: string, slots: SlotDraft[]): Promise<void> {
    const now = Date.now();
    const courseInfo = await findCourseById(courseId);
    if (courseInfo === null) return;
    await ScheduleDao.updateCourseByUuid(courseInfo.uuid, name, teacher, color, note, now);
    // 时间段整体替换(旧槽位生成墓碑)
    const oldSlots = await ScheduleDao.listSchedulesOfCourse(courseId);
    for (const slot of oldSlots) {
      await ScheduleDao.addPendingDeletion('schedule', slot.uuid, courseInfo.uuid);
      await ScheduleDao.deleteScheduleById(slot.id);
    }
    for (const slot of slots) {
      await ScheduleDao.insertSchedule({
        uuid: generateUuid(),
        courseId: courseId,
        dayOfWeek: slot.dayOfWeek,
        startSection: slot.startSection,
        endSection: slot.endSection,
        weeksType: slot.weeksType,
        customWeeks: slot.customWeeks,
        location: slot.location,
        updatedAtMs: now
      });
    }
  }

  static async deleteCourse(courseId: number): Promise<void> {
    const courseInfo = await findCourseById(courseId);
    if (courseInfo === null) return;
    const slots = await ScheduleDao.listSchedulesOfCourse(courseId);
    for (const slot of slots) {
      await ScheduleDao.addPendingDeletion('schedule', slot.uuid, courseInfo.uuid);
    }
    await ScheduleDao.addPendingDeletion('course', courseInfo.uuid, '');
    for (const slot of slots) {
      await ScheduleDao.deleteScheduleById(slot.id);
    }
    await ScheduleDao.deleteCourseById(courseId);
  }
}
