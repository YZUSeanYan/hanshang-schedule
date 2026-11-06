export interface InboxNotification {
  id: number;
  title: string;
  body: string;
  deliveryStatus: string;
  createdAt: string;
  readAt: string | null;
}

export interface NotificationPage {
  items: InboxNotification[];
  unread: number;
  hasMore: boolean;
  nextBeforeId: number | null;
}
