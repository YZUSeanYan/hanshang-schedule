import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../../core/constants/course_colors.dart';
import '../../../core/database/app_database.dart';
import '../../../core/settings/section_time_settings.dart';
import 'schedule_repository.dart';

/// 个人日程仓库（AI 日程 2.0）：本地读写 + 墓碑记录，同步由 SyncRepository 负责。
///
/// 日程与课程并列：不参与学期，不按周次循环。一次性日程用绝对日期，
/// 周期日程（recurring）按星期几长期有效。
class EventRepository {
  EventRepository(this._db);

  final AppDatabase _db;

  static const _uuidGen = Uuid();

  /// 监听全部未过期日程（含全部类型；页面自行筛选/排序）。
  Stream<List<LocalEvent>> watchAll() {
    final query = _db.select(_db.localEvents)
      ..orderBy([(e) => OrderingTerm.asc(e.date), (e) => OrderingTerm.asc(e.startTime)]);
    return query.watch();
  }

  Future<int> createEvent(EventDraft draft) async {
    final now = DateTime.now();
    return _db.into(_db.localEvents).insert(
          LocalEventsCompanion.insert(
            uuid: Value(_uuidGen.v4()),
            title: draft.title,
            shortTitle: Value(draft.shortTitle),
            eventType: Value(draft.eventType),
            date: Value(draft.date),
            weekday: Value(draft.weekday),
            startTime: Value(draft.startTime),
            endTime: Value(draft.endTime),
            startSection: Value(draft.startSection),
            endSection: Value(draft.endSection),
            busySections: Value(draft.busySections),
            location: Value(draft.location),
            note: Value(draft.note),
            color: Value(draft.color ?? 0),
            remindMinutes: Value(draft.remindMinutes),
            source: Value(draft.source),
            updatedAt: now,
          ),
        );
  }

  Future<void> updateEvent(LocalEvent event) async {
    // 同步 LWW 依据：任何本地修改都要刷新 updatedAt
    await _db.update(_db.localEvents).replace(event.copyWith(updatedAt: DateTime.now()));
  }

  Future<void> deleteEvent(int id) async {
    await _db.transaction(() async {
      final event = await (_db.select(_db.localEvents)
            ..where((e) => e.id.equals(id)))
          .getSingleOrNull();
      if (event == null) return;
      if (event.uuid.isNotEmpty) {
        await _db.into(_db.pendingDeletions).insert(
              PendingDeletionsCompanion.insert(
                entity: 'event',
                uuid: event.uuid,
                parentUuid: const Value(''),
                deletedAt: DateTime.now(),
              ),
            );
      }
      await (_db.delete(_db.localEvents)..where((e) => e.id.equals(id))).go();
    });
  }
}

/// 新建日程的草稿（无 id/uuid/updatedAt）。
class EventDraft {
  const EventDraft({
    required this.title,
    this.shortTitle = '',
    this.eventType = 'event',
    this.date = '',
    this.weekday = 0,
    this.startTime = '',
    this.endTime = '',
    this.startSection = 0,
    this.endSection = 0,
    this.busySections = '',
    this.location = '',
    this.note = '',
    this.color,
    this.remindMinutes = -1,
    this.source = 'manual',
  });

  final String title;

  /// 课表小格子上的简写（AI 提炼），空=展示 title；用户改过标题时应置空
  final String shortTitle;
  final String eventType;
  final String date;
  final int weekday;
  final String startTime;
  final String endTime;
  final int startSection;
  final int endSection;
  final String busySections;
  final String location;
  final String note;
  final int? color;
  final int remindMinutes;
  final String source;
}

// ==================== 日程工具函数 ====================

/// 日程显示色：未指定时按标题稳定哈希取马卡龙色（与课程同一套配色语言）。
int eventColorOf(LocalEvent event) =>
    event.color != 0 ? event.color : CourseColors.forCourseName(event.title).toARGB32();

/// 解析 busy_sections（"8,9,10"）为有序整数列表。节次域上限 12（SectionTimes.sectionCount）。
List<int> parseBusySections(String raw) {
  final result = <int>[];
  for (final piece in raw.split(',')) {
    final value = int.tryParse(piece.trim());
    if (value != null && value >= 1 && value <= 12) result.add(value);
  }
  return result.toSet().toList()..sort();
}

