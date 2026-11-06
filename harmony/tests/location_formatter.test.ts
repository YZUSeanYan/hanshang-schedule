/** 地点排版单测。运行：node tests/location_formatter.test.ts */
import { formatCourseLocation } from '../entry/src/main/ets/utils/LocationFormatter.ts';
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

console.log('LocationFormatter:');

t('箭头三段：楼室在前，校区在后', () => {
  assert.equal(formatCourseLocation('扬子津东校区>>文津楼>>E206'), '文津楼E206 · 扬子津东校区');
});

t('箭头两段', () => {
  assert.equal(formatCourseLocation('荷花池校区>>主楼101'), '主楼101 · 荷花池校区');
});

t('全角箭头 / ＞＞ 变体', () => {
  assert.equal(formatCourseLocation('扬子津东校区→→文津楼→→E206'), '文津楼E206 · 扬子津东校区');
});

t('去头部 @ 与空白', () => {
  assert.equal(formatCourseLocation('  @主楼101  '), '主楼101');
});

t('空输入', () => {
  assert.equal(formatCourseLocation(''), '');
  assert.equal(formatCourseLocation('   '), '');
});

t('逗号分隔：按扫读重要性排序（房号优先于楼名）', () => {
  assert.equal(formatCourseLocation('主楼，101'), '101 · 主楼');
});

t('无分隔的「校区+楼+室」', () => {
  assert.equal(formatCourseLocation('荷花池校区主楼101'), '主楼101 · 荷花池校区');
});

t('无匹配规则时原样返回（trim 后）', () => {
  assert.equal(formatCourseLocation(' 教八A204 '), '教八A204');
});

if (failed > 0) {
  console.error(`location_formatter: ${failed} 个用例失败`);
  process.exit(1);
}
console.log('location_formatter: 全部通过');
