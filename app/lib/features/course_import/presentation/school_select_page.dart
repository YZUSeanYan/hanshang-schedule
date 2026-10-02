import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/remote_features/remote_feature_providers.dart';
import '../data/import_runtime_provider.dart';
import '../data/school_directory.dart';

/// 名单条目 = 展示模型 + 是否带针对性适配 + 可选的远程拼音首字母。
class _SchoolItem {
  const _SchoolItem(this.entry, {this.adapted = false, this.initial = ''});
  final SchoolEntry entry;
  final bool adapted;

  /// runtime 下发的拼音首字母（客户端内置拼音表只覆盖少量汉字）。
  final String initial;

  String get letter => initial.isNotEmpty ? initial : schoolInitial(entry.name);
}

/// 其他学校教务导入 · 学校选择页（设计稿：搜索 + A-Z 索引 + 教务系统标注）。
///
/// 名单优先级：import-runtime 签名通道下发的按校适配目录（RuntimeSchool，
/// 加/改学校不用发版）> 旧 app-manifest schoolDirectory > 内置种子名单；
/// 合并时按教务域名去重，runtime 优先。选中后进入 App 内 WebView 通用导入，
/// 命中 runtime 学校时自动应用其引导文案与嗅探配置。
class SchoolSelectPage extends ConsumerStatefulWidget {
  const SchoolSelectPage({super.key});

  @override
  ConsumerState<SchoolSelectPage> createState() => _SchoolSelectPageState();
}

class _SchoolSelectPageState extends ConsumerState<SchoolSelectPage> {
  final _searchController = TextEditingController();
  final _scrollController = ScrollController();
  String _query = '';

  SchoolEntry _entryOf(String name, String url, String system) =>
      SchoolEntry(name: name, url: url, system: system);

  /// 当前生效的名单：runtime 目录 > 旧签名目录 > 内置，按 host 去重。
  List<_SchoolItem> get _directory {
    final seen = <String>{};
    bool freshHost(String url) {
      final host = Uri.tryParse(url)?.host.toLowerCase() ?? '';
      return host.isNotEmpty && seen.add(host);
    }

    final runtime =
        ref.watch(importRuntimeProvider).valueOrNull?.schools;
    if (runtime != null && runtime.isNotEmpty) {
      final items = [
        for (final s in runtime)
          if (freshHost(s.url))
            _SchoolItem(
              _entryOf(s.name, s.url, s.system),
              adapted: s.isAdapted,
              initial: s.initial,
            ),
      ];
      // runtime 未覆盖的学校按 host 补齐：旧目录 + 内置种子
      final legacy = ref
          .watch(remoteFeatureManifestProvider)
          .valueOrNull
          ?.schoolDirectory;
      final extras = <SchoolEntry>[
        ...?legacy?.map(
            (e) => SchoolEntry(name: e.name, url: e.url, system: e.system)),
        ...kSchoolDirectory,
      ];
      for (final e in extras) {
        if (freshHost(e.url)) {
          items.add(_SchoolItem(e));
        }
      }
      return items;
    }
    final remote =
        ref.watch(remoteFeatureManifestProvider).valueOrNull?.schoolDirectory;
    if (remote != null && remote.isNotEmpty) {
      return [
        for (final e in remote)
          if (freshHost(e.url)) _SchoolItem(_entryOf(e.name, e.url, e.system)),
      ];
    }
    return [for (final e in kSchoolDirectory) _SchoolItem(e)];
  }

  /// 按搜索过滤并按首字母分组（有序 LinkedHashMap：字母 → 学校列表）。
  Map<String, List<_SchoolItem>> get _grouped {
    final q = _query.trim();
    final lower = q.toLowerCase();
    // 复制一份再排序：内置名单是 const，远程名单是 unmodifiable
    final filtered = (q.isEmpty
        ? _directory
        : _directory
            .where((s) =>
                s.entry.name.contains(q) ||
                s.entry.system.toLowerCase().contains(lower)))
        .toList();
    // 按首字母 + 组内按名称排序
    filtered.sort((a, b) {
      final ia = a.letter;
      final ib = b.letter;
      if (ia != ib) return ia.compareTo(ib);
      return a.entry.name.compareTo(b.entry.name);
    });
    final grouped = <String, List<_SchoolItem>>{};
    for (final school in filtered) {
      grouped.putIfAbsent(school.letter, () => []).add(school);
    }
    return grouped;
  }

  List<String> get _letters => _grouped.keys.toList();

