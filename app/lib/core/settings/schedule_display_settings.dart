import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/schedule/data/schedule_repository.dart';
import '../database/app_database.dart';

/// 只改变周视图的展示，不改变课程、日程或提醒规则。
class ScheduleDisplayOptions {
  const ScheduleDisplayOptions({
    this.showWeekends = true,
    this.trimEmptyEvenings = true,
  });

  final bool showWeekends;
  final bool trimEmptyEvenings;

  ScheduleDisplayOptions copyWith(
          {bool? showWeekends, bool? trimEmptyEvenings}) =>
      ScheduleDisplayOptions(
        showWeekends: showWeekends ?? this.showWeekends,
        trimEmptyEvenings: trimEmptyEvenings ?? this.trimEmptyEvenings,
      );

  String encode() => jsonEncode({
        'show_weekends': showWeekends,
        'trim_empty_evenings': trimEmptyEvenings,
      });

  static ScheduleDisplayOptions decode(String? raw) {
    try {
      final data = jsonDecode(raw!) as Map<String, dynamic>;
      return ScheduleDisplayOptions(
        showWeekends: data['show_weekends'] is bool
            ? data['show_weekends'] as bool
            : true,
        trimEmptyEvenings: data['trim_empty_evenings'] is bool
            ? data['trim_empty_evenings'] as bool
            : true,
      );
    } catch (_) {
      return const ScheduleDisplayOptions();
    }
  }
}

class ScheduleDisplaySettings {
  ScheduleDisplaySettings(this.db);
  final AppDatabase db;
  static const key = 'schedule_display_v1';

  Stream<ScheduleDisplayOptions> watch() =>
      (db.select(db.settingsEntries)..where((row) => row.key.equals(key)))
          .watchSingleOrNull()
          .map((row) => ScheduleDisplayOptions.decode(row?.value));

  Future<void> save(ScheduleDisplayOptions options) =>
      db.into(db.settingsEntries).insertOnConflictUpdate(
            SettingsEntriesCompanion(
              key: const Value(key),
              value: Value(options.encode()),
            ),
          );
}

final scheduleDisplaySettingsProvider = Provider<ScheduleDisplaySettings>(
  (ref) => ScheduleDisplaySettings(ref.watch(databaseProvider)),
);
final scheduleDisplayOptionsProvider = StreamProvider<ScheduleDisplayOptions>(
  (ref) => ref.watch(scheduleDisplaySettingsProvider).watch(),
);
