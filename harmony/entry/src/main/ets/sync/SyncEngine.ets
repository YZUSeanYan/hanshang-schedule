/**
 * 云端同步引擎：客户端权威 + 按记录 updated_at 的 last-write-wins。
 * 移植自 Flutter 版 features/sync/data/sync_repository.dart。
 *
 * - push：本地全部记录 + 待删除墓碑一次性推上去（学生课表数据量极小，
 *   全量推送换零状态追踪成本；服务端只接受更新的记录；单类 500 条上限透明分批）；
 * - pull：按服务端 cursor 增量拉取，逐条 LWW 比较 updated_at，新者覆盖本地；
 *   墓碑执行本地删除；父实体尚未同步到时跳过（下轮同步自愈）；
 * - 同步前后都做「当前学期归一化」，修复结果立即回传云端。
 */
import { ApiClient } from '../network/ApiClient';
import { ScheduleDao, SemInsert, CourseInsert, SchedInsert } from '../data/ScheduleDao';
import { AppDb } from '../data/AppDb';
import { TokenStore } from '../storage/TokenStore';
import {
  semesterToPush, courseToPush, scheduleToPush, tombstoneFor,
  semesterFromPull, courseFromPull, scheduleFromPull,
} from '../model/SyncCodecs';

const CURSOR_KEY = 'sync_cursor';
const LAST_SYNC_KEY = 'sync_last_at';
const BATCH_SIZE = 500;

export class SyncEngine {
  private static inFlight: Promise<string> | null = null;
  private static accountTransitioning: boolean = false;

  /** 执行一次完整同步（push → pull）。同一进程内只允许一个账号同步任务运行。 */
  static sync(): Promise<string> {
    if (SyncEngine.accountTransitioning) {
      return Promise.reject(new Error('账号正在切换，已阻止同步'));
    }
    if (SyncEngine.inFlight !== null) {
      return SyncEngine.inFlight;
    }
    const task = SyncEngine.runSync();
    SyncEngine.inFlight = task;
    task.then(() => { SyncEngine.inFlight = null; }, () => { SyncEngine.inFlight = null; });
    return task;
  }

  /** 账号退出/切库前等待已发出的同步结束，避免请求跨越凭据切换。 */
  static async waitForIdle(): Promise<void> {
    const task = SyncEngine.inFlight;
    if (task !== null) {
      try {
        await task;
      } catch (e) {
      }
    }
  }

  static async beginAccountTransition(): Promise<void> {
    SyncEngine.accountTransitioning = true;
    await SyncEngine.waitForIdle();
  }

  static endAccountTransition(): void {
    SyncEngine.accountTransitioning = false;
  }

  private static async runSync(): Promise<string> {
    const activeAccountId = AppDb.activeUserId();
    const cachedAccountId = TokenStore.readCachedUserId();
    if (activeAccountId === null || activeAccountId !== cachedAccountId) {
      throw new Error('账号与本地课表未绑定，已阻止同步');
    }
    const syncAccountId = activeAccountId;
    // 先修复旧版本可能遗留的重复「当前学期」，避免把脏状态再次上传
    await ScheduleDao.normalizeCurrentSemesters();
    const pushSummary = await SyncEngine.push();
    SyncEngine.assertAccount(syncAccountId);
    const pullSummary = await SyncEngine.pull();
    SyncEngine.assertAccount(syncAccountId);
    await ScheduleDao.setSetting(LAST_SYNC_KEY, new Date().toISOString());
    return `上传 ${pushSummary}，下载 ${pullSummary}`;
  }

  private static assertAccount(accountId: number): void {
    if (SyncEngine.accountTransitioning || AppDb.activeUserId() !== accountId
      || TokenStore.readCachedUserId() !== accountId) {
      throw new Error('账号已切换，同步结果已丢弃');
    }
  }

  /** 上次同步时间（本地显示用），null → '从未同步' */
  static async lastSyncAtText(): Promise<string> {
    const raw = await ScheduleDao.getSetting(LAST_SYNC_KEY);
    if (raw === null) {
      return '从未同步';
    }
    const d = new Date(raw);
    const mm = d.getMonth() + 1 < 10 ? `0${d.getMonth() + 1}` : `${d.getMonth() + 1}`;
    const dd = d.getDate() < 10 ? `0${d.getDate()}` : `${d.getDate()}`;
    const hh = d.getHours() < 10 ? `0${d.getHours()}` : `${d.getHours()}`;
    const mi = d.getMinutes() < 10 ? `0${d.getMinutes()}` : `${d.getMinutes()}`;
    return `${d.getFullYear()}-${mm}-${dd} ${hh}:${mi}`;
  }

