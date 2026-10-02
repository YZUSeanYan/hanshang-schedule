/// 「其他学校教务导入」的学校目录数据。
///
/// 数据模型参考 WakeUp课程表 / CourseTable 类开源课表项目：
/// 每所学校 = {全称, 教务系统首页 URL, 教务系统类型标签}，按拼音首字母分组。
/// 内置常用高校（江苏为主 + 全国常见教务系统样板），命中后直接进入
/// App 内 WebView 导入；不在名单内的学校仍可在上一页的网址输入框手动输入。
class SchoolEntry {
  const SchoolEntry({
    required this.name,
    required this.url,
    required this.system,
  });

  /// 学校全称（列表主文本）
  final String name;

  /// 教务系统首页 URL（https）
  final String url;

  /// 教务系统类型标签（列表右侧标注，如 新URP / 正方 / 强智 / 青果 / URP）
  final String system;
}

/// 按拼音首字母 A-Z 排序的学校目录。
/// 注：名单可持续扩充；首字母用于分组与右侧索引。
const List<SchoolEntry> kSchoolDirectory = [
  // A
  SchoolEntry(
    name: '安庆师范大学',
    url: 'https://jwxt.aqnu.edu.cn',
    system: '新URP',
  ),
  SchoolEntry(
    name: '安康学院',
    url: 'https://jwgl.aku.edu.cn',
    system: '正方教务',
  ),
  // C
  SchoolEntry(
    name: '重庆大学',
    url: 'https://my.cqu.edu.cn',
    system: '新URP',
  ),
  // H
  SchoolEntry(
    name: '河海大学',
    url: 'https://jwc.hhu.edu.cn',
    system: '正方教务',
  ),
  SchoolEntry(
    name: '合肥工业大学',
    url: 'https://jwgl.hfut.edu.cn',
    system: '新URP',
  ),
  // J
  SchoolEntry(
    name: '江南大学',
    url: 'https://jwgl.jiangnan.edu.cn',
    system: '新URP',
  ),
  SchoolEntry(
    name: '江苏大学',
    url: 'https://jwc.ujs.edu.cn',
    system: '正方教务',
  ),
  SchoolEntry(
    name: '江苏师范大学',
    url: 'https://jwxt.jsnu.edu.cn',
    system: '正方教务',
  ),
  SchoolEntry(
    name: '江苏科技大学',
    url: 'https://jwgl.just.edu.cn',
    system: '强智教务',
  ),
  // N
  SchoolEntry(
    name: '南京大学',
    url: 'https://jw.nju.edu.cn',
    system: '新URP',
  ),
  SchoolEntry(
    name: '东南大学',
    url: 'https://jwc.seu.edu.cn',
    system: '新URP',
  ),
  SchoolEntry(
    name: '南京师范大学',
    url: 'https://jwxt.njnu.edu.cn',
    system: '正方教务',
  ),
  SchoolEntry(
    name: '南京理工大学',
    url: 'https://jw.njust.edu.cn',
    system: '正方教务',
  ),
  SchoolEntry(
    name: '南京航空航天大学',
    url: 'https://jwc.nuaa.edu.cn',
    system: '正方教务',
  ),
  SchoolEntry(
    name: '南京邮电大学',
    url: 'https://jwxt.njupt.edu.cn',
    system: '正方教务',
  ),
  SchoolEntry(
    name: '南京工业大学',
    url: 'https://jwgl.njtech.edu.cn',
    system: '新URP',
  ),
  SchoolEntry(
    name: '南京信息工程大学',
    url: 'https://jwxt.nuist.edu.cn',
    system: '正方教务',
  ),
  SchoolEntry(
    name: '南通大学',
    url: 'https://jwgl.ntu.edu.cn',
    system: '正方教务',
  ),
  // S
  SchoolEntry(
    name: '苏州大学',
    url: 'https://jwxt.suda.edu.cn',
    system: '新URP',
  ),
  SchoolEntry(
    name: '上海大学',
    url: 'https://jwxt.shu.edu.cn',
    system: '新URP',
  ),
  // X
  SchoolEntry(
    name: '西交利物浦大学',
    url: 'https://jwxt.xjtlu.edu.cn',
    system: '青果教务',
  ),
  SchoolEntry(
    name: '徐州工程学院',
    url: 'https://jwgl.xzit.edu.cn',
    system: '正方教务',
  ),
  // Y
  SchoolEntry(
    name: '扬州大学广陵学院',
    url: 'https://jwgl.yzu.edu.cn',
    system: 'URP系统',
  ),
  SchoolEntry(
    name: '盐城工学院',
    url: 'https://jwc.ycit.cn',
    system: '正方教务',
  ),
  // Z
  SchoolEntry(
    name: '中国矿业大学',
    url: 'https://jwxt.cumt.edu.cn',
    system: '新URP',
  ),
  SchoolEntry(
    name: '中国药科大学',
    url: 'https://jwc.cpu.edu.cn',
    system: '正方教务',
  ),
  SchoolEntry(
    name: '浙江大学',
    url: 'https://jwgl.zju.edu.cn',
    system: '新URP',
  ),
];

/// 学校名 → 拼音首字母（A-Z，# 表示非字母开头）。
/// 内置目录内的学校按首个汉字映射；未知汉字按拼音库粗查，兜底 #。
String schoolInitial(String name) {
  if (name.isEmpty) return '#';
  final ch = name.codeUnitAt(0);
  if (ch >= 65 && ch <= 90) return String.fromCharCode(ch); // A-Z
  if (ch >= 97 && ch <= 122) {
    return String.fromCharCode(ch - 32); // a-z → A-Z
  }
  return _initialOf(String.fromCharCode(ch)) ?? '#';
}

/// 常用汉字拼音首字母粗查表（仅覆盖内置目录需要的字）。
String? _initialOf(String ch) => switch (ch) {
      '安' || '爱' => 'A',
      '重' || '成' || '常' => 'C',
      '东' || '大' => 'D',
      '合' || '河' || '淮' => 'H',
      '江' || '济' => 'J',
      '南' || '宁' => 'N',
      '苏' || '上' || '山' => 'S',
      '西' || '徐' || '扬' || '盐' => 'X',
      '中' || '浙' || '镇' => 'Z',
      _ => null,
    };
