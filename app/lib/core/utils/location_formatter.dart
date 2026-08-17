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
