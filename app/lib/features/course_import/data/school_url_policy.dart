/// 只允许扬州大学 HTTPS 站点作为扬大模式的教务导入导航白名单。
bool isAllowedSchoolUri(Uri? uri) {
  if (uri?.scheme.toLowerCase() != 'https') return false;
  final host = uri?.host.toLowerCase() ?? '';
  return host == 'yzu.edu.cn' || host.endsWith('.yzu.edu.cn');
}
