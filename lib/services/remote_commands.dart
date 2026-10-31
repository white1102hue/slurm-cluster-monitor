import 'dart:async';
import 'dart:convert';
import 'package:dartssh2/dartssh2.dart';
import '../models/slurm_models.dart';
import 'slurm_ssh_service.dart';

String directoryCommand(String directory, String command) {
  if (!directory.startsWith('/') || directory.contains('\x00')) {
    throw const FormatException('无效的工作目录');
  }
  if (command.trim().isEmpty || command.contains('\x00')) {
    throw const FormatException('请输入命令');
  }
  return 'bash -lc ${shellQuote('# SLURM_DIRECTORY_COMMAND_V1\ncd -- ${shellQuote(directory)} && {\n$command\n} </dev/null')}';
}

List<String> splitArguments(String value) {
  if (value.contains('\x00')) throw const FormatException('参数含无效字符');
  final out = <String>[];
  var token = '', quote = '', active = false, escape = false;
  for (final rune in value.runes) {
    final c = String.fromCharCode(rune);
    if (escape) {
      token += c;
      active = true;
      escape = false;
      continue;
    }
    if (c == '\\' && quote != "'") {
      escape = true;
      active = true;
      continue;
    }
    if (quote.isNotEmpty) {
      if (c == quote) {
        quote = '';
      } else {
        token += c;
      }
      continue;
    }
    if (c == "'" || c == '"') {
      quote = c;
      active = true;
      continue;
    }
    if (RegExp(r'\s').hasMatch(c)) {
      if (active) {
        out.add(token);
        token = '';
        active = false;
      }
    } else {
      token += c;
      active = true;
    }
  }
  if (escape || quote.isNotEmpty) throw const FormatException('参数的引号或转义未闭合');
  if (active) out.add(token);
  return out;
}

String sbatchCommand(
  String script, {
  String options = '',
  String arguments = '',
}) {
  if (script.trim().isEmpty ||
      script.contains('\x00') ||
      script.contains('\n')) {
    throw const FormatException('请输入脚本路径');
  }
  final path = script.contains('/') ? script : './$script';
  return [
    'sbatch',
    '--parsable',
    ...splitArguments(options).map(shellQuote),
    '--',
    shellQuote(path),
    ...splitArguments(arguments).map(shellQuote),
  ].join(' ');
}

String? submittedJobId(String output) {
  for (final line in output.split('\n')) {
    final match = RegExp(
      r'^(\d+)(?:;[A-Za-z0-9_.-]+)?$',
    ).firstMatch(line.trim());
    if (match != null) return match[1];
  }
  return null;
}

class CommandResult {
  const CommandResult({
    required this.stdout,
    required this.stderr,
    this.exitCode,
    this.started = true,
    this.cancelled = false,
    this.timedOut = false,
    this.truncated = false,
    this.error,
  });
  final String stdout, stderr;
  final int? exitCode;
  final bool started, cancelled, timedOut, truncated;
  final String? error;
}

abstract class RemoteCommands {
  bool get demo => false;
  String get serverName => '';
  Future<CommandResult> run(
    String directory,
    String command, {
    void Function(String, bool)? onOutput,
    Duration timeout = const Duration(seconds: 120),
  });
  void cancel();
  void close();
}

