import 'dart:convert';
import 'dart:typed_data';
import 'package:cryptography/cryptography.dart';
import 'package:dio/dio.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yzu_schedule/features/course_import/data/import_runtime.dart';
import 'package:yzu_schedule/import/yzu_parser.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final now = DateTime.utc(2026, 9, 7);
  Map<String, dynamic> payload() => {'schema': 1, 'revision': 2, 'minBuild': 34,
    'maxBuild': 40, 'issuedAt': now.millisecondsSinceEpoch ~/ 1000,
    'expiresAt': now.add(const Duration(days: 7)).millisecondsSinceEpoch ~/ 1000,
    'entryUrl': 'https://webvpn.yzu.edu.cn/login', 'enabled': true,
    'guide': '新引导', 'urlHints': ['newCurriculum'],
    'fieldAliases': {'newName': 'courseName', 'newDay': 'dayOfWeek'}, 'intermediates': []};
  test('signed runtime is verified; tampering, expiry and incompatible build fail', () async {
    final key = await Ed25519().newKeyPair();
    final store = ImportRuntimeStore(publicKey: (await key.extractPublicKey()).bytes);
    final bytes = utf8.encode(jsonEncode(payload()));
    final sig = await Ed25519().sign(bytes, keyPair: key);
    String envelope(List<int> data) => jsonEncode({'payload': base64Encode(data), 'signature': base64Encode(sig.bytes)});
    final good = envelope(bytes);
    expect((await store.verify(good, build: 34, now: now)).revision, 2);
    await expectLater(store.verify(envelope(utf8.encode('{}')), build: 34, now: now), throwsFormatException);
    await expectLater(store.verify(good, build: 33, now: now), throwsFormatException);
    await expectLater(store.verify(good, build: 41, now: now), throwsFormatException);
    await expectLater(store.verify(good, build: 34, now: now.add(const Duration(days: 8))), throwsFormatException);
    final other = ImportRuntimeStore(publicKey: (await (await Ed25519().newKeyPair()).extractPublicKey()).bytes);
    await expectLater(other.verify(good, build: 34, now: now), throwsFormatException);
  });
  test('runtime cannot change scheme, destination authority or inject code', () {
    for (final url in ['http://webvpn.yzu.edu.cn/', 'https://yzu.edu.cn.evil.test/',
      'https://a@webvpn.yzu.edu.cn/', 'https://webvpn.yzu.edu.cn:444/']) {
      expect(() => ImportRuntime.fromPayload({...payload(), 'entryUrl': url}, build: 34, now: now), throwsFormatException);
    }
    expect(() => ImportRuntime.fromPayload({...payload(), 'urlHints': ['x);alert(1)//']}, build: 34, now: now), throwsFormatException);
    expect(() => ImportRuntime.fromPayload({...payload(), 'fieldAliases': {'secret': 'arbitraryCode'}}, build: 34, now: now), throwsFormatException);
  });
  test('remote field changes repair parsing without changing the APK parser', () {
    final config = ImportRuntime.fromPayload(payload(), build: 34, now: now);
    final body = jsonEncode([{'newName': '数学', 'newDay': 2, 'startSection': 3, 'endSection': 4, 'weeksText': '1-16周'}]);
    expect(YzuParser.tryParseJson(body), isNull);
    final courses = YzuParser.tryParseJson(body, fieldAliases: config.fieldAliases)!;
    expect(courses.single.name, '数学');
    expect(courses.single.slots.single.dayOfWeek, 2);
    expect(config.snifferScript, contains('newCurriculum'));
    expect(config.snifferScript, contains('runtimeFields'));
  });
  test('canonical fields cannot be overwritten by aliases', () {
    final body = jsonEncode([{'newName': 'wrong', 'courseName': 'right', 'dayOfWeek': 1, 'startSection': 1, 'endSection': 2}]);
    expect(YzuParser.tryParseJson(body, fieldAliases: {'newName': 'courseName'})!.single.name, 'right');
  });
  test('last known good survives offline, tampering and replay; new revision replaces it', () async {
    SharedPreferences.setMockInitialValues({});
    final key = await Ed25519().newKeyPair();
    final pub = (await key.extractPublicKey()).bytes;
    Future<String> signed(int revision) async {
      final raw = utf8.encode(jsonEncode({...payload(), 'revision': revision,
        'issuedAt': DateTime.now().millisecondsSinceEpoch ~/ 1000,
        'expiresAt': DateTime.now().add(const Duration(days: 1)).millisecondsSinceEpoch ~/ 1000}));
      final sig = await Ed25519().sign(raw, keyPair: key);
      return jsonEncode({'payload': base64Encode(raw), 'signature': base64Encode(sig.bytes)});
    }
    Future<ImportRuntime> load(String? response) => ImportRuntimeStore(publicKey: pub,
      endpoint: Uri.parse('https://runtime.example.test/api/import-runtime'),
      clientFactory: () => Dio()..httpClientAdapter = RuntimeAdapter(response)).load(build: 34);
    expect((await load(await signed(2))).revision, 2);
    expect((await load(null)).revision, 2);
    expect((await load('{}')).revision, 2);
    expect((await load(await signed(1))).revision, 2);
    expect((await load(await signed(3))).revision, 3);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(ImportRuntimeStore.cacheKey, 'corrupt');
    expect((await load(null)).revision, 0);
    expect((await load(await signed(2))).revision, 0);
    expect((await load(await signed(4))).revision, 4);
  });
}

class RuntimeAdapter implements HttpClientAdapter {
  RuntimeAdapter(this.response);
  final String? response;
  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    if (response == null) throw DioException.connectionError(requestOptions: options, reason: 'offline');
    return ResponseBody.fromString(response!, 200);
  }
  @override
  void close({bool force = false}) {}
}
