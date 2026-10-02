// 语音添加弹层（设计稿 2/3，AI 日程 2.0）。
//
// 交互模型：
// - 长按底部导航「添加」→ [VoiceRecordSheet.show]：震动反馈 + 弹出本层并开始录音；
// - 录音免手持持续进行，「完成录音」→ 识别并进入确认弹层；「取消」丢弃录音。
//
// 实时转写（2026-09-19，按用户指定走服务端 MiMo ASR）：
// 录音用 PCM 流式采集，每 2.5s 把累计音频（WAV 头+PCM）发服务端
// /api/schedule-ai/transcribe 分段转写，返回的累计文本实时上屏；
// 波形直接由 PCM 块计算 RMS 驱动（不依赖识别器音量回调）。
// 「完成」后仍走 parseVoice 整段权威识别（ASR+LLM），分段文本只做预览。
import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:record/record.dart';

import '../../../core/settings/haptics_settings.dart';
import '../data/schedule_ai_repository.dart';
import 'confirm_event_sheet.dart';

class VoiceRecordSheet extends ConsumerStatefulWidget {
  const VoiceRecordSheet({super.key});

  static const maxSeconds = 60;

  /// 长按底部「添加」的入口：震动反馈（可在设置关闭）+ 弹出录音层。
  static Future<void> show(BuildContext context) {
    // 默认加强到 heavyImpact；ProviderScope.containerOf 在路由层也可用
    final container = ProviderScope.containerOf(context, listen: false);
    if (container.read(hapticsEnabledProvider)) {
      HapticFeedback.heavyImpact();
    }
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (_) => const VoiceRecordSheet(),
    );
  }

  @override
  ConsumerState<VoiceRecordSheet> createState() => _VoiceRecordSheetState();
}

class _VoiceRecordSheetState extends ConsumerState<VoiceRecordSheet> {
  final AudioRecorder _recorder = AudioRecorder();

  /// 波形历史（0.04-1.0），新值在右
  final List<double> _waveform = List.filled(40, 0.04);

  /// 推入一个波形采样：快攻慢放（attack 立即、release 缓降），视觉上跟随人声起伏
  void _pushWaveform(double level) {
    if (!mounted) return;
    final last = _waveform.last;
    final smoothed = level > last ? level : last * 0.72 + level * 0.28;
    setState(() {
      _waveform.removeAt(0);
      _waveform.add(smoothed.clamp(0.04, 1.0));
    });
  }

  Timer? _tickTimer;
  Timer? _maxTimer;
  Timer? _transcribeTimer;
  StreamSubscription<Uint8List>? _pcmSub;
  StreamSubscription<Amplitude>? _amplitudeSub;

  bool _processing = false;
  bool _permissionDenied = false;
  int _elapsedSeconds = 0;

  /// 累计 PCM（16kHz 16bit 单声道）
  final BytesBuilder _pcm = BytesBuilder(copy: false);

  /// 服务端分段转写的累计文本（每次响应覆盖上一次）
  String _serverText = '';
  bool _transcribeInFlight = false;
  int _transcribedBytes = 0;

  @override
  void initState() {
    super.initState();
    _startRecording();
  }

