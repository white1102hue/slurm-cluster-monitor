import 'dart:async';
import 'dart:convert';
import 'package:dartssh2/dartssh2.dart';
import 'shell_utils.dart';
import 'remote_files.dart';

String outputSearchCommand(String directory) {
  if (!directory.startsWith('/') || directory.contains('\x00')) {
    throw const FormatException('无效的工作目录');
  }
  final script =
      r'''# SLURM_OUTPUT_SEARCH_V2
export LC_ALL=C
find -L ROOT -type f \( -iname OUTCAR -o -iname '*.log' -o -iname '*.out' \) -printf '%T@\t%s\t%p\0'
'''
          .replaceFirst('ROOT', shellQuote(directory));
  return 'bash -lc ${shellQuote(script)}';
}

/// One remote metadata walk, with streaming reduction on the client. No log
/// contents, depth limit, result limit, sorting subprocess or temporary files.
Future<RemoteOutputSearch?> searchRemoteOutputs(
  SSHClient client,
  String directory, {
  bool Function()? cancelled,
  void Function(int matched)? onProgress,
  Duration timeout = const Duration(minutes: 3),
}) async {
  if (cancelled?.call() == true) throw const FileReadCancelled();
  final accumulator = OutputSearchAccumulator();
  final session = await client
      .execute(outputSearchCommand(directory))
      .timeout(const Duration(seconds: 15));
  var stopped = false, failed = false, errorBytes = 0;
  final diagnostics = StringBuffer();
  final timer = Timer.periodic(const Duration(milliseconds: 100), (_) {
    if (!stopped && cancelled?.call() == true) {
      stopped = true;
      session.kill(SSHSignal.TERM);
      session.close();
    }
  });
  try {
    await Future.wait([
      () async {
        await for (final chunk in const Utf8Decoder(
          allowMalformed: true,
        ).bind(session.stdout)) {
          if (cancelled?.call() == true) throw const FileReadCancelled();
          accumulator.addFindText(chunk);
          onProgress?.call(accumulator.matched);
        }
      }(),
      () async {
        await for (final chunk in session.stderr) {
          if (errorBytes < 4096) {
            diagnostics.write(
              utf8.decode(
                chunk.take(4096 - errorBytes).toList(),
                allowMalformed: true,
              ),
            );
            errorBytes += chunk.length;
          }
        }
      }(),
    ]).timeout(timeout);
    await session.done.timeout(const Duration(seconds: 5));
    failed = session.exitCode != 0;
  } on FileReadCancelled {
    stopped = true;
  } on TimeoutException {
    failed = true;
    session.kill(SSHSignal.TERM);
  } catch (_) {
    failed = true;
  } finally {
    timer.cancel();
    session.close();
  }
  if (stopped || cancelled?.call() == true) throw const FileReadCancelled();
  final unsupported = RegExp(
    r'command not found|unknown predicate|unrecognized|illegal option|unknown option',
    caseSensitive: false,
  ).hasMatch(diagnostics.toString());
  if (failed && unsupported && accumulator.matched == 0) return null;
  return accumulator.finish(
    complete: !failed,
    warnings: [if (failed) '部分目录无法扫描或扫描已超时；显示已找到的最新输出，可重新检测。'],
  );
}