  // ---------- push ----------

  private static async push(): Promise<string> {
    const semesters = await ScheduleDao.listSemesters();
    const courses = await ScheduleDao.listAllCourses();
    const schedules = await ScheduleDao.listAllSchedules();
    const deletions = await ScheduleDao.listPendingDeletions();

    // id → uuid，用于给载荷/墓碑补外键字段
    const semesterUuidById = new Map<number, string>();
    for (const s of semesters) {
      semesterUuidById.set(s.id, s.uuid);
    }
    const courseUuidById = new Map<number, string>();
    for (const c of courses) {
      courseUuidById.set(c.id, c.uuid);
    }

    const semesterItems: Record<string, Object>[] = [];
    for (const s of semesters) {
      semesterItems.push(semesterToPush(s));
    }
    const courseItems: Record<string, Object>[] = [];
    for (const c of courses) {
      courseItems.push(courseToPush(c, semesterUuidById.get(c.semesterId) ?? ''));
    }
    const scheduleItems: Record<string, Object>[] = [];
    for (const s of schedules) {
      scheduleItems.push(scheduleToPush(s, courseUuidById.get(s.courseId) ?? ''));
    }

    // 墓碑：按实体类型塞进对应列表（deleted=true，字段用最小合法值）
    for (const d of deletions) {
      const tombstone = tombstoneFor(d);
      if (tombstone === null) {
        continue;
      }
      if (d.entity === 'semester') {
        semesterItems.push(tombstone);
      } else if (d.entity === 'course') {
        courseItems.push(tombstone);
      } else if (d.entity === 'schedule') {
        scheduleItems.push(tombstone);
      }
    }

    const maxItems = Math.max(1, Math.max(semesterItems.length,
      Math.max(courseItems.length, scheduleItems.length)));
    let total = 0;
    for (let start = 0; start < maxItems; start += BATCH_SIZE) {
      const body: Record<string, Object> = {
        'semesters': SyncEngine.batchOf(semesterItems, start),
        'courses': SyncEngine.batchOf(courseItems, start),
        'schedules': SyncEngine.batchOf(scheduleItems, start)
      };
      const data = await ApiClient.post('/api/sync/push', body) as Record<string, Object>;
      const applied = data['applied'] as Record<string, Object>;
      total += SyncEngine.countOf(applied, 'semesters')
        + SyncEngine.countOf(applied, 'courses')
        + SyncEngine.countOf(applied, 'schedules');
    }

    // 只删除本次快照中的墓碑；推送期间新增的删除必须留待下轮同步。
    await ScheduleDao.deletePendingDeletions(deletions.map((row) => row.id));
    return `${total} 条`;
  }

  private static batchOf(items: Record<string, Object>[], start: number): Record<string, Object>[] {
    if (start >= items.length) {
      return [];
    }
    const end = Math.min(start + BATCH_SIZE, items.length);
    return items.slice(start, end);
  }

  private static countOf(map: Record<string, Object>, key: string): number {
    const v = map[key];
    return typeof v === 'number' ? v : 0;
  }

  // ---------- pull ----------

  private static async pull(): Promise<string> {
    const cursorRaw = await ScheduleDao.getSetting(CURSOR_KEY);
    let cursor = 0;
    if (cursorRaw !== null) {
      const n = Number(cursorRaw);
      if (Number.isFinite(n) && n >= 0) {
        cursor = Math.floor(n);
      }
    }
    // 说明：cursor 是服务端 time_ns（约 1.8e18），超过 JS Number 2^53 精度。
    // 纳秒级误差只可能造成个别记录重复下发（LWW 幂等）或 ns 级窗口漏单
    // （实际不可能），与网页版 JS 行为一致，可安全接受。
    const data = await ApiClient.get(`/api/sync/pull?since=${cursor}`) as Record<string, Object>;

    let changes = await SyncEngine.applySemesters(SyncEngine.asList(data['semesters']));
    changes += await SyncEngine.applyCourses(SyncEngine.asList(data['courses']));
    changes += await SyncEngine.applySchedules(SyncEngine.asList(data['schedules']));
    const repaired = await ScheduleDao.normalizeCurrentSemesters();

    const cursorVal = data['cursor'];
    const nextCursor = typeof cursorVal === 'number' ? String(cursorVal) : `${cursor}`;
    await ScheduleDao.setSetting(CURSOR_KEY, nextCursor);
    // 拉取本身带来重复状态时，把本地修复立即回传云端
    if (repaired > 0) {
      await SyncEngine.push();
    }
    return `${changes + repaired} 条`;
  }

