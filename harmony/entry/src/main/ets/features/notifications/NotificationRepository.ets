import { ApiClient } from '../../network/ApiClient';
import { AuthRepository } from '../../repository/AuthRepository';
import { decodeNotificationPage } from './NotificationCodecs';
import { NotificationPage } from './NotificationTypes';

export class NotificationAccountChangedError extends Error {
  constructor() {
    super('账号状态已变化');
    this.name = 'NotificationAccountChangedError';
  }
}

export class NotificationRepository {
  static currentAccountId(): number | null {
    const user = AuthRepository.lastKnownUser();
    return user !== null && !user.offline && user.id > 0 ? user.id : null;
  }

  static async list(beforeId: number | null = null, limit: number = 30): Promise<NotificationPage> {
    const accountId = NotificationRepository.requireAccount();
    const cursor = beforeId === null ? '' : `&before_id=${beforeId}`;
    const data = await ApiClient.get(`/api/notifications?limit=${limit}${cursor}`);
    NotificationRepository.assertSameAccount(accountId);
    return decodeNotificationPage(data);
  }

  static async markRead(id: number): Promise<void> {
    const accountId = NotificationRepository.requireAccount();
    const body: Record<string, Object> = {};
    await ApiClient.post(`/api/notifications/${id}/read`, body);
    NotificationRepository.assertSameAccount(accountId);
  }

  static async markAllRead(): Promise<void> {
    const accountId = NotificationRepository.requireAccount();
    const body: Record<string, Object> = {};
    await ApiClient.post('/api/notifications/read-all', body);
    NotificationRepository.assertSameAccount(accountId);
  }

  static async deleteOne(id: number): Promise<void> {
    const accountId = NotificationRepository.requireAccount();
    await ApiClient.delete(`/api/notifications/${id}`);
    NotificationRepository.assertSameAccount(accountId);
  }

  static async clear(): Promise<void> {
    const accountId = NotificationRepository.requireAccount();
    await ApiClient.delete('/api/notifications');
    NotificationRepository.assertSameAccount(accountId);
  }

  private static requireAccount(): number {
    const id = NotificationRepository.currentAccountId();
    if (id === null) {
      throw new NotificationAccountChangedError();
    }
    return id;
  }

  private static assertSameAccount(expectedId: number): void {
    if (NotificationRepository.currentAccountId() !== expectedId) {
      throw new NotificationAccountChangedError();
    }
  }
}
