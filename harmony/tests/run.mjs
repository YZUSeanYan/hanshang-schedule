/**
 * 测试入口：逐个运行纯逻辑单测（每个文件独立进程，任一失败则整体退出码非 0）。
 * 运行：npm test（或 node tests/run.mjs）
 */
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const files = [
  'week_calculator.test.ts',
  'section_times.test.ts',
  'course_colors.test.ts',
  'theme_logic.test.ts',
  'location_formatter.test.ts',
  'sync_codecs.test.ts',
  'yzu_parser.test.ts',
  'notification_intent_handler.test.ts',
  'notification_inbox.test.ts',
  'account_vault.test.ts',
];

const dir = path.dirname(fileURLToPath(import.meta.url));
let failed = 0;
for (const f of files) {
  const r = spawnSync(process.execPath, [path.join(dir, f)], { stdio: 'inherit' });
  if (r.status !== 0) {
    failed++;
  }
}

if (failed > 0) {
  console.error(`\n${failed} 个测试文件失败`);
  process.exit(1);
}
console.log('\n全部纯逻辑单测通过 ✅');
