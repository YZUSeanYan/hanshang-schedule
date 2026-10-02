import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/schedule/data/schedule_repository.dart';

/// 课程卡片是否显示教师与校区（默认收起：名称/教室/楼名三级优先，
/// 教师、校区与周次等完整信息点按卡片进详情查看）。
class CourseCardDisplay extends Notifier<bool> {
  static const _key = 'course_card_show_teacher_campus';

  @override
  bool build() {
    _restore();
    return false;
  }

  Future<void> _restore() async {
    final saved = await ref.read(settingsRepositoryProvider).get(_key);
    final show = saved == '1';
    if (show != state) state = show;
  }

  Future<void> setShow(bool value) async {
    state = value;
    await ref
        .read(settingsRepositoryProvider)
        .set(_key, value ? '1' : '0');
  }
}

final courseCardDisplayProvider =
    NotifierProvider<CourseCardDisplay, bool>(CourseCardDisplay.new);
