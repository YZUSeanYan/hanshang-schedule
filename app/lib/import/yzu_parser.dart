/// 扬大教务课表解析器（设计文档 4.2 要求的独立模块）。
///
/// 纯函数、无 UI 依赖：输入"原始 HTML/JSON 字符串"，输出"标准课程列表"。
/// 扬大教务改版时原则上只需修改本文件。
///
/// 解析策略（按优先级）：
/// 1. JSON 嗅探：从抓包到的接口响应里找课程列表（多厂商字段方言映射）；
/// 2. HTML 表格兜底：解析服务端渲染的课表表格。
library;

import 'dart:convert';

import 'package:html/parser.dart' as html_parser;

import '../core/utils/week_calculator.dart';

/// 标准课程模型：一门课 + 若干时间段
class ParsedCourse {
  ParsedCourse({required this.name, this.teacher = '', List<ParsedSlot>? slots})
      : slots = slots ?? [];

  final String name;
  final String teacher;
  final List<ParsedSlot> slots;

  @override
  String toString() => 'ParsedCourse($name, $teacher, ${slots.length}个时间段)';
}

/// 标准时间段模型
class ParsedSlot {
  ParsedSlot({
    required this.dayOfWeek, // 1=周一 ... 7=周日
    required this.startSection,
    required this.endSection,
    required this.weeksType,
    this.customWeeks = const [],
    this.location = '',
    this.weeksText = '', // 原始周次文本，用于详情展示
  });

  final int dayOfWeek;
  final int startSection;
  final int endSection;
  final WeeksType weeksType;
  final List<int> customWeeks;
  final String location;
  final String weeksText;
}

/// 解析结果
class ParseResult {
  ParseResult({
    required this.courses,
    required this.source,
    required this.detail,
  });

  final List<ParsedCourse> courses;

  /// 命中来源：json（接口嗅探）/ html（表格解析）/ none（失败）
  final String source;

  /// 诊断信息（失败时给用户和开发者看）
  final String detail;

  bool get isSuccess => courses.isNotEmpty;
}

class YzuParser {
  YzuParser._();

  // ==================== 主入口 ====================

  /// 解析 WebView 抓取包：{url, title, captured: [{type,url,body}], html}
  static ParseResult parseCapture(Map<String, dynamic> capture) {
    // 1. 优先：JSON 接口嗅探
    final captured = (capture['captured'] as List?) ?? const [];
    final failures = <String>[];
    for (final resp in captured) {
      if (resp is! Map) continue;
      final body = resp['body'];
      if (body is! String || body.isEmpty) continue;
      final result = tryParseJson(body);
      if (result != null) {
        return ParseResult(
          courses: result,
          source: 'json',
          detail: '命中接口：${resp['url'] ?? '未知'}，解析出 ${result.length} 门课',
        );
      }
    }
    failures.add('嗅探到 ${captured.length} 个接口响应，均未识别出课程结构');

    // 2. 兜底：HTML 解析（主页面 + WebVPN/移动版的同源 iframe）
    final htmlSources = <({String label, String html})>[];
    final mainHtml = capture['html'];
    if (mainHtml is String && mainHtml.isNotEmpty) {
      htmlSources.add((label: '主页面', html: mainHtml));
    }
    final frames = (capture['frames'] as List?) ?? const [];
    for (var i = 0; i < frames.length; i++) {
      final frame = frames[i];
      if (frame is! Map) continue;
      final html = frame['html'];
      if (html is String && html.isNotEmpty) {
        htmlSources.add((label: 'iframe ${i + 1}', html: html));
      }
    }

    for (final source in htmlSources) {
      final yzuCourses = parseYzuCourseTable(source.html);
      if (yzuCourses.isNotEmpty) {
        return ParseResult(
          courses: yzuCourses,
          source: 'html',
          detail: '在${source.label}命中扬大教务课表结构，解析出 ${yzuCourses.length} 门课',
        );
      }
      final mobileCourses = parseMobileCourseCards(source.html);
      if (mobileCourses.isNotEmpty) {
        return ParseResult(
          courses: mobileCourses,
          source: 'html',
          detail: '在${source.label}命中扬大移动课表结构，解析出 ${mobileCourses.length} 门课',
        );
      }
      final courses = parseHtmlTable(source.html);
      if (courses.isNotEmpty) {
        return ParseResult(
          courses: courses,
          source: 'html',
          detail: '从${source.label}表格解析出 ${courses.length} 门课',
        );
      }
    }
    failures.add('检查 ${htmlSources.length} 个 HTML 文档，均未找到课表结构');
    failures.add(buildCaptureDiagnostic(capture));

    return ParseResult(
      courses: const [],
      source: 'none',
      detail: failures.join('；'),
    );
  }

