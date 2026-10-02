import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../../../core/settings/section_time_settings.dart';
import '../data/shared_availability_repository.dart';

class SharedAvailabilityPage extends ConsumerStatefulWidget {
  const SharedAvailabilityPage({super.key});

  @override
  ConsumerState<SharedAvailabilityPage> createState() =>
      _SharedAvailabilityPageState();
}

class _SharedAvailabilityPageState
    extends ConsumerState<SharedAvailabilityPage> {
  final _usernameController = TextEditingController();
  final _codeController = TextEditingController();
  late Future<AvailabilityStatus> _status;
  DateTime _monday = _startOfWeek(DateTime.now());
  bool _acting = false;
  CodeInvitation? _codeInvitation;

  @override
  void initState() {
    super.initState();
    _status = ref.read(sharedAvailabilityRepositoryProvider).status();
  }

  @override
  void dispose() {
    _usernameController.dispose();
    _codeController.dispose();
    super.dispose();
  }

  static DateTime _startOfWeek(DateTime value) {
    final date = DateTime(value.year, value.month, value.day);
    return date.subtract(Duration(days: date.weekday - 1));
  }

  Future<void> _reload() async {
    final next = ref.read(sharedAvailabilityRepositoryProvider).status();
    if (mounted) setState(() => _status = next);
    await next;
  }

  Future<void> _run(Future<void> Function() action, {String? success}) async {
    if (_acting) return;
    setState(() => _acting = true);
    try {
      await action();
      await _reload();
      if (success != null && mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(success)));
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text(apiErrorMessage(error, fallback: '操作失败，请稍后重试'))),
        );
      }
    } finally {
      if (mounted) setState(() => _acting = false);
    }
  }

  Future<void> _invite() async {
    final username = _usernameController.text.trim();
    if (username.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请输入对方的完整用户名')),
      );
      return;
    }
    await _run(
      () => ref.read(sharedAvailabilityRepositoryProvider).invite(username),
      success: '邀请已发送，等待对方确认',
    );
  }

  Future<void> _createCode() async {
    if (_acting) return;
    setState(() => _acting = true);
    try {
      final invitation = await ref
          .read(sharedAvailabilityRepositoryProvider)
          .createCodeInvite();
      if (mounted) {
        setState(() {
          _codeInvitation = invitation;
          _status = ref.read(sharedAvailabilityRepositoryProvider).status();
        });
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(apiErrorMessage(error, fallback: '邀请码生成失败'))),
        );
      }
    } finally {
      if (mounted) setState(() => _acting = false);
    }
  }

  Future<void> _claimCode() async {
    final code = _codeController.text.trim().toUpperCase();
    if (code.length != 8) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请输入完整的 8 位邀请码')),
      );
      return;
    }
    await _run(
      () => ref.read(sharedAvailabilityRepositoryProvider).claimCode(code),
      success: '连接成功，只会共享忙闲状态',
    );
  }

  Future<void> _cancelCode() async {
    await _run(
      () => ref.read(sharedAvailabilityRepositoryProvider).cancelCodeInvite(),
      success: '邀请码已取消',
    );
    if (mounted) setState(() => _codeInvitation = null);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
          title: const Text('共同空闲'),
          actions: [
            IconButton(
              tooltip: '刷新',
              onPressed: _acting ? null : _reload,
              icon: const Icon(Icons.refresh),
            ),
          ],
        ),
        body: FutureBuilder<AvailabilityStatus>(
          future: _status,
          builder: (context, snapshot) {
            if (snapshot.connectionState != ConnectionState.done) {
              return const Center(child: CircularProgressIndicator());
            }
            if (snapshot.hasError) {
              return _CenteredState(
                icon: Icons.cloud_off_outlined,
                title: '暂时无法读取共同空闲',
                action: FilledButton.tonal(
                    onPressed: _reload, child: const Text('重试')),
              );
            }
            final status = snapshot.data!;
            return RefreshIndicator(
              onRefresh: _reload,
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
                children: [
                  const _FeatureIntroCard(),
                  const SizedBox(height: 14),
                  if (status.connected)
                    _ConnectedView(
                      status: status,
                      monday: _monday,
                      weekFuture: ref
                          .read(sharedAvailabilityRepositoryProvider)
                          .week(_monday),
                      onPrevious: () => setState(
                        () =>
                            _monday = _monday.subtract(const Duration(days: 7)),
                      ),
                      onNext: () => setState(
                        () => _monday = _monday.add(const Duration(days: 7)),
                      ),
                      onDisconnect: () => _run(
                        () => ref
                            .read(sharedAvailabilityRepositoryProvider)
                            .disconnect(),
                        success: '已解除连接',
                      ),
                    )
                  else ...[
                    for (final invitation in status.invitations)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: _InvitationCard(
                          invitation: invitation,
                          disabled: _acting,
                          onAccept: () => _run(
                            () => ref
                                .read(sharedAvailabilityRepositoryProvider)
                                .respond(invitation.id, accept: true),
                            success: '已接受邀请',
                          ),
                          onReject: () => _run(
                            () => ref
                                .read(sharedAvailabilityRepositoryProvider)
                                .respond(invitation.id, accept: false),
                            success: '已拒绝邀请',
                          ),
                        ),
                      ),
                    if (status.inviteType == 'code')
                      _CodeWaitingCard(
                        invitation: _codeInvitation,
                        disabled: _acting,
                        onRegenerate: _createCode,
                        onCancel: _cancelCode,
                      )
                    else if (status.outgoing != null)
                      _WaitingCard(
                        invitation: status.outgoing!,
                        disabled: _acting,
                        onCancel: () => _run(
                          () => ref
                              .read(sharedAvailabilityRepositoryProvider)
                              .cancel(status.outgoing!.id),
                          success: '已撤回邀请',
                        ),
                      )
                    else
                      _InviteCard(
                        usernameController: _usernameController,
                        codeController: _codeController,
                        disabled: _acting,
                        onInvite: _invite,
                        onCreateCode: _createCode,
                        onClaimCode: _claimCode,
                      ),
                  ],
                ],
              ),
            );
          },
        ),
      );
}

