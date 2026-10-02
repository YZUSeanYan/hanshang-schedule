import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/schedule/data/schedule_repository.dart';
import '../constants/section_times.dart';
import '../database/app_database.dart';

/// 此设备所有学期共用；自动模式按实际上课日期选用扬大模板。
class SectionTimeConfig {
  const SectionTimeConfig.defaults() : custom = null;
  SectionTimeConfig.custom(List<(String, String)> times)
      : custom = List.unmodifiable(times) {
    final error = validate(times);
    if (error != null) throw FormatException(error);
  }
  final List<(String, String)>? custom;
  bool get automatic => custom == null;

  /// 全 App 统一的节次上限（作息表/日视图/提醒都按 12 节设计），
  /// 导入与 AI 解析的节次必须夹进 [1, maxSection]（review R12）。
  static const int maxSection = SectionTimes.sectionCount;

  List<(String, String)> forDate(DateTime date) =>
      custom ?? SectionTimes.forDate(date);
  String startOf(int section, DateTime date) => forDate(date)[section - 1].$1;
  String endOf(int section, DateTime date) => forDate(date)[section - 1].$2;

  static int? minutes(String value) {
    if (!RegExp(r'^(?:[01]\d|2[0-3]):[0-5]\d$').hasMatch(value)) return null;
    final parts = value.split(':');
    return int.parse(parts[0]) * 60 + int.parse(parts[1]);
  }

  static String? validate(List<(String, String)> times) {
    if (times.length != SectionTimes.sectionCount) return '请设置完整的 12 节课时间';
    var previousEnd = -1;
    for (var i = 0; i < times.length; i++) {
      final start = minutes(times[i].$1);
      final end = minutes(times[i].$2);
      if (start == null || end == null) return '第 ${i + 1} 节时间格式不正确';
      if (end <= start) return '第 ${i + 1} 节下课时间必须晚于上课时间';
      if (start < previousEnd) return '第 ${i + 1} 节与上一节时间重叠';
      previousEnd = end;
    }
    return null;
  }

  String encode() => jsonEncode({
        'version': 1,
        'mode': automatic ? 'automatic' : 'custom',
        if (custom != null) 'times': custom!.map((t) => [t.$1, t.$2]).toList(),
      });

  static SectionTimeConfig decode(String? raw) {
    try {
      final data = jsonDecode(raw!) as Map<String, dynamic>;
      if (data['version'] != 1) return const SectionTimeConfig.defaults();
      if (data['mode'] == 'custom') {
        return SectionTimeConfig.custom((data['times'] as List)
            .map((t) => (t[0] as String, t[1] as String))
            .toList());
      }
    } catch (_) {/* 损坏的本地数据使用默认作息。 */}
    return const SectionTimeConfig.defaults();
  }
}

class SectionTimeSettings {
  SectionTimeSettings(this.db);
  final AppDatabase db;
  static const key = 'section_times_v1';
  SimpleSelectStatement<SettingsEntries, SettingsEntry> _query() =>
      db.select(db.settingsEntries)..where((s) => s.key.equals(key));
  Future<SectionTimeConfig> load() async =>
      SectionTimeConfig.decode((await _query().getSingleOrNull())?.value);
  Stream<SectionTimeConfig> watch() => _query()
      .watchSingleOrNull()
      .map((row) => SectionTimeConfig.decode(row?.value));
  Future<void> save(SectionTimeConfig config) async {
    await db.into(db.settingsEntries).insertOnConflictUpdate(
        SettingsEntriesCompanion(
            key: const Value(key), value: Value(config.encode())));
  }
}

final sectionTimeSettingsProvider = Provider<SectionTimeSettings>(
    (ref) => SectionTimeSettings(ref.watch(databaseProvider)));
final sectionTimeConfigProvider = StreamProvider<SectionTimeConfig>(
    (ref) => ref.watch(sectionTimeSettingsProvider).watch());
