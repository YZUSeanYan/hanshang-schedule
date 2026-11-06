import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';

/// A server-generated, seven-day timetable sharing code.
class ShareCodeInfo {
  const ShareCodeInfo({required this.code, required this.expiresAt});

  final String code;
  final DateTime expiresAt;

  factory ShareCodeInfo.fromJson(Map<String, dynamic> json) => ShareCodeInfo(
        code: json['code'] as String,
        expiresAt: DateTime.parse(json['expires_at'] as String),
      );
}

/// Sends only a local semester UUID. The server reads the already-synced
/// schedule snapshot; education-system credentials never enter this flow.
class ShareRepository {
  ShareRepository(this._dio);

  final Dio _dio;

  Future<ShareCodeInfo> create(String semesterUuid) async {
    final response = await _dio.post<Map<String, dynamic>>(
      '/api/share/create',
      data: {'semester_uuid': semesterUuid},
    );
    return ShareCodeInfo.fromJson(
      response.data!['data'] as Map<String, dynamic>,
    );
  }

  /// 预览同学分享的 6 位口令对应的课表快照（不写本地库）。
  Future<SharePreview> preview(String code) async {
    final response = await _dio.get<Map<String, dynamic>>(
      '/api/share/${Uri.encodeComponent(code)}',
    );
    final data = response.data!['data'] as Map<String, dynamic>;
    final payload = data['payload'] as Map<String, dynamic>;
    final semester = payload['semester'] as Map<String, dynamic>;
    final courses = (payload['courses'] as List? ?? const []).cast<Map<String, dynamic>>();
    return SharePreview(
      semesterName: semester['name'] as String? ?? '',
      courseCount: courses.length,
      expiresAt: DateTime.parse(data['expires_at'] as String),
      courses: [
        for (final course in courses)
          SharePreviewCourse(
            name: course['name'] as String? ?? '',
            teacher: course['teacher'] as String? ?? '',
            slotCount: (course['slots'] as List? ?? const []).length,
          ),
      ],
    );
  }

  /// 领取口令课表为独立副本；返回导入的课程数。
  /// 与现有学期同名同开学日时服务端返回 409，需用户确认后传 replaceExisting 重试。
  Future<int> claim(String code, {required bool replaceExisting}) async {
    final response = await _dio.post<Map<String, dynamic>>(
      '/api/share/${Uri.encodeComponent(code)}/claim',
      data: {'replace_existing': replaceExisting},
    );
    final data = response.data!['data'] as Map<String, dynamic>;
    return (data['course_count'] as num).toInt();
  }

  /// 获取口令对应的完整快照 payload（BLE 发送到手表用），不做摘要转换。
  Future<Map<String, dynamic>> previewRaw(String code) async {
    final response = await _dio.get<Map<String, dynamic>>(
      '/api/share/${Uri.encodeComponent(code)}',
    );
    final data = response.data!['data'] as Map<String, dynamic>;
    return data['payload'] as Map<String, dynamic>;
  }
}

/// 分享口令对应的课表快照预览。
class SharePreview {
  const SharePreview({
    required this.semesterName,
    required this.courseCount,
    required this.expiresAt,
    required this.courses,
  });

  final String semesterName;
  final int courseCount;
  final DateTime expiresAt;
  final List<SharePreviewCourse> courses;
}

class SharePreviewCourse {
  const SharePreviewCourse({
    required this.name,
    required this.teacher,
    required this.slotCount,
  });

  final String name;
  final String teacher;
  final int slotCount;
}

final shareRepositoryProvider = Provider<ShareRepository>(
  (ref) => ShareRepository(ref.read(dioProvider)),
);
