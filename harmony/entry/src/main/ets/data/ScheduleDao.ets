/**
 * 课表数据访问层：semesters / courses / schedules / settings / pending_deletions
 * 的增删改查。移植自 Flutter 版 Drift 查询（schema 等价）。
 *
 * 关键坑位（沿用 Flutter 版结论）：
 * - 外键级联不可靠：删除一律显式级联（deleteSemesterCascade / deleteCourseCascade）；
 * - 「当前学期」是选择状态不是数量限制：读取必须 ORDER BY updated_at DESC, id DESC
 *   LIMIT 1 容错（防两条 is_current=1 时页面崩溃）；归一化见 normalizeCurrentSemesters。
 */
import { relationalStore } from '@kit.ArkData';
import { AppDb } from './AppDb';
import { weeksListToJson } from '../model/SyncCodecs';
import { SemRow, CourseRow, SchedRow, PendingDeletionRow } from '../model/SyncCodecs';

export interface SemInsert {
  uuid: string;
  name: string;
  startDateMs: number;
  totalWeeks: number;
  isCurrent: boolean;
  updatedAtMs: number;
}

export interface CourseInsert {
  uuid: string;
  semesterId: number;
  name: string;
  teacher: string;
  color: number;
  note: string;
  updatedAtMs: number;
}

export interface SchedInsert {
  uuid: string;
  courseId: number;
  dayOfWeek: number;
  startSection: number;
  endSection: number;
  weeksType: number;
  customWeeks: number[];
  location: string;
  updatedAtMs: number;
}

export class ScheduleDao {
  // ---------- 学期 ----------

  static async listSemesters(): Promise<SemRow[]> {
    return ScheduleDao.querySemesters('SELECT * FROM semesters ORDER BY id', []);
  }

  /** 当前学期：至多一条 is_current=1；多条时按最后更新者胜（容错读取） */
  static async findCurrentSemester(): Promise<SemRow | null> {
    const rows = await ScheduleDao.querySemesters(
      'SELECT * FROM semesters WHERE is_current = 1 ORDER BY updated_at DESC, id DESC LIMIT 1', []);
    return rows.length > 0 ? rows[0] : null;
  }

  static async findSemesterByUuid(uuid: string): Promise<SemRow | null> {
    const rows = await ScheduleDao.querySemesters(
      'SELECT * FROM semesters WHERE uuid = ? LIMIT 1', [uuid]);
    return rows.length > 0 ? rows[0] : null;
  }

  static async insertSemester(v: SemInsert): Promise<number> {
    const bucket: relationalStore.ValuesBucket = {
      'uuid': v.uuid,
      'name': v.name,
      'start_date': v.startDateMs,
      'total_weeks': v.totalWeeks,
      'is_current': v.isCurrent ? 1 : 0,
      'updated_at': v.updatedAtMs
    };
    return AppDb.get().insert('semesters', bucket);
  }

  static async updateSemesterByUuid(uuid: string, name: string, startDateMs: number,
    totalWeeks: number, isCurrent: boolean, updatedAtMs: number): Promise<void> {
    await AppDb.get().executeSql(
      'UPDATE semesters SET name = ?, start_date = ?, total_weeks = ?, is_current = ?, updated_at = ? WHERE uuid = ?',
      [name, startDateMs, totalWeeks, isCurrent ? 1 : 0, updatedAtMs, uuid]);
  }

  static async deleteSemesterById(id: number): Promise<void> {
    await AppDb.get().executeSql('DELETE FROM semesters WHERE id = ?', [id]);
  }

