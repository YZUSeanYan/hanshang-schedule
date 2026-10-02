import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../../../core/settings/section_time_settings.dart';
import '../../../import/yzu_parser.dart';

/// 服务器 LLM 课表解析：支持文件导入，以及本地规则解析失败后的页面兜底。
///
/// 上传内容与隐私边界：
/// - 页面兜底只上传当前课表页 HTML 与嗅探响应体，不碰 Cookie、密码框；
/// - 页面数据上传前在本机抹除姓名、学号等身份信息（[stripIdentityInfo]），
///   服务端收到后会再做一轮同样的脱敏作为纵深防御；
/// - 截图经用户确认后转交 MiMo；表格由服务器只读提取并脱敏文本；
/// - 服务端清洗后交由第三方大模型（小米 MiMo）解析一次，原文不落库、不写日志；
/// - 需要登录态（JWT），每用户每天限 10 次。
class LlmImportRepository {
  LlmImportRepository(this._dio);

  final Dio _dio;

  /// 服务端 html 字段上限 2 MB（YZU 整页另存约 1.7 MB）。
  static const _maxHtmlChars = 2000000;

  /// 服务端单条嗅探响应上限。
  static const _maxCapturedChars = 200000;

  /// 上传课表截图或表格。服务端按文件头重新校验类型，不信任扩展名。
  Future<ParseResult> parseFile({
    required String filename,
    required List<int> bytes,
  }) async {
    final response = await _dio.post<Map<String, dynamic>>(
      '/api/education-import/file-parse',
      data: FormData.fromMap({
        'file': MultipartFile.fromBytes(bytes, filename: filename),
      }),
      options: Options(
        contentType: 'multipart/form-data',
        sendTimeout: const Duration(seconds: 60),
        receiveTimeout: const Duration(seconds: 55),
      ),
    );
    final data = response.data?['data'];
    if (data is! Map<String, dynamic>) {
      throw const LlmImportException('服务器响应格式异常');
    }
    final courses = mapCoursesResponse(data['courses'] as List? ?? const []);
    if (courses.isEmpty) {
      throw const LlmImportException('服务器未能从文件中识别出课程');
    }
    final source = data['source'] as String? ?? 'llm';
    return ParseResult(
      courses: courses,
      source: source,
      detail: source == 'image_llm'
          ? 'AI 从课表截图中识别出 ${courses.length} 门课，请逐项核对'
          : 'AI 从表格文件中识别出 ${courses.length} 门课，请逐项核对',
    );
  }

  /// 从抓取包发起云端解析，成功返回与本地解析器相同的 [ParseResult]。
  Future<ParseResult> parseCapture(Map<String, dynamic> capture) async {
    // 主页面与同源 iframe 全部收集：课表经常在 iframe 而非最大文档里，
    // 最大文档作 html 上传，其余文档并入 captured 供服务端规则/LLM 参考。
    final docs = <String>[
      if (capture['html'] is String && (capture['html'] as String).isNotEmpty)
        capture['html'] as String,
      for (final frame in (capture['frames'] as List? ?? const []))
        if (frame is Map &&
            frame['html'] is String &&
            (frame['html'] as String).isNotEmpty)
          frame['html'] as String,
    ];
    if (docs.isEmpty) {
      throw const LlmImportException('抓取包里没有可解析的页面内容');
    }
    docs.sort((a, b) => b.length.compareTo(a.length));
    final response = await _dio.post<Map<String, dynamic>>(
      '/api/education-import/llm-parse',
      data: {
        'html': stripIdentityInfo(_cap(docs.first, _maxHtmlChars)),
        'captured': [
          ...collectCapturedBodies(capture),
          for (final extra in docs.skip(1).take(2))
            stripIdentityInfo(_cap(extra, _maxCapturedChars)),
        ],
        'page_url': _safeUrl(capture['url']),
      },
      options: Options(
        // 云端解析实测约 25-35 秒，显著长于普通接口的默认超时
        sendTimeout: const Duration(seconds: 60),
        receiveTimeout: const Duration(seconds: 55),
      ),
    );
    final data = response.data?['data'];
    if (data is! Map<String, dynamic>) {
      throw const LlmImportException('服务器响应格式异常');
    }
    final courses = mapCoursesResponse(data['courses'] as List? ?? const []);
    if (courses.isEmpty) {
      throw const LlmImportException('服务器未能从页面中识别出课程');
    }
    final source = data['source'] as String? ?? 'llm';
    return ParseResult(
      courses: courses,
      source: source,
      detail: source == 'json'
          ? '服务器从页面接口数据中解析出 ${courses.length} 门课'
          : '服务器 AI 解析出 ${courses.length} 门课，请核对后确认导入',
    );
  }

  /// 选取最可能包含课表的文档：主页面与同源 iframe 中内容最多的一个。
  /// WebVPN 常把教务系统套在 iframe 里，课表往往在 iframe 而非主页面。
  static String? selectHtmlDocument(Map<String, dynamic> capture) {
    final docs = <String>[
      if (capture['html'] is String && (capture['html'] as String).isNotEmpty)
        capture['html'] as String,
      for (final frame in (capture['frames'] as List? ?? const []))
        if (frame is Map &&
            frame['html'] is String &&
            (frame['html'] as String).isNotEmpty)
          frame['html'] as String,
    ];
    if (docs.isEmpty) return null;
    docs.sort((a, b) => b.length.compareTo(a.length));
    return docs.first;
  }

  /// 收集嗅探到的接口响应体：服务端会先用规则解析器尝试它们（JSON 快路径），
  /// 命中时无需调用大模型。
  static List<String> collectCapturedBodies(Map<String, dynamic> capture) {
    return [
      for (final resp in (capture['captured'] as List? ?? const []))
        if (resp is Map &&
            resp['body'] is String &&
            (resp['body'] as String).isNotEmpty)
          stripIdentityInfo(_cap(resp['body'] as String, _maxCapturedChars)),
    ];
  }

