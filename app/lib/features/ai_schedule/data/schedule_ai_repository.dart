import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';

/// AI 日程理解结果（服务端 /api/schedule-ai/parse 的 data 层）。
class ScheduleAiResult {
  const ScheduleAiResult({
    required this.operations,
    this.transcript,
    this.asrMs,
    this.llmMs,
  });

  /// 语音输入的转写文本（纯文字输入为 null）
  final String? transcript;
  final List<AiOperation> operations;
  final int? asrMs;
  final int? llmMs;
}

/// 一条结构化日程操作，字段与服务端输出契约一一对应（null = 模型没给）。
class AiOperation {
  const AiOperation({
    required this.action,
    required this.type,
    this.title,
    this.shortTitle,
    this.date,
    this.weekday,
    this.startTime,
    this.endTime,
    this.startSection,
    this.endSection,
    this.location,
    this.target,
    this.fromWeekday,
    this.fromStartSection,
    required this.confidence,
  });

  final String action; // create / reschedule / cancel
  final String type; // event / ddl / exam / recurring
  final String? title;

  /// 课表小格子上的简写（服务端 AI 提炼，2-6 字），空则展示 title
  final String? shortTitle;
  final String? date; // YYYY-MM-DD
  final int? weekday; // 1-7
  final String? startTime; // HH:MM
  final String? endTime;
  final int? startSection;
  final int? endSection;
  final String? location;

  /// reschedule/cancel 要匹配的课程名或日程标题
  final String? target;
  final int? fromWeekday;
  final int? fromStartSection;
  final double confidence;

  factory AiOperation.fromJson(Map<String, dynamic> json) => AiOperation(
        action: json['action'] as String? ?? 'create',
        type: json['type'] as String? ?? 'event',
        title: json['title'] as String?,
        shortTitle: json['short_title'] as String?,
        date: json['date'] as String?,
        weekday: (json['weekday'] as num?)?.toInt(),
        startTime: json['start_time'] as String?,
        endTime: json['end_time'] as String?,
        startSection: (json['start_section'] as num?)?.toInt(),
        endSection: (json['end_section'] as num?)?.toInt(),
        location: json['location'] as String?,
        target: json['target'] as String?,
        fromWeekday: (json['from_weekday'] as num?)?.toInt(),
        fromStartSection: (json['from_start_section'] as num?)?.toInt(),
        confidence: (json['confidence'] as num?)?.toDouble() ?? 0.5,
      );

  AiOperation copyWith({
    String? action,
    String? type,
    String? title,
    String? shortTitle,
    String? date,
    int? weekday,
    String? startTime,
    String? endTime,
    int? startSection,
    int? endSection,
    String? location,
    String? target,
    double? confidence,
  }) =>
      AiOperation(
        action: action ?? this.action,
        type: type ?? this.type,
        title: title ?? this.title,
        shortTitle: shortTitle ?? this.shortTitle,
        date: date ?? this.date,
        weekday: weekday ?? this.weekday,
        startTime: startTime ?? this.startTime,
        endTime: endTime ?? this.endTime,
        startSection: startSection ?? this.startSection,
        endSection: endSection ?? this.endSection,
        location: location ?? this.location,
        target: target ?? this.target,
        fromWeekday: fromWeekday,
        fromStartSection: fromStartSection,
        confidence: confidence ?? this.confidence,
      );
}

/// 调休通知解析结果：date=YYYY-MM-DD，kind=off(放假)/makeup(补课)。
class HolidayAdjustment {
  const HolidayAdjustment({
    required this.date,
    required this.kind,
    this.weekday = 0,
    this.note = '',
  });

  final String date;
  final String kind;
  final int weekday;
  final String note;
}

/// AI 日程理解仓库：把一句话（文字或 PCM WAV 语音）解析成日程操作列表。
///
/// 服务端不落库、不写日志、音频即转即删；客户端同样只在内存中传递，
/// 录音文件在发送后立即删除（见 voice_record_sheet.dart）。
class ScheduleAiRepository {
  ScheduleAiRepository(this._dio);

  final Dio _dio;

  Future<ScheduleAiResult> parseText(String text) => _parse({'text': text});

  Future<ScheduleAiResult> parseVoice(List<int> wavBytes) =>
      _parse({'audio_base64': base64Encode(wavBytes)});

  /// 调休通知解析（文字或截图）→ 调整列表：放假 off / 补课 makeup(weekday)。
  /// 只识别不保存，客户端确认后再落库。
  Future<List<HolidayAdjustment>> parseHoliday({
    String? text,
    List<int>? imageBytes,
  }) async {
    final body = <String, dynamic>{};
    if (text != null && text.trim().isNotEmpty) body['text'] = text.trim();
    if (imageBytes != null) body['image_base64'] = base64Encode(imageBytes);
    final resp = await _dio.post<Map<String, dynamic>>(
      '/api/schedule-ai/holiday-parse',
      data: body,
      // 与其它 AI 调用一致：视觉理解可能耗时 20-50s，
      // 全局 receiveTimeout 只有 15s，必须显式放宽（曾导致「添加失败」）
      options: Options(
        sendTimeout: const Duration(seconds: 30),
        receiveTimeout: const Duration(seconds: 55),
      ),
    );
    final raw = (resp.data?['data'] as Map?)?['adjustments'] as List? ?? [];
    return [
      for (final item in raw)
        HolidayAdjustment(
          date: (item as Map)['date'] as String,
          kind: item['kind'] as String,
          weekday: (item['weekday'] as num?)?.toInt() ?? 0,
          note: item['note'] as String? ?? '',
        ),
    ];
  }

  /// 分段转写（录音中实时上屏）：发累计音频，返回累计文本；不落库。
  /// 调用方自行单飞与节流；失败抛异常由调用方静默。
  Future<String> transcribeChunk(List<int> wavBytes) async {
    final resp = await _dio.post<Map<String, dynamic>>(
      '/api/schedule-ai/transcribe',
      data: {'audio_base64': base64Encode(wavBytes)},
    );
    return ((resp.data?['data'] as Map?)?['text'] as String? ?? '').trim();
  }

  /// 图片识别：活动海报/截图 → 结构化日程（与文字同一解析管线，视觉模型）。
  Future<ScheduleAiResult> parseImage(List<int> imageBytes) =>
      _parse({'image_base64': base64Encode(imageBytes)});

  Future<ScheduleAiResult> _parse(Map<String, dynamic> body) async {
    final resp = await _dio.post<Map<String, dynamic>>(
      '/api/schedule-ai/parse',
      data: body,
      // 语音 + 理解两段式调用，放宽接收超时（服务端硬时限 50s，nginx 60s）
      options: Options(receiveTimeout: const Duration(seconds: 55)),
    );
    final data = resp.data?['data'] as Map<String, dynamic>?;
    if (data == null) {
      throw StateError('日程理解服务返回异常');
    }
    final rawOps = data['operations'] as List? ?? const [];
    return ScheduleAiResult(
      operations: [
        for (final item in rawOps)
          AiOperation.fromJson(item as Map<String, dynamic>),
      ],
      transcript: data['transcript'] as String?,
      asrMs: (data['asr_ms'] as num?)?.toInt(),
      llmMs: (data['llm_ms'] as num?)?.toInt(),
    );
  }
}

final scheduleAiRepositoryProvider = Provider<ScheduleAiRepository>(
  (ref) => ScheduleAiRepository(ref.read(dioProvider)),
);
