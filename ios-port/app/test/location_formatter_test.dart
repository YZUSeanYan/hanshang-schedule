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
}
