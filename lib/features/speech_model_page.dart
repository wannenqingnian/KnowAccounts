import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../speech/speech_model_service.dart';
import '../speech/speech_input.dart';
import 'manage_page.dart' show showError;
import 'widgets.dart';

Future<void> showSpeechModelPage(BuildContext context) => Navigator.of(
  context,
).push(MaterialPageRoute<void>(builder: (_) => const SpeechModelPage()));

class SpeechModelPage extends ConsumerStatefulWidget {
  const SpeechModelPage({super.key});

  @override
  ConsumerState<SpeechModelPage> createState() => _SpeechModelPageState();
}

class _SpeechModelPageState extends ConsumerState<SpeechModelPage> {
  bool _checking = true, _ready = false, _busy = false, _cancelled = false;
  int _recordingLimitSeconds = 0;
  int _silenceFinishSeconds = 2;
  bool _silenceAutoFinish = false;
  double? _progress;
  String _status = '检查模型…';

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    final ready = await ref.read(speechModelServiceProvider).isReady();
    var recordingLimit = 0;
    var silenceFinishSeconds = 2;
    var silenceAutoFinish = false;
    try {
      recordingLimit = await const SpeechInput().recordingLimitSeconds();
      silenceAutoFinish = await const SpeechInput().silenceAutoFinish();
      silenceFinishSeconds = await const SpeechInput().silenceFinishSeconds();
    } catch (_) {
      // Keep the safe manual-completion default if platform settings cannot
      // be read on this device.
    }
    if (!mounted) return;
    setState(() {
      _checking = false;
      _ready = ready;
      _recordingLimitSeconds = recordingLimit;
      _silenceAutoFinish = silenceAutoFinish;
      _silenceFinishSeconds = silenceFinishSeconds;
      _status = ready ? 'SenseVoiceSmall 已就绪，可完全离线识别' : '模型尚未下载';
    });
  }

  Future<void> _saveRecordingLimit(int seconds) async {
    try {
      await const SpeechInput().setRecordingLimitSeconds(seconds);
      if (mounted) setState(() => _recordingLimitSeconds = seconds);
    } catch (error) {
      if (mounted) showError(context, error);
    }
  }

  Future<void> _saveSilenceAutoFinish(bool enabled) async {
    try {
      await const SpeechInput().setSilenceAutoFinish(enabled);
      if (mounted) setState(() => _silenceAutoFinish = enabled);
    } catch (error) {
      if (mounted) showError(context, error);
    }
  }

  Future<void> _saveSilenceFinishSeconds(int seconds) async {
    try {
      await const SpeechInput().setSilenceFinishSeconds(seconds);
      if (mounted) setState(() => _silenceFinishSeconds = seconds);
    } catch (error) {
      if (mounted) showError(context, error);
    }
  }

  Future<void> _chooseSilenceFinishSeconds() async {
    var input = '$_silenceFinishSeconds';
    String? error;
    final selected = await showDialog<int>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('静音多久后结束'),
          content: TextFormField(
            key: const ValueKey('speech_silence_seconds_input'),
            initialValue: input,
            autofocus: true,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            onChanged: (value) => input = value,
            decoration: InputDecoration(
              labelText: '连续静音秒数',
              helperText: '可填写 1～10 秒；检测到说话后才开始计算',
              errorText: error,
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () {
                final seconds = int.tryParse(input);
                if (seconds == null || seconds < 1 || seconds > 10) {
                  setDialogState(() => error = '请输入 1～10');
                  return;
                }
                Navigator.pop(context, seconds);
              },
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );
    if (selected != null && mounted) {
      await _saveSilenceFinishSeconds(selected);
    }
  }

  Future<void> _chooseRecordingLimit() async {
    var input = '${_recordingLimitSeconds == 0 ? 60 : _recordingLimitSeconds}';
    String? error;
    final selected = await showDialog<int>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('最长录音时长'),
          content: TextFormField(
            key: const ValueKey('speech_recording_limit_input'),
            initialValue: input,
            autofocus: true,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            onChanged: (value) => input = value,
            decoration: InputDecoration(
              labelText: '秒数',
              helperText: '可填写 5～300 秒；到时自动结束并开始识别',
              errorText: error,
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () {
                final seconds = int.tryParse(input);
                if (seconds == null || seconds < 5 || seconds > 300) {
                  setDialogState(() => error = '请输入 5～300');
                  return;
                }
                Navigator.pop(context, seconds);
              },
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );
    if (selected != null && mounted) await _saveRecordingLimit(selected);
  }

  Future<void> _run(
    String status,
    Future<void> Function(SpeechModelService service) action,
  ) async {
    setState(() {
      _busy = true;
      _cancelled = false;
      _progress = null;
      _status = status;
    });
    try {
      await action(ref.read(speechModelServiceProvider));
    } catch (error) {
      if (mounted) showError(context, error);
    } finally {
      if (mounted) {
        setState(() => _busy = false);
        await _refresh();
      }
    }
  }

  Future<void> _download() => _run(
    '正在下载并校验模型…',
    (service) => service.download(
      cancelled: () => _cancelled,
      onProgress: (received, total) {
        if (mounted) setState(() => _progress = received / total);
      },
    ),
  );

  Future<void> _remove() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除语音模型？'),
        content: const Text('将释放约 229 MB 空间。账本不会受影响，之后仍可重新下载。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除模型'),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) {
      await _run('正在删除模型…', (service) => service.remove());
    }
  }

  Future<void> _checkModel() async {
    setState(() {
      _busy = true;
      _status = '正在加载模型并运行自检…';
    });
    try {
      final path = await ref.read(speechModelServiceProvider).installedPath();
      if (path == null) throw const SpeechInputException('语音模型缺失或损坏，请重新下载');
      await const SpeechInput().prepare(path);
      if (mounted) setState(() => _status = '模型自检通过，可以开始语音记账');
    } catch (error) {
      if (mounted) {
        final message = error is PlatformException
            ? error.message ?? '模型初始化失败'
            : error.toString();
        setState(() => _status = '模型自检失败：$message');
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(message)));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final service = ref.watch(speechModelServiceProvider);
    final disabled = _busy || _checking;
    return PopScope(
      canPop: !_busy,
      child: Scaffold(
        appBar: AppBar(title: const Text('语音模型')),
        body: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            SectionCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        _ready ? Icons.check_circle : Icons.mic_none,
                        color: _ready ? teal : Colors.grey,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          _status,
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                      ),
                    ],
                  ),
                  if (_progress != null) ...[
                    const SizedBox(height: 16),
                    LinearProgressIndicator(value: _progress),
                    const SizedBox(height: 8),
                    Text('${(_progress! * 100).toStringAsFixed(0)}%'),
                  ],
                  const SizedBox(height: 16),
                  const Text('SenseVoiceSmall INT8 + Silero VAD'),
                  const SizedBox(height: 6),
                  const Text(
                    '下载约 156 MB，安装后约 229 MB。支持普通话、粤语、英语、日语和韩语；记账默认使用中文。',
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    '模型不会放进安装包。只有你点击下载后才会保存到本机应用私有目录；录音只在本机内存中识别，不保存、不上传。',
                    style: TextStyle(color: Colors.grey),
                  ),
                  const SizedBox(height: 18),
                  if (_busy)
                    OutlinedButton.icon(
                      onPressed: () => setState(() => _cancelled = true),
                      icon: const Icon(Icons.close),
                      label: const Text('取消下载'),
                    )
                  else if (_ready)
                    Wrap(
                      spacing: 10,
                      runSpacing: 8,
                      children: [
                        FilledButton.icon(
                          key: const ValueKey('check_speech_model'),
                          onPressed: disabled ? null : _checkModel,
                          icon: const Icon(Icons.health_and_safety_outlined),
                          label: const Text('运行模型自检'),
                        ),
                        OutlinedButton.icon(
                          onPressed: disabled ? null : _remove,
                          icon: const Icon(Icons.delete_outline),
                          label: const Text('删除模型'),
                        ),
                      ],
                    )
                  else
                    FilledButton.icon(
                      key: const ValueKey('download_speech_model'),
                      onPressed: disabled || !service.supported
                          ? null
                          : _download,
                      icon: const Icon(Icons.download),
                      label: const Text('下载本地语音模型'),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            SectionCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SwitchListTile.adaptive(
                    key: const ValueKey('speech_recording_limit_switch'),
                    contentPadding: EdgeInsets.zero,
                    title: const Text('到时自动完成录音'),
                    subtitle: Text(
                      _recordingLimitSeconds == 0
                          ? '关闭：一直录音，直到你点击“完成录音”'
                          : '开启：录到 $_recordingLimitSeconds 秒时自动完成',
                    ),
                    value: _recordingLimitSeconds > 0,
                    onChanged: disabled
                        ? null
                        : (enabled) => enabled
                              ? _chooseRecordingLimit()
                              : _saveRecordingLimit(0),
                  ),
                  const Divider(height: 1),
                  SwitchListTile.adaptive(
                    key: const ValueKey('speech_silence_auto_finish_switch'),
                    contentPadding: EdgeInsets.zero,
                    title: const Text('静音后自动结束'),
                    subtitle: Text(
                      _silenceAutoFinish
                          ? '开启：连续静音 $_silenceFinishSeconds 秒后自动完成录音'
                          : '关闭：静音不会结束，等待你点击“完成录音”',
                    ),
                    value: _silenceAutoFinish,
                    onChanged: disabled ? null : _saveSilenceAutoFinish,
                  ),
                  if (_silenceAutoFinish)
                    ListTile(
                      key: const ValueKey('edit_speech_silence_seconds'),
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.graphic_eq_outlined),
                      title: const Text('静音结束时长'),
                      subtitle: Text('当前 $_silenceFinishSeconds 秒'),
                      trailing: const Icon(Icons.edit_outlined),
                      onTap: disabled ? null : _chooseSilenceFinishSeconds,
                    ),
                  if (_recordingLimitSeconds > 0)
                    ListTile(
                      key: const ValueKey('edit_speech_recording_limit'),
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.timer_outlined),
                      title: const Text('自定义最长时长'),
                      subtitle: Text('当前 $_recordingLimitSeconds 秒'),
                      trailing: const Icon(Icons.edit_outlined),
                      onTap: disabled ? null : _chooseRecordingLimit,
                    ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            const SectionCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('语音记账流程', style: TextStyle(fontWeight: FontWeight.w600)),
                  SizedBox(height: 10),
                  Text(
                    '立即录音 + 并行加载模型 → 点击完成（或按设置自动完成）→ 本地 VAD 截句 → SenseVoiceSmall → 领域纠错 → 中文金额解析 → 账单草稿',
                  ),
                  SizedBox(height: 8),
                  Text('示例：昨天晚上滴滴四十二块五，支付宝付的。'),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
