import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:dio/dio.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/config/app_config.dart';
import '../../../import/sniffer_js.dart';
import 'runtime_defaults.dart';
import 'school_url_policy.dart';

/// 单所学校的远程适配配置（import-runtime schema 2 的 `schools` 条目）。
///
/// 全部是声明式数据：嗅探关键词与字段别名沿用全局槽位的白名单校验，
/// 不携带任何可执行内容；`url` 的 host 即该配置的唯一键。
class RuntimeSchool {
  const RuntimeSchool({
    required this.name,
    required this.url,
    required this.system,
    this.initial = '',
    this.guide = '',
    this.urlHints = const [],
    this.fieldAliases = const {},
    this.intermediates = const [],
  });

  final String name, url, system, guide;

  /// 拼音首字母（A-Z 单字符，可空）。仅用于目录分组：客户端内置拼音表
  /// 只覆盖少量汉字，远程名单必须自带首字母才能正确落组。
  final String initial;

  final List<String> urlHints, intermediates;
  final Map<String, String> fieldAliases;

  String get host => Uri.tryParse(url)?.host.toLowerCase() ?? '';

  /// 带针对性适配（引导/嗅探词/别名/证书）的学校在学校目录中标「已适配」。
  bool get isAdapted =>
      guide.isNotEmpty ||
      urlHints.isNotEmpty ||
      fieldAliases.isNotEmpty ||
      intermediates.isNotEmpty;

  factory RuntimeSchool.fromPayload(Map<String, dynamic> data) {
    String bounded(String key, int max, {bool required_ = true}) {
      final value = data[key];
      if (value is! String || value.isEmpty) {
        if (required_ || (value != null && value != '')) {
          throw const FormatException('Invalid school string');
        }
        return '';
      }
      if (value.length > max) throw const FormatException('School string too long');
      return value;
    }

    final name = bounded('name', 80);
    final url = bounded('url', 2048);
    final uri = Uri.tryParse(url);
    if (name.isEmpty ||
        uri == null ||
        uri.scheme.toLowerCase() != 'https' ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasFragment ||
        (uri.hasPort && uri.port != 443)) {
      throw const FormatException('Invalid school url');
    }
    final guide = bounded('guide', 600, required_: false);
    List<String> strings(String key, int count, int length) {
      final values = data[key] ?? <String>[];
      if (values is! List ||
          values.length > count ||
          values.any((v) => v is! String || v.isEmpty || v.length > length)) {
        throw const FormatException('Invalid school list');
      }
      return List<String>.unmodifiable(values.cast<String>());
    }

    final hints = strings('urlHints', 8, 80);
    if (hints.any(
        (v) => v.length < 3 || !RegExp(r'^[a-zA-Z0-9_/.-]+$').hasMatch(v))) {
      throw const FormatException('Invalid school hint');
    }
    final aliases = data['fieldAliases'] ?? <String, String>{};
    if (aliases is! Map ||
        aliases.length > 16 ||
        aliases.entries.any((e) =>
            e.key is! String ||
            !RegExp(r'^[a-zA-Z][a-zA-Z0-9_]{0,63}$').hasMatch(e.key) ||
            !ImportRuntime.targets.contains(e.value))) {
      throw const FormatException('Invalid school field mapping');
    }
    final certs = strings('intermediates', 2, 22000);
    for (final cert in certs) {
      if (base64Decode(cert).length > 16384) {
        throw const FormatException('School certificate too large');
      }
    }
    final initial = bounded('initial', 1, required_: false);
    if (initial.isNotEmpty && !RegExp(r'^[A-Z]$').hasMatch(initial)) {
      throw const FormatException('Invalid school initial');
    }
    return RuntimeSchool(
        name: name,
        url: url,
        system: bounded('system', 32, required_: false),
        initial: initial,
        guide: guide,
        urlHints: hints,
        fieldAliases:
            Map<String, String>.unmodifiable(aliases.cast<String, String>()),
        intermediates: certs);
  }
}

/// Signed declarative updates only. No downloaded Dart, JavaScript or native code.
class ImportRuntime {
  const ImportRuntime(
      {this.revision = 0,
      this.entryUrl = 'https://webvpn.yzu.edu.cn/',
      this.guide = '',
      this.urlHints = const [],
      this.fieldAliases = const {},
      this.intermediates = const [],
      this.schools = const [],
      this.enabled = true});
  final int revision;
  final String entryUrl, guide;
  final bool enabled;
  final List<String> urlHints, intermediates;
  final Map<String, String> fieldAliases;

