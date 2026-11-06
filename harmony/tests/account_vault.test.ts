import assert from 'node:assert/strict';
import test from 'node:test';
import {
  accountDbName,
  GUEST_DB_NAME,
  LEGACY_DB_NAME,
} from '../entry/src/main/ets/data/AccountVault.ts';

test('guest never opens an account database', () => {
  assert.equal(accountDbName(null, 2), GUEST_DB_NAME);
});

test('trusted cached owner keeps the legacy database after upgrade', () => {
  assert.equal(accountDbName(2, 2), LEGACY_DB_NAME);
});

test('another account receives an isolated database', () => {
  assert.equal(accountDbName(40, 2), 'yzu_schedule_account_40.db');
});

test('unclaimed legacy database is quarantined after logged-out upgrade', () => {
  assert.equal(accountDbName(2, null), 'yzu_schedule_account_2.db');
});

test('invalid account ids fail closed', () => {
  assert.throws(() => accountDbName(0, null), /invalid account id/);
});
