import assert from 'node:assert/strict';
import {
  DEFAULT_THEME_SEED,
  THEME_MODE_DARK,
  THEME_MODE_LIGHT,
  THEME_MODE_SYSTEM,
  deserializeThemeSnapshot,
  effectiveDark,
  normalizeThemeSnapshot,
  serializeThemeSnapshot,
} from '../entry/src/main/ets/common/ThemeLogic.ts';

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

console.log('ThemeLogic:');

t('system mode follows system dark state', () => {
  assert.equal(effectiveDark(THEME_MODE_SYSTEM, true), true);
  assert.equal(effectiveDark(THEME_MODE_SYSTEM, false), false);
});

t('explicit modes ignore system dark state', () => {
  assert.equal(effectiveDark(THEME_MODE_LIGHT, true), false);
  assert.equal(effectiveDark(THEME_MODE_DARK, false), true);
});

t('snapshot normalization validates complete mode and seed', () => {
  assert.deepEqual(normalizeThemeSnapshot({ mode: 9, seed: 'bad' }), {
    mode: THEME_MODE_SYSTEM,
    seed: DEFAULT_THEME_SEED,
  });
  assert.deepEqual(normalizeThemeSnapshot({ mode: THEME_MODE_DARK, seed: ' #3a7bd5 ' }), {
    mode: THEME_MODE_DARK,
    seed: '#3A7BD5',
  });
});

t('snapshot serialization always contains mode and seed', () => {
  const raw = serializeThemeSnapshot({ mode: THEME_MODE_LIGHT, seed: '#43a047' });
  assert.deepEqual(JSON.parse(raw), { mode: THEME_MODE_LIGHT, seed: '#43A047' });
});

t('invalid persisted data falls back as one complete snapshot', () => {
  const fallback = { mode: THEME_MODE_DARK, seed: '#EC407A' };
  assert.deepEqual(deserializeThemeSnapshot('{', fallback), fallback);
  assert.deepEqual(deserializeThemeSnapshot('{"mode":1}', fallback), fallback);
});

if (failed > 0) {
  console.error(`theme_logic: ${failed} failed cases`);
  process.exit(1);
}
console.log('theme_logic: all passed');