  private static asList(raw: Object): Array<Record<string, Object>> {
    if (Array.isArray(raw)) {
      return raw as Array<Record<string, Object>>;
    }
    return [];
  }

  private static async applySemesters(items: Array<Record<string, Object>>): Promise<number> {
    let changes = 0;
    for (const item of items) {
      const remote = semesterFromPull(item);
      if (remote.uuid.length === 0) {
        continue;
      }
      const local = await ScheduleDao.findSemesterByUuid(remote.uuid);
      if (remote.deletedMark) {
        if (local !== null) {
          await ScheduleDao.deleteSemesterRowsOnly(local.id);
          changes++;
        }
        continue;
      }
      if (local === null) {
        const insert: SemInsert = {
          uuid: remote.uuid,
          name: remote.name,
          startDateMs: remote.startDateMs,
          totalWeeks: remote.totalWeeks,
          isCurrent: remote.isCurrent,
          updatedAtMs: remote.updatedAtMs
        };
        await ScheduleDao.insertSemester(insert);
        changes++;
      } else if (remote.updatedAtMs > local.updatedAtMs) {
        await ScheduleDao.updateSemesterByUuid(remote.uuid, remote.name,
          remote.startDateMs, remote.totalWeeks, remote.isCurrent, remote.updatedAtMs);
        changes++;
      }
    }
    return changes;
  }

  private static async applyCourses(items: Array<Record<string, Object>>): Promise<number> {
    let changes = 0;
    for (const item of items) {
      const remote = courseFromPull(item);
      if (remote.uuid.length === 0) {
        continue;
      }
      const local = await ScheduleDao.findCourseByUuid(remote.uuid);
      if (remote.deletedMark) {
        if (local !== null) {
          await ScheduleDao.deleteCourseRowsOnly(local.id);
          changes++;
        }
        continue;
      }
      // 所属学期本地不存在则跳过（下轮同步自愈）
      const semester = await ScheduleDao.findSemesterByUuid(remote.semesterUuid);
      if (semester === null) {
        continue;
      }
      if (local === null) {
        const insert: CourseInsert = {
          uuid: remote.uuid,
          semesterId: semester.id,
          name: remote.name,
          teacher: remote.teacher,
          color: remote.color,
          note: remote.note,
          updatedAtMs: remote.updatedAtMs
        };
        await ScheduleDao.insertCourse(insert);
        changes++;
      } else if (remote.updatedAtMs > local.updatedAtMs) {
        await ScheduleDao.updateCourseByUuid(remote.uuid, remote.name,
          remote.teacher, remote.color, remote.note, remote.updatedAtMs);
        changes++;
      }
    }
    return changes;
  }

  private static async applySchedules(items: Array<Record<string, Object>>): Promise<number> {
    let changes = 0;
    for (const item of items) {
      const remote = scheduleFromPull(item);
      if (remote.uuid.length === 0) {
        continue;
      }
      const local = await ScheduleDao.findScheduleByUuid(remote.uuid);
      if (remote.deletedMark) {
        if (local !== null) {
          await ScheduleDao.deleteScheduleById(local.id);
          changes++;
        }
        continue;
      }
      const course = await ScheduleDao.findCourseByUuid(remote.courseUuid);
      if (course === null) {
        continue;
      }
      if (local === null) {
        const insert: SchedInsert = {
          uuid: remote.uuid,
          courseId: course.id,
          dayOfWeek: remote.dayOfWeek,
          startSection: remote.startSection,
          endSection: remote.endSection,
          weeksType: remote.weeksType,
          customWeeks: SyncEngine.weeksOf(remote.customWeeksJson),
          location: remote.location,
          updatedAtMs: remote.updatedAtMs
        };
        await ScheduleDao.insertSchedule(insert);
        changes++;
      } else if (remote.updatedAtMs > local.updatedAtMs) {
        await ScheduleDao.updateScheduleByUuid(remote.uuid, remote.dayOfWeek,
          remote.startSection, remote.endSection, remote.weeksType,
          SyncEngine.weeksOf(remote.customWeeksJson), remote.location, remote.updatedAtMs);
        changes++;
      }
    }
    return changes;
  }

  private static weeksOf(customWeeksJson: string): number[] {
    try {
      const parsed = JSON.parse(customWeeksJson) as number[];
      if (Array.isArray(parsed)) {
        return parsed;
      }
      return [];
    } catch (e) {
      return [];
    }
  }
}
