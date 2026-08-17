/// 周次计算核心逻辑：纯函数、无 Flutter 依赖，便于单元测试。
///
/// 这是整个 App 最容易出错的地方（设计文档阶段 2 明确要求单测覆盖），
/// 所有周次相关判断都必须经过本文件，禁止在 UI 里另写一套。
library;

/// 课程周次类型（数据库存储枚举下标，顺序不许变）
enum WeeksType {
  every, // 每周
  odd, // 单周
  even, // 双周
  custom, // 自定义周次
}

/// 取日期所在周的周一（time 分量清零）。
DateTime mondayOf(DateTime date) {
  final d = DateTime(date.year, date.month, date.day);
  return d.subtract(Duration(days: d.weekday - DateTime.monday));
}

/// 计算 [target] 是学期的第几周（1 起）。
///
/// [startMonday] 为开学第一周的周一。
/// 开学前返回 ≤ 0；超过学期总周数时照常返回（由 UI 决定如何展示）。
int weekNumberOf(DateTime startMonday, DateTime target) {
  final s = DateTime(startMonday.year, startMonday.month, startMonday.day);
  final t = DateTime(target.year, target.month, target.day);
  final days = t.difference(s).inDays; // 中国无夏令时，按天差可靠
  // 必须用向下取整除法：days 为负（开学前）时 ~/ 会朝零截断导致错算成第 1 周
  return (days / 7).floor() + 1;
}

/// 判断某课程安排是否在 [week] 这一周上课。
///
/// [week] ≤ 0（还没开学）时一律返回 false。
bool occursInWeek(WeeksType type, List<int> customWeeks, int week) {
  if (week < 1) return false;
  switch (type) {
    case WeeksType.every:
      return true;
    case WeeksType.odd:
      return week.isOdd;
    case WeeksType.even:
      return week >= 2; // 双周从第 2 周起（第 1 周不是双周）
    case WeeksType.custom:
      return customWeeks.contains(week);
  }
}

/// 解析自定义周次输入，支持逗号/空格/顿号分隔与区间：
/// "1,3,5-8，12" → [1, 3, 5, 6, 7, 8, 12]
///
/// 非法片段直接忽略；结果去重并升序。
List<int> parseCustomWeeks(String input) {
  final weeks = <int>{};
  for (final part in input.split(RegExp(r'[,，、\s]+'))) {
    if (part.isEmpty) continue;
    final range = part.split(RegExp(r'[-~—]'));
    if (range.length == 1) {
      final v = int.tryParse(range[0]);
      if (v != null && v > 0) weeks.add(v);
    } else if (range.length == 2) {
      final a = int.tryParse(range[0]);
      final b = int.tryParse(range[1]);
      if (a != null && b != null && a > 0 && b >= a) {
        for (var i = a; i <= b; i++) {
          weeks.add(i);
        }
      }
    }
  }
  return weeks.toList()..sort();
}

/// 周次的人类可读描述，用于课程详情/编辑页。
String describeWeeks(WeeksType type, List<int> customWeeks) {
  switch (type) {
    case WeeksType.every:
      return '每周';
    case WeeksType.odd:
      return '单周';
    case WeeksType.even:
      return '双周';
    case WeeksType.custom:
      if (customWeeks.isEmpty) return '未设置周次';
      return '第 ${customWeeks.join('、')} 周';
  }
}

/// 把 UI 选择的周（可能超出学期范围）收敛到可展示区间。
/// 返回 null 表示学期尚未开始或已结束（假期中）。
int? clampWeek(int rawWeek, int totalWeeks) {
  if (rawWeek < 1 || rawWeek > totalWeeks) return null;
  return rawWeek;
}
