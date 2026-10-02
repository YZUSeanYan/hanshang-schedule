import 'package:flutter_test/flutter_test.dart';
import 'package:yzu_schedule/core/utils/location_formatter.dart';

void main() {
  group('formatCourseLocation', () {
    test('moves building and room before a concatenated campus', () {
      expect(
        formatCourseLocation('@扬子津东校区文经楼N202'),
        '文经楼N202 · 扬子津东校区',
      );
    });

    test('moves room-like segment before campus across separators', () {
      expect(
        formatCourseLocation('扬子津西校区@文津楼101'),
        '文津楼101 · 扬子津西校区',
      );
      expect(
        formatCourseLocation('文汇楼201@荷花池校区'),
        '文汇楼201 · 荷花池校区',
      );
    });

    test('keeps simple locations and handles empty input', () {
      expect(formatCourseLocation('瘦西湖校区'), '瘦西湖校区');
      expect(formatCourseLocation('  '), '');
    });

    test('reorders arrow-separated campus>>building>>room text', () {
      expect(
        formatCourseLocation('扬子津东校区>>文津楼>>N204'),
        '文津楼N204 · 扬子津东校区',
      );
      expect(
        formatCourseLocation('扬子津东校区>>文津楼>>101'),
        '文津楼101 · 扬子津东校区',
      );
      expect(
        formatCourseLocation('荷花池校区>>教学楼>>E206'),
        '教学楼E206 · 荷花池校区',
      );
      expect(
        formatCourseLocation('瘦西湖校区>>昭文馆'),
        '昭文馆 · 瘦西湖校区',
      );
      expect(
        formatCourseLocation('扬子津东校区→→文津楼→→N204'),
        '文津楼N204 · 扬子津东校区',
      );
    });
  });

  group('parseCourseLocation', () {
    test('splits arrow-separated campus>>building>>room', () {
      final parts = parseCourseLocation('扬子津东校区>>文津楼>>N204');
      expect(parts.campus, '扬子津东校区');
      expect(parts.building, '文津楼');
      expect(parts.room, 'N204');
      expect(parts.formatted, '文津楼N204 · 扬子津东校区');
    });

    test('splits concatenated campus+building+room', () {
      final parts = parseCourseLocation('@扬子津东校区文经楼N202');
      expect(parts.campus, '扬子津东校区');
      expect(parts.building, '文经楼');
      expect(parts.room, 'N202');
    });

    test('splits building+room without campus', () {
      final parts = parseCourseLocation('文津楼101');
      expect(parts.campus, '');
      expect(parts.building, '文津楼');
      expect(parts.room, '101');
    });

    test('room-only location keeps room prominent', () {
      final parts = parseCourseLocation('E206');
      expect(parts.room, 'E206');
      expect(parts.building, '');
    });

    test('building-only location has no room', () {
      final parts = parseCourseLocation('瘦西湖校区>>昭文馆');
      expect(parts.campus, '瘦西湖校区');
      expect(parts.building, '昭文馆');
      expect(parts.room, '');
    });

    test('already-formatted string with campus suffix parses structurally', () {
      // 分享/网页端写回的展示格式：「文津楼N204 · 扬子津东校区」
      final parts = parseCourseLocation('文津楼N204 · 扬子津东校区');
      expect(parts.campus, '扬子津东校区');
      expect(parts.building, '文津楼');
      expect(parts.room, 'N204');
    });

    test('free-form location falls back to formatted string', () {
      final parts = parseCourseLocation('线上课程');
      expect(parts.room, '');
      expect(parts.building, '');
      expect(parts.formatted, '线上课程');
    });

    test('empty input stays empty', () {
      expect(parseCourseLocation('  ').isEmpty, isTrue);
    });
  });
}