  /**
   * 保证本地至多一个当前学期。最后更新者胜出；其余记录刷新 updated_at，
   * 让修复能通过 LWW 同步到其他设备（移植自 Flutter 版同步仓库）。
   */
  static async normalizeCurrentSemesters(): Promise<number> {
    const rows = await ScheduleDao.querySemesters(
      'SELECT * FROM semesters WHERE is_current = 1 ORDER BY updated_at DESC, id DESC', []);
    if (rows.length <= 1) {
      return 0;
    }
    let repairMillis = Date.now();
    for (const row of rows) {
      if (row.updatedAtMs >= repairMillis) {
        repairMillis = row.updatedAtMs + 1;
      }
    }
    for (let index = 1; index < rows.length; index++) {
      await AppDb.get().executeSql(
        'UPDATE semesters SET is_current = 0, updated_at = ? WHERE id = ?',
        [repairMillis + index - 1, rows[index].id]);
    }
    return rows.length - 1;
  }

  static async listAllCourses(): Promise<CourseRow[]> {
    return ScheduleDao.queryCourses('SELECT * FROM courses ORDER BY id', []);
  }

  static async listCoursesOfSemester(semesterId: number): Promise<CourseRow[]> {
    return ScheduleDao.queryCourses(
      'SELECT * FROM courses WHERE semester_id = ? ORDER BY id', [semesterId]);
  }

  static async findCourseByUuid(uuid: string): Promise<CourseRow | null> {
    const rows = await ScheduleDao.queryCourses(
      'SELECT * FROM courses WHERE uuid = ? LIMIT 1', [uuid]);
    return rows.length > 0 ? rows[0] : null;
  }

  static async insertCourse(v: CourseInsert): Promise<number> {
    const bucket: relationalStore.ValuesBucket = {
      'uuid': v.uuid,
      'semester_id': v.semesterId,
      'name': v.name,
      'teacher': v.teacher,
      'color': v.color,
      'note': v.note,
      'updated_at': v.updatedAtMs
    };
    return AppDb.get().insert('courses', bucket);
  }

  static async updateCourseByUuid(uuid: string, name: string, teacher: string,
    color: number, note: string, updatedAtMs: number): Promise<void> {
    await AppDb.get().executeSql(
      'UPDATE courses SET name = ?, teacher = ?, color = ?, note = ?, updated_at = ? WHERE uuid = ?',
      [name, teacher, color, note, updatedAtMs, uuid]);
  }

  static async deleteCourseById(id: number): Promise<void> {
    await AppDb.get().executeSql('DELETE FROM courses WHERE id = ?', [id]);
  }

  // ---------- 排课时间段 ----------

  static async listAllSchedules(): Promise<SchedRow[]> {
    return ScheduleDao.querySchedules('SELECT * FROM schedules ORDER BY id', []);
  }

  static async listSchedulesOfSemester(semesterId: number): Promise<SchedRow[]> {
    return ScheduleDao.querySchedules(
      `SELECT s.* FROM schedules s
       INNER JOIN courses c ON s.course_id = c.id
       WHERE c.semester_id = ? ORDER BY s.id`, [semesterId]);
  }

  static async listSchedulesOfCourse(courseId: number): Promise<SchedRow[]> {
    return ScheduleDao.querySchedules(
      'SELECT * FROM schedules WHERE course_id = ? ORDER BY id', [courseId]);
  }

  static async findScheduleByUuid(uuid: string): Promise<SchedRow | null> {
    const rows = await ScheduleDao.querySchedules(
      'SELECT * FROM schedules WHERE uuid = ? LIMIT 1', [uuid]);
    return rows.length > 0 ? rows[0] : null;
  }

  static async insertSchedule(v: SchedInsert): Promise<number> {
    const bucket: relationalStore.ValuesBucket = {
      'uuid': v.uuid,
      'course_id': v.courseId,
      'day_of_week': v.dayOfWeek,
      'start_section': v.startSection,
      'end_section': v.endSection,
      'weeks_type': v.weeksType,
      'custom_weeks': weeksListToJson(v.customWeeks),
      'location': v.location,
      'updated_at': v.updatedAtMs
    };
    return AppDb.get().insert('schedules', bucket);
  }

