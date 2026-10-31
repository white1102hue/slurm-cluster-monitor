import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/remote_commands.dart';
import 'app_theme.dart';

class RemoteCommandPanel extends StatefulWidget {
  const RemoteCommandPanel({
    super.key,
    required this.directory,
    required this.commands,
    this.scripts = const [],
    this.initialScript,
    this.visible = true,
    this.onBusyChanged,
    this.onFinished,
    this.onSubmitted,
    this.onClose,
  });
  final String directory;
  final RemoteCommands commands;
  final List<String> scripts;
  final String? initialScript;
  final bool visible;
  final ValueChanged<bool>? onBusyChanged;
  final VoidCallback? onFinished, onSubmitted, onClose;

  @override
  State<RemoteCommandPanel> createState() => _RemoteCommandPanelState();
}

class _RemoteCommandPanelState extends State<RemoteCommandPanel> {
  final _command = TextEditingController(),
      _options = TextEditingController(),
      _args = TextEditingController();
  final _focus = FocusNode();
  late final _script = TextEditingController(
    text: widget.initialScript ?? widget.scripts.firstOrNull ?? '',
  );
  bool _submit = false, _busy = false, _submitted = false, _uncertain = false;
  bool _showOptions = false;
  String _status = '';
  final _pendingOutput = StringBuffer();
  final _outputLines = <String>[''];
  Timer? _outputTimer;
  bool get _hasOutput =>
      _outputLines.length > 1 || _outputLines.first.isNotEmpty;
  String get _output => _outputLines.join('\n');
  void _resetOutput() {
    _outputTimer?.cancel();
    _pendingOutput.clear();
    _outputLines
      ..clear()
      ..add('');
  }

  void _flushOutput({bool notify = true}) {
    _outputTimer?.cancel();
    _outputTimer = null;
    if (_pendingOutput.isEmpty) return;
    final parts = _pendingOutput.toString().split('\n');
    _pendingOutput.clear();
    _outputLines[_outputLines.length - 1] += parts.first;
    _outputLines.addAll(parts.skip(1));
    if (notify && mounted) setState(() {});
  }

  void _appendOutput(String text) {
    _pendingOutput.write(text);
    _outputTimer ??= Timer(const Duration(milliseconds: 75), _flushOutput);
  }

  @override
  void initState() {
    super.initState();
    _submit = widget.initialScript != null;
    _updateFocus();
  }

