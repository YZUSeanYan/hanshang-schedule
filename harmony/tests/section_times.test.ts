/** 节次作息表单测。运行：node tests/section_times.test.ts */
import {
  SPRING_SUMMER, AUTUMN_WINTER, SECTION_COUNT, sectionTimesForMonth, startOf, endOf,
} from '../entry/src/main/ets/constants/SectionTimes.ts';
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

console.log('SectionTimes:');

t('两套各 12 小节，与 SECTION_COUNT 一致', () => {
  assert.equal(SPRING_SUMMER.length, SECTION_COUNT);
  assert.equal(AUTUMN_WINTER.length, SECTION_COUNT);
  assert.equal(SECTION_COUNT, 12);
});

t('春夏季关键时间点（真实样本）', () => {
  assert.equal(SPRING_SUMMER[0].start, '08:00');
  assert.equal(SPRING_SUMMER[5].start, '14:30'); // 下午第 6 节
  assert.equal(SPRING_SUMMER[10].start, '19:30'); // 晚第 11 节
  assert.equal(SPRING_SUMMER[11].end, '21:10');
});

t('秋冬季关键时间点（14:00 / 19:00）', () => {
  assert.equal(AUTUMN_WINTER[0].start, '08:00');
  assert.equal(AUTUMN_WINTER[5].start, '14:00'); // 修正后的下午第 6 节
  assert.equal(AUTUMN_WINTER[10].start, '19:00'); // 晚第 11 节
  assert.equal(AUTUMN_WINTER[11].end, '20:35');
});

t('上午两套完全一致', () => {
  for (let i = 0; i < 5; i++) {
    assert.equal(SPRING_SUMMER[i].start, AUTUMN_WINTER[i].start);
    assert.equal(SPRING_SUMMER[i].end, AUTUMN_WINTER[i].end);
  }
});

t('月份选择：5-9 月春夏季，其余秋冬季', () => {
  assert.equal(sectionTimesForMonth(5), SPRING_SUMMER);
  assert.equal(sectionTimesForMonth(8), SPRING_SUMMER);
  assert.equal(sectionTimesForMonth(9), SPRING_SUMMER);
  assert.equal(sectionTimesForMonth(4), AUTUMN_WINTER);
  assert.equal(sectionTimesForMonth(10), AUTUMN_WINTER);
  assert.equal(sectionTimesForMonth(1), AUTUMN_WINTER);
  assert.equal(sectionTimesForMonth(12), AUTUMN_WINTER);
});

t('startOf / endOf 下标换算', () => {
  assert.equal(startOf(1, 8), '08:00');
  assert.equal(endOf(1, 1), '08:45');
  assert.equal(startOf(6, 8), '14:30');
  assert.equal(startOf(6, 1), '14:00');
  assert.equal(endOf(12, 8), '21:10');
  assert.equal(endOf(12, 12), '20:35');
});

if (failed > 0) {
  console.error(`section_times: ${failed} 个用例失败`);
  process.exit(1);
}
console.log('section_times: 全部通过');
