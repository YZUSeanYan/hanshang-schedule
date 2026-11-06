/** 课程配色单测。运行：node tests/course_colors.test.ts */
import {
  MACARON, forCourseName, textOn, computeLuminance, argbToCss, TEXT_DARK, TEXT_WHITE,
} from '../entry/src/main/ets/constants/CourseColors.ts';
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

console.log('CourseColors:');

t('色盘 10 色', () => {
  assert.equal(MACARON.length, 10);
});

t('空课名哈希为 0 → 第 0 色', () => {
  assert.equal(forCourseName(''), MACARON[0]);
});

t('同课名同色（稳定）', () => {
  const a = forCourseName('大学物理Ⅳ');
  const b = forCourseName('大学物理Ⅳ');
  assert.equal(a, b);
  assert.ok(MACARON.includes(a));
});

t('不同课名分布到色盘', () => {
  const names = ['高等数学', '大学英语', '数据结构', '操作系统', '计算机网络',
    '大学物理', '线性代数', '概率论', '体育', '马克思主义基本原理'];
  const colors = new Set(names.map((n) => forCourseName(n)));
  assert.ok(colors.size > 1);
});

t('哈希语义与 Dart codeUnits 一致（手工算例）', () => {
  // 'Ab' 的 UTF-16 代码单元：65, 98 → hash = (65*31+98) & 0x7fffffff = 2113
  const manual = (65 * 31 + 98) & 0x7fffffff;
  assert.equal(forCourseName('Ab'), MACARON[manual % 10]);
});

t('computeLuminance：黑白极值', () => {
  assert.ok(Math.abs(computeLuminance(0xFFFFFFFF) - 1) < 1e-9);
  assert.ok(computeLuminance(0xFF000000) < 1e-9);
});

t('textOn：浅色块配深字，深色块配白字', () => {
  for (const c of MACARON) {
    assert.equal(textOn(c), TEXT_DARK, `马卡龙色 ${c.toString(16)} 应配深色文字`);
  }
  assert.equal(textOn(0xFF000000), TEXT_WHITE);
});

t('argbToCss：格式与小写 hex', () => {
  assert.equal(argbToCss(0xFFA8D8EA), '#ffa8d8ea');
  assert.equal(argbToCss(0xFF0A0B0C), '#ff0a0b0c');
});

if (failed > 0) {
  console.error(`course_colors: ${failed} 个用例失败`);
  process.exit(1);
}
console.log('course_colors: 全部通过');