/// 计算日程占用的节次（写库与共同空闲共用的依据）：
/// - 节次表达（startSection/endSection）直接展开；
/// - 时刻表达（startTime/endTime）按作息表求交集——[referenceDate] 决定用
///   哪套作息模板（一次性日程用当天；周期日程用下次发生日）；
/// - DDL / 无时间：不占节次，返回空。
List<int> computeBusySections({
  required int startSection,
  required int endSection,
  required String startTime,
  required String endTime,
  required SectionTimeConfig config,
  required DateTime referenceDate,
}) {
  if (startSection >= 1 && endSection >= startSection) {
    return [for (var s = startSection; s <= endSection && s <= 30; s++) s];
  }
  final start = SectionTimeConfig.minutes(startTime);
  final end = SectionTimeConfig.minutes(endTime);
  if (start == null || end == null || end <= start) return const [];
  final times = config.forDate(referenceDate);
  final busy = <int>[];
  for (var i = 0; i < times.length; i++) {
    final sStart = SectionTimeConfig.minutes(times[i].$1);
    final sEnd = SectionTimeConfig.minutes(times[i].$2);
    if (sStart == null || sEnd == null) continue;
    if (sStart < end && start < sEnd) busy.add(i + 1);
  }
  return busy;
}

/// 日程在 [date] 是否发生。
bool eventOccursOn(LocalEvent event, DateTime date) {
  if (event.eventType == 'recurring') {
    return event.weekday >= 1 && event.weekday <= 7 && event.weekday == date.weekday;
  }
  if (event.date.isEmpty) return false;
  final target = DateTime.tryParse(event.date);
  if (target == null) return false;
  return target.year == date.year && target.month == date.month && target.day == date.day;
}

/// 日程在 [date] 那天的开始时刻（分钟）：时刻表达直接给；节次表达查作息表；
/// 无时间（DDL）返回 null。
int? eventStartMinutes(LocalEvent event, DateTime date, SectionTimeConfig config) {
  final byTime = SectionTimeConfig.minutes(event.startTime);
  if (byTime != null) return byTime;
  if (event.startSection >= 1) {
    return SectionTimeConfig.minutes(config.startOf(event.startSection, date));
  }
  return null;
}

/// 日程在 [date] 那天占据的节次区间（用于周视图渲染）：优先 busySections，
/// 其次 start/endSection；都无则 null（DDL 不占网格）。
(int, int)? eventSectionRange(LocalEvent event) {
  final busy = parseBusySections(event.busySections);
  if (busy.isNotEmpty) return (busy.first, busy.last);
  if (event.startSection >= 1 && event.endSection >= event.startSection) {
    return (event.startSection, event.endSection);
  }
  return null;
}

/// 日程的时间显示文本（日视图/详情用）。
String eventTimeLabel(LocalEvent event, DateTime date, SectionTimeConfig config) {
  if (event.startTime.isNotEmpty) {
    return event.endTime.isNotEmpty
        ? '${event.startTime}-${event.endTime}'
        : event.startTime;
  }
  if (event.startSection >= 1 && event.endSection >= event.startSection) {
    final start = config.startOf(event.startSection, date);
    final end = config.endOf(event.endSection, date);
    return '$start-$end（第${event.startSection}-${event.endSection}节）';
  }
  return '';
}

/// 日程类型的中文标签。
String eventTypeLabel(String eventType) => switch (eventType) {
      'ddl' => '待办',
      'exam' => '考试',
      'recurring' => '每周',
      _ => '日程',
    };

// ==================== Provider ====================

final eventRepositoryProvider = Provider<EventRepository>(
  (ref) => EventRepository(ref.read(databaseProvider)),
);

/// 全部日程（变化驱动周/日视图、提醒重排与静默同步）
final eventsProvider = StreamProvider<List<LocalEvent>>(
  (ref) => ref.read(eventRepositoryProvider).watchAll(),
);

/// 即将到来的日程（今天起，一次性按日期、周期按本周起），AI 页"即将进行"列表用。
final upcomingEventsProvider = Provider<List<LocalEvent>>((ref) {
  final events = ref.watch(eventsProvider).valueOrNull ?? const <LocalEvent>[];
  final today = DateTime.now();
  final todayOnly = DateTime(today.year, today.month, today.day);
  final horizon = todayOnly.add(const Duration(days: 60));
  bool isUpcoming(LocalEvent e) {
    if (e.eventType == 'recurring') return true; // 长期有效
    final d = DateTime.tryParse(e.date);
    if (d == null) return false;
    final day = DateTime(d.year, d.month, d.day);
    return !day.isBefore(todayOnly) && !day.isAfter(horizon);
  }

  final list = events.where(isUpcoming).toList();
  int sortKey(LocalEvent e) {
    if (e.eventType == 'recurring') {
      // 下一次发生日期
      var days = (e.weekday - today.weekday) % 7;
      final at = todayOnly.add(Duration(days: days));
      return at.millisecondsSinceEpoch ~/ 86400000;
    }
    final d = DateTime.tryParse(e.date);
    return d == null ? 1 << 30 : d.millisecondsSinceEpoch ~/ 86400000;
  }

  list.sort((a, b) {
    final byDay = sortKey(a).compareTo(sortKey(b));
    if (byDay != 0) return byDay;
    return a.startTime.compareTo(b.startTime);
  });
  return list;
});
