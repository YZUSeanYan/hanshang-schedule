import 'package:flutter/material.dart';

/// 课程块默认配色：柔和马卡龙色系（设计文档 6.2）。
/// 同课程同色；未手动指定时按课程名哈希自动分配。
class CourseColors {
  CourseColors._();

  static const List<Color> macaron = [
    Color(0xFFA8D8EA), // 浅蓝
    Color(0xFFFFCBCB), // 浅粉
    Color(0xFFB5EAD7), // 薄荷绿
    Color(0xFFFFDAC1), // 浅橙
    Color(0xFFC7CEEA), // 薰衣草
    Color(0xFFF6E6AD), // 鹅黄
    Color(0xFFA2E1DB), // 青绿
    Color(0xFFF3B0C3), // 玫粉
    Color(0xFFBFD8B8), // 豆绿
    Color(0xFFE7C6E7), // 浅紫
  ];

  /// 按课程名稳定分配一个默认颜色
  static Color forCourseName(String name) {
    var hash = 0;
    for (final unit in name.codeUnits) {
      hash = (hash * 31 + unit) & 0x7fffffff;
    }
    return macaron[hash % macaron.length];
  }

  /// 课程块文字颜色：按背景亮度自动选黑/白，保证深浅色下都可读（设计文档 6.2）
  static Color textOn(Color background) {
    return background.computeLuminance() > 0.5
        ? const Color(0xFF1A1A1A)
        : Colors.white;
  }
}
