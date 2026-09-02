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

  group('stripIdentityInfo（合规红线：姓名/学号不出设备）', () {
    test('抹除标签式与 JSON 式身份信息，课程数据不受影响', () {
      const raw = '<div>姓名：张三</div><div>学号: 2113401234</div>'
          '{"xm":"李四","xh":"2113401234","kcmc":"高等数学","name":"高等数学"}'
          '联系电话 13800001111';
      final stripped = stripIdentityInfo(raw);

      expect(stripped.contains('张三'), isFalse);
      expect(stripped.contains('李四'), isFalse);
      expect(stripped.contains('2113401234'), isFalse);
      expect(stripped.contains('13800001111'), isFalse);
      // 课程名与通用 name 键（课程名）必须保留
      expect('高等数学'.allMatches(stripped).length, 2);
      expect(stripped.contains('"kcmc":"高等数学"'), isTrue);
    });

    test('标签与值分处相邻单元格时也能抹除', () {
      const raw = '<tr><td>姓名</td><td>王五</td></tr>'
          '<tr><td>学号</td><td>2098012345</td></tr>';
      final stripped = stripIdentityInfo(raw);
      expect(stripped.contains('王五'), isFalse);
      expect(stripped.contains('2098012345'), isFalse);
    });

    test('8 位以内课程代码、周次、节次原样保留', () {
      const raw = '高等数学 1-16周 第1-2节 文津楼N107 10021001 2026-2027';
      expect(stripIdentityInfo(raw), raw);
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