  static async updateScheduleByUuid(uuid: string, dayOfWeek: number, startSection: number,
    endSection: number, weeksType: number, customWeeks: number[], location: string,
    updatedAtMs: number): Promise<void> {
    await AppDb.get().executeSql(
      `UPDATE schedules SET day_of_week = ?, start_section = ?, end_section = ?,
       weeks_type = ?, custom_weeks = ?, location = ?, updated_at = ? WHERE uuid = ?`,
      [dayOfWeek, startSection, endSection, weeksType, weeksListToJson(customWeeks),
        location, updatedAtMs, uuid]);
  }

  static async deleteScheduleById(id: number): Promise<void> {
    await AppDb.get().executeSql('DELETE FROM schedules WHERE id = ?', [id]);
  }

  // ---------- 待删除队列（墓碑） ----------

  static async listPendingDeletions(): Promise<PendingDeletionRow[]> {
    const rs = await AppDb.get().querySql(
      'SELECT * FROM pending_deletions ORDER BY id', []);
    const rows: PendingDeletionRow[] = [];
    try {
      while (rs.goToNextRow()) {
        rows.push({
          id: rs.getLong(rs.getColumnIndex('id')),
          entity: rs.getString(rs.getColumnIndex('entity')),
          uuid: rs.getString(rs.getColumnIndex('uuid')),
          parentUuid: rs.getString(rs.getColumnIndex('parent_uuid')),
          deletedAtMs: rs.getLong(rs.getColumnIndex('deleted_at'))
        });
      }
    } finally {
      rs.close();
    }
    return rows;
  }

  static async addPendingDeletion(entity: string, uuid: string, parentUuid: string): Promise<void> {
    const bucket: relationalStore.ValuesBucket = {
      'entity': entity,
      'uuid': uuid,
      'parent_uuid': parentUuid,
      'deleted_at': Date.now()
    };
    await AppDb.get().insert('pending_deletions', bucket);
  }

  static async deletePendingDeletions(ids: number[]): Promise<void> {
    if (ids.length === 0) {
      return;
    }
    const placeholders = ids.map(() => '?').join(', ');
    await AppDb.get().executeSql(
      `DELETE FROM pending_deletions WHERE id IN (${placeholders})`, ids);
  }

  // ---------- 级联删除（用户主动删除；显式级联 + 生成墓碑） ----------

  /** 删除学期及其全部课程/排课，并为每条记录生成待推送墓碑 */
  static async deleteSemesterCascade(sem: SemRow): Promise<void> {
    const courses = await ScheduleDao.listCoursesOfSemester(sem.id);
    for (const course of courses) {
      await ScheduleDao.deleteCourseCascade(course, sem.uuid);
    }
    await ScheduleDao.addPendingDeletion('semester', sem.uuid, '');
    await ScheduleDao.deleteSemesterById(sem.id);
  }

  /** 删除课程及其全部排课，并为每条记录生成待推送墓碑 */
  static async deleteCourseCascade(course: CourseRow, semesterUuid: string): Promise<void> {
    const scheds = await ScheduleDao.listSchedulesOfCourse(course.id);
    for (const sched of scheds) {
      await ScheduleDao.addPendingDeletion('schedule', sched.uuid, course.uuid);
      await ScheduleDao.deleteScheduleById(sched.id);
    }
    await ScheduleDao.addPendingDeletion('course', course.uuid, semesterUuid);
    await ScheduleDao.deleteCourseById(course.id);
  }

  /** pull 应用墓碑时的本地删除：只删行，不再生成新墓碑 */
  static async deleteSemesterRowsOnly(id: number): Promise<void> {
    await AppDb.get().executeSql(
      'DELETE FROM schedules WHERE course_id IN (SELECT id FROM courses WHERE semester_id = ?)',
      [id]);
    await AppDb.get().executeSql('DELETE FROM courses WHERE semester_id = ?', [id]);
    await AppDb.get().executeSql('DELETE FROM semesters WHERE id = ?', [id]);
  }

