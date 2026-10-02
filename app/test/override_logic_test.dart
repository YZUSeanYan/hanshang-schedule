import 'package:flutter_test/flutter_test.dart';
import 'package:yzu_schedule/core/database/app_database.dart';
import 'package:yzu_schedule/features/schedule/data/override_repository.dart';

ScheduleOverride _row({
  required String date,
  required String kind,
  int weekday = 0,
  String note = '',
}) =>
    ScheduleOverride(
      id: 1,
      uuid: 'u',
      date: date,
      kind: kind,
      weekday: weekday,
      note: note,
      updatedAt: DateTime(2026, 9, 22),
    );

void main() {
  test('无覆盖时按自然星期', () {
    expect(effectiveWeekday(const [], DateTime(2026, 10, 7)), 3);
  });

  test('放假当天不排课（null）', () {
    final rows = [_row(date: '2026-10-01', kind: 'off')];
    expect(effectiveWeekday(rows, DateTime(2026, 10, 1)), isNull);
    // 其他日期不受影响
    expect(effectiveWeekday(rows, DateTime(2026, 10, 2)), 5);
  });

  test('补课按指定星期', () {
    // 10/11 是周日，补周三（3）
    final rows = [_row(date: '2026-10-11', kind: 'makeup', weekday: 3)];
    expect(effectiveWeekday(rows, DateTime(2026, 10, 11)), 3);
  });

  test('备注与标签', () {
    expect(overrideLabel(_row(date: '2026-10-01', kind: 'off', note: '国庆假期')),
        '国庆假期');
    expect(overrideLabel(_row(date: '2026-10-11', kind: 'makeup', weekday: 3, note: '')),
        '补周三的课');
  });
}
