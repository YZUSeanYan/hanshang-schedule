export const LEGACY_DB_NAME = 'yzu_schedule.db';
export const GUEST_DB_NAME = 'yzu_schedule_guest.db';

export function accountDbName(accountId: number | null, legacyOwnerId: number | null): string {
  if (accountId === null) {
    return GUEST_DB_NAME;
  }
  if (!Number.isInteger(accountId) || accountId <= 0) {
    throw new Error('invalid account id');
  }
  if (legacyOwnerId === accountId) {
    return LEGACY_DB_NAME;
  }
  return `yzu_schedule_account_${accountId}.db`;
}