  Future<void> _startRecording() async {
    try {
      if (!await _recorder.hasPermission()) {
        setState(() => _permissionDenied = true);
        return;
      }
      // PCM 流式采集：同一份数据既驱动波形（RMS）又攒成分段转写的音频
      final stream = await _recorder.startStream(
        const RecordConfig(
          encoder: AudioEncoder.pcm16bits,
          sampleRate: 16000,
          numChannels: 1,
        ),
      );
      _pcmSub = stream.listen(_onPcmChunk);
      // 双保险：部分设备 PCM 流间歇/不出块时，amplitude 通道仍能驱动波形
      _amplitudeSub = _recorder
          .onAmplitudeChanged(const Duration(milliseconds: 60))
          .listen((amp) {
        final normalized = ((amp.current + 50) / 50).clamp(0.04, 1.0);
        _pushWaveform(normalized);
      });
      _tickTimer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() => _elapsedSeconds++);
      });
      _maxTimer = Timer(
        const Duration(seconds: VoiceRecordSheet.maxSeconds),
        () => _finish(send: true),
      );
      // 分段转写节奏：每 2.5s 把「到目前为止的全部音频」发服务端转写
      _transcribeTimer = Timer.periodic(
        const Duration(milliseconds: 2500),
        (_) => _transcribeTick(),
      );
    } catch (_) {
      if (mounted) setState(() => _permissionDenied = true);
    }
  }

  void _onPcmChunk(Uint8List chunk) {
    _pcm.add(chunk);
    // PCM16 LE → RMS（抽样最多 4000 字节控制开销）
    final sample = chunk.length > 4000 ? chunk.sublist(0, 4000) : chunk;
    var sum = 0.0;
    final count = sample.length ~/ 2;
    if (count == 0) return;
    for (var i = 0; i < count * 2; i += 2) {
      final v = sample[i] | (sample[i + 1] << 8);
      final s = v >= 0x8000 ? v - 0x10000 : v;
      sum += s * s;
    }
    final rms = math.sqrt(sum / count) / 32768;
    // 对数映射（宽动态）：手机人声 RMS 典型 0.005-0.15，映射后 0.27-0.76，
    // 再做 0.75 次幂提亮中小声，保证说话就有明显起伏
    final mapped = (math.log(rms * 300 + 1) / math.log(301)).clamp(0.0, 1.0);
    final level = math.pow(mapped, 0.75).toDouble().clamp(0.04, 1.0);
    _pushWaveform(level);
  }

  /// WAV 头（PCM16 单声道 16kHz）+ 累计 PCM，组一个完整可解码的 wav
  List<int> _buildWav() {
    final pcm = _pcm.toBytes();
    final b = BytesBuilder(copy: false);
    void w32(int v) =>
        b.add([v & 0xff, (v >> 8) & 0xff, (v >> 16) & 0xff, (v >> 24) & 0xff]);
    void w16(int v) => b.add([v & 0xff, (v >> 8) & 0xff]);
    b.add('RIFF'.codeUnits);
    w32(36 + pcm.length);
    b.add('WAVE'.codeUnits);
    b.add('fmt '.codeUnits);
    w32(16); // PCM fmt chunk
    w16(1); // PCM
    w16(1); // mono
    w32(16000);
    w32(32000); // byte rate
    w16(2); // block align
    w16(16); // bits
    b.add('data'.codeUnits);
    w32(pcm.length);
    b.add(pcm);
    return b.toBytes();
  }

  Future<void> _transcribeTick() async {
    // 单飞 + 增量门槛（≥0.8s 新音频 = 25.6KB）：失败静默，不打断录音
    if (_transcribeInFlight || _processing) return;
    final bytes = _pcm.length;
    if (bytes - _transcribedBytes < 25600) return;
    _transcribeInFlight = true;
    _transcribedBytes = bytes;
    try {
      final text = await ref
          .read(scheduleAiRepositoryProvider)
          .transcribeChunk(_buildWav());
      if (!mounted) return;
      if (text.isNotEmpty) setState(() => _serverText = text);
    } catch (_) {
      // 分段失败静默：下一段会带上更全的音频重试
    } finally {
      _transcribeInFlight = false;
    }
  }

  Future<void> _finish({required bool send}) async {
    if (_processing) return;
    _tickTimer?.cancel();
    _maxTimer?.cancel();
    _transcribeTimer?.cancel();
    await _pcmSub?.cancel();
    await _amplitudeSub?.cancel();
    await _recorder.stop();
    if (!send) {
      if (mounted) Navigator.of(context).pop();
      return;
    }
    setState(() => _processing = true);
    try {
      final wavBytes = _buildWav();
      // 合规：语音内容仅用于本次解析，服务端即转即删；分段转写不落库
      final result =
          await ref.read(scheduleAiRepositoryProvider).parseVoice(wavBytes);
      if (!mounted) return;
      Navigator.of(context).pop();
      // 单条新建 → 设计稿的「确认日程」弹层；其余（多操作/调课/取消）走完整预览页
      if (result.operations.length == 1 &&
          result.operations.single.action == 'create') {
        await ConfirmEventSheet.show(context, result: result, source: 'voice');
      } else {
        await context.push('/ai/preview',
            extra: (result: result, source: 'voice'));
      }
    } catch (error) {
      if (!mounted) return;
      Navigator.of(context).pop();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_friendlyError(error))),
      );
    }
  }

  String _friendlyError(Object error) {
    final raw = error.toString();
    if (raw.contains('42950')) return '今日 AI 日程次数已达上限，明天再来';
    if (raw.contains('42250')) return '没有听懂日程安排，可以换个说法再试试';
    if (raw.contains('42252')) return '录音太短了，把话说完再点完成';
    if (raw.contains('41340')) return '录音太长了，一句话日程控制在 60 秒内';
    if (raw.contains('50341')) return 'AI 日程理解暂未开放';
    return '识别失败，请检查网络后重试';
  }

  @override
  void dispose() {
    _tickTimer?.cancel();
    _maxTimer?.cancel();
    _transcribeTimer?.cancel();
    _pcmSub?.cancel();
    _amplitudeSub?.cancel();
    _recorder.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final timerText =
        '00:${_elapsedSeconds.toString().padLeft(2, '0')}';
    return Padding(
      // 让出悬浮导航高度（76）+ 安全区（规范 §三.6，键盘不会出现在本层）
      padding: EdgeInsets.only(
        bottom: MediaQuery.viewPaddingOf(context).bottom + 76,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // ---- 标题行 ----
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 8, 0),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '语音添加',
                    style: Theme.of(context)
                        .textTheme
                        .titleLarge
                        ?.copyWith(fontWeight: FontWeight.w700),
                  ),
                ),
                IconButton(
                  tooltip: '关闭',
                  icon: const Icon(Icons.close),
                  onPressed: () => _finish(send: false),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
            child: Text(
              '说出时间、地点和要做的事。',
              style: Theme.of(context)
                  .textTheme
                  .bodyMedium
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ),
          if (_permissionDenied)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 24, 20, 32),
              child: Text(
                '需要麦克风权限才能语音录入日程。拒绝授权不影响文字输入与其他功能。',
                textAlign: TextAlign.center,
                style: Theme.of(context)
                    .textTheme
                    .bodyMedium
                    ?.copyWith(color: scheme.error),
              ),
            )
          else ...[
            // ---- 实时转写区：服务端分段识别文本实时上屏；无内容时显示示例语 ----
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: _serverText.isEmpty
                  ? Text(
                      '例如：明天下午三点，\n在图书馆小组讨论。',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                            color:
                                scheme.onSurfaceVariant.withValues(alpha: 0.75),
                            height: 1.6,
                          ),
                    )
                  : Text(
                      _serverText,
                      textAlign: TextAlign.center,
                      style: Theme.of(context)
                          .textTheme
                          .titleMedium
                          ?.copyWith(height: 1.6, color: scheme.onSurface),
                    ),
            ),
            const SizedBox(height: 24),
            // ---- 波形 / 识别中呼吸条 ----
            SizedBox(
              height: 52,
              child: Center(
                child: _processing
                    ? _BreathingBars(color: scheme.primary)
                    : Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          for (final level in _waveform)
                            Padding(
                              padding:
                                  const EdgeInsets.symmetric(horizontal: 1.2),
                              child: AnimatedContainer(
                                duration: const Duration(milliseconds: 70),
                                curve: Curves.easeOut,
                                width: 3.5,
                                height: 5 + 42 * level,
                                decoration: BoxDecoration(
                                  // 声音越大越实：透明度也随电平起伏
                                  color: scheme.primary.withValues(
                                      alpha: 0.35 + 0.55 * level),
                                  borderRadius: BorderRadius.circular(2),
                                ),
                              ),
                            ),
                        ],
                      ),
              ),
            ),
            const SizedBox(height: 12),
            Text(
              _processing
                  ? '正在识别与理解…'
                  : _serverText.isNotEmpty
                      ? '$timerText\n正在聆听 · 实时转写中…'
                      : '$timerText\n正在聆听…',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: scheme.onSurfaceVariant,
                    fontWeight: FontWeight.w600,
                    height: 1.5,
                  ),
            ),
            const SizedBox(height: 24),
          ],
          // ---- 操作按钮 ----
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 0),
            child: Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: _processing ? null : () => _finish(send: false),
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(24),
                      ),
                    ),
                    child: const Text('取消'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton(
                    onPressed: (_processing || _permissionDenied)
                        ? null
                        : () => _finish(send: true),
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(24),
                      ),
                    ),
                    child: const Text('完成录音'),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          Text(
            '录音结束后，可核对并修改。',
            textAlign: TextAlign.center,
            style: Theme.of(context)
                .textTheme
                .bodySmall
                ?.copyWith(color: scheme.outline),
          ),
          const SizedBox(height: 16),
        ],
      ),
    );
  }
}

/// 识别阶段的整排呼吸条。
class _BreathingBars extends StatefulWidget {
  const _BreathingBars({required this.color});

  final Color color;

  @override
  State<_BreathingBars> createState() => _BreathingBarsState();
}

class _BreathingBarsState extends State<_BreathingBars>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (context, _) {
        return Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            for (var i = 0; i < 12; i++)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 2.5),
                child: Container(
                  width: 5,
                  // 相位依次错开的正弦呼吸
                  height: 8 +
                      24 *
                          (0.5 +
                              0.5 *
                                  math.sin(
                                      2 * math.pi * (_ctrl.value + i / 12))),
                  decoration: BoxDecoration(
                    color: widget.color.withValues(alpha: 0.8),
                    borderRadius: BorderRadius.circular(2.5),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}