  /// 按学校下发的适配配置（schema 2；schema 1 为空）。host 唯一。
  final List<RuntimeSchool> schools;
  static const bundled = ImportRuntime(intermediates: [bundledIntermediate]);
  static const targets = {
    'courseName',
    'teacherName',
    'location',
    'dayOfWeek',
    'startSection',
    'endSection',
    'weeksText',
    'timeAndPlaceList'
  };

  factory ImportRuntime.fromPayload(Map<String, dynamic> data,
      {required int build, required DateTime now}) {
    int number(String key) {
      final value = data[key];
      if (value is! int) throw const FormatException('Invalid integer');
      return value;
    }

    final schema = number('schema');
    if ((schema != 1 && schema != 2) ||
        number('revision') < 1 ||
        build < number('minBuild') ||
        build > number('maxBuild') ||
        now.millisecondsSinceEpoch ~/ 1000 >= number('expiresAt') ||
        number('issuedAt') > now.millisecondsSinceEpoch ~/ 1000 + 300) {
      throw const FormatException('Incompatible or expired runtime');
    }
    final entry = data['entryUrl'];
    final uri = entry is String ? Uri.tryParse(entry) : null;
    if (!isAllowedSchoolUri(uri) ||
        uri!.userInfo.isNotEmpty ||
        uri.hasFragment ||
        (uri.hasPort && uri.port != 443) ||
        entry.length > 2048) {
      throw const FormatException('Invalid school entry');
    }
    final guide = data['guide'] ?? '';
    if (guide is! String || guide.length > 1200 || data['enabled'] is! bool) {
      throw const FormatException('Invalid guide');
    }
    List<String> strings(String key, int count, int length) {
      final values = data[key] ?? <String>[];
      if (values is! List ||
          values.length > count ||
          values.any((v) => v is! String || v.isEmpty || v.length > length)) {
        throw const FormatException('Invalid list');
      }
      return List<String>.unmodifiable(values.cast<String>());
    }

    final hints = strings('urlHints', 24, 80);
    if (hints.any(
        (v) => v.length < 3 || !RegExp(r'^[a-zA-Z0-9_/.-]+$').hasMatch(v))) {
      throw const FormatException('Invalid literal hint');
    }
    final aliases = data['fieldAliases'] ?? <String, String>{};
    if (aliases is! Map ||
        aliases.length > 32 ||
        aliases.entries.any((e) =>
            e.key is! String ||
            !RegExp(r'^[a-zA-Z][a-zA-Z0-9_]{0,63}$').hasMatch(e.key) ||
            !targets.contains(e.value))) {
      throw const FormatException('Invalid field mapping');
    }
    final certs = strings('intermediates', 8, 22000);
    for (final cert in certs) {
      if (base64Decode(cert).length > 16384) {
        throw const FormatException('Certificate too large');
      }
    }
    // schema 2：按学校下发适配配置。任一条目非法即整体拒绝（fail-closed，
    // 客户端保留 last known good），防止发布侧笔误造成半生效状态。
    final rawSchools = data['schools'] ?? const <dynamic>[];
    if (rawSchools is! List || rawSchools.length > 400) {
      throw const FormatException('Invalid schools');
    }
    final schools = <RuntimeSchool>[];
    final hosts = <String>{};
    for (final raw in rawSchools) {
      if (raw is! Map<String, dynamic>) {
        throw const FormatException('Invalid school entry');
      }
      final school = RuntimeSchool.fromPayload(raw);
      if (!hosts.add(school.host)) {
        throw const FormatException('Duplicate school host');
      }
      schools.add(school);
    }
    return ImportRuntime(
        revision: number('revision'),
        entryUrl: entry,
        guide: guide,
        enabled: data['enabled'],
        urlHints: hints,
        fieldAliases:
            Map<String, String>.unmodifiable(aliases.cast<String, String>()),
        intermediates: certs,
        schools: List<RuntimeSchool>.unmodifiable(schools));
  }

  /// 按教务系统域名（大小写不敏感精确匹配）查找学校适配配置。
  RuntimeSchool? schoolForHost(String? host) {
    final key = host?.toLowerCase() ?? '';
    if (key.isEmpty) return null;
    for (final school in schools) {
      if (school.host == key) return school;
    }
    return null;
  }