class SshRemoteCommands extends RemoteCommands {
  SshRemoteCommands(this.server);
  final ServerConfig server;
  @override
  String get serverName => server.name;
  final _ssh = SlurmSshService();
  SSHSession? _session;
  bool _running = false, _cancelled = false, _closed = false;
  Completer<void>? _cancelSignal;
  Object? _operation;
  static const outputLimit = 1024 * 1024;
  @override
  Future<CommandResult> run(
    String directory,
    String command, {
    void Function(String, bool)? onOutput,
    Duration timeout = const Duration(seconds: 120),
  }) async {
    if (_closed) throw const FormatException('命令连接已关闭');
    if (_running) throw const FormatException('当前命令尚未结束');
    final shell = directoryCommand(directory, command);
    _running = true;
    _cancelled = false;
    final cancelled = _cancelSignal = Completer<void>();
    var expired = false;
    final operation = Object();
    _operation = operation;
    final out = <int>[], err = <int>[];
    var started = false, timedOut = false, truncated = false;
    String? error;
    try {
      Future<T> interrupt<T>(Future<T> future) => Future.any([
        future,
        cancelled.future.then<T>((_) => throw const _CommandCancelled()),
      ]);
      final client = await interrupt(_ssh.connect(server));
      if (_cancelled) {
        _ssh.close();
        return const CommandResult(
          stdout: '',
          stderr: '',
          started: false,
          cancelled: true,
        );
      }
      // The request may reach the server even when its acknowledgement is lost.
      // Treat that interval as uncertain rather than safe to submit again.
      started = true;
      _session = await interrupt(
        client
            .execute(shell)
            .then((session) {
              if (expired ||
                  _cancelled ||
                  _closed ||
                  !identical(_operation, operation)) {
                session.kill(SSHSignal.TERM);
                session.close();
                throw const _CommandCancelled();
              }
              return session;
            })
            .timeout(const Duration(seconds: 15)),
      );
      Future<void> read(
        Stream<List<int>> stream,
        List<int> target,
        bool stderr,
      ) async {
        await for (final text in const Utf8Decoder(
          allowMalformed: true,
        ).bind(stream)) {
          if (expired || !identical(_operation, operation)) return;
          final chunk = utf8.encode(text);
          final available = outputLimit - out.length - err.length;
          final kept = chunk.take(available.clamp(0, chunk.length)).toList();
          if (kept.length < chunk.length) truncated = true;
          target.addAll(kept);
          if (kept.isNotEmpty) {
            onOutput?.call(utf8.decode(kept, allowMalformed: true), stderr);
          }
        }
      }

      await interrupt(
        Future.wait([
          read(_session!.stdout, out, false),
          read(_session!.stderr, err, true),
        ]).timeout(timeout),
      );
      await interrupt(_session!.done.timeout(const Duration(seconds: 5)));
    } on _CommandCancelled {
      _cancelled = true;
    } on TimeoutException {
      timedOut = true;
      _session?.kill(SSHSignal.TERM);
    } catch (e) {
      error = friendlyError(e);
    } finally {
      expired = true;
      if (_session == null || _cancelled || timedOut) _ssh.close();
      _session?.close();
      if (_session != null) {
        try {
          await _session!.done.timeout(const Duration(seconds: 2));
        } catch (_) {}
      }
      _running = false;
      _cancelSignal = null;
    }
    final result = CommandResult(
      stdout: utf8.decode(out, allowMalformed: true),
      stderr: utf8.decode(err, allowMalformed: true),
      exitCode: _session?.exitCode,
      started: started,
      cancelled: _cancelled,
      timedOut: timedOut,
      truncated: truncated,
      error: error,
    );
    _session = null;
    return result;
  }

  @override
  void cancel() {
    if (!_running) return;
    _cancelled = true;
    if (_cancelSignal?.isCompleted == false) _cancelSignal!.complete();
    _session?.kill(SSHSignal.TERM);
    _session?.close();
    _ssh.close();
  }

  @override
  void close() {
    _closed = true;
    cancel();
    _ssh.close();
  }
}

class _CommandCancelled implements Exception {
  const _CommandCancelled();
}

class DemoRemoteCommands extends RemoteCommands {
  @override
  bool get demo => true;
  @override
  Future<CommandResult> run(
    String directory,
    String command, {
    void Function(String, bool)? onOutput,
    Duration timeout = const Duration(seconds: 120),
  }) async {
    final text = command.startsWith('sbatch ')
        ? '9001\n'
        : '示例目录：$directory\n此为演示输出，未执行真实命令。\n';
    onOutput?.call(text, false);
    return CommandResult(stdout: text, stderr: '', exitCode: 0);
  }

  @override
  void cancel() {}
  @override
  void close() {}
}