  /// 生成可复制的失败诊断。只保留 URL 路径、DOM 选择器和 JSON 字段形状，
  /// 不包含查询参数、Cookie、密码、token 或接口字段的实际值。
  static String buildCaptureDiagnostic(Map<String, dynamic> capture) {
    final frames = (capture['frames'] as List?) ?? const [];
    final lines = <String>[
      '抓取诊断 v2',
      '页面标题：${capture['title'] ?? ''}',
      '页面 URL：${_safeUrl(capture['url'])}',
      '同源 iframe：${frames.length} 个',
    ];

    final htmlSources = <String>[];
    final mainHtml = capture['html'];
    if (mainHtml is String) htmlSources.add(mainHtml);
    for (final frame in frames) {
      if (frame is Map && frame['html'] is String) {
        htmlSources.add(frame['html'] as String);
      }
    }
    for (var i = 0; i < htmlSources.length; i++) {
      final document = html_parser.parse(htmlSources[i]);
      final selectors = document
          .querySelectorAll('[id], [class]')
          .map(_selectorOf)
          .where((value) => value.isNotEmpty)
          .toSet()
          .take(40)
          .join(', ');
      lines.add('HTML ${i + 1}：${htmlSources[i].length} 字符；$selectors');
    }

    final captured = (capture['captured'] as List?) ?? const [];
    lines.add('捕获响应：${captured.length} 个');
    for (var i = 0; i < captured.length && i < 10; i++) {
      final response = captured[i];
      if (response is! Map) continue;
      final body = response['body'];
      lines.add('响应 ${i + 1}：${_safeUrl(response['url'])}，'
          '${body is String ? body.length : 0} 字符');
      if (body is String) {
        lines.add('字段形状：${_describeBodyShape(body)}');
      }
    }
    return lines.join('\n');
  }

  static String _safeUrl(Object? raw) {
    final value = '$raw';
    final uri = Uri.tryParse(value);
    if (uri == null) return value.split('?').first.split('#').first;
    if (!uri.hasScheme || uri.host.isEmpty) {
      return value.split('?').first.split('#').first;
    }
    return Uri(
      scheme: uri.scheme,
      host: uri.host,
      port: uri.hasPort ? uri.port : null,
      path: uri.path,
    ).toString();
  }

  static String _selectorOf(dynamic element) {
    final tag = '${element.localName ?? ''}';
    final id = element.attributes['id'] as String?;
    final classValue = '${element.attributes['class'] ?? ''}';
    final classes = classValue
        .split(RegExp(r'\s+'))
        .where((value) => value.isNotEmpty)
        .take(3)
        .join('.');
    return '$tag${id == null || id.isEmpty ? '' : '#$id'}'
        '${classes.isEmpty ? '' : '.$classes'}';
  }

  static String _describeBodyShape(String body) {
    try {
      return jsonEncode(_jsonShape(jsonDecode(body), 0));
    } catch (_) {
      final document = html_parser.parse(body);
      return document
          .querySelectorAll('[id], [class]')
          .map(_selectorOf)
          .where((value) => value.isNotEmpty)
          .toSet()
          .take(20)
          .join(', ');
    }
  }