  void _updateFocus() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (widget.visible && !_busy) {
        _focus.requestFocus();
      } else {
        _focus.unfocus();
      }
    });
  }

  @override
  void didUpdateWidget(covariant RemoteCommandPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.directory != oldWidget.directory && !_busy) {
      _resetOutput();
      _status = '';
      _submitted = false;
      _uncertain = false;
      _script.text = widget.scripts.firstOrNull ?? '';
    } else if (_script.text.isEmpty && widget.scripts.isNotEmpty) {
      _script.text = widget.scripts.first;
    }
    if (widget.visible != oldWidget.visible) _updateFocus();
  }

  @override
  void dispose() {
    _outputTimer?.cancel();
    _command.dispose();
    _options.dispose();
    _args.dispose();
    _script.dispose();
    _focus.dispose();
    super.dispose();
  }

  Future<void> _run() async {
    if (_busy || (_submit && (_submitted || _uncertain))) return;
    String command;
    try {
      command = _submit
          ? sbatchCommand(
              _script.text,
              options: _options.text,
              arguments: _args.text,
            )
          : _command.text;
      directoryCommand(widget.directory, command);
    } catch (e) {
      setState(() => _status = e is FormatException ? e.message : '请检查输入');
      return;
    }
    _focus.unfocus();
    setState(() {
      _busy = true;
      _resetOutput();
      _status = _submit ? '正在提交…' : '运行中…';
    });
    widget.onBusyChanged?.call(true);
    CommandResult result;
    try {
      result = await widget.commands.run(
        widget.directory,
        command,
        onOutput: (text, stderr) {
          if (mounted) _appendOutput(text);
        },
      );
    } catch (e) {
      if (mounted) {
        _flushOutput(notify: false);
        setState(() {
          _busy = false;
          _status = e is FormatException ? e.message : '命令执行失败，请检查连接';
        });
        widget.onBusyChanged?.call(false);
      }
      return;
    }
    if (!mounted) return;
    _flushOutput(notify: false);
    setState(() {
      _busy = false;
      if (result.truncated) {
        _pendingOutput.write('\n…输出超过 1 MB，已截断显示。');
        _flushOutput(notify: false);
      }
      if (result.error != null || result.timedOut || result.cancelled) {
        _status = result.cancelled
            ? '会话已停止'
            : result.timedOut
            ? '命令超时，已请求停止'
            : result.error!;
        if (_submit && result.started) _uncertain = true;
      } else if (_submit && result.exitCode == 0) {
        final id = submittedJobId(result.stdout);
        if (id != null) {
          _status = '已提交任务 #$id';
          _submitted = true;
          widget.onSubmitted?.call();
        } else {
          _status = '未取得作业编号，请先刷新队列核对，避免重复提交';
          _uncertain = true;
        }
      } else {
        _status = '退出码 ${result.exitCode ?? '未知'}';
      }
    });
    widget.onBusyChanged?.call(false);
    widget.onFinished?.call();
  }

  String get _preview {
    try {
      return sbatchCommand(
        _script.text,
        options: _options.text,
        arguments: _args.text,
      );
    } catch (_) {
      return '请选择脚本并检查参数';
    }
  }

  Widget _details() => SingleChildScrollView(
    padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (widget.commands.demo)
          Text(
            '示例模式，不执行真实命令',
            style: TextStyle(fontSize: 11, color: context.muted),
          ),
        if (_submit) ...[
          Row(
            children: [
              const Text('提交任务', style: TextStyle(fontWeight: FontWeight.w600)),
              const Spacer(),
              IconButton(
                tooltip: '提交选项',
                visualDensity: VisualDensity.compact,
                onPressed: _busy || _submitted || _uncertain
                    ? null
                    : () => setState(() => _showOptions = !_showOptions),
                icon: Icon(
                  _showOptions ? Icons.expand_less : Icons.tune,
                  size: 20,
                ),
              ),
            ],
          ),
          if (widget.scripts.isNotEmpty)
            SizedBox(
              height: 38,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: widget.scripts.length,
                separatorBuilder: (_, _) => const SizedBox(width: 6),
                itemBuilder: (_, index) => ActionChip(
                  label: Text(widget.scripts[index]),
                  onPressed: _busy || _submitted || _uncertain
                      ? null
                      : () => setState(
                          () => _script.text = widget.scripts[index],
                        ),
                ),
              ),
            ),
          if (_showOptions) ...[
            const SizedBox(height: 6),
            TextField(
              controller: _options,
              enabled: !_busy && !_submitted && !_uncertain,
              decoration: const InputDecoration(
                labelText: 'sbatch 选项（可选）',
                hintText: '-p compute -N 1',
                isDense: true,
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _args,
              enabled: !_busy && !_submitted && !_uncertain,
              decoration: const InputDecoration(
                labelText: '脚本参数（可选）',
                isDense: true,
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 8),
          ],
          SelectableText(
            _preview,
            style: TextStyle(
              fontSize: 11,
              fontFamily: 'monospace',
              color: context.muted,
            ),
          ),
        ],
        if (_status.isNotEmpty || _hasOutput)
          Row(
            children: [
              Expanded(
                child: Text(
                  _status,
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              if (_hasOutput)
                IconButton(
                  tooltip: '复制输出',
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.copy_outlined, size: 18),
                  onPressed: () =>
                      Clipboard.setData(ClipboardData(text: _output)),
                ),
            ],
          ),
        if (_hasOutput)
          Container(
            height: 132,
            padding: const EdgeInsets.all(8),
            color: context.track.withValues(alpha: .35),
            child: Builder(
              builder: (_) {
                final lines = _outputLines;
                return ListView.builder(
                  itemCount: lines.length,
                  itemBuilder: (context, index) {
                    final line = lines[index];
                    return SelectableText(
                      line.length > 4000
                          ? '${line.substring(0, 4000)}…（可复制完整输出）'
                          : line,
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 12,
                      ),
                    );
                  },
                );
              },
            ),
          ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.surface,
      border: Border(
        top: BorderSide(color: Theme.of(context).colorScheme.outlineVariant),
      ),
    ),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (_busy) const LinearProgressIndicator(minHeight: 2),
        if (_submit || _status.isNotEmpty || widget.commands.demo)
          Flexible(child: _details()),
        if (_submit && (_submitted || _uncertain))
          TextButton(
            onPressed: () => setState(() {
              _submitted = false;
              _uncertain = false;
              _status = '';
            }),
            child: Text(_uncertain ? '已核对队列，允许重新提交' : '新建提交'),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 8, 4, 8),
          child: Row(
            children: [
              PopupMenuButton<bool>(
                tooltip: '命令类型',
                enabled: !_busy,
                initialValue: _submit,
                icon: Icon(
                  _submit ? Icons.send_outlined : Icons.terminal,
                  size: 22,
                ),
                onSelected: (submit) {
                  setState(() => _submit = submit);
                  _updateFocus();
                },
                itemBuilder: (_) => [
                  const PopupMenuItem(value: false, child: Text('运行命令')),
                  const PopupMenuItem(value: true, child: Text('提交任务')),
                ],
              ),
              Expanded(
                child: TextField(
                  key: ValueKey(
                    _submit ? 'remote-script-input' : 'remote-command-input',
                  ),
                  controller: _submit ? _script : _command,
                  focusNode: _focus,
                  enabled: !_busy && (!_submit || (!_submitted && !_uncertain)),
                  minLines: 1,
                  maxLines: 3,
                  keyboardType: TextInputType.multiline,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
                  decoration: InputDecoration(
                    labelText: _submit ? '脚本文件' : '命令',
                    hintText: _submit ? 'job.sh' : '例如 pwd 或 ls -lh',
                    isDense: true,
                  ),
                  onChanged: _submit ? (_) => setState(() {}) : null,
                ),
              ),
              IconButton(
                tooltip: _busy
                    ? '停止会话'
                    : _submit
                    ? '提交到 Slurm'
                    : '运行',
                onPressed: _busy
                    ? widget.commands.cancel
                    : _submit && (_submitted || _uncertain)
                    ? null
                    : _run,
                icon: Icon(
                  _busy ? Icons.stop_circle_outlined : Icons.arrow_upward,
                  size: 22,
                ),
              ),
              IconButton(
                tooltip: '收起终端',
                onPressed: widget.onClose,
                icon: const Icon(Icons.keyboard_arrow_down),
              ),
            ],
          ),
        ),
      ],
    ),
  );
}
