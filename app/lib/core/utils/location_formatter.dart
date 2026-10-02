/// Formats timetable locations so the most useful room/building part appears
/// first while preserving the original campus information.
String formatCourseLocation(String raw) {
  var value = raw.trim().replaceFirst(RegExp(r'^[@\s]+'), '');
  if (value.isEmpty) return '';

  // 教务复制文本的"校区>>楼>>教室"（或 →→ 箭头）分隔格式：楼宇教室放最前，
  // 校区放最后，与网页端 displayLocation 保持一致。
  final arrowParts = value
      .split(RegExp(r'>>|→→|＞＞|->|→'))
      .map((part) => part.trim())
      .where((part) => part.isNotEmpty)
      .toList();
  if (arrowParts.length >= 3) {
    return '${arrowParts.sublist(1).join()} · ${arrowParts[0]}';
  }
  if (arrowParts.length == 2) {
    return '${arrowParts[1]} · ${arrowParts[0]}';
  }

  final parts = value
      .split(RegExp(r'\s*(?:@|·|，|,|/|\|)\s*'))
      .map((part) => part.trim())
      .where((part) => part.isNotEmpty)
      .toList();

  if (parts.length > 1) {
    parts.sort((a, b) => _locationScore(b).compareTo(_locationScore(a)));
    return parts.toSet().join(' · ');
  }

  // 教务处常返回“校区+教学楼+教室”的无分隔格式。把校区作为补充信息
  // 放到后面，学生最需要扫读的“楼+教室”放在最前面。
  final campusEnd = value.lastIndexOf('校区');
  if (campusEnd >= 0) {
    final splitAt = campusEnd + '校区'.length;
    final campus = value.substring(0, splitAt).trim();
    final room =
        value.substring(splitAt).replaceFirst(RegExp(r'^[\s:：-]+'), '').trim();
    if (campus.isNotEmpty && room.isNotEmpty) {
      return '$room · $campus';
    }
  }

  return value;
}

int _locationScore(String value) {
  var score = 0;
  if (RegExp(r'(楼|馆|中心|实验室)').hasMatch(value)) score += 4;
  if (RegExp(r'[A-Za-z]?\d{2,4}[A-Za-z]?$').hasMatch(value)) score += 5;
  if (value.contains('校区')) score -= 2;
  return score;
}

/// 结构化地点拆分：课程卡片按信息层级分级展示用（教室醒目、楼名次要、
/// 校区默认收起进详情）。解析不出结构时只有 [formatted] 兜底串非空。
class CourseLocationParts {
  const CourseLocationParts({
    this.room = '',
    this.building = '',
    this.campus = '',
    this.formatted = '',
  });

  /// 教室号，如 N107 / E206 / 101
  final String room;

  /// 楼名，如 文津楼 / 体育馆
  final String building;

  /// 校区，如 扬子津东校区
  final String campus;

  /// 完整展示串（formatCourseLocation 的结果），无结构时的兜底
  final String formatted;

  bool get isEmpty => formatted.isEmpty;
}

final _roomPattern = RegExp(r'[A-Za-z]{0,3}\d{2,4}[A-Za-z]?$');
final _buildingPattern = RegExp(r'^(.*?)(楼|馆|中心|实验室|体育场|操场|学院楼)');
// 已是展示格式的输入（"文津楼N204 · 扬子津东校区"）：末尾的 "· xx校区" 后缀
final _formattedCampusSuffix = RegExp(r'^(.*?)\s*·\s*([^·]*校区)\s*$');

/// 把原始地点拆成 校区/楼/教室 三级。覆盖教务的四种来源格式：
/// 「校区>>楼>>教室」箭头链、「校区楼教室」无分隔连写、「文津楼E206」
/// 楼+教室连写、以及完全自由的文本（此时只给 formatted 兜底）。
CourseLocationParts parseCourseLocation(String raw) {
  final formatted = formatCourseLocation(raw);
  final value = raw.trim().replaceFirst(RegExp(r'^[@\s]+'), '');
  if (value.isEmpty) return const CourseLocationParts();

  String campus = '';
  String rest = value;

  // 箭头链：校区>>楼>>教室（前两段以上时首段是校区，末段是教室）
  final arrowParts = value
      .split(RegExp(r'>>|→→|＞＞|->|→'))
      .map((part) => part.trim())
      .where((part) => part.isNotEmpty)
      .toList();
  if (arrowParts.length >= 3) {
    return CourseLocationParts(
      room: arrowParts.sublist(2).join(),
      building: arrowParts[1],
      campus: arrowParts[0],
      formatted: formatted,
    );
  }
  if (arrowParts.length == 2) {
    if (arrowParts[0].contains('校区')) {
      campus = arrowParts[0];
      rest = arrowParts[1];
    } else {
      return CourseLocationParts(
        room: arrowParts[1],
        building: arrowParts[0],
        formatted: formatted,
      );
    }
  } else {
    // 先剥「已是展示格式」的 "· xx校区" 后缀（分享/网页端写回的串），
    // 否则 lastIndexOf('校区') 会把整串吞成 campus
    final suffix = _formattedCampusSuffix.firstMatch(value);
    if (suffix != null) {
      campus = suffix.group(2)!.trim();
      rest = suffix.group(1)!.trim();
    } else {
      // 无分隔连写：先剥校区
      final campusEnd = value.lastIndexOf('校区');
      if (campusEnd >= 0) {
        final splitAt = campusEnd + '校区'.length;
        campus = value.substring(0, splitAt).trim();
        rest = value
            .substring(splitAt)
            .replaceFirst(RegExp(r'^[\s:：-]+'), '')
            .trim();
      }
    }
  }

  // rest = 楼+教室：教室号是结尾的字母+数字组合（N107/E206/101）
  final roomMatch = _roomPattern.firstMatch(rest);
  if (roomMatch != null) {
    final room = roomMatch.group(0)!;
    final building = rest.substring(0, roomMatch.start).trim();
    if (building.isNotEmpty || campus.isNotEmpty) {
      return CourseLocationParts(
        room: room,
        building: building,
        campus: campus,
        formatted: formatted,
      );
    }
    // 只有教室号（如 "N107"）：视为纯教室
    return CourseLocationParts(room: room, formatted: formatted);
  }

  // 没有教室号：尝试识别楼名
  final buildingMatch = _buildingPattern.firstMatch(rest);
  if (buildingMatch != null && rest != campus) {
    return CourseLocationParts(
      building: rest,
      campus: campus,
      formatted: formatted,
    );
  }

  return CourseLocationParts(campus: campus, formatted: formatted);
}
