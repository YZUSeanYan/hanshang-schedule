/**
 * 周次计算单测。基准事实：2024-01-01 是周一。
 * 运行：node tests/week_calculator.test.ts（需 Node >= 23.6）
 */
import {
  mondayOfMs, weekNumberOf, occursInWeek, parseCustomWeeks, describeWeeks,
  clampWeek, msOfYmd,
  WEEKS_TYPE_EVERY, WEEKS_TYPE_ODD, WEEKS_TYPE_EVEN, WEEKS_TYPE_CUSTOM,
} from '../entry/src/main/ets/utils/WeekCalculator.ts';
import { dateStrToMs, msToDateStr } from '../entry/src/main/ets/model/SyncCodecs.ts';
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

const MON_2024_0101 = msOfYmd(2024, 1, 1);

console.log('WeekCalculator:');

t('mondayOfMs：周一返回自身', () => {
  assert.equal(mondayOfMs(MON_2024_0101), MON_2024_0101);
});

t('mondayOfMs：周三回到周一', () => {
  assert.equal(mondayOfMs(msOfYmd(2024, 1, 3)), MON_2024_0101);
});

t('mondayOfMs：周日回到本周周一', () => {
  assert.equal(mondayOfMs(msOfYmd(2024, 1, 7)), MON_2024_0101);
});

t('mondayOfMs：下周一', () => {
  assert.equal(mondayOfMs(msOfYmd(2024, 1, 8)), msOfYmd(2024, 1, 8));
});

t('weekNumberOf：第 1 周（开学当天）', () => {
  assert.equal(weekNumberOf(MON_2024_0101, MON_2024_0101), 1);
});

t('weekNumberOf：第 1 周周日', () => {
  assert.equal(weekNumberOf(MON_2024_0101, msOfYmd(2024, 1, 7)), 1);
});

t('weekNumberOf：第 2 周周一', () => {
  assert.equal(weekNumberOf(MON_2024_0101, msOfYmd(2024, 1, 8)), 2);
});

t('weekNumberOf：开学前一天返回 0（负数天差向下取整，不截断为 1）', () => {
  assert.equal(weekNumberOf(MON_2024_0101, msOfYmd(2023, 12, 31)), 0);
});

t('weekNumberOf：开学前一周返回 -1 以下', () => {
  assert.equal(weekNumberOf(MON_2024_0101, msOfYmd(2023, 12, 25)), 0);
  assert.equal(weekNumberOf(MON_2024_0101, msOfYmd(2023, 12, 24)), -1);
});

t('weekNumberOf：超总周数照常返回', () => {
  assert.equal(weekNumberOf(MON_2024_0101, msOfYmd(2024, 12, 30)), 53);
});

t('occursInWeek：每周恒真', () => {
  assert.equal(occursInWeek(WEEKS_TYPE_EVERY, [], 1), true);
  assert.equal(occursInWeek(WEEKS_TYPE_EVERY, [], 18), true);
});

t('occursInWeek：单周奇数', () => {
  assert.equal(occursInWeek(WEEKS_TYPE_ODD, [], 1), true);
  assert.equal(occursInWeek(WEEKS_TYPE_ODD, [], 2), false);
  assert.equal(occursInWeek(WEEKS_TYPE_ODD, [], 17), true);
});

t('occursInWeek：双周从第 2 周起', () => {
  assert.equal(occursInWeek(WEEKS_TYPE_EVEN, [], 1), false);
  assert.equal(occursInWeek(WEEKS_TYPE_EVEN, [], 2), true);
  assert.equal(occursInWeek(WEEKS_TYPE_EVEN, [], 18), true);
});

t('occursInWeek：自定义按列表', () => {
  assert.equal(occursInWeek(WEEKS_TYPE_CUSTOM, [1, 3, 5], 3), true);
  assert.equal(occursInWeek(WEEKS_TYPE_CUSTOM, [1, 3, 5], 4), false);
});

t('occursInWeek：week<1 一律 false', () => {
  assert.equal(occursInWeek(WEEKS_TYPE_EVERY, [], 0), false);
  assert.equal(occursInWeek(WEEKS_TYPE_EVERY, [], -2), false);
});

t('parseCustomWeeks：混合分隔与区间', () => {
  assert.deepEqual(parseCustomWeeks('1,3,5-8，12'), [1, 3, 5, 6, 7, 8, 12]);
});

t('parseCustomWeeks：顿号/空格分隔', () => {
  assert.deepEqual(parseCustomWeeks('1、2 4'), [1, 2, 4]);
});

t('parseCustomWeeks：波浪号/长破折号区间', () => {
  assert.deepEqual(parseCustomWeeks('2~4'), [2, 3, 4]);
  assert.deepEqual(parseCustomWeeks('2—4'), [2, 3, 4]);
});

t('parseCustomWeeks：非法片段忽略 + 去重升序', () => {
  assert.deepEqual(parseCustomWeeks('abc,0,2,2,x9'), [2]);
});

t('parseCustomWeeks：空输入', () => {
  assert.deepEqual(parseCustomWeeks(''), []);
});

t('describeWeeks：四类描述', () => {
  assert.equal(describeWeeks(WEEKS_TYPE_EVERY, []), '每周');
  assert.equal(describeWeeks(WEEKS_TYPE_ODD, []), '单周');
  assert.equal(describeWeeks(WEEKS_TYPE_EVEN, []), '双周');
  assert.equal(describeWeeks(WEEKS_TYPE_CUSTOM, []), '未设置周次');
  assert.equal(describeWeeks(WEEKS_TYPE_CUSTOM, [1, 3]), '第 1、3 周');
});

t('clampWeek：范围内返回，范围外 null', () => {
  assert.equal(clampWeek(1, 20), 1);
  assert.equal(clampWeek(20, 20), 20);
  assert.equal(clampWeek(0, 20), null);
  assert.equal(clampWeek(21, 20), null);
  assert.equal(clampWeek(-1, 20), null);
});

t('dateStrToMs / msToDateStr：往返一致', () => {
  const ms = dateStrToMs('2025-09-01');
  assert.notEqual(ms, null);
  assert.equal(msToDateStr(ms as number), '2025-09-01');
});

t('dateStrToMs：非法与溢出日期', () => {
  assert.equal(dateStrToMs('2026-02-31'), null);
  assert.equal(dateStrToMs('2026-13-01'), null);
  assert.equal(dateStrToMs('abc'), null);
  assert.equal(dateStrToMs('2026-8-1'), null);
});

t('msToDateStr：补零', () => {
  assert.equal(msToDateStr(msOfYmd(2026, 8, 5)), '2026-08-05');
});

if (failed > 0) {
  console.error(`week_calculator: ${failed} 个用例失败`);
  process.exit(1);
}
console.log('week_calculator: 全部通过');
