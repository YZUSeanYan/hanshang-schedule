import 'package:flutter_test/flutter_test.dart';
import 'package:yzu_schedule/features/course_import/data/school_url_policy.dart';

void main() {
  test('Yunzhou school navigation requires trusted HTTPS authority', () {
    expect(isAllowedSchoolUri(Uri.parse('https://webvpn.yzu.edu.cn/')), isTrue);
    expect(isAllowedSchoolUri(Uri.parse('https://webvpn.yzu.edu.cn:443/login')), isTrue);
    expect(isAllowedSchoolUri(Uri.parse('https://webvpn.yzu.edu.cn:8443/login')), isFalse);
    expect(isAllowedSchoolUri(Uri.parse('https://user:pass@webvpn.yzu.edu.cn/')), isFalse);
    expect(isAllowedSchoolUri(Uri.parse('https://webvpn.yzu.edu.cn.evil.test/')), isFalse);
    expect(isAllowedSchoolUri(Uri.parse('http://webvpn.yzu.edu.cn/')), isFalse);
  });
}