  static Object? _jsonShape(Object? node, int depth) {
    if (depth >= 5) return node.runtimeType.toString();
    if (node is Map) {
      final result = <String, Object?>{};
      for (final entry in node.entries.take(40)) {
        result['${entry.key}'] = _jsonShape(entry.value, depth + 1);
      }
      if (node.length > 40) result['…'] = '${node.length - 40} more keys';
      return result;
    }
    if (node is List) {
      return {
        'type': 'List',
        'length': node.length,
        if (node.isNotEmpty) 'item': _jsonShape(node.first, depth + 1),
      };
    }
    if (node == null) return 'null';
    return node.runtimeType.toString();
  }

  // ==================== 策略 1：JSON 嗅探 ====================

  // 各教务厂商的字段方言（命中任一键名即识别）
  static const _nameKeys = [
    'kcmc',
    'kcm',
    'KCM',
    'courseName',
    'course_name',
    'kcName',
    'name',
    'title',
    'courseTitle'
  ];
  static const _teacherKeys = [
    'jsxm',
    'jsm',
    'JSXM',
    'teacherName',
    'attendClassTeacher',
    'teacher_name',
    'teacher',
    'jsmc',
    'teachers',
    'SKJS'
  ];
  static const _locationKeys = [
    'jxcdm',
    'jxcd',
    'roomName',
    'room_name',
    'location',
    'cdmc',
    'CDMC',
    'place',
    'room',
    'classroom',
    'jsmc_location',
    'skdd',
    'SKDD'
  ];
  static const _dayKeys = [
    'xqj',
    'skxq',
    'XQI',
    'weekDay',
    'week_day',
    'dayOfWeek',
    'classDay',
    'day',
    'xq',
    'xingqi'
  ];
  static const _sectionsKeys = [
    'jcs',
    'jcdm',
    'sections',
    'sectionText',
    'jc',
    'nodes',
    'jiec',
    'JC',
    'time'
  ];
  static const _startSectionKeys = [
    'startSection',
    'sectionStart',
    'start_section',
    'ksjc',
    'startNode',
    'classSessions'
  ];
  static const _endSectionKeys = [
    'endSection',
    'sectionEnd',
    'end_section',
    'jsjc',
    'endNode'
  ];
  static const _weeksKeys = [
    'zcd',
    'zcsm',
    'ZCD',
    'weeksText',
    'weeks',
    'zc',
    'skzc',
    'weekText',
    'zcs',
    'weekStr',
    'weekDescription'
  ];

  /// 尝试把一段 JSON 文本解析为课程列表；识别不了返回 null。
  static List<ParsedCourse>? tryParseJson(String body) {
    Object? decoded;
    try {
      decoded = jsonDecode(body);
    } catch (_) {
      return null;
    }
    final list = _findCourseList(decoded);
    if (list == null || list.isEmpty) return null;

    final courses = <String, ParsedCourse>{};
    for (final item in list) {
      final name = _pickString(item, _nameKeys);
      if (name == null || name.isEmpty) continue;
      final teacher = _pickString(item, _teacherKeys) ?? '';
      final nestedSlots = item['timeAndPlaceList'];
      var usedNestedSlots = false;
      if (nestedSlots is List) {
        for (final value in nestedSlots) {
          if (value is! Map<String, dynamic>) continue;
          usedNestedSlots = _appendJsonSlot(
                courses: courses,
                name: name,
                teacher: teacher,
                slot: value,
              ) ||
              usedNestedSlots;
        }
      }
      if (!usedNestedSlots) {
        _appendJsonSlot(
          courses: courses,
          name: name,
          teacher: teacher,
          slot: item,
        );
      }
    }
    return courses.isEmpty ? null : courses.values.toList();
  }

