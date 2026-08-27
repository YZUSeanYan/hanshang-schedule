import 'package:flutter_test/flutter_test.dart';
import 'package:yzu_schedule/features/course_import/data/llm_import_repository.dart';
import 'package:yzu_schedule/core/utils/week_calculator.dart';
import 'package:yzu_schedule/import/yzu_parser.dart';

void main() {
  group('移动版 URP 索引字典结构（2026-08-23 真实失败案例还原）', () {
    test('xkxx 列表套按课程号索引的大字典可解析，周次继承到时间段', () {
      const body = '{"rwbgLists":[],"allUnits":2.0,"xkxx":[{"21031003_01":{'
          '"courseName":"毛泽东思想和中国特色社会主义理论体系概论",'
          '"attendClassTeacher":"邓雪莉","skzcs":"1-18","unit":3.0,'
          '"timeAndPlaceList":[{"id":{"skxq":"4","skjc":"9","cxjc":"2"},'
          '"skdd":"扬子津东校区文津楼E206"}]}}]}';

      final courses = YzuParser.tryParseJson(body);

      expect(courses, isNotNull);
      expect(courses!.single.name, '毛泽东思想和中国特色社会主义理论体系概论');
      expect(courses.single.teacher, '邓雪莉');
      final slot = courses.single.slots.single;
      expect(slot.dayOfWeek, 4);
      expect((slot.startSection, slot.endSection), (9, 10));
      expect(slot.weeksText, '1-18');
      expect(slot.customWeeks.first, 1);
      expect(slot.customWeeks.last, 18);
      expect(slot.location, '扬子津东校区文津楼E206');
    });
  });

  group('selectHtmlDocument', () {
    test('选取内容最多的文档（iframe 往往比主页面包含有用课表）', () {
      final capture = {
        'html': '<html>短</html>',
        'frames': [
          {'html': '<html><table>很长的课表内容xxxxxxxxxxxxxxxxxx</table></html>'},
          {'html': ''},
          'not-a-map',
        ],
      };
      expect(
        LlmImportRepository.selectHtmlDocument(capture),
        '<html><table>很长的课表内容xxxxxxxxxxxxxxxxxx</table></html>',
      );
    });

    test('没有可用文档时返回 null', () {
      expect(LlmImportRepository.selectHtmlDocument({'captured': []}), isNull);
      expect(
        LlmImportRepository.selectHtmlDocument({'html': '', 'frames': []}),
        isNull,
      );
    });
  });

  group('collectCapturedBodies', () {
    test('只收集非空字符串 body', () {
      final capture = {
        'captured': [
          {'body': '{"kcmc":"高数"}'},
          {'body': ''},
          {'body': 123},
          'garbage',
        ],
      };
      expect(
        LlmImportRepository.collectCapturedBodies(capture),
        ['{"kcmc":"高数"}'],
      );
    });
  });

  group('mapCoursesResponse', () {
    test('标准契约映射为 ParsedCourse，周次文本展开为 customWeeks', () {
      final courses = LlmImportRepository.mapCoursesResponse([
        {
          'name': '大学物理Ⅳ',
          'teacher': '熊国欢',
          'slots': [
            {
              'day_of_week': 2,
              'start_section': 1,
              'end_section': 2,
              'weeks_text': '1-16周(单)',
              'location': '文津楼101',
            },
          ],
        },
      ]);

      expect(courses, hasLength(1));
      expect(courses.single.name, '大学物理Ⅳ');
      final slot = courses.single.slots.single;
      expect(slot.dayOfWeek, 2);
      expect(slot.weeksType, WeeksType.custom);
      expect(slot.customWeeks, [1, 3, 5, 7, 9, 11, 13, 15]);
      expect(slot.weeksText, '1-16周(单)');
    });

    test('丢弃越界/倒置的 slot 与无 slot 的课程', () {
      final courses = LlmImportRepository.mapCoursesResponse([
        {
          'name': '坏课',
          'teacher': '',
          'slots': [
            {'day_of_week': 9, 'start_section': 1, 'end_section': 2},
            {'day_of_week': 1, 'start_section': 5, 'end_section': 3},
          ],
        },
        {
          'name': '好课',
          'teacher': '王老师',
          'slots': [
            {'day_of_week': 1, 'start_section': 1, 'end_section': 2},
          ],
        },
        'garbage',
        {'teacher': '没有课名'},
      ]);

      expect(courses, hasLength(1));
      expect(courses.single.name, '好课');
      // 缺省 weeks_text 视为每周
      expect(courses.single.slots.single.weeksType, WeeksType.every);
    });
  });
}