  /// 返回并入指定学校配置后的生效运行时：学校嗅探词/字段别名优先，
  /// 全局值兜底；证书学校优先（扬大 WebVPN 专属 CA 只在其他学校没有
  /// 自身中间证书时才作为兜底参与补链）。
  ImportRuntime effectiveForSchool(RuntimeSchool? school) {
    if (school == null) return this;
    return ImportRuntime(
        revision: revision,
        entryUrl: entryUrl,
        guide: guide,
        enabled: enabled,
        urlHints: List<String>.unmodifiable(
            (<String>{...school.urlHints, ...urlHints}).take(24)),
        fieldAliases: Map<String, String>.unmodifiable(
            <String, String>{...fieldAliases, ...school.fieldAliases}),
        intermediates: List<String>.unmodifiable(
            (<String>{...school.intermediates, ...intermediates}).take(8)),
        schools: schools);
  }

  String get snifferScript => kYzuSnifferInjectJs
      .replaceFirst(
          '  var MAX_KEEP = 30;',
          '  var runtimeUrls = ${jsonEncode(urlHints)};\n'
              '  var runtimeFields = ${jsonEncode(fieldAliases.keys.toList())};\n'
              '  var MAX_KEEP = 30;')
      .replaceFirst("if (URL_HINT.test(url || '')) return true;",
          "if (URL_HINT.test(url || '') || runtimeUrls.some(function(h) { return (url || '').indexOf(h) >= 0; })) return true;")
      .replaceFirst('return BODY_HINT.test(head);',
          'return BODY_HINT.test(head) || runtimeFields.some(function(h) { return head.indexOf(JSON.stringify(h)) >= 0; });');
}

class ImportRuntimeStore {
  static const cacheKey = 'import_runtime_signed_v1';
  static const maximumBytes = 196608;
  final List<int> publicKey;
  final Dio Function()? clientFactory;
  final Uri? endpoint;
  ImportRuntimeStore({List<int>? publicKey, this.clientFactory, this.endpoint})
      : publicKey = publicKey ?? base64Decode(runtimePublicKey);

  Future<ImportRuntime> verify(String envelope,
      {required int build, DateTime? now}) async {
    if (utf8.encode(envelope).length > maximumBytes) {
      throw const FormatException('Oversized runtime');
    }
    final object = jsonDecode(envelope) as Map<String, dynamic>;
    final payload = base64Decode(object['payload'] as String);
    final signature = base64Decode(object['signature'] as String);
    if (signature.length != 64 ||
        !await Ed25519().verify(payload,
            signature: Signature(signature,
                publicKey:
                    SimplePublicKey(publicKey, type: KeyPairType.ed25519)))) {
      throw const FormatException('Runtime signature mismatch');
    }
    return ImportRuntime.fromPayload(
        jsonDecode(utf8.decode(payload)) as Map<String, dynamic>,
        build: build,
        now: now ?? DateTime.now());
  }

  Future<ImportRuntime> load({required int build}) async {
    var active = ImportRuntime.bundled;
    SharedPreferences? prefs;
    try {
      prefs = await SharedPreferences.getInstance();
      final cached = prefs.getString(cacheKey);
      if (cached != null) active = await verify(cached, build: build);
    } catch (_) {/* Invalid cache always falls back to compiled defaults. */}
    final dio = clientFactory?.call() ?? Dio(BaseOptions(
        connectTimeout: const Duration(seconds: 2),
        receiveTimeout: const Duration(seconds: 2),
        followRedirects: false));
    final cancel = CancelToken();
    final deadline = Timer(const Duration(seconds: 3), () => cancel.cancel('Runtime deadline'));
    try {
      final url = endpoint?.toString() ??
          '${AppConfig.apiBaseUrl.replaceAll(RegExp(r'/+$'), '')}/api/import-runtime';
      if (Uri.parse(url).scheme != 'https') return active;
      final response = await dio.get<ResponseBody>(url, cancelToken: cancel,
          options: Options(responseType: ResponseType.stream));
      final bytes = BytesBuilder(copy: false);
      await for (final part
          in response.data!.stream.timeout(const Duration(seconds: 2))) {
        if (bytes.length + part.length > maximumBytes) {
          throw const FormatException('Oversized runtime');
        }
        bytes.add(part);
      }
      final text = utf8.decode(bytes.takeBytes());
      final next = await verify(text, build: build);
      if (next.revision >= active.revision && next.revision >= (prefs?.getInt('import_runtime_highest_v1') ?? 0)) {
        await prefs?.setString(cacheKey, text);
        await prefs?.setInt('import_runtime_highest_v1', next.revision);
        active = next;
      }
    } catch (_) {
      /* Offline, timeout, bad signature: retain last known good. */
    } finally {
      deadline.cancel();
      dio.close(force: true);
    }
    return active;
  }
}
