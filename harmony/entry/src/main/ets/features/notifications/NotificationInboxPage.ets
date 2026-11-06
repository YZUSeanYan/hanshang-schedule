import { router } from '@kit.ArkUI';
import { AppTheme } from '../../common/AppTheme';
import { apiErrorMessage } from '../../network/ApiClient';
import { InboxNotification } from './NotificationTypes';
import { NotificationAccountChangedError, NotificationRepository } from './NotificationRepository';
import { notificationTimeText } from './NotificationTime';

@Entry
@Component
struct NotificationInboxPage {
  @StorageProp(AppTheme.KEY_BRAND) brandColor: string = '#158A63';
  @StorageProp(AppTheme.KEY_EFFECTIVE_DARK) effectiveDark: boolean = false;
  @State items: InboxNotification[] = [];
  @State unread: number = 0;
  @State loading: boolean = true;
  @State refreshing: boolean = false;
  @State loadingMore: boolean = false;
  @State operating: boolean = false;
  @State errorText: string = '';
  @State hasMore: boolean = false;
  @State nextBeforeId: number | null = null;
  private requestEpoch: number = 0;

  aboutToAppear(): void {
    this.openPushedNotification();
  }

  private async openPushedNotification(): Promise<void> {
    const params = router.getParams() as Record<string, Object> | undefined;
    const rawId = params?.['notificationId'];
    const notificationId = typeof rawId === 'number' && Number.isSafeInteger(rawId) && rawId > 0
      ? rawId : null;
    if (notificationId !== null) {
      try {
        await NotificationRepository.markRead(notificationId);
      } catch (e) {
        // 消息可能已删除或属于另一个账号，列表接口仍是最终可信来源。
      }
    }
    await this.reload(false);
  }

  aboutToDisappear(): void {
    this.requestEpoch++;
  }

  private pageColor(): string { return this.effectiveDark ? '#101214' : '#FFFFFF'; }
  private surfaceColor(): string { return this.effectiveDark ? '#1C1F22' : '#F7F8FA'; }
  private unreadColor(): string { return this.effectiveDark ? '#202A27' : '#F0F8F5'; }
  private primaryText(): string { return this.effectiveDark ? '#F2F3F4' : '#1A1A1A'; }
  private secondaryText(): string { return this.effectiveDark ? '#B8BDC2' : '#666666'; }
  private mutedText(): string { return this.effectiveDark ? '#8F969D' : '#999999'; }
  private dividerColor(): string { return this.effectiveDark ? '#34383D' : '#E5E7EA'; }
  private dangerColor(): string { return this.effectiveDark ? '#FF746C' : '#C9362B'; }

  private async reload(fromRefresh: boolean): Promise<void> {
    const epoch = ++this.requestEpoch;
    if (fromRefresh) {
      this.refreshing = true;
    } else {
      this.loading = true;
    }
    this.errorText = '';
    try {
      const page = await NotificationRepository.list();
      if (epoch !== this.requestEpoch) {
        return;
      }
      this.items = page.items;
      this.unread = page.unread;
      this.hasMore = page.hasMore;
      this.nextBeforeId = page.nextBeforeId;
    } catch (error) {
      if (epoch !== this.requestEpoch || error instanceof NotificationAccountChangedError) {
        return;
      }
      this.errorText = apiErrorMessage(error as Object, '加载通知失败，请稍后重试');
    } finally {
      if (epoch === this.requestEpoch) {
        this.loading = false;
        this.refreshing = false;
      }
    }
  }

  private async loadMore(): Promise<void> {
    if (!this.hasMore || this.nextBeforeId === null || this.loadingMore || this.refreshing) {
      return;
    }
    const epoch = this.requestEpoch;
    this.loadingMore = true;
    try {
      const page = await NotificationRepository.list(this.nextBeforeId);
      if (epoch !== this.requestEpoch) {
        return;
      }
      const known: Set<number> = new Set(this.items.map((item: InboxNotification) => item.id));
      const additions = page.items.filter((item: InboxNotification) => !known.has(item.id));
      this.items = this.items.concat(additions);
      this.unread = page.unread;
      this.hasMore = page.hasMore;
      this.nextBeforeId = page.nextBeforeId;
    } catch (error) {
      if (epoch === this.requestEpoch && !(error instanceof NotificationAccountChangedError)) {
        this.toast(apiErrorMessage(error as Object, '加载更多失败'));
      }
    } finally {
      if (epoch === this.requestEpoch) {
        this.loadingMore = false;
      }
    }
  }

  private async markRead(item: InboxNotification): Promise<void> {
    if (item.readAt !== null || this.operating) {
      return;
    }
    const epoch = this.requestEpoch;
    this.operating = true;
    try {
      await NotificationRepository.markRead(item.id);
      if (epoch !== this.requestEpoch) {
        return;
      }
      const readAt = new Date().toISOString();
      this.items = this.items.map((current: InboxNotification) => current.id === item.id
        ? this.withReadAt(current, readAt) : current);
      this.unread = Math.max(0, this.unread - 1);
    } catch (error) {
      this.showOperationError(epoch, error as Object, '标记已读失败');
    } finally {
      if (epoch === this.requestEpoch) {
        this.operating = false;
      }
    }
  }

