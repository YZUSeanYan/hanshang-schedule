import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:yzu_schedule/features/shared_availability/data/shared_availability_repository.dart';
import 'package:yzu_schedule/features/shared_availability/presentation/shared_availability_page.dart';

class _FakeAvailabilityApi implements SharedAvailabilityApi {
  AvailabilityStatus current = const AvailabilityStatus(state: 'disconnected');
  String? invitedUsername;

  @override
  Future<AvailabilityStatus> status() async => current;

  @override
  Future<List<String>> searchUsers(String query) async =>
      query.toLowerCase().startsWith('yang') ? const ['Yang', 'Yangz'] : const [];

  @override
  Future<void> invite(String username) async {
    invitedUsername = username;
    current = AvailabilityStatus(
      state: 'waiting',
      outgoing: AvailabilityInvitation(
        id: 'a' * 64,
        username: username,
        expiresAt: DateTime(2030),
      ),
    );
  }

  @override
  Future<CodeInvitation> createCodeInvite() async {
    current = const AvailabilityStatus(state: 'waiting', inviteType: 'code');
    return CodeInvitation(code: '7KMP3XQH', expiresAt: DateTime(2030));
  }

  @override
  Future<void> claimCode(String code) async {}

  @override
  Future<void> cancelCodeInvite() async {
    current = const AvailabilityStatus(state: 'disconnected');
  }

  @override
  Future<void> respond(String invitationId, {required bool accept}) async {}

  @override
  Future<void> cancel(String invitationId) async {}

  @override
  Future<void> disconnect() async {}

  @override
  Future<AvailabilityWeek> week(DateTime monday) async => AvailabilityWeek(
        partnerUsername: '同学甲',
        sectionCount: 4,
        days: [
          for (var day = 1; day <= 7; day++)
            AvailabilityDay(
              day: day,
              date: monday.add(Duration(days: day - 1)),
              states: const [
                'both_free',
                'me_busy',
                'partner_busy',
                'both_busy'
              ],
            ),
        ],
      );
}

void main() {
  testWidgets('共同空闲使用原生用户名邀请并介绍使用场景', (tester) async {
    final fake = _FakeAvailabilityApi();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedAvailabilityRepositoryProvider.overrideWithValue(fake),
        ],
        child: const MaterialApp(home: SharedAvailabilityPage()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('共同空闲'), findsOneWidget);
    expect(find.text('一起找空闲时间'), findsOneWidget);
    expect(find.textContaining('自习、讨论或见面'), findsOneWidget);
    expect(find.textContaining('支持完整用户名邀请和临时邀请码'), findsOneWidget);
    expect(find.byType(TextField), findsNWidgets(2));

    await tester.enterText(find.byType(TextField).first, ' 同学甲 ');
    await tester.tap(find.text('发送邀请'));
    await tester.pumpAndSettle();

    expect(fake.invitedUsername, '同学甲');
    expect(find.text('等待 同学甲 确认'), findsOneWidget);
    expect(find.textContaining('接受前不会共享任何课表状态'), findsOneWidget);
  });

  testWidgets('共同空闲原生页保留临时邀请码', (tester) async {
    final fake = _FakeAvailabilityApi();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedAvailabilityRepositoryProvider.overrideWithValue(fake),
        ],
        child: const MaterialApp(home: SharedAvailabilityPage()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('生成我的邀请码'), findsOneWidget);
    expect(find.text('加入共同空闲'), findsOneWidget);
    await tester.tap(find.text('生成我的邀请码'));
    await tester.pumpAndSettle();
    expect(find.text('7KMP3XQH'), findsOneWidget);
    expect(find.textContaining('15 分钟内有效'), findsOneWidget);
  });

  testWidgets('共同空闲可搜索用户名并从结果发送邀请', (tester) async {
    final fake = _FakeAvailabilityApi();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedAvailabilityRepositoryProvider.overrideWithValue(fake),
        ],
        child: const MaterialApp(home: SharedAvailabilityPage()),
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).first, 'yang');
    await tester.pump(const Duration(milliseconds: 320));
    await tester.pumpAndSettle();
    expect(find.text('Yang'), findsOneWidget);
    expect(find.text('Yangz'), findsOneWidget);

    await tester.tap(find.text('Yang'));
    await tester.pumpAndSettle();
    expect(fake.invitedUsername, 'Yang');
  });

  testWidgets('共同空闲原生页展示接受和拒绝邀请', (tester) async {
    final fake = _FakeAvailabilityApi()
      ..current = AvailabilityStatus(
        state: 'invited',
        invitations: [
          AvailabilityInvitation(
            id: 'b' * 64,
            username: '同学乙',
            expiresAt: DateTime(2030),
          ),
        ],
      );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedAvailabilityRepositoryProvider.overrideWithValue(fake),
        ],
        child: const MaterialApp(home: SharedAvailabilityPage()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('同学乙 邀请你查看共同空闲'), findsOneWidget);
    expect(find.text('接受邀请'), findsOneWidget);
    expect(find.text('拒绝'), findsOneWidget);
  });
}
