import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yzu_schedule/core/notifications/reminder_service.dart';
import 'package:yzu_schedule/features/profile/presentation/profile_page.dart';

class _FakeReminderService implements ReminderServiceApi {
  _FakeReminderService({required this.enabled, required this.minutes});

  bool enabled;
  int minutes;
  Completer<void>? enabledSave;
  Completer<void>? minutesSave;

  @override
  Future<void> requestPermission() async {}

  @override
  Future<bool> hasPermission() async => true;

  @override
  Future<bool> isEnabled() async => enabled;

  @override
  Future<int> leadMinutes() async => minutes;

  @override
  Future<void> setEnabled(bool value) {
    enabled = value;
    return enabledSave?.future ?? Future.value();
  }

  @override
  Future<void> setLeadMinutes(int value) {
    minutes = value;
    return minutesSave?.future ?? Future.value();
  }

  @override
  Future<void> reschedule() async {}

  @override
  Future<void> sendTestNotification() async {}
}

void main() {
  Widget subject(ReminderServiceApi service) => MaterialApp(
        home: Scaffold(body: ReminderSettingsTile(service: service)),
      );

  testWidgets('开关点击后立即反馈，不等待原生通知重排', (tester) async {
    final service = _FakeReminderService(enabled: false, minutes: 15)
      ..enabledSave = Completer<void>();
    await tester.pumpWidget(subject(service));
    await tester.pump();

    await tester.tap(find.byType(Switch));
    await tester.pump();

    expect(tester.widget<Switch>(find.byType(Switch)).value, isTrue);
    expect(find.textContaining('正在保存'), findsOneWidget);
    expect(service.enabled, isTrue);

    service.enabledSave!.complete();
    await tester.pump();
    expect(find.textContaining('正在保存'), findsNothing);
  });

  testWidgets('提前时间点击后立即切换选中项', (tester) async {
    final service = _FakeReminderService(enabled: true, minutes: 15)
      ..minutesSave = Completer<void>();
    await tester.pumpWidget(subject(service));
    await tester.pump();

    await tester.tap(find.text('30分钟'));
    await tester.pump();

    final segmented = tester.widget<SegmentedButton<int>>(
      find.byType(SegmentedButton<int>),
    );
    expect(segmented.selected, {30});
    expect(service.minutes, 30);

    service.minutesSave!.complete();
    await tester.pump();
  });
}