class _FeatureIntroCard extends StatelessWidget {
  const _FeatureIntroCard();

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Theme.of(context)
              .colorScheme
              .primaryContainer
              .withValues(alpha: .5),
          borderRadius: BorderRadius.circular(20),
        ),
        child: const Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.event_available_outlined),
            SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('一起找空闲时间',
                      style: TextStyle(fontWeight: FontWeight.w700)),
                  SizedBox(height: 3),
                  Text('连接同学或朋友的课表，在周视图中快速找到双方都有空的节次，方便约自习、讨论或见面。'),
                ],
              ),
            ),
          ],
        ),
      );
}

class _InviteCard extends ConsumerStatefulWidget {
  const _InviteCard({
    required this.usernameController,
    required this.codeController,
    required this.disabled,
    required this.onInvite,
    required this.onCreateCode,
    required this.onClaimCode,
  });

  final TextEditingController usernameController;
  final TextEditingController codeController;
  final bool disabled;
  final VoidCallback onInvite;
  final VoidCallback onCreateCode;
  final VoidCallback onClaimCode;

  @override
  ConsumerState<_InviteCard> createState() => _InviteCardState();
}

class _InviteCardState extends ConsumerState<_InviteCard> {
  Timer? _searchTimer;
  List<String> _results = const [];
  bool _searching = false;

  @override
  void dispose() {
    _searchTimer?.cancel();
    super.dispose();
  }

  void _onQueryChanged(String value) {
    _searchTimer?.cancel();
    final query = value.trim();
    if (query.length < 2) {
      setState(() {
        _results = const [];
        _searching = false;
      });
      return;
    }
    setState(() => _searching = true);
    _searchTimer = Timer(const Duration(milliseconds: 280), () async {
      try {
        final results = await ref
            .read(sharedAvailabilityRepositoryProvider)
            .searchUsers(query);
        if (!mounted || widget.usernameController.text.trim() != query) return;
        setState(() {
          _results = results;
          _searching = false;
        });
      } catch (error) {
        if (!mounted || widget.usernameController.text.trim() != query) return;
        setState(() {
          _results = const [];
          _searching = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(apiErrorMessage(error, fallback: '搜索用户失败'))),
        );
      }
    });
  }

  void _inviteResult(String username) {
    widget.usernameController.text = username;
    setState(() => _results = const []);
    widget.onInvite();
  }