  static bool _appendJsonSlot({
    required Map<String, ParsedCourse> courses,
    required String name,
    required String teacher,
    required Map<String, dynamic> slot,
  }) {
    final day = _parseDay(slot);
    final sections = _parseSections(slot);
    if (day == null || sections == null) return false;

    final weeksText = _pickString(slot, _weeksKeys) ?? '';
    final (weeksType, customWeeks) = parseWeeksText(weeksText);
    final key = '$name|$teacher';
    final course = courses.putIfAbsent(
      key,
      () => ParsedCourse(name: name, teacher: teacher),
    );
    course.slots.add(ParsedSlot(
      dayOfWeek: day,
      startSection: sections.$1,
      endSection: sections.$2,
      weeksType: weeksType,
      customWeeks: customWeeks,
      location: _parseLocation(slot),
      weeksText: weeksText,
    ));
    return true;
  }

  /// 在 JSON 树里递归寻找"课程列表"：元素为 Map 且包含课程名键的 List。
  static List<Map<String, dynamic>>? _findCourseList(Object? node) {
    if (node is List) {
      if (node.isNotEmpty &&
          node.every((e) => e is Map<String, dynamic>) &&
          node.cast<Map<String, dynamic>>().any((m) =>
              _nameKeys.any(m.containsKey) &&
              (_parseDay(m) != null || _hasNestedSchedule(m)))) {
        return node.cast<Map<String, dynamic>>();
      }
      for (final e in node) {
        final found = _findCourseList(e);
        if (found != null) return found;
      }
    } else if (node is Map<String, dynamic>) {
      for (final v in node.values) {
        final found = _findCourseList(v);
        if (found != null) return found;
      }
    }
    return null;
  }

  static bool _hasNestedSchedule(Map<String, dynamic> item) {
    final values = item['timeAndPlaceList'];
    return values is List &&
        values.any((value) =>
            value is Map<String, dynamic> && _parseDay(value) != null);
  }

  static String? _pickString(Map<String, dynamic> map, List<String> keys) {
    for (final k in keys) {
      final v = map[k];
      if (v is String && v.trim().isNotEmpty) return v.trim();
      if (v is num) return v.toString();
    }
    return null;
  }

  /// 星期几：兼容 数字 / "3" / "周三" / "星期三"
  static int? _parseDay(Map<String, dynamic> item) {
    for (final fields in _itemAndIdFields(item)) {
      for (final k in _dayKeys) {
        final v = fields[k];
        if (v == null) continue;
        if (v is num && v >= 1 && v <= 7) return v.toInt();
        if (v is String) {
          final n = int.tryParse(v.trim());
          if (n != null && n >= 1 && n <= 7) return n;
          const cn = ['一', '二', '三', '四', '五', '六', '日'];
          for (var i = 0; i < cn.length; i++) {
            if (v.contains(cn[i])) return i + 1;
          }
        }
      }
    }
    return null;
  }

  /// 节次：兼容 "3,4" / "3-4" / [3,4] / 分开的 start/end 字段
  static (int, int)? _parseSections(Map<String, dynamic> item) {
    for (final k in _sectionsKeys) {
      final v = item[k];
      if (v == null) continue;
      if (v is List) {
        final nums = v.map((e) => int.tryParse('$e')).whereType<int>().toList();
        if (nums.isNotEmpty) {
          nums.sort();
          return (nums.first, nums.last);
        }
      }
      if (v is num) return (v.toInt(), v.toInt());
      if (v is String) {
        final nums =
            RegExp(r'\d+').allMatches(v).map((m) => int.parse(m[0]!)).toList();
        if (nums.isNotEmpty) {
          nums.sort();
          return (nums.first, nums.last);
        }
      }
    }
    // 开始/结束分字段
    final id = item['id'];
    final idFields =
        id is Map<String, dynamic> ? id : const <String, dynamic>{};
    final start = _pickNum(item, _startSectionKeys) ??
        _pickNum(idFields, [..._startSectionKeys, 'skjc']);
    final end =
        _pickNum(item, _endSectionKeys) ?? _pickNum(idFields, _endSectionKeys);
    if (start != null && end != null && end >= start) return (start, end);
    // 扬大 URP：id.skjc 是起始节次，cxjc 是连续节数。
    final count = _pickNum(
        item, const ['cxjc', 'continuingSession', 'sectionCount', 'duration']);
    if (start != null && count != null && count > 0) {
      return (start, start + count - 1);
    }
    return null;
  }

