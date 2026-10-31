import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slurm_cluster_monitor/models/slurm_models.dart';
import 'package:slurm_cluster_monitor/services/remote_files.dart';
import 'package:slurm_cluster_monitor/ui/optimization_check_page.dart';

class ScanFiles extends RemoteFiles {
  final calls = <String>[];
  final pending = <String, Completer<RemoteOutputSearch>>{};
  final progress = <String, void Function(int)?>{};
  @override
  Future<RemoteOutputSearch> findOutputs(
    String directory, {
    bool Function()? cancelled,
    void Function(int)? onProgress,
  }) async {
    calls.add(directory);
    progress[directory] = onProgress;
    final result =
        await (pending[directory] = Completer<RemoteOutputSearch>()).future;
    if (cancelled?.call() == true) throw const FileReadCancelled();
    return result;
  }

  @override
  Future<RemoteDirectory> list(String path) async => const RemoteDirectory([]);
  @override
  Future<bool> isDirectory(String path) async => true;
  @override
  Future<RemoteText> read(String path, {bool tail = false}) async =>
      const RemoteText('', size: 0);
  @override
  void close() {}
}

void main() {
  testWidgets(
    'different hosts scan concurrently and shared directories share progress and one scan',
    (tester) async {
      tester.view.physicalSize = const Size(1000, 1200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      const a = ServerConfig(id: 'a', name: 'A', host: 'a', username: 'u');
      const b = ServerConfig(id: 'b', name: 'B', host: 'b', username: 'u');
      final files = {'a': ScanFiles(), 'b': ScanFiles()};
      SlurmJob job(String id, String server, String directory) => SlurmJob(
        serverId: server,
        serverName: server,
        jobId: id,
        jobName: id,
        state: 'RUNNING',
        workDir: directory,
      );
      await tester.pumpWidget(
        MaterialApp(
          home: OptimizationCheckPage(
            servers: [a, b],
            jobs: [
              job('1', 'a', '/same'),
              job('2', 'a', '/same'),
              job('3', 'b', '/fast'),
            ],
            filesFactory: (s) => files[s.id]!,
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 150));
      expect(files['a']!.calls, ['/same']);
      expect(files['b']!.calls, ['/fast']);
      files['a']!.progress['/same']!(7);
      await tester.pump();
      expect(find.text('扫描子目录中 · 已找到 7 个输出'), findsNWidgets(2));
      files['b']!.pending['/fast']!.complete(const RemoteOutputSearch());
      await tester.pump();
      await tester.pump();
      expect(find.text('脚本运行中 · 尚未找到 OUTCAR / Gaussian 输出'), findsOneWidget);
      files['a']!.pending['/same']!.complete(const RemoteOutputSearch());
      await tester.pumpAndSettle();
      expect(files['a']!.calls, ['/same']);
      expect(find.byType(LinearProgressIndicator), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'batch scans use four host slots and stop does not start queued hosts',
    (tester) async {
      final hosts = [
        for (var i = 0; i < 6; i++)
          ServerConfig(id: '$i', name: '$i', host: '$i', username: 'u'),
      ];
      final files = {for (final s in hosts) s.id: ScanFiles()};
      await tester.pumpWidget(
        MaterialApp(
          home: OptimizationCheckPage(
            servers: hosts,
            jobs: [
              for (final s in hosts)
                SlurmJob(
                  serverId: s.id,
                  serverName: s.name,
                  jobId: s.id,
                  jobName: s.name,
                  state: 'RUNNING',
                  workDir: '/work',
                ),
            ],
            filesFactory: (s) => files[s.id]!,
          ),
        ),
      );
      await tester.pump();
      expect(files.values.where((f) => f.calls.isNotEmpty), hasLength(4));
      await tester.tap(find.byTooltip('停止检测'));
      await tester.pump();
      for (final f in files.values) {
        for (final p in f.pending.values) {
          p.complete(const RemoteOutputSearch());
        }
      }
      await tester.pumpAndSettle();
      expect(files.values.where((f) => f.calls.isNotEmpty), hasLength(4));
      expect(tester.takeException(), isNull);
    },
  );
}