  static async deleteCourseRowsOnly(id: number): Promise<void> {
    await AppDb.get().executeSql('DELETE FROM schedules WHERE course_id = ?', [id]);
    await AppDb.get().executeSql('DELETE FROM courses WHERE id = ?', [id]);
  }

  // ---------- settings ----------

  static async getSetting(key: string): Promise<string | null> {
    const rs = await AppDb.get().querySql(
      'SELECT value FROM settings_entries WHERE key = ? LIMIT 1', [key]);
    try {
      if (rs.goToNextRow()) {
        return rs.getString(rs.getColumnIndex('value'));
      }
      return null;
    } finally {
      rs.close();
    }
  }

  static async setSetting(key: string, value: string): Promise<void> {
    await AppDb.get().executeSql(
      'INSERT INTO settings_entries (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value',
      [key, value]);
  }

  // ---------- ResultSet 行映射 ----------

  private static async querySemesters(sql: string, args: relationalStore.ValueType[]): Promise<SemRow[]> {
    const rs = await AppDb.get().querySql(sql, args);
    const rows: SemRow[] = [];
    try {
      while (rs.goToNextRow()) {
        rows.push({
          id: rs.getLong(rs.getColumnIndex('id')),
          uuid: rs.getString(rs.getColumnIndex('uuid')),
          name: rs.getString(rs.getColumnIndex('name')),
          startDateMs: rs.getLong(rs.getColumnIndex('start_date')),
          totalWeeks: rs.getLong(rs.getColumnIndex('total_weeks')),
          isCurrent: rs.getLong(rs.getColumnIndex('is_current')) === 1,
          updatedAtMs: rs.getLong(rs.getColumnIndex('updated_at'))
        });
      }
    } finally {
      rs.close();
    }
    return rows;
  }

  private static async queryCourses(sql: string, args: relationalStore.ValueType[]): Promise<CourseRow[]> {
    const rs = await AppDb.get().querySql(sql, args);
    const rows: CourseRow[] = [];
    try {
      while (rs.goToNextRow()) {
        rows.push({
          id: rs.getLong(rs.getColumnIndex('id')),
          uuid: rs.getString(rs.getColumnIndex('uuid')),
          semesterId: rs.getLong(rs.getColumnIndex('semester_id')),
          name: rs.getString(rs.getColumnIndex('name')),
          teacher: rs.getString(rs.getColumnIndex('teacher')),
          color: rs.getLong(rs.getColumnIndex('color')),
          note: rs.getString(rs.getColumnIndex('note')),
          updatedAtMs: rs.getLong(rs.getColumnIndex('updated_at'))
        });
      }
    } finally {
      rs.close();
    }
    return rows;
  }

  private static async querySchedules(sql: string, args: relationalStore.ValueType[]): Promise<SchedRow[]> {
    const rs = await AppDb.get().querySql(sql, args);
    const rows: SchedRow[] = [];
    try {
      while (rs.goToNextRow()) {
        rows.push({
          id: rs.getLong(rs.getColumnIndex('id')),
          uuid: rs.getString(rs.getColumnIndex('uuid')),
          courseId: rs.getLong(rs.getColumnIndex('course_id')),
          dayOfWeek: rs.getLong(rs.getColumnIndex('day_of_week')),
          startSection: rs.getLong(rs.getColumnIndex('start_section')),
          endSection: rs.getLong(rs.getColumnIndex('end_section')),
          weeksType: rs.getLong(rs.getColumnIndex('weeks_type')),
          customWeeksJson: rs.getString(rs.getColumnIndex('custom_weeks')),
          location: rs.getString(rs.getColumnIndex('location')),
          updatedAtMs: rs.getLong(rs.getColumnIndex('updated_at'))
        });
      }
    } finally {
      rs.close();
    }
    return rows;
  }
}
