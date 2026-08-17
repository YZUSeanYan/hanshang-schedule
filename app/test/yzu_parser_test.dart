import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:yzu_schedule/core/utils/week_calculator.dart';
import 'package:yzu_schedule/import/yzu_parser.dart';

/// 教务课表解析器单测（设计文档阶段 3 验收要求）。
///
/// 覆盖三类输入：
/// 1. JSON 接口嗅探（多种字段方言）；
/// 2. HTML 表格兜底；
/// 3. 周次文本解析（单双周、区间、混合）。
void main() {
  group('parseWeeksText 周次文本解析', () {
    test('空文本 → 每周', () {
      final (type, weeks) = YzuParser.parseWeeksText('');
      expect(type, WeeksType.every);
      expect(weeks, isEmpty);
    });

    test('普通区间展开', () {
      final (type, weeks) = YzuParser.parseWeeksText('1-16周');
      expect(type, WeeksType.custom);
      expect(weeks.length, 16);
      expect(weeks.first, 1);
      expect(weeks.last, 16);
    });

    test('单周区间只留单数周', () {
      final (type, weeks) = YzuParser.parseWeeksText('1-15周单');
      expect(type, WeeksType.custom);
      expect(weeks, [1, 3, 5, 7, 9, 11, 13, 15]);
    });

    test('双周区间只留双数周', () {
      final (type, weeks) = YzuParser.parseWeeksText('2-16周双');
      expect(type, WeeksType.custom);
      expect(weeks, [2, 4, 6, 8, 10, 12, 14, 16]);
    });

    test('单双周文本在前也能识别', () {
      final (type, weeks) = YzuParser.parseWeeksText('单周1-15');
      expect(type, WeeksType.custom);
      expect(weeks, [1, 3, 5, 7, 9, 11, 13, 15]);
    });

    test('逗号与区间混合', () {
      final (type, weeks) = YzuParser.parseWeeksText('1,3,5-7周');
      expect(type, WeeksType.custom);
      expect(weeks, [1, 3, 5, 6, 7]);
    });

    test('只有"单周"无范围 → odd 类型', () {
      final (type, _) = YzuParser.parseWeeksText('单周');
      expect(type, WeeksType.odd);
    });

    test('只有"双周"无范围 → even 类型', () {
      final (type, _) = YzuParser.parseWeeksText('双周');
      expect(type, WeeksType.even);
    });

    test('全角分隔符也能解析', () {
      final (type, weeks) = YzuParser.parseWeeksText('1、3，5—7周');
      expect(type, WeeksType.custom);
      expect(weeks, [1, 3, 5, 6, 7]);
    });
  });

  group('tryParseJson 接口嗅探', () {
    test('正方风格字段方言', () {
      const body = '''
      {"code": 0, "data": {"kbList": [
        {"kcmc": "高等数学A", "jsxm": "张三", "jxcdm": "文汇楼203",
         "xqj": "1", "jcs": "1-2", "zcd": "1-16周"},
        {"kcmc": "高等数学A", "jsxm": "张三", "jxcdm": "文汇楼203",
         "xqj": "3", "jcs": "3-4", "zcd": "1-16周"},
        {"kcmc": "大学英语", "jsxm": "李四", "jxcdm": "中心楼A101",
         "xqj": "2", "jcs": "5-6", "zcd": "1-15周单"}
      ]}}
      ''';
      final courses = YzuParser.tryParseJson(body);
      expect(courses, isNotNull);
      expect(courses!.length, 2);

      final math = courses.firstWhere((c) => c.name == '高等数学A');
      expect(math.teacher, '张三');
      expect(math.slots.length, 2);
      expect(math.slots.first.dayOfWeek, 1);
      expect(math.slots.first.startSection, 1);
      expect(math.slots.first.endSection, 2);

      final eng = courses.firstWhere((c) => c.name == '大学英语');
      expect(eng.slots.single.weeksType, WeeksType.custom);
      expect(eng.slots.single.customWeeks, [1, 3, 5, 7, 9, 11, 13, 15]);
    });

    test('嵌套在更深层级的课程列表也能找到', () {
      const body = '''
      {"result": {"body": {"items": {"rows": [
        {"courseName": "操作系统", "teacherName": "王五",
         "roomName": "信息馆301", "weekDay": 5,
         "startSection": 7, "endSection": 8, "weeks": "2-16周双"}
      ]}}}}
      ''';
      final courses = YzuParser.tryParseJson(body);
      expect(courses, isNotNull);
      expect(courses!.single.name, '操作系统');
      expect(courses.single.slots.single.dayOfWeek, 5);
      expect(courses.single.slots.single.customWeeks,
          [2, 4, 6, 8, 10, 12, 14, 16]);
    });

    test('扬大 URP classCurriculum 接口字段', () {
      // 字段来自真实课表页 fillCourseTable(courseInfo) 的页面脚本：
      // 星期/起始节次位于 id 中，cxjc 表示连续节数，地点拆成三段。
      const body = '''
      [[
        {"id":{"skxq":2,"skjc":1,"kch":"21092107","kxh":"02"},
         "kcm":"大学物理Ⅳ","jsm":"熊国欢","zcsm":"1-16周","cxjc":2,
         "xqm":"扬子津东校区","jxlm":"文津楼","jasm":"101"},
        {"id":{"skxq":4,"skjc":1,"kch":"21092107","kxh":"02"},
         "kcm":"大学物理Ⅳ","jsm":"熊国欢","zcsm":"1-16周","cxjc":2,
         "xqm":"扬子津东校区","jxlm":"文津楼","jasm":"101"}
      ]]
      ''';

      final courses = YzuParser.tryParseJson(body);
      expect(courses, isNotNull);
      expect(courses, hasLength(1));
      expect(courses!.single.name, '大学物理Ⅳ');
      expect(courses.single.teacher, '熊国欢');
      expect(courses.single.slots, hasLength(2));
      expect(courses.single.slots.first.dayOfWeek, 2);
      expect(courses.single.slots.first.startSection, 1);
      expect(courses.single.slots.first.endSection, 2);
      expect(courses.single.slots.first.weeksText, '1-16周');
      expect(courses.single.slots.first.location, '扬子津东校区文津楼101');
    });

    test('扬大本学期课表 selectCourseList 嵌套时间地点字段', () {
      const body = '''
      {
        "dateList": [{
          "programPlanName": "本科培养方案",
          "selectCourseList": [{
            "courseName": "大学物理Ⅳ",
            "attendClassTeacher": "熊老师",
            "timeAndPlaceList": [
              {
                "classDay": 2,
                "classSessions": 1,
                "continuingSession": 2,
                "weekDescription": "1-16周",
                "campusName": "扬子津东校区",
                "teachingBuildingName": "文津楼",
                "classroomName": "101"
              },
              {
                "classDay": 4,
                "classSessions": 3,
                "continuingSession": 2,
                "weekDescription": "1-16周",
                "campusName": "扬子津东校区",
                "teachingBuildingName": "文津楼",
                "classroomName": "203"
              }
            ]
          }]
        }]
      }
      ''';

      final courses = YzuParser.tryParseJson(body);
      expect(courses, isNotNull);
      expect(courses, hasLength(1));
      expect(courses!.single.name, '大学物理Ⅳ');
      expect(courses.single.teacher, '熊老师');
      expect(courses.single.slots, hasLength(2));
      expect(courses.single.slots.first.dayOfWeek, 2);
      expect(courses.single.slots.first.startSection, 1);
      expect(courses.single.slots.first.endSection, 2);
      expect(courses.single.slots.first.weeksText, '1-16周');
      expect(courses.single.slots.first.location, '扬子津东校区文津楼101');
    });

    test('星期中文字符串', () {
      const body = '''
      [{"name": "体育", "teacher": "赵六", "day": "周三",
        "sections": "9-10", "weeksText": "1-16周"}]
      ''';
      final courses = YzuParser.tryParseJson(body);
      expect(courses, isNotNull);
      expect(courses!.single.slots.single.dayOfWeek, 3);
    });

    test('非课表 JSON 返回 null', () {
      expect(YzuParser.tryParseJson('{"code":0,"msg":"ok"}'), isNull);
      expect(YzuParser.tryParseJson('[{"a":1}]'), isNull);
      expect(YzuParser.tryParseJson('not json at all'), isNull);
    });
  });

  group('parseCapture 主入口', () {
    test('优先命中 JSON 接口', () {
      final result = YzuParser.parseCapture({
        'url': 'https://jw.example/student/schedule',
        'title': '我的课表',
        'captured': [
          {'url': 'https://jw.example/api/kb', 'body': '{"a":1}'},
          {
            'url': 'https://jw.example/api/kbList',
            'body':
                '[{"kcmc":"线性代数","jsxm":"钱七","xqj":"4","jcs":"1-2","zcd":"1-16周"}]'
          },
        ],
        'html': '<html><body>无表格</body></html>',
      });
      expect(result.isSuccess, isTrue);
      expect(result.source, 'json');
      expect(result.courses.single.name, '线性代数');
    });

    test('JSON 全部失败时回退 HTML 表格', () {
      final result = YzuParser.parseCapture({
        'captured': [
          {'url': 'https://jw.example/api/other', 'body': '{"x":1}'}
        ],
        'html': '''
        <table>
          <tr><th>节次</th><th>周一</th><th>周二</th><th>周三</th>
              <th>周四</th><th>周五</th><th>周六</th><th>周日</th></tr>
          <tr>
            <td>1-2节</td>
            <td>高等数学A
张三
1-16周[1-2节]
文汇楼203</td>
            <td></td><td></td>
            <td>大学英语  李四  1-16周  [3-4节]  中心楼A101</td>
            <td></td><td></td><td></td>
          </tr>
        </table>
        ''',
      });
      expect(result.isSuccess, isTrue);
      expect(result.source, 'html');
      expect(result.courses.length, 2);
      final math = result.courses.firstWhere((c) => c.name == '高等数学A');
      expect(math.slots.single.dayOfWeek, 1);
      expect(math.slots.single.location, '文汇楼203');
      final eng = result.courses.firstWhere((c) => c.name == '大学英语');
      expect(eng.slots.single.dayOfWeek, 4);
      expect(eng.teacher, '李四');
    });

    test('都识别不了时返回诊断信息', () {
      final result = YzuParser.parseCapture({
        'url': 'https://jw.example/schedule?token=secret-token',
        'title': '移动课表',
        'captured': const [],
        'html': '<html><body><iframe id="mobile-kb"></iframe></body></html>',
      });
      expect(result.isSuccess, isFalse);
      expect(result.source, 'none');
      expect(result.detail, contains('抓取诊断 v2'));
      expect(result.detail, contains('iframe#mobile-kb'));
      expect(result.detail, isNot(contains('secret-token')));
    });

    test('同源 iframe HTML 可以被解析', () {
      final result = YzuParser.parseCapture({
        'captured': const [],
        'html': '<html><body><iframe id="kb"></iframe></body></html>',
        'frames': [
          {
            'url': 'https://jw.example/mobile/schedule',
            'title': '移动课表',
            'html': '''
              <table>
                <tr><th>节次</th><th>周一</th><th>周二</th><th>周三</th>
                    <th>周四</th><th>周五</th></tr>
                <tr><td>1-2节</td><td>高等数学\n张三\n1-16周[1-2节]\n文汇楼203</td>
                    <td></td><td></td><td></td><td></td></tr>
              </table>
            ''',
          }
        ],
      });

      expect(result.isSuccess, isTrue);
      expect(result.source, 'html');
      expect(result.detail, contains('iframe 1'));
      expect(result.courses.single.name, '高等数学');
    });

    test('移动版 course-item data-course 可以被解析', () {
      final result = YzuParser.parseCapture({
        'captured': const [],
        'html': '''
          <table><tr><td id="cell_3_1">
            <div class="course-item div-kcb-4"
              data-course="{&quot;courseName&quot;:&quot;流体热力学&quot;,
                &quot;teacherName&quot;:&quot;李老师&quot;,
                &quot;weekDescription&quot;:&quot;1-4周&quot;,
                &quot;day&quot;:&quot;星期三&quot;,
                &quot;time&quot;:&quot;第1-2节&quot;,
                &quot;campusName&quot;:&quot;扬子津东校区&quot;,
                &quot;buildingName&quot;:&quot;文津楼&quot;,
                &quot;roomName&quot;:&quot;202&quot;}">
              <strong>流体热力学</strong>
            </div>
          </td></tr></table>
        ''',
      });

      expect(result.isSuccess, isTrue);
      expect(result.source, 'html');
      expect(result.detail, contains('移动课表结构'));
      expect(result.courses.single.name, '流体热力学');
      expect(result.courses.single.teacher, '李老师');
      expect(result.courses.single.slots.single.dayOfWeek, 3);
      expect(result.courses.single.slots.single.startSection, 1);
      expect(result.courses.single.slots.single.endSection, 2);
      expect(result.courses.single.slots.single.customWeeks, [1, 2, 3, 4]);
      expect(result.courses.single.slots.single.location, '扬子津东校区文津楼202');
    });

    test('失败诊断只输出 JSON 字段形状，不泄露字段值', () {
      final detail = YzuParser.buildCaptureDiagnostic({
        'url': 'https://jw.example/mobile?k=v',
        'title': '课表',
        'html': '<main class="mobile-schedule"></main>',
        'captured': [
          {
            'url': 'https://jw.example/api/list?ticket=secret-ticket',
            'body':
                '{"password":"secret-password","rows":[{"kcm":"秘密课程","skxq":2}]}'
          }
        ],
      });

      expect(detail, contains('password'));
      expect(detail, contains('kcm'));
      expect(detail, contains('skxq'));
      expect(detail, isNot(contains('secret-password')));
      expect(detail, isNot(contains('秘密课程')));
      expect(detail, isNot(contains('secret-ticket')));
    });
  });

  group('真实样本回归（docs/samples/班级课表.html）', () {
    // 扬大教务真实课表页面（2026-08 用户提供），预期：
    // 13 个课程块 → 聚合为 8 门课（流体热力学因教师顺序不同拆成 2 条）
    late final String sampleHtml;

    setUpAll(() {
      sampleHtml = File('../docs/samples/班级课表.html').readAsStringSync();
    });

    test('扬大专属结构解析出 8 门课 13 个时间段', () {
      final courses = YzuParser.parseYzuCourseTable(sampleHtml);
      expect(courses.length, 8);
      final totalSlots = courses.fold<int>(0, (sum, c) => sum + c.slots.length);
      expect(totalSlots, 13);
    });

    test('大学物理Ⅳ：课名去课序号、教师取竖线右侧、多时间段聚合', () {
      final courses = YzuParser.parseYzuCourseTable(sampleHtml);
      final phy = courses.firstWhere((c) => c.name == '大学物理Ⅳ');
      expect(phy.teacher, '熊国欢');
      expect(phy.slots.length, 2);
      expect(phy.slots.map((s) => s.dayOfWeek), containsAll([2, 4]));
      expect(phy.slots.first.startSection, 1);
      expect(phy.slots.first.endSection, 2);
      expect(phy.slots.first.location, '扬子津东校区文津楼101');
      expect(phy.slots.first.weeksType, WeeksType.custom);
      expect(phy.slots.first.customWeeks.length, 16);
    });

    test('形势与政策-3：7-8周 展开为自定义周次 [7, 8]', () {
      final courses = YzuParser.parseYzuCourseTable(sampleHtml);
      final course = courses.firstWhere((c) => c.name == '形势与政策-3');
      expect(course.slots.single.weeksType, WeeksType.custom);
      expect(course.slots.single.customWeeks, [7, 8]);
      expect(course.slots.single.dayOfWeek, 1);
      expect(course.slots.single.startSection, 9);
    });

    test('parseCapture 走 HTML 通道也能命中真实样本', () {
      final result = YzuParser.parseCapture({
        'url': 'https://webvpn.yzu.edu.cn/.../classCurriculum/index',
        'title': '班级课表',
        'captured': const [],
        'html': sampleHtml,
      });
      expect(result.isSuccess, isTrue);
      expect(result.source, 'html');
      expect(result.courses.length, 8);
    });
  });
}