  @override
  Widget build(BuildContext context) => Card(
        margin: EdgeInsets.zero,
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Icon(Icons.group_add_outlined,
                  size: 38, color: Theme.of(context).colorScheme.primary),
              const SizedBox(height: 14),
              Text('邀请同学或朋友',
                  style: Theme.of(context)
                      .textTheme
                      .titleLarge
                      ?.copyWith(fontWeight: FontWeight.w700)),
              const SizedBox(height: 6),
              const Text('支持完整用户名邀请和临时邀请码，对方加入后即可查看共同空闲。'),
              const SizedBox(height: 18),
              Text('方式一 · 用户名', style: Theme.of(context).textTheme.labelLarge),
              const SizedBox(height: 8),
              TextField(
                controller: widget.usernameController,
                enabled: !widget.disabled,
                maxLength: 32,
                textInputAction: TextInputAction.done,
                autofillHints: const [AutofillHints.username],
                decoration: const InputDecoration(
                  labelText: '对方用户名',
                  hintText: '输入至少 2 个字符搜索',
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.alternate_email),
                ),
                onChanged: _onQueryChanged,
                onSubmitted: (_) => widget.onInvite(),
              ),
              if (_searching) ...[
                const LinearProgressIndicator(),
                const SizedBox(height: 8),
              ] else if (_results.isNotEmpty) ...[
                Card(
                  margin: EdgeInsets.zero,
                  elevation: 0,
                  color: Theme.of(context).colorScheme.surfaceContainerLow,
                  child: Column(
                    children: [
                      for (final username in _results)
                        ListTile(
                          dense: true,
                          leading: const Icon(Icons.person_outline),
                          title: Text(username),
                          trailing: const Text('邀请'),
                          onTap: widget.disabled
                              ? null
                              : () => _inviteResult(username),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
              ],
              const SizedBox(height: 4),
              FilledButton.icon(
                onPressed: widget.disabled ? null : widget.onInvite,
                icon: const Icon(Icons.send_outlined),
                label: Text(widget.disabled ? '正在发送…' : '发送邀请'),
              ),
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 18),
                child: Divider(),
              ),
              Text('方式二 · 邀请码', style: Theme.of(context).textTheme.labelLarge),
              const SizedBox(height: 5),
              const Text('生成一个 15 分钟有效的邀请码发给对方，或输入对方的邀请码。'),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: widget.disabled ? null : widget.onCreateCode,
                icon: const Icon(Icons.password_outlined),
                label: const Text('生成我的邀请码'),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: widget.codeController,
                enabled: !widget.disabled,
                maxLength: 8,
                textCapitalization: TextCapitalization.characters,
                inputFormatters: [
                  FilteringTextInputFormatter.allow(
                      RegExp('[A-HJ-NP-Za-hj-np-z2-9]')),
                  LengthLimitingTextInputFormatter(8),
                ],
                decoration: const InputDecoration(
                  labelText: '输入对方的邀请码',
                  hintText: '例如 7KMP3XQH',
                  counterText: '',
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.key_outlined),
                ),
                onSubmitted: (_) => widget.onClaimCode(),
              ),
              const SizedBox(height: 10),
              FilledButton.tonalIcon(
                onPressed: widget.disabled ? null : widget.onClaimCode,
                icon: const Icon(Icons.link),
                label: const Text('加入共同空闲'),
              ),
            ],
          ),
        ),
      );
}

class _CodeWaitingCard extends StatelessWidget {
  const _CodeWaitingCard({
    required this.invitation,
    required this.disabled,
    required this.onRegenerate,
    required this.onCancel,
  });

  final CodeInvitation? invitation;
  final bool disabled;
  final VoidCallback onRegenerate;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) => Card(
        margin: EdgeInsets.zero,
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Icon(Icons.password_rounded,
                  size: 40, color: Theme.of(context).colorScheme.primary),
              const SizedBox(height: 12),
              Text(
                invitation == null ? '邀请码仍在等待使用' : '把邀请码发给对方',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
              ),
              const SizedBox(height: 8),
              if (invitation != null) ...[
                FilledButton.tonal(
                  onPressed: disabled
                      ? null
                      : () async {
                          await Clipboard.setData(
                            ClipboardData(text: invitation!.code),
                          );
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('邀请码已复制')),
                            );
                          }
                        },
                  child: Text(
                    invitation!.code,
                    style: const TextStyle(
                      fontSize: 24,
                      letterSpacing: 4,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                const Text('15 分钟内有效，点击邀请码即可复制。', textAlign: TextAlign.center),
              ] else ...[
                const Text(
                  '出于安全考虑，服务器只保存邀请码摘要，离开页面后无法恢复原码。请重新生成。',
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 12),
                OutlinedButton(
                  onPressed: disabled ? null : onRegenerate,
                  child: const Text('重新生成邀请码'),
                ),
              ],
              const SizedBox(height: 10),
              TextButton.icon(
                onPressed: disabled ? null : onCancel,
                icon: const Icon(Icons.close),
                label: const Text('取消邀请码'),
              ),
            ],
          ),
        ),
      );
}

