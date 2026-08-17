/// 只允许扬州大学 HTTPS 站点承载教务登录、凭据捕获与自动填入。
bool isAllowedSchoolUri(Uri? uri) {
  if (uri?.scheme.toLowerCase() != 'https') return false;
  final host = uri?.host.toLowerCase() ?? '';
  return host == 'yzu.edu.cn' || host.endsWith('.yzu.edu.cn');
}