  @override
  void dispose() {
    _searchController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _pick(_SchoolItem item) {
    context.push('/import/webview-generic', extra: item.entry.url);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final grouped = _grouped;

    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        centerTitle: false,
        elevation: 0,
        scrolledUnderElevation: 0,
        title: SizedBox(
          height: kToolbarHeight - 16,
          child: TextField(
            controller: _searchController,
            autofocus: false,
            onChanged: (v) => setState(() => _query = v),
            decoration: InputDecoration(
              hintText: '搜索学校',
              prefixIcon: const Icon(Icons.search),
              isDense: true,
              filled: true,
              fillColor: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(24),
                borderSide: BorderSide.none,
              ),
              contentPadding:
                  const EdgeInsets.symmetric(vertical: 8),
            ),
          ),
        ),
      ),
      body: Stack(
        children: [
          ListView.builder(
            controller: _scrollController,
            padding: EdgeInsets.fromLTRB(
              20,
              MediaQuery.paddingOf(context).top + kToolbarHeight + 8,
              32,
              MediaQuery.paddingOf(context).bottom + 24,
            ),
            itemCount: _letters.length + 1,
            itemBuilder: (context, index) {
              if (index == 0) {
                // 顶部：通用教务导入入口（名单外/任意学校教务网址都能进）+ 提示
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Card(
                      elevation: 0,
                      color: scheme.primaryContainer.withValues(alpha: 0.45),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                        side: BorderSide(color: scheme.outlineVariant),
                      ),
                      child: ListTile(
                        leading: Icon(Icons.public, color: scheme.primary),
                        title: const Text('通用教务导入'),
                        subtitle: const Text('名单外学校：输入教务系统网址导入'),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => _showGenericImportDialog(context),
                      ),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      _query.isEmpty ? '在搜索框输入学校全称以快速定位' : '搜索“$_query”的结果',
                      style: text.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                );
              }
              final letter = _letters[index - 1];
              final schools = grouped[letter]!;
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 分组字母标题
                  Padding(
                    padding: const EdgeInsets.only(top: 14, bottom: 6),
                    child: Text(
                      letter,
                      style: text.titleSmall?.copyWith(
                        color: scheme.primary,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  for (final item in schools)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(item.entry.name),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (item.adapted)
                            Container(
                              margin: const EdgeInsets.only(right: 8),
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 8, vertical: 3),
                              decoration: BoxDecoration(
                                color: scheme.primaryContainer,
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Text('已适配',
                                  style: text.labelSmall?.copyWith(
                                    color: scheme.onPrimaryContainer,
                                    fontWeight: FontWeight.w600,
                                  )),
                            ),
                          if (item.entry.system.isNotEmpty)
                            Text(
                              item.entry.system,
                              style: text.bodySmall?.copyWith(
                                color: scheme.onSurfaceVariant,
                              ),
                            ),
                        ],
                      ),
                      onTap: () => _pick(item),
                    ),
                ],
              );
            },
          ),
          // 右侧 A-Z 索引
          if (_letters.length > 1)
            Positioned(
              right: 2,
              top: MediaQuery.paddingOf(context).top + kToolbarHeight + 40,
              bottom: MediaQuery.paddingOf(context).bottom + 16,
              child: _LetterIndex(
                letters: _letters,
                onTap: (letter) {
                  final groupIndex = _letters.indexOf(letter);
                  if (groupIndex < 0) return;
                  // 粗定位：按分组的累计高度估算（标题+每条约 72）
                  var offset = 0.0;
                  final g = grouped;
                  for (var i = 0; i < groupIndex; i++) {
                    offset += 32 + 72.0 * g[_letters[i]]!.length;
                  }
                  _scrollController.animateTo(
                    offset.clamp(
                        0, _scrollController.position.maxScrollExtent),
                    duration: const Duration(milliseconds: 260),
                    curve: Curves.easeOut,
                  );
                },
              ),
            ),
        ],
      ),
    );
  }
}

/// 右侧竖排 A-Z 索引条。
class _LetterIndex extends StatelessWidget {
  const _LetterIndex({required this.letters, required this.onTap});

  final List<String> letters;
  final ValueChanged<String> onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        for (final letter in letters)
          InkWell(
            onTap: () => onTap(letter),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
              child: Text(
                letter,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  color: scheme.primary,
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// 通用教务导入：任意学校教务系统网址 → App 内 WebView 登录抓取，
/// 识别不出结构时服务器 AI 兜底（与「添加」页里的入口同一实现）。
Future<void> _showGenericImportDialog(BuildContext context) async {
  final controller = TextEditingController();
  final url = await showDialog<String>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      icon: const Icon(Icons.public),
      title: const Text('通用教务导入'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '输入你学校教务系统网址，在 App 内登录到课表页后抓取；'
            '识别不出结构时由服务器 AI 兜底解析（需你确认后才会上传页面内容）。',
            style: Theme.of(dialogContext).textTheme.bodySmall,
          ),
          const SizedBox(height: 12),
          TextField(
            controller: controller,
            keyboardType: TextInputType.url,
            autocorrect: false,
            autofocus: true,
            decoration: const InputDecoration(
              hintText: '例如 https://jwgl.example.edu.cn',
              border: OutlineInputBorder(),
              prefixIcon: Icon(Icons.link),
            ),
            onSubmitted: (v) => Navigator.pop(dialogContext, v.trim()),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () =>
              Navigator.pop(dialogContext, controller.text.trim()),
          child: const Text('打开教务系统'),
        ),
      ],
    ),
  );
  if (url == null || url.isEmpty || !context.mounted) return;
  var input = url;
  if (!input.contains('://')) input = 'https://$input';
  final uri = Uri.tryParse(input);
  if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('请输入正确的教务系统网址（https:// 开头）')),
    );
    return;
  }
  context.push('/import/webview-generic', extra: uri.toString());
}