class _InvitationCard extends StatelessWidget {
  const _InvitationCard({
    required this.invitation,
    required this.disabled,
    required this.onAccept,
    required this.onReject,
  });

  final AvailabilityInvitation invitation;
  final bool disabled;
  final VoidCallback onAccept;
  final VoidCallback onReject;

  @override
  Widget build(BuildContext context) => Card(
        margin: EdgeInsets.zero,
        color: Theme.of(context)
            .colorScheme
            .primaryContainer
            .withValues(alpha: .5),
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(Icons.mark_email_unread_outlined),
              const SizedBox(height: 12),
              Text('${invitation.username} 邀请你查看共同空闲',
                  style: Theme.of(context)
                      .textTheme
                      .titleMedium
                      ?.copyWith(fontWeight: FontWeight.w700)),
              const SizedBox(height: 6),
              const Text('接受后，双方只能看到每节课是忙还是空。'),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                      onPressed: disabled ? null : onReject,
                      child: const Text('拒绝')),
                  const SizedBox(width: 8),
                  FilledButton(
                      onPressed: disabled ? null : onAccept,
                      child: const Text('接受邀请')),
                ],
              ),
            ],
          ),
        ),
      );
}

class _WaitingCard extends StatelessWidget {
  const _WaitingCard({
    required this.invitation,
    required this.disabled,
    required this.onCancel,
  });

  final AvailabilityInvitation invitation;
  final bool disabled;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) => Card(
        margin: EdgeInsets.zero,
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            children: [
              const Icon(Icons.hourglass_top_rounded, size: 42),
              const SizedBox(height: 14),
              Text('等待 ${invitation.username} 确认',
                  style: Theme.of(context)
                      .textTheme
                      .titleLarge
                      ?.copyWith(fontWeight: FontWeight.w700)),
              const SizedBox(height: 6),
              const Text('邀请在 7 天内有效。对方接受前不会共享任何课表状态。'),
              const SizedBox(height: 16),
              TextButton.icon(
                onPressed: disabled ? null : onCancel,
                icon: const Icon(Icons.undo),
                label: const Text('撤回邀请'),
              ),
            ],
          ),
        ),
      );
}

class _ConnectedView extends StatelessWidget {
  const _ConnectedView({
    required this.status,
    required this.monday,
    required this.weekFuture,
    required this.onPrevious,
    required this.onNext,
    required this.onDisconnect,
  });

  final AvailabilityStatus status;
  final DateTime monday;
  final Future<AvailabilityWeek> weekFuture;
  final VoidCallback onPrevious;
  final VoidCallback onNext;
  final VoidCallback onDisconnect;

  @override
  Widget build(BuildContext context) => Column(
        children: [
          Card(
            margin: EdgeInsets.zero,
            child: ListTile(
              leading: CircleAvatar(
                child: Text(status.partnerUsername.isEmpty
                    ? '?'
                    : status.partnerUsername.characters.first),
              ),
              title: Text('已连接 ${status.partnerUsername}',
                  style: const TextStyle(fontWeight: FontWeight.w700)),
              subtitle: const Text('双方都可以随时解除'),
              trailing: IconButton(
                tooltip: '解除连接',
                onPressed: onDisconnect,
                icon: const Icon(Icons.link_off_outlined),
              ),
            ),
          ),
          const SizedBox(height: 14),
          Card(
            margin: EdgeInsets.zero,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 16),
              child: Column(
                children: [
                  Row(
                    children: [
                      IconButton(
                          onPressed: onPrevious,
                          icon: const Icon(Icons.chevron_left)),
                      Expanded(
                        child: Column(
                          children: [
                            const Text('共同空闲时间',
                                style: TextStyle(fontWeight: FontWeight.w700)),
                            Text('${monday.month}月${monday.day}日这一周',
                                style: Theme.of(context).textTheme.bodySmall),
                          ],
                        ),
                      ),
                      IconButton(
                          onPressed: onNext,
                          icon: const Icon(Icons.chevron_right)),
                    ],
                  ),
                  const _Legend(),
                  const SizedBox(height: 8),
                  FutureBuilder<AvailabilityWeek>(
                    future: weekFuture,
                    builder: (context, snapshot) {
                      if (snapshot.connectionState != ConnectionState.done) {
                        return const Padding(
                          padding: EdgeInsets.all(32),
                          child: CircularProgressIndicator(),
                        );
                      }
                      if (snapshot.hasError) {
                        return const Padding(
                          padding: EdgeInsets.all(24),
                          child: Text('这一周暂时无法读取，请下拉刷新。'),
                        );
                      }
                      return Column(
                        children: [
                          for (final day in snapshot.data!.days)
                            _DayAvailability(day: day),
                        ],
                      );
                    },
                  ),
                ],
              ),
            ),
          ),
        ],
      );
}