  static Iterable<Map<String, dynamic>> _itemAndIdFields(
      Map<String, dynamic> item) sync* {
    yield item;
    final id = item['id'];
    if (id is Map<String, dynamic>) yield id;
  }

  static String _parseLocation(Map<String, dynamic> item) {
    // 扬大 URP 的新旧页面都会把校区、教学楼、教室拆成三个字段。
    final splitLocation = const [
      ['xqm', 'campusName'],
      ['jxlm', 'teachingBuildingName', 'buildingName'],
      ['jasm', 'classroomName', 'roomName'],
    ]
        .map((keys) => _pickString(item, keys) ?? '')
        .where((part) => part.isNotEmpty)
        .join();
    if (splitLocation.isNotEmpty) return splitLocation;

    return _pickString(item, _locationKeys) ?? '';
  }

  static int? _pickNum(Map<String, dynamic> map, List<String> keys) {
    for (final k in keys) {
      final v = map[k];
      if (v is num) return v.toInt();
      if (v is String) {
        final n = int.tryParse(v.trim());
        if (n != null) return n;
      }
    }
    return null;
  }

  // ==================== 周次文本解析 ====================

  /// 解析周次文本（设计文档重点：单双周）：
  /// - "1-16周"        → 自定义展开 [1..16]
  /// - "1-15周单"/"单周1-15" → 自定义展开其中的单数周
  /// - "2-16周双"      → 自定义展开其中的双数周
  /// - "1,3,5-7周"     → 自定义 [1,3,5,6,7]
  /// - "单周"/"双周"（无范围）→ odd / even 类型
  /// - 空文本          → 每周
  static (WeeksType, List<int>) parseWeeksText(String raw) {
    final text = raw.replaceAll(RegExp(r'\s'), '');
    if (text.isEmpty) return (WeeksType.every, const []);

    final isOdd = text.contains('单');
    final isEven = text.contains('双');

    final weeks = <int>{};
    for (final m in RegExp(r'(\d+)(?:[-~—](\d+))?').allMatches(text)) {
      final a = int.parse(m[1]!);
      final b = m[2] != null ? int.parse(m[2]!) : a;
      for (var i = a; i <= b && i <= 60; i++) {
        weeks.add(i);
      }
    }
    final list = weeks.toList()..sort();

    if (list.isEmpty) {
      if (isOdd) return (WeeksType.odd, const []);
      if (isEven) return (WeeksType.even, const []);
      return (WeeksType.every, const []);
    }
    if (isOdd) {
      return (WeeksType.custom, list.where((w) => w.isOdd).toList());
    }
    if (isEven) {
      return (WeeksType.custom, list.where((w) => w.isEven).toList());
    }
    return (WeeksType.custom, list);
  }

  // ==================== 策略 2a：扬大教务课表页专属结构 ====================

