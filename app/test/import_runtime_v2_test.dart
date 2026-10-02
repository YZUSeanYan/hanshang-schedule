import 'dart:convert';
import 'dart:typed_data';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yzu_schedule/features/course_import/data/import_runtime.dart';

/// import-runtime schema 2（按学校下发适配配置）的解析、校验与生效逻辑。
///
/// 安全红线回归：schools 条目必须与全局槽位同样防 JS 注入、防 URL 漂移，
/// 任何一条非法即整体拒绝（fail-closed 保留 last known good）。
void main() {
  final now = DateTime.utc(2026, 10, 2);

  Map<String, dynamic> payload(
          {int schema = 2, Object? schools, Map<String, String>? fieldAliases}) =>
      {
        'schema': schema,
        'revision': 12,
        'minBuild': 68,
        'maxBuild': 999,
        'issuedAt': now.millisecondsSinceEpoch ~/ 1000,
        'expiresAt':
            now.add(const Duration(days: 7)).millisecondsSinceEpoch ~/ 1000,
        'entryUrl': 'https://webvpn.yzu.edu.cn/login',
        'enabled': true,
        'guide': '全局扬大引导',
        'urlHints': ['newCurriculum'],
        'fieldAliases': fieldAliases ?? {'globalName': 'courseName'},
        'intermediates': <String>[],
        if (schools != null) 'schools': schools,
      };

  Map<String, dynamic> school({
    String name = '南京邮电大学',
    String url = 'https://jwxt.njupt.edu.cn/',
    String system = '正方教务',
    String guide = '登录后进入个人课表页再点抓取',
    List<String> urlHints = const ['xskb'],
    Map<String, String> fieldAliases = const {'kcmc': 'courseName'},
  }) =>
      {
        'name': name,
        'url': url,
        'system': system,
        'guide': guide,
        'urlHints': urlHints,
        'fieldAliases': fieldAliases,
      };

  ImportRuntime parse(Map<String, dynamic> data) =>
      ImportRuntime.fromPayload(data, build: 68, now: now);

  group('schema 2 解析与校验', () {
    test('合法 payload：schools 逐条解析，host 由 url 派生', () {
      final runtime = parse(payload(schools: [school()]));
      expect(runtime.schools.single.name, '南京邮电大学');
      expect(runtime.schools.single.host, 'jwxt.njupt.edu.cn');
      expect(runtime.schools.single.isAdapted, isTrue);
    });

    test('schema 1 向后兼容：无 schools 键 → 空目录，老缓存可继续使用', () {
      final runtime = parse(payload(schema: 1));
      expect(runtime.schools, isEmpty);
      expect(runtime.guide, '全局扬大引导');
    });

    test('单条非法即整体拒绝（fail-closed）', () {
      final cases = [
        school(url: 'http://jwxt.njupt.edu.cn/'),
        school(url: 'https://kcm@jwxt.njupt.edu.cn/'),
        school(url: 'https://jwxt.njupt.edu.cn/#frag'),
        school(url: 'https://jwxt.njupt.edu.cn:8443/'),
        school(name: ''),
        school(name: 'x' * 81),
        school(guide: 'g' * 601),
        school(urlHints: ['']),
        school(urlHints: ["x');alert(1)//"]),
        school(urlHints: ['a1', 'a2', 'a3', 'a4', 'a5', 'a6', 'a7', 'a8', 'a9']),
        school(fieldAliases: {'secret': 'arbitraryCode'}),
        school(fieldAliases: {'1bad': 'courseName'}),
      ];
      for (final bad in cases) {
        expect(
          () => parse(payload(schools: [bad])),
          throwsFormatException,
          reason: bad.toString(),
        );
      }
    });

    test('规模与结构约束：>400 条、重复 host、非对象条目均拒绝', () {
      expect(
        () => parse(payload(
            schools: List.generate(
                401, (i) => school(url: 'https://h$i.example.edu.cn')))),
        throwsFormatException,
      );
      expect(
        () => parse(payload(schools: [school(), school()])),
        throwsFormatException,
      );
      expect(
        () => parse(payload(schools: ['not-a-map'])),
        throwsFormatException,
      );
      expect(
        () => parse(payload(schools: 'oops')),
        throwsFormatException,
      );
    });

    test('guide/system 缺省为空但不得为非法类型', () {
      final minimal = {
        'name': '某某学院',
        'url': 'https://jw.minimal.edu.cn',
      };
      final runtime = parse(payload(schools: [minimal]));
      expect(runtime.schools.single.guide, isEmpty);
      expect(runtime.schools.single.system, isEmpty);
      expect(runtime.schools.single.isAdapted, isFalse);
      expect(
        () => parse(payload(schools: [
          {'name': 'x', 'url': 'https://a.example.edu.cn', 'guide': 42}
        ])),
        throwsFormatException,
      );
    });

    test('initial 只接受单个 A-Z，非法即拒绝；合法值随条目解析', () {
      final runtime = parse(payload(schools: [
        {'name': 'S', 'url': 'https://s1.example.edu.cn', 'initial': 'Z'},
      ]));
      expect(runtime.schools.single.initial, 'Z');
      expect(runtime.schools.single.isAdapted, isFalse);
      for (final bad in ['b', 'AB', '1', '浙']) {
        expect(
          () => parse(payload(schools: [
            {'name': 'S', 'url': 'https://s2.example.edu.cn', 'initial': bad}
          ])),
          throwsFormatException,
          reason: bad,
        );
      }
    });

    test('schema 3 / 老版本 build 依旧拒绝', () {
      expect(() => parse(payload(schema: 3)), throwsFormatException);
      expect(
        () => ImportRuntime.fromPayload(payload(), build: 67, now: now),
        throwsFormatException,
      );
    });
  });

  group('按 host 查找与生效合并', () {
    final runtime = parse(payload(schools: [
      school(),
      school(
          name: '测试大学',
          url: 'https://JWXT.Test.edu.cn',
          system: '强智',
          guide: '',
          urlHints: ['kbList'],
          fieldAliases: {}),
    ]));

    test('schoolForHost 大小写不敏感精确匹配，未命中返回 null', () {
      expect(runtime.schoolForHost('jwxt.njupt.edu.cn')?.name, '南京邮电大学');
      expect(runtime.schoolForHost('JWXT.TEST.EDU.CN')?.name, '测试大学');
      expect(runtime.schoolForHost('sub.jwxt.njupt.edu.cn'), isNull);
      expect(runtime.schoolForHost(''), isNull);
      expect(runtime.schoolForHost(null), isNull);
      expect(ImportRuntime.bundled.schoolForHost('jwxt.njupt.edu.cn'), isNull);
    });

    test('effectiveForSchool：学校嗅探词优先、全局兜底、去重封顶 24', () {
      final target = runtime.schools.first;
      final effective = runtime.effectiveForSchool(target);
      expect(effective.urlHints.first, 'xskb');
      expect(effective.urlHints, contains('newCurriculum'));
      expect(effective.urlHints.length, lessThanOrEqualTo(24));
      expect(effective.fieldAliases['kcmc'], 'courseName');
      expect(effective.fieldAliases['globalName'], 'courseName');
      // 别名冲突时学校覆盖全局
      final conflict = parse(payload(
          fieldAliases: {'kcmc': 'courseName'},
          schools: [school(fieldAliases: {'kcmc': 'teacherName'})]));
      expect(
        conflict
            .effectiveForSchool(conflict.schools.first)
            .fieldAliases['kcmc'],
        'teacherName',
      );
      // 未命中/无学校 → 原样返回
      expect(identical(runtime.effectiveForSchool(null), runtime), isTrue);
    });

    test('生效运行时的嗅探脚本注入学校关键词（防注入回归）', () {
      final effective = runtime.effectiveForSchool(runtime.schools.first);
      expect(effective.snifferScript, contains('xskb'));
      expect(effective.snifferScript, contains('kcmc'));
      expect(effective.snifferScript, contains('runtimeUrls'));
      // 学校配置经过白名单校验，只有安全字面量能进入脚本
      final hostile = RuntimeSchool.fromPayload({
        'name': 'H',
        'url': 'https://h.example.edu.cn',
        'urlHints': ['safe-literal'],
      });
      final hostileEffective = runtime.effectiveForSchool(hostile);
      expect(hostileEffective.snifferScript, contains('safe-literal'));
    });

    test('中间证书：学校优先、全局兜底、去重封顶 8', () {
      final runtimeWithCerts = ImportRuntime(
        revision: 1,
        urlHints: const [],
        intermediates: const ['globalCertBase64=='],
        schools: [
          const RuntimeSchool(
              name: 'C',
              url: 'https://c.example.edu.cn',
              system: '',
              intermediates: ['schoolCertBase64==']),
        ],
      );
      final effective =
          runtimeWithCerts.effectiveForSchool(runtimeWithCerts.schools.single);
      expect(effective.intermediates.first, 'schoolCertBase64==');
      expect(effective.intermediates, contains('globalCertBase64=='));
      expect(effective.intermediates.length, lessThanOrEqualTo(8));
    });
  });

  group('签名信封端到端', () {
    test('带 schools 的签名 payload 通过 verify；篡改 schools 被拒', () async {
      final key = await Ed25519().newKeyPair();
      final store =
          ImportRuntimeStore(publicKey: (await key.extractPublicKey()).bytes);
      final bytes = utf8.encode(jsonEncode(payload(schools: [school()])));
      final sig = await Ed25519().sign(bytes, keyPair: key);
      final envelope = jsonEncode(
          {'payload': base64Encode(bytes), 'signature': base64Encode(sig.bytes)});
      final verified = await store.verify(envelope, build: 68, now: now);
      expect(verified.schools.single.host, 'jwxt.njupt.edu.cn');

      // 篡改 payload（换掉 schools）→ 验签失败
      final tampered = utf8.encode(jsonEncode(payload(schools: [
        school(name: '假大学', url: 'https://evil.example.edu.cn'),
      ])));
      final tamperedEnvelope = jsonEncode({
        'payload': base64Encode(tampered),
        'signature': base64Encode(sig.bytes),
      });
      await expectLater(
        store.verify(tamperedEnvelope, build: 68, now: now),
        throwsFormatException,
      );
    });
  });
}
