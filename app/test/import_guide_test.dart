import 'package:flutter_test/flutter_test.dart';
import 'package:yzu_schedule/features/course_import/data/import_runtime.dart';
import 'package:yzu_schedule/features/course_import/presentation/import_webview_page.dart';

void main() {
  test('导入引导包含学生端与班级课表完整路径', () {
    const guide = ImportWebViewPage.guideText;

    expect(guide, contains('教务系统（学生端）'));
    expect(guide, contains('常用服务'));
    expect(guide, contains('班级课表'));
    expect(guide, contains('选择对应班级'));
    expect(guide, contains('课表信息'));
    expect(guide, contains('抓取课表'));
  });

  test('引导文案选择：runtime 命中学校优先，未命中回落通用文案', () {
    const schoolWithGuide = RuntimeSchool(
      name: '测试大学',
      url: 'https://jwxt.test.edu.cn',
      system: '正方教务',
      guide: '登录后进入个人课表页再点抓取',
    );
    const schoolWithoutGuide = RuntimeSchool(
      name: '裸大学',
      url: 'https://plain.edu.cn',
      system: '',
    );

    // 通用模式：命中学校 → 学校专属引导
    expect(
      ImportWebViewPage.guideFor(
          genericMode: true, school: schoolWithGuide, runtimeGuide: ''),
      '登录后进入个人课表页再点抓取',
    );
    // 通用模式：命中学校但无引导 → 通用文案
    expect(
      ImportWebViewPage.guideFor(
          genericMode: true, school: schoolWithoutGuide, runtimeGuide: ''),
      ImportWebViewPage.genericGuideText,
    );
    // 通用模式：未命中 → 通用文案
    expect(
      ImportWebViewPage.guideFor(genericMode: true, school: null, runtimeGuide: ''),
      ImportWebViewPage.genericGuideText,
    );
    // 扬大模式：runtime 引导优先于内置文案，空则回落
    expect(
      ImportWebViewPage.guideFor(
          genericMode: false, school: schoolWithGuide, runtimeGuide: '远程扬大引导'),
      '远程扬大引导',
    );
    expect(
      ImportWebViewPage.guideFor(genericMode: false, school: null, runtimeGuide: ''),
      ImportWebViewPage.guideText,
    );
  });
}
