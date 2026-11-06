/** 同步编解码单测。运行：node tests/sync_codecs.test.ts */
import {
  parseWeeksList, weeksListToJson, jsonToWeeksList,
  semesterToPush, courseToPush, scheduleToPush, tombstoneFor,
  semesterFromPull, courseFromPull, scheduleFromPull,
  readString, readNumber, readBool,
} from '../entry/src/main/ets/model/SyncCodecs.ts';
import type {
  SemRow, CourseRow, SchedRow, PendingDeletionRow,
} from '../entry/src/main/ets/model/SyncCodecs.ts';
import { msOfYmd } from '../entry/src/main/ets/utils/WeekCalculator.ts';
import assert from 'node:assert/strict';

let failed = 0;
function t(name: string, fn: () => void): void {
  try {
    fn();
    console.log(`  PASS ${name}`);
  } catch (e) {
    failed++;
    console.error(`  FAIL ${name}`);
    console.error(`       ${e instanceof Error ? e.message : String(e)}`);
  }
}

console.log('SyncCodecs:');

t('parseWeeksList：范围展开 "1-18"', () => {
  const list = parseWeeksList('1-18');
  assert.equal(list.length, 18);
  assert.equal(list[0], 1);
  assert.equal(list[17], 18);
});

t('parseWeeksList：混合 "1-8,10,12"', () => {
  assert.deepEqual(parseWeeksList('1-8,10,12'), [1, 2, 3, 4, 5, 6, 7, 8, 10, 12]);
});

t('parseWeeksList：带空格 + 反向区间 + 去重排序', () => {
  assert.deepEqual(parseWeeksList(' 3 - 5 '), [3, 4, 5]);
  assert.deepEqual(parseWeeksList('8-3'), [3, 4, 5, 6, 7, 8]);
  assert.deepEqual(parseWeeksList('2,1,2'), [1, 2]);
});

t('parseWeeksList：非法输入', () => {
  assert.deepEqual(parseWeeksList(''), []);
  assert.deepEqual(parseWeeksList('abc'), []);
});

t('weeksListToJson / jsonToWeeksList 往返', () => {
  const json = weeksListToJson([1, 2, 3]);
  assert.equal(json, '[1,2,3]');
  assert.deepEqual(jsonToWeeksList(json), [1, 2, 3]);
  assert.deepEqual(jsonToWeeksList('not json'), []);
  assert.deepEqual(jsonToWeeksList('[1,"a",3]'), [1, 3]);
});

const sem: SemRow = {
  id: 1, uuid: 'sem-u1', name: '2025-2026-1',
  startDateMs: msOfYmd(2025, 9, 1), totalWeeks: 18, isCurrent: true, updatedAtMs: 1700000000000,
};
const course: CourseRow = {
  id: 2, uuid: 'crs-u2', semesterId: 1, name: '大学物理Ⅳ', teacher: '教师A',
  color: -16776961, note: '', updatedAtMs: 1700000000001,
};
const sched: SchedRow = {
  id: 3, uuid: 'sch-u3', courseId: 2, dayOfWeek: 2, startSection: 1, endSection: 2,
  weeksType: 0, customWeeksJson: '[1,2,3]', location: '扬子津东校区文津楼101', updatedAtMs: 1700000000002,
};

t('semesterToPush：字段与日期格式', () => {
  const item = semesterToPush(sem);
  assert.equal(item['uuid'], 'sem-u1');
  assert.equal(item['start_date'], '2025-09-01');
  assert.equal(item['total_weeks'], 18);
  assert.equal(item['is_current'], true);
  assert.equal(item['updated_at'], 1700000000000);
  assert.equal(item['deleted'], false);
});

t('courseToPush：外键换成 uuid', () => {
  const item = courseToPush(course, 'sem-u1');
  assert.equal(item['semester_uuid'], 'sem-u1');
  assert.equal(item['name'], '大学物理Ⅳ');
  assert.equal(item['color'], -16776961);
});

t('scheduleToPush：custom_weeks 转 CSV', () => {
  const item = scheduleToPush(sched, 'crs-u2');
  assert.equal(item['course_uuid'], 'crs-u2');
  assert.equal(item['day_of_week'], 2);
  assert.equal(item['weeks_type'], 0);
  assert.equal(item['custom_weeks'], '1,2,3');
});

t('墓碑：semester 最小合法字段', () => {
  const d: PendingDeletionRow = { id: 0, entity: 'semester', uuid: 'sem-u1', parentUuid: '', deletedAtMs: 99 };
  const item = tombstoneFor(d);
  assert.notEqual(item, null);
  assert.equal(item!['deleted'], true);
  assert.equal(item!['start_date'], '1970-01-01');
  assert.equal(item!['total_weeks'], 20);
  assert.equal(item!['is_current'], false);
  assert.equal(item!['updated_at'], 99);
});

t('墓碑：course / schedule 携带 parentUuid', () => {
  const dc: PendingDeletionRow = { id: 0, entity: 'course', uuid: 'crs-u2', parentUuid: 'sem-u1', deletedAtMs: 99 };
  assert.equal(tombstoneFor(dc)!['semester_uuid'], 'sem-u1');
  const ds: PendingDeletionRow = { id: 0, entity: 'schedule', uuid: 'sch-u3', parentUuid: 'crs-u2', deletedAtMs: 99 };
  assert.equal(tombstoneFor(ds)!['course_uuid'], 'crs-u2');
  assert.equal(tombstoneFor({ ...ds, entity: 'unknown' }), null);
});

t('pull 解码：semester（含 deleted 标记）', () => {
  const item = semesterFromPull({
    'uuid': 'sem-x', 'name': '2026春', 'start_date': '2026-02-23',
    'total_weeks': 20, 'is_current': false, 'updated_at': 123, 'deleted': true,
  });
  assert.equal(item.deletedMark, true);
  assert.equal(item.startDateMs, msOfYmd(2026, 2, 23));
  assert.equal(item.name, '2026春');
});

t('pull 解码：course 缺省字段容错', () => {
  const item = courseFromPull({ 'uuid': 'c1', 'semester_uuid': 's1', 'name': '体育', 'updated_at': 5 });
  assert.equal(item.teacher, '');
  assert.equal(item.color, 0);
  assert.equal(item.deletedMark, false);
});

t('pull 解码：schedule 的 custom_weeks 范围展开成本地 JSON', () => {
  const item = scheduleFromPull({
    'uuid': 'sc1', 'course_uuid': 'c1', 'day_of_week': 4, 'start_section': 9,
    'end_section': 10, 'weeks_type': 3, 'custom_weeks': '1-18', 'location': '', 'updated_at': 7,
  });
  assert.deepEqual(jsonToWeeksList(item.customWeeksJson), parseWeeksList('1-18'));
  assert.equal(item.courseUuid, 'c1');
});

t('readString / readNumber / readBool 缺省行为', () => {
  const m: Record<string, Object> = { 'a': 'x', 'b': 3, 'c': true };
  assert.equal(readString(m, 'a'), 'x');
  assert.equal(readString(m, 'missing'), '');
  assert.equal(readNumber(m, 'b'), 3);
  assert.equal(readNumber(m, 'missing'), 0);
  assert.equal(readBool(m, 'c'), true);
  assert.equal(readBool(m, 'missing'), false);
});

if (failed > 0) {
  console.error(`sync_codecs: ${failed} 个用例失败`);
  process.exit(1);
}
console.log('sync_codecs: 全部通过');