  /// 把服务端契约（与教务代抓接口相同的 ImportedCourseOut）映射为本地模型。
  static List<ParsedCourse> mapCoursesResponse(List<dynamic> rawCourses) {
    final courses = <ParsedCourse>[];
    for (final rawCourse in rawCourses) {
      if (rawCourse is! Map) continue;
      final name = rawCourse['name'];
      if (name is! String || name.trim().isEmpty) continue;
      final slots = <ParsedSlot>[];
      for (final rawSlot in (rawCourse['slots'] as List? ?? const [])) {
        if (rawSlot is! Map) continue;
        final day = rawSlot['day_of_week'];
        final start = rawSlot['start_section'];
        final end = rawSlot['end_section'];
        if (day is! int || start is! int || end is! int) continue;
        if (day < 1 || day > 7 || start < 1 || end < start) continue;
        // 统一节次契约（review R12）：作息表、日视图与提醒最多支持 12 节，
        // 超出部分夹回支持范围。原样放行 13-30 节会让下游 startOf 抛
        // RangeError，整页日视图或整轮提醒重排一起挂掉。
        const maxSection = SectionTimeConfig.maxSection;
        var slotStart = start.clamp(1, maxSection);
        var slotEnd = end.clamp(1, maxSection);
        if (slotStart > slotEnd) slotStart = slotEnd;
        final weeksText = rawSlot['weeks_text'] as String? ?? '';
        final (weeksType, customWeeks) = YzuParser.parseWeeksText(weeksText);
        slots.add(
          ParsedSlot(
            dayOfWeek: day,
            startSection: slotStart,
            endSection: slotEnd,
            weeksType: weeksType,
            customWeeks: customWeeks,
            location: rawSlot['location'] as String? ?? '',
            weeksText: weeksText,
          ),
        );
      }
      if (slots.isEmpty) continue;
      courses.add(
        ParsedCourse(
          name: name.trim(),
          teacher: rawCourse['teacher'] as String? ?? '',
          slots: slots,
        ),
      );
    }
    return courses;
  }

  static String _cap(String text, int maxChars) =>
      text.length <= maxChars ? text : text.substring(0, maxChars);

  /// 只保留 scheme/host/path，查询参数可能携带会话 ticket。
  static String _safeUrl(dynamic url) {
    if (url is! String || url.isEmpty) return '';
    final uri = Uri.tryParse(url);
    if (uri == null || !uri.hasScheme) return '';
    return '${uri.scheme}://${uri.host}${uri.path}';
  }
}

class LlmImportException implements Exception {
  const LlmImportException(this.message);

  final String message;

  @override
  String toString() => message;
}

final llmImportRepositoryProvider = Provider<LlmImportRepository>(
  (ref) => LlmImportRepository(ref.read(dioProvider)),
);

// ---------------------------------------------------------------------------
// 合规红线（2026-09-02）：姓名、学号等身份信息和教务密码绝不上传。
// 以下规则与服务端 app/services/llm_schedule_import.py 的
// strip_identity_info 保持一致；服务端收到后会再执行一轮作为纵深防御。
// ---------------------------------------------------------------------------

/// 教务 JSON 接口常见身份字段键名（故意不含通用 "name"，那是课程名字段）。
final RegExp _identityJsonRe = RegExp(
  r'("(?:xm|xsm|xingming|studentname|stuname|realname|xh|xuehao|studentid'
  r'|student_id|zjh|sfzh|sfzhm|ksbh|idcard)"\s*:\s*")[^"]*(")',
  caseSensitive: false,
);

/// 页面文本里的「标签: 值」形式，值与标签之间最多隔几个 HTML 标签。
final RegExp _identityLabelRe = RegExp(
  '(?:姓名|学号|考生号|证件号|身份证号|学生编号)["\']?\\s*[:：]?\\s*["\']?'
  '(?:<[^>]*>\\s*){0,3}'
  '(?:[一-龥·]{2,4}(?=\\s*<|\$|[，,；;、\\s])|\\d{6,20}|[A-Za-z]{0,3}\\d{6,20})',
);

/// 9 位及以上纯数字串：学号/身份证/手机号。课程代码多含字母或不超过 8 位。
final RegExp _longNumberRe = RegExp(r'\d{9,}');

/// <script>/<style> 块整块移除：脚本里常内嵌 token、用户信息甚至回显的
/// 表单数据，规则替换无法枚举（review R13）。
final RegExp _scriptBlockRe = RegExp(
  r'<(script|style)\b[^>]*>[\s\S]*?</\1\s*>',
  caseSensitive: false,
);

/// <input>/<textarea>/<select> 标签整体移除：表单控件的 value 属性会回显
/// 已输入的密码/学号，hidden 字段会携带 CSRF token 等凭据。表单元素
/// 不承载课表内容，直接删掉最稳。
final RegExp _formControlRe = RegExp(
  r'<(input|textarea|select|button)\b[^>]*>(?:[^<]*</\1\s*>)?',
  caseSensitive: false,
);

/// 在上传内容离开设备前抹除姓名、学号等身份信息。
String stripIdentityInfo(String text) {
  if (text.isEmpty) return text;
  var out = text.replaceAll(_scriptBlockRe, '<script></script>');
  out = out.replaceAll(_formControlRe, '');
  out = out.replaceAllMapped(_identityJsonRe, (m) => '${m[1]}***${m[2]}');
  out = out.replaceAll(_identityLabelRe, '***');
  return out.replaceAll(_longNumberRe, '*********');
}
