import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yzu_schedule/core/notifications/push_service.dart';
import 'package:yzu_schedule/features/profile/presentation/notification_inbox_page.dart';

class _InboxService implements PushServiceApi {
  int loads = 0;
  @override
  Future<Map<String, dynamic>> inbox() async {
    loads++;
    return {'items': <Map<String, dynamic>>[], 'unread': 0};
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  testWidgets('open inbox reloads on foreground delivery and app resume', (tester) async {
    final service = _InboxService();
    final container = ProviderContainer(overrides: [
      pushServiceProvider.overrideWithValue(service),
    ]);
    addTearDown(container.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: NotificationInboxPage()),
    ));
    await tester.pumpAndSettle();
    expect(service.loads, 1);
    container.read(notificationInboxRevisionProvider.notifier).state++;
    await tester.pumpAndSettle();
    expect(service.loads, 2);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(service.loads, 3);
    await tester.pumpWidget(const SizedBox());
  });
}