  private async markAllRead(): Promise<void> {
    if (this.unread === 0 || this.operating) {
      return;
    }
    const epoch = this.requestEpoch;
    this.operating = true;
    try {
      await NotificationRepository.markAllRead();
      if (epoch !== this.requestEpoch) {
        return;
      }
      const readAt = new Date().toISOString();
      this.items = this.items.map((item: InboxNotification) => item.readAt === null
        ? this.withReadAt(item, readAt) : item);
      this.unread = 0;
      this.toast('已全部标记为已读');
    } catch (error) {
      this.showOperationError(epoch, error as Object, '操作失败');
    } finally {
      if (epoch === this.requestEpoch) {
        this.operating = false;
      }
    }
  }

  private async confirmDelete(item: InboxNotification): Promise<void> {
    const confirmed = await this.confirm('删除通知', '删除后不可恢复，确定删除这条通知吗？', '删除');
    if (confirmed) {
      await this.deleteOne(item);
    }
  }

  private async deleteOne(item: InboxNotification): Promise<void> {
    if (this.operating) {
      return;
    }
    const epoch = this.requestEpoch;
    this.operating = true;
    try {
      await NotificationRepository.deleteOne(item.id);
      if (epoch !== this.requestEpoch) {
        return;
      }
      this.items = this.items.filter((current: InboxNotification) => current.id !== item.id);
      if (item.readAt === null) {
        this.unread = Math.max(0, this.unread - 1);
      }
    } catch (error) {
      this.showOperationError(epoch, error as Object, '删除失败');
    } finally {
      if (epoch === this.requestEpoch) {
        this.operating = false;
      }
    }
  }

  private async confirmClear(): Promise<void> {
    if (this.items.length === 0 || this.operating) {
      return;
    }
    const confirmed = await this.confirm('清空全部通知', '将删除收件箱中的全部通知，且不可恢复。确定继续吗？', '清空');
    if (!confirmed) {
      return;
    }
    const epoch = this.requestEpoch;
    this.operating = true;
    try {
      await NotificationRepository.clear();
      if (epoch !== this.requestEpoch) {
        return;
      }
      this.items = [];
      this.unread = 0;
      this.hasMore = false;
      this.nextBeforeId = null;
      this.toast('通知已清空');
    } catch (error) {
      this.showOperationError(epoch, error as Object, '清空失败');
    } finally {
      if (epoch === this.requestEpoch) {
        this.operating = false;
      }
    }
  }

  private async confirm(title: string, message: string, action: string): Promise<boolean> {
    const result = await this.getUIContext().getPromptAction().showDialog({
      title,
      message,
      buttons: [
        { text: '取消', color: this.secondaryText() },
        { text: action, color: this.dangerColor() }
      ]
    });
    return result.index === 1;
  }

  private withReadAt(item: InboxNotification, readAt: string): InboxNotification {
    return {
      id: item.id,
      title: item.title,
      body: item.body,
      deliveryStatus: item.deliveryStatus,
      createdAt: item.createdAt,
      readAt
    };
  }

  private showOperationError(epoch: number, error: Object, fallback: string): void {
    if (epoch === this.requestEpoch && !(error instanceof NotificationAccountChangedError)) {
      this.toast(apiErrorMessage(error, fallback));
    }
  }

  private toast(message: string): void {
    this.getUIContext().getPromptAction().showToast({ message, duration: 2200 });
  }

