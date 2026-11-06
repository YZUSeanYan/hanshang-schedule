/**
 * 本地数据库：relationalStore（SQLite），表结构与 Flutter Drift v2 完全等价。
 * 移植自 Flutter 版 core/database/app_database.dart。
 *
 * 六张表：semesters / courses / schedules / settings_entries /
 *        sync_states / pending_deletions
 * 时间列一律存毫秒整数（Drift dateTime 也是 INTEGER 毫秒，两端对齐）。
 */
import { relationalStore } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { TokenStore } from '../storage/TokenStore';
import { accountDbName } from './AccountVault';

const DDL: string[] = [
  `CREATE TABLE IF NOT EXISTS semesters (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    uuid TEXT NOT NULL DEFAULT '',
    name TEXT NOT NULL,
    start_date INTEGER NOT NULL,
    total_weeks INTEGER NOT NULL DEFAULT 20,
    is_current INTEGER NOT NULL DEFAULT 0,
    updated_at INTEGER NOT NULL
  )`,
  `CREATE TABLE IF NOT EXISTS courses (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    uuid TEXT NOT NULL DEFAULT '',
    semester_id INTEGER NOT NULL,
    name TEXT NOT NULL,
    teacher TEXT NOT NULL DEFAULT '',
    color INTEGER NOT NULL,
    note TEXT NOT NULL DEFAULT '',
    updated_at INTEGER NOT NULL
  )`,
  `CREATE TABLE IF NOT EXISTS schedules (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    uuid TEXT NOT NULL DEFAULT '',
    course_id INTEGER NOT NULL,
    day_of_week INTEGER NOT NULL,
    start_section INTEGER NOT NULL,
    end_section INTEGER NOT NULL,
    weeks_type INTEGER NOT NULL,
    custom_weeks TEXT NOT NULL DEFAULT '[]',
    location TEXT NOT NULL DEFAULT '',
    updated_at INTEGER NOT NULL
  )`,
  `CREATE TABLE IF NOT EXISTS settings_entries (
    key TEXT PRIMARY KEY,
    value TEXT NOT NULL
  )`,
  `CREATE TABLE IF NOT EXISTS sync_states (
    entity TEXT PRIMARY KEY,
    last_synced_at INTEGER,
    dirty INTEGER NOT NULL DEFAULT 0
  )`,
  `CREATE TABLE IF NOT EXISTS pending_deletions (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    entity TEXT NOT NULL,
    uuid TEXT NOT NULL,
    parent_uuid TEXT NOT NULL DEFAULT '',
    deleted_at INTEGER NOT NULL
  )`,
  `CREATE INDEX IF NOT EXISTS idx_semesters_uuid ON semesters(uuid)`,
  `CREATE INDEX IF NOT EXISTS idx_courses_uuid ON courses(uuid)`,
  `CREATE INDEX IF NOT EXISTS idx_schedules_uuid ON schedules(uuid)`,
  `CREATE INDEX IF NOT EXISTS idx_courses_semester ON courses(semester_id)`,
  `CREATE INDEX IF NOT EXISTS idx_schedules_course ON schedules(course_id)`,
];

export class AppDb {
  private static rdb: relationalStore.RdbStore | null = null;
  private static context: common.Context | null = null;
  private static activeDbName: string = '';
  private static activeAccountId: number | null = null;
  private static activationQueue: Promise<void> = Promise.resolve();

  static async init(context: common.Context, cachedAccountId: number | null = null): Promise<void> {
    AppDb.context = context;
    if (cachedAccountId !== null) {
      // 仅升级时仍有可信缓存账号才能认领旧库；已登出的旧库保持隔离，不猜测所有者。
      await TokenStore.claimLegacyDbFor(cachedAccountId);
    }
    await AppDb.activate(cachedAccountId);
  }

  static async activateAccount(userId: number): Promise<void> {
    if (!Number.isInteger(userId) || userId <= 0) {
      throw new Error('无法为无效账号打开本地课表');
    }
    await AppDb.activate(userId);
  }

  static async activateGuest(): Promise<void> {
    await AppDb.activate(null);
  }

  static activeUserId(): number | null {
    return AppDb.activeAccountId;
  }

  private static async activate(accountId: number | null): Promise<void> {
    const task = AppDb.activationQueue.then(() => AppDb.doActivate(accountId));
    AppDb.activationQueue = task.catch(() => {});
    await task;
  }

  private static async doActivate(accountId: number | null): Promise<void> {
    const context = AppDb.context;
    if (context === null) {
      throw new Error('AppDb 缺少 Context');
    }
    const dbName = accountDbName(accountId, TokenStore.readLegacyDbOwnerId());
    if (AppDb.rdb !== null && AppDb.activeDbName === dbName) {
      AppDb.activeAccountId = accountId;
      return;
    }
    if (AppDb.rdb !== null) {
      AppDb.rdb.close();
      AppDb.rdb = null;
    }
    const config: relationalStore.StoreConfig = {
      name: dbName,
      securityLevel: relationalStore.SecurityLevel.S1
    };
    const rdb = await relationalStore.getRdbStore(context, config);
    for (const sql of DDL) {
      await rdb.executeSql(sql);
    }
    AppDb.rdb = rdb;
    AppDb.activeDbName = dbName;
    AppDb.activeAccountId = accountId;
  }

  static get(): relationalStore.RdbStore {
    if (AppDb.rdb === null) {
      throw new Error('AppDb 未初始化（应先经 Bootstrap.ensure）');
    }
    return AppDb.rdb;
  }

  /** 直接执行 SQL(学期切换等需要原子性的场景) */
  static async execSql(sql: string, args: relationalStore.ValueType[] = []): Promise<void> {
    await AppDb.get().executeSql(sql, args);
  }
}
