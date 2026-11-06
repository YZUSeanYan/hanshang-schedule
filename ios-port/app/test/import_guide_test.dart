import 'package:flutter_test/flutter_test.dart';
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
}
