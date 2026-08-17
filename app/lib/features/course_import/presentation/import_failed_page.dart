import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// 导入失败页（设计文档 4.2 要求：解析失败时给用户明确反馈和自救路径）。
///
/// 展示解析器返回的诊断信息，并给出排查建议；
/// 引导用户把课表页面样本（截图/网页另存）反馈给开发者，
/// 以便按真实教务结构迭代解析器。
class ImportFailedPage extends StatelessWidget {
  const ImportFailedPage({super.key, required this.detail});

  /// 解析器返回的诊断信息
  final String detail;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('未能识别课表')),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          Icon(Icons.search_off, size: 64, color: colorScheme.outline),
          const SizedBox(height: 16),
          Text('这个页面的课表结构暂时认不出来',
              style: Theme.of(context).textTheme.titleMedium,
              textAlign: TextAlign.center),
          const SizedBox(height: 16),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Text('诊断信息：$detail',
                  style: Theme.of(context).textTheme.bodySmall),
            ),
          ),
          const SizedBox(height: 16),
          Text('可以试试：', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 8),
          const Text('1. 确认已进到「我的课表 / 学生课表」页面，'
              '并且课表格子已经显示出来；\n'
              '2. 如果课表是按周切换的，先切到第 1 周再抓取；\n'
              '3. 返回上一页重新加载后再试一次；\n'
              '4. 仍失败：点下方「复制诊断信息」并发给开发者。'
              '诊断只包含页面结构与字段类型，不包含密码和字段值。'),
          const SizedBox(height: 24),
          FilledButton.icon(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: detail));
              if (!context.mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('诊断信息已复制')),
              );
            },
            icon: const Icon(Icons.copy),
            label: const Text('复制诊断信息'),
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: () => Navigator.of(context).pop(),
            icon: const Icon(Icons.arrow_back),
            label: const Text('返回重试'),
          ),
        ],
      ),
    );
  }
}