class _Legend extends StatelessWidget {
  const _Legend();

  @override
  Widget build(BuildContext context) => const Wrap(
        alignment: WrapAlignment.center,
        spacing: 12,
        runSpacing: 6,
        children: [
          _LegendItem(state: 'both_free', label: '都空闲'),
          _LegendItem(state: 'me_busy', label: '我没空'),
          _LegendItem(state: 'partner_busy', label: '对方没空'),
          _LegendItem(state: 'both_busy', label: '都没空'),
        ],
      );
}

class _LegendItem extends StatelessWidget {
  const _LegendItem({required this.state, required this.label});
  final String state;
  final String label;

  @override
  Widget build(BuildContext context) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
              width: 11,
              height: 11,
              decoration: BoxDecoration(
                  color: _stateColor(context, state),
                  borderRadius: BorderRadius.circular(3))),
          const SizedBox(width: 4),
          Text(label, style: Theme.of(context).textTheme.labelSmall),
        ],
      );
}

class _DayAvailability extends ConsumerWidget {
  const _DayAvailability({required this.day});
  final AvailabilityDay day;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final config = ref.watch(sectionTimeConfigProvider).valueOrNull ??
        const SectionTimeConfig.defaults();
    // 空闲段用「几点到几点」表述（比节次更直觉）
    final free = _freeRanges(day.states, day.date, config);
    const weekday = ['一', '二', '三', '四', '五', '六', '日'];
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 10, 4, 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                  '周${weekday[day.day - 1]}  ${day.date.month}/${day.date.day}',
                  style: const TextStyle(fontWeight: FontWeight.w700)),
              const Spacer(),
              const SizedBox(width: 8),
              // 小屏上「有空 08:00-09:40、14:30-16:10」一行放不下：
              // 允许折行到两行（右对齐），不再省略号截断末端时间
              Flexible(
                child: Text(
                  free.isEmpty ? '暂无共同空闲' : '有空 ${free.join('、')}',
                  style: Theme.of(context).textTheme.labelMedium,
                  textAlign: TextAlign.right,
                  maxLines: 2,
                ),
              ),
            ],
          ),
          const SizedBox(height: 7),
          SizedBox(
            height: 26,
            child: Row(
              children: [
                for (var index = 0; index < day.states.length; index++) ...[
                  Expanded(
                    child: Semantics(
                      label: '第${index + 1}节 ${_stateLabel(day.states[index])}',
                      child: Container(
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: _stateColor(context, day.states[index]),
                          borderRadius: BorderRadius.circular(5),
                        ),
                        child: Text('${index + 1}',
                            style: Theme.of(context).textTheme.labelSmall),
                      ),
                    ),
                  ),
                  if (index != day.states.length - 1) const SizedBox(width: 3),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

List<String> _freeRanges(
    List<String> states, DateTime date, SectionTimeConfig config) {
  final result = <String>[];
  var start = -1;
  for (var i = 0; i <= states.length; i++) {
    final free = i < states.length && states[i] == 'both_free';
    if (free && start < 0) start = i + 1;
    if (!free && start > 0) {
      final end = i;
      final from = config.startOf(start, date);
      final to = config.endOf(end, date);
      result.add('$from-$to');
      start = -1;
    }
  }
  return result;
}

String _stateLabel(String state) => switch (state) {
      'both_free' => '双方都空闲',
      'me_busy' => '我没空',
      'partner_busy' => '对方没空',
      'both_busy' => '双方都没空',
      _ => '状态未知',
    };

Color _stateColor(BuildContext context, String state) {
  final colors = Theme.of(context).colorScheme;
  return switch (state) {
    'both_free' => colors.primaryContainer,
    'me_busy' => colors.tertiaryContainer,
    'partner_busy' => colors.secondaryContainer,
    'both_busy' => colors.errorContainer,
    _ => colors.surfaceContainerHighest,
  };
}

class _CenteredState extends StatelessWidget {
  const _CenteredState(
      {required this.icon, required this.title, required this.action});
  final IconData icon;
  final String title;
  final Widget action;

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 52),
              const SizedBox(height: 14),
              Text(title),
              const SizedBox(height: 16),
              action,
            ],
          ),
        ),
      );
}