  /// 扬大教务「班级课表 / 我的课表」页面结构（依据真实样本 2026-08 校准，
  /// 样本存 docs/samples/班级课表.html）：
  ///
  /// - 表格 #courseTable，单元格 td id = "{星期}_{起始小节}"（星期 1=周一）；
  /// - 每个课程是绝对定位的 div.class_div，内部 p 标签依次为：
  ///   p.p-kcm-*  课名（带课序号后缀，如 "大学物理Ⅳ_02"）
  ///   p.kcb_p_gray  教师行（"21092107 | 熊国欢"，竖线左侧是课程代码）
  ///   p.kcb_p_gray  周次行（"1-16周"）
  ///   p.kcb_p_gray  节次行（"1-2节"）
  ///   p.p-jxl-*  地点（"扬子津东校区文津楼101"）
  static List<ParsedCourse> parseYzuCourseTable(String html) {
    final document = html_parser.parse(html);
    final divs = document.querySelectorAll('div.class_div');
    if (divs.isEmpty) return [];

    final courses = <String, ParsedCourse>{};
    for (final div in divs) {
      // 星期从父级 td 的 id 取（"2_1" → 周二）；取不到就跳过
      final tdId = div.parent?.attributes['id'] ?? '';
      final idMatch = RegExp(r'^(\d)_(\d+)$').firstMatch(tdId);
      if (idMatch == null) continue;
      final day = int.parse(idMatch[1]!);
      if (day < 1 || day > 7) continue;

      String name = '';
      String teacher = '';
      String weeksText = '';
      (int, int)? sections;
      String location = '';

      for (final pTag in div.querySelectorAll('p')) {
        final cls = pTag.attributes['class'] ?? '';
        final text = pTag.text.trim();
        if (text.isEmpty) continue;
        if (cls.startsWith('p-kcm')) {
          name = text;
        } else if (cls.startsWith('p-jxl')) {
          location = text;
        } else if (cls.contains('kcb_p_gray')) {
          if (text.contains('|')) {
            // "课程代码 | 教师1,教师2"，只要竖线右侧
            teacher = text.split('|').last.trim();
          } else if (text.contains('周')) {
            weeksText = text;
          } else {
            final m =
                RegExp(r'(\d{1,2})\s*[-~—]\s*(\d{1,2})\s*节').firstMatch(text);
            if (m != null) {
              sections = (int.parse(m[1]!), int.parse(m[2]!));
            }
          }
        }
      }
      if (name.isEmpty || sections == null) continue;

      // 课名去掉课序号后缀："大学物理Ⅳ_02" → "大学物理Ⅳ"
      name = name.replaceFirst(RegExp(r'_\d+$'), '');

      final (weeksType, customWeeks) = parseWeeksText(weeksText);
      final key = '$name|$teacher';
      final course = courses.putIfAbsent(
        key,
        () => ParsedCourse(name: name, teacher: teacher),
      );
      course.slots.add(ParsedSlot(
        dayOfWeek: day,
        startSection: sections.$1,
        endSection: sections.$2,
        weeksType: weeksType,
        customWeeks: customWeeks,
        location: location,
        weeksText: weeksText,
      ));
    }
    return courses.values.toList();
  }

