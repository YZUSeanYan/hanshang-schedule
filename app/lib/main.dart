import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app.dart';

/// 应用入口
void main() {
  // ProviderScope：Riverpod 状态管理的根容器
  runApp(const ProviderScope(child: YzuScheduleApp()));
}
