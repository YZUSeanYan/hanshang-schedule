import 'package:flutter_test/flutter_test.dart';
import 'package:yzu_schedule/core/settings/section_time_settings.dart';
import 'package:yzu_schedule/features/schedule/data/event_repository.dart';

void main() {
  const config = SectionTimeConfig.defaults();
  // 2026-09-16（周三）属春夏季作息：6 节 14:30-15:15，7 节 15:25-16:10，
  // 8 节 16:20-17:05，9 节 17:15-18:00
  final date = DateTime(2026, 9, 16);

  group('computeBusySections', () {
    test('节次表达直接展开', () {
      expect(
        computeBusySections(
          startSection: 3,
          endSection: 4,
          startTime: '',
          endTime: '',
          config: config,
          referenceDate: date,
        ),
        [3, 4],
      );
    });

    test('时刻表达按作息求交集（15:30-17:30 → 7,8,9 节）', () {
      expect(
        computeBusySections(
          startSection: 0,
          endSection: 0,
          startTime: '15:30',
          endTime: '17:30',
          config: config,
          referenceDate: date,
        ),
        [7, 8, 9],
      );
    });

    test('擦边不算占用（14:00-14:30 恰好避开 14:30 开始的第 6 节）', () {
      expect(
        computeBusySections(
          startSection: 0,
          endSection: 0,
          startTime: '13:50',
          endTime: '14:30',
          config: config,
          referenceDate: date,
        ),
        isEmpty,
      );
    });

    test('DDL 无时间不占节次', () {
      expect(
        computeBusySections(
          startSection: 0,
          endSection: 0,
          startTime: '',
          endTime: '',
          config: config,
          referenceDate: date,
        ),
        isEmpty,
      );
    });

    test('结束早于开始视为无效', () {
      expect(
        computeBusySections(
          startSection: 0,
          endSection: 0,
          startTime: '17:30',
          endTime: '15:30',
          config: config,
          referenceDate: date,
        ),
        isEmpty,
      );
    });
  });

  group('parseBusySections', () {
    test('解析、去重、排序、过滤越界', () {
      expect(parseBusySections('10,8,9,8,0,13,31,abc'), [8, 9, 10]);
      expect(parseBusySections(''), isEmpty);
    });
  });

  group('eventStartMinutes', () {
    test('时刻优先，其次节次查表', () {
      expect(
        SectionTimeConfig.minutes('15:30'),
        15 * 60 + 30,
      );
      expect(SectionTimeConfig.minutes('25:00'), isNull);
    });
  });
}