  /// 扬大移动版课表会把每个课程时间段的完整 JSON 放进
  /// `.course-item[data-course]`，比从表格文本反推字段更稳定。
  static List<ParsedCourse> parseMobileCourseCards(String html) {
    final document = html_parser.parse(html);
    final items = <Map<String, dynamic>>[];
    for (final element
        in document.querySelectorAll('.course-item[data-course]')) {
      final raw = element.attributes['data-course'];
      if (raw == null || raw.isEmpty) continue;
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map<String, dynamic>) items.add(decoded);
      } catch (_) {
        // 单个损坏卡片不应阻断其余课程导入。
      }
    }
    if (items.isEmpty) return const [];
    return tryParseJson(jsonEncode(items)) ?? const [];
  }

  // ==================== 策略 2b：通用 HTML 表格兜底 ====================

  /// 解析服务端渲染的课表表格（先按经典正方网格结构实现）。
  /// 真实样本到手后大概率需要按实际结构调整本函数。
  static List<ParsedCourse> parseHtmlTable(String html) {
    final document = html_parser.parse(html);
    final tables = document.querySelectorAll('table');

    for (final table in tables) {
      final rows = table.querySelectorAll('tr');
      if (rows.length < 2) continue;

      // 表头定位星期列：如 周一/星期一/Monday
      final headerCells = rows.first.querySelectorAll('th, td');
      final dayCols = <int, int>{}; // 列下标 → dayOfWeek
      const cnDays = ['一', '二', '三', '四', '五', '六', '日'];
      for (var col = 0; col < headerCells.length; col++) {
        final text = headerCells[col].text.trim();
        for (var d = 0; d < 7; d++) {
          if (text.contains('周${cnDays[d]}') ||
              text.contains('星期${cnDays[d]}')) {
            dayCols[col] = d + 1;
          }
        }
      }
      if (dayCols.length < 5) continue; // 不像课表

      final courses = <String, ParsedCourse>{};
      for (var r = 1; r < rows.length; r++) {
        final cells = rows[r].querySelectorAll('th, td');
        for (var c = 0; c < cells.length; c++) {
          final day = dayCols[c];
          if (day == null) continue;
          final cellText = cells[c].text.trim();
          if (cellText.length < 2) continue;
          for (final block in _splitCellBlocks(cellText)) {
            final parsed = _parseCellBlock(block, day);
            if (parsed == null) continue;
            final key = '${parsed.$1.name}|${parsed.$1.teacher}';
            final course = courses.putIfAbsent(key, () => parsed.$1);
            course.slots.addAll(parsed.$2);
          }
        }
      }
      if (courses.isNotEmpty) return courses.values.toList();
    }
    return [];
  }

  /// 单元格可能含多门课：按空行/多个换行分块
  static List<String> _splitCellBlocks(String cellText) {
    return cellText
        .split(RegExp(r'\n{2,}|-{3,}'))
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
  }

  /// 解析一个课程文本块：
  /// 经典格式如 "高等数学A\n张三\n1-16周[3-4节]\n文汇楼203"，
  /// 或 "大学英语 1-16周 李明 中心楼A101 (3-4节)"。
  /// 返回 (课程, [时间段])；识别失败返回 null。
  static (ParsedCourse, List<ParsedSlot>)? _parseCellBlock(
      String block, int day) {
    // 提取周次文本
    final weeksMatch =
        RegExp(r'[\d,，、\-~—]+\s*周\s*[单双]?|[单双]周').firstMatch(block);
    final weeksText = weeksMatch?[0] ?? '';
    final (weeksType, customWeeks) = parseWeeksText(weeksText);

    // 先剔除周次片段再识别节次，避免 "1-16周" 被误当成节次区间
    final rest0 =
        weeksMatch != null ? block.replaceAll(weeksMatch[0]!, ' ') : block;

    // 提取节次，优先级：带括号 [3-4节] > 带"节"字 3-4节 > 裸区间 3-4
    RegExpMatch? secMatch;
    for (final pattern in [
      RegExp(r'[\[\(（【]\s*(\d{1,2})\s*[-~—]\s*(\d{1,2})\s*节?\s*[\]\)）】]'),
      RegExp(r'(\d{1,2})\s*[-~—]\s*(\d{1,2})\s*节'),
      RegExp(r'(\d{1,2})\s*[-~—]\s*(\d{1,2})'),
    ]) {
      secMatch = pattern.firstMatch(rest0);
      if (secMatch != null) break;
    }
    if (secMatch == null) return null; // 没节次信息就无法排进格子，放弃该块
    final startSection = int.parse(secMatch[1]!);
    final endSection = int.parse(secMatch[2]!);

    // 剩余文本按行/空白分段，分类为 课名/教师/教室
    var rest = rest0.replaceAll(secMatch[0]!, ' ');
    final segments = rest
        .split(RegExp(r'[\n\r]+| {2,}|　'))
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
    if (segments.isEmpty) return null;

    final name = segments.first;
    if (name.length < 2 || name.contains('周')) return null;

    String teacher = '';
    String location = '';
    for (final seg in segments.skip(1)) {
      if (RegExp(r'[楼层馆室场中心]|^\S+楼|^\d+').hasMatch(seg) && location.isEmpty) {
        location = seg; // 像教室
      } else if (teacher.isEmpty && seg.length <= 12) {
        teacher = seg; // 像教师名
      }
    }

    return (
      ParsedCourse(name: name, teacher: teacher),
      [
        ParsedSlot(
          dayOfWeek: day,
          startSection: startSection,
          endSection: endSection,
          weeksType: weeksType,
          customWeeks: customWeeks,
          location: location,
          weeksText: weeksText,
        )
      ],
    );
  }
}