  @Builder
  private notificationRow(item: InboxNotification) {
    Row({ space: 12 }) {
      Stack() {
        SymbolGlyph($r('sys.symbol.bell'))
          .fontSize(21)
          .fontColor([item.readAt === null ? this.brandColor : this.mutedText()]);
      }
      .width(36)
      .height(36)
      .borderRadius(18)
      .backgroundColor(item.readAt === null ? this.brandColor + '1F' : this.pageColor());

      Column({ space: 6 }) {
        Row({ space: 8 }) {
          Text(item.title)
            .fontSize(15)
            .fontWeight(item.readAt === null ? FontWeight.Bold : FontWeight.Medium)
            .fontColor(this.primaryText())
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1);
          if (item.readAt === null) {
            Circle().width(7).height(7).fill(this.brandColor);
          }
        }
        .width('100%');
        Text(item.body)
          .fontSize(13)
          .fontColor(item.readAt === null ? this.secondaryText() : this.mutedText())
          .lineHeight(19)
          .maxLines(5)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%');
        Row() {
          Text(notificationTimeText(item.createdAt)).fontSize(11).fontColor(this.mutedText());
          Blank();
          Button({ type: ButtonType.Circle, stateEffect: true }) {
            SymbolGlyph($r('sys.symbol.trash')).fontSize(17).fontColor([this.mutedText()]);
          }
          .width(32).height(32)
          .backgroundColor(Color.Transparent)
          .onClick(() => { this.confirmDelete(item); });
        }
        .width('100%')
        .height(32);
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1);
    }
    .width('100%')
    .padding(14)
    .borderRadius(8)
    .backgroundColor(item.readAt === null ? this.unreadColor() : this.surfaceColor())
    .border({ width: item.readAt === null ? 1 : 0, color: item.readAt === null ? this.brandColor + '33' : Color.Transparent })
    .onClick(() => { this.markRead(item); });
  }

  build() {
    Column() {
      Row({ space: 4 }) {
        Button({ type: ButtonType.Circle, stateEffect: true }) {
          SymbolGlyph($r('sys.symbol.chevron_left')).fontSize(22).fontColor([this.primaryText()]);
        }
        .width(44).height(44).backgroundColor(Color.Transparent)
        .onClick(() => router.back());
        Column() {
          Text('消息中心').fontSize(17).fontWeight(FontWeight.Bold).fontColor(this.primaryText());
          if (this.unread > 0) {
            Text(`${this.unread} 条未读`).fontSize(11).fontColor(this.brandColor).margin({ top: 1 });
          }
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1);
        Button('全部已读')
          .fontSize(13)
          .fontColor(this.unread > 0 && !this.operating ? this.brandColor : this.mutedText())
          .backgroundColor(Color.Transparent)
          .enabled(this.unread > 0 && !this.operating)
          .onClick(() => { this.markAllRead(); });
        Button({ type: ButtonType.Circle, stateEffect: true }) {
          SymbolGlyph($r('sys.symbol.trash')).fontSize(19)
            .fontColor([this.items.length > 0 ? this.dangerColor() : this.mutedText()]);
        }
        .width(40).height(40).backgroundColor(Color.Transparent)
        .enabled(this.items.length > 0 && !this.operating)
        .onClick(() => { this.confirmClear(); });
      }
      .width('100%')
      .height(56)
      .padding({ left: 4, right: 8 })
      .border({ width: { bottom: 1 }, color: this.dividerColor() });

      if (this.loading && this.items.length === 0) {
        Column({ space: 12 }) {
          LoadingProgress().width(36).height(36).color(this.brandColor);
          Text('正在加载消息').fontSize(13).fontColor(this.mutedText());
        }
        .justifyContent(FlexAlign.Center)
        .layoutWeight(1)
        .width('100%');
      } else if (this.errorText.length > 0 && this.items.length === 0) {
        Column({ space: 12 }) {
          SymbolGlyph($r('sys.symbol.exclamationmark_circle')).fontSize(36).fontColor([this.mutedText()]);
          Text(this.errorText).fontSize(14).fontColor(this.secondaryText()).textAlign(TextAlign.Center)
            .padding({ left: 28, right: 28 });
          Button('重新加载').fontSize(14).backgroundColor(this.brandColor)
            .onClick(() => { this.reload(false); });
        }
        .justifyContent(FlexAlign.Center)
        .layoutWeight(1)
        .width('100%');
      } else if (this.items.length === 0) {
        Refresh({ refreshing: this.refreshing }) {
          Column({ space: 10 }) {
            SymbolGlyph($r('sys.symbol.bell')).fontSize(42).fontColor([this.mutedText()]);
            Text('暂无消息').fontSize(16).fontWeight(FontWeight.Medium).fontColor(this.primaryText());
            Text('新的账户通知会显示在这里').fontSize(13).fontColor(this.mutedText());
          }
          .justifyContent(FlexAlign.Center)
          .width('100%')
          .height('100%');
        }
        .layoutWeight(1)
        .width('100%')
        .onRefreshing(() => { this.reload(true); });
      } else {
        Refresh({ refreshing: this.refreshing }) {
          List({ space: 8 }) {
            ForEach(this.items, (item: InboxNotification) => {
              ListItem() { this.notificationRow(item); }
            }, (item: InboxNotification) => `notification-${item.id}`);
            ListItem() {
              if (this.loadingMore) {
                Row({ space: 8 }) {
                  LoadingProgress().width(18).height(18).color(this.brandColor);
                  Text('正在加载更多').fontSize(12).fontColor(this.mutedText());
                }
                .justifyContent(FlexAlign.Center)
                .width('100%')
                .height(52);
              } else if (!this.hasMore) {
                Text('没有更多消息').fontSize(11).fontColor(this.mutedText())
                  .width('100%').height(44).textAlign(TextAlign.Center);
              }
            }
          }
          .width('100%')
          .height('100%')
          .padding({ left: 12, right: 12, top: 10, bottom: 12 })
          .edgeEffect(EdgeEffect.Spring)
          .onReachEnd(() => { this.loadMore(); });
        }
        .layoutWeight(1)
        .width('100%')
        .onRefreshing(() => { this.reload(true); });
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.pageColor());
  }
}
