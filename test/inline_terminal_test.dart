import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slurm_cluster_monitor/models/app_skin.dart';
import 'package:slurm_cluster_monitor/services/remote_commands.dart';
import 'package:slurm_cluster_monitor/services/remote_files.dart';
import 'package:slurm_cluster_monitor/ui/app_theme.dart';
import 'package:slurm_cluster_monitor/ui/remote_file_browser.dart';
import 'package:slurm_cluster_monitor/ui/remote_file_row.dart';

class _Files extends RemoteFiles {
  @override
  Future<RemoteDirectory> list(String path) async => const RemoteDirectory([
    RemoteEntry('outputs', directory: true),
    RemoteEntry('job.sh', size: 30),
  ]);
  @override
  Future<bool> isDirectory(String path) async => true;
  @override
  Future<RemoteText> read(String path, {bool tail = false}) async =>
      const RemoteText('text', size: 4);
  @override
  void close() {}
}

class _Commands extends RemoteCommands {
  final calls = <(String, String)>[];
  Completer<CommandResult>? pending;
  int cancellations = 0;
  @override
  Future<CommandResult> run(
    String directory,
    String command, {
    void Function(String, bool)? onOutput,
    Duration timeout = const Duration(seconds: 120),
  }) async {
    calls.add((directory, command));
    if (pending != null) return pending!.future;
    final output = command.startsWith('sbatch ') ? '9001\n' : '$directory\n';
    onOutput?.call(output, false);
    return CommandResult(stdout: output, stderr: '', exitCode: 0);
  }

  @override
  void cancel() {
    cancellations++;
    pending?.complete(
      const CommandResult(stdout: '', stderr: '', cancelled: true),
    );
  }

  @override
  void close() {}
}

Future<void> _openBrowser(WidgetTester tester, _Commands commands) async {
  tester.view.physicalSize = const Size(360, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetViewInsets);
  await tester.pumpWidget(
    MaterialApp(
      theme: buildAppTheme(AppSkin.daylight),
      home: RemoteFileBrowser(
        files: _Files(),
        directory: '/home/u/task',
        title: 'Task files',
        commands: commands,
      ),
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.byTooltip('当前目录命令'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'terminal stays in the browser and follows its directory above the keyboard',
    (tester) async {
      final source = _Commands();
      await _openBrowser(tester, source);
      final input = find.byKey(const ValueKey('remote-command-input'));
      expect(find.byType(Scaffold), findsOneWidget);
      expect(find.text('Task files'), findsOneWidget);
      expect(source.calls, isEmpty);
      await tester.tap(find.text('outputs'));
      await tester.pumpAndSettle();
      tester.view.viewInsets = const FakeViewPadding(bottom: 300);
      await tester.pumpAndSettle();
      expect(tester.getBottomRight(input).dy, lessThanOrEqualTo(500));
      expect(tester.getTopLeft(input).dy, greaterThan(300));
      await tester.enterText(input, 'pwd');
      await tester.tap(find.byTooltip('运行'));
      await tester.pumpAndSettle();
      expect(source.calls, [('/home/u/task/outputs', 'pwd')]);
      expect(find.text('退出码 0'), findsOneWidget);
      expect(find.text('job.sh'), findsOneWidget);
      expect(find.byType(Scaffold), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'collapsing a running command keeps it alive and the stop control works',
    (tester) async {
      final source = _Commands()..pending = Completer<CommandResult>();
      await _openBrowser(tester, source);
      await tester.enterText(
        find.byKey(const ValueKey('remote-command-input')),
        'sleep 30',
      );
      await tester.tap(find.byTooltip('运行'));
      await tester.pump();
      expect(
        tester
            .widget<IconButton>(
              find.byWidgetPredicate(
                (w) => w is IconButton && w.tooltip == '上级目录',
              ),
            )
            .onPressed,
        isNull,
      );
      expect(
        tester
            .widget<RemoteFileRow>(
              find.ancestor(
                of: find.text('outputs'),
                matching: find.byType(RemoteFileRow),
              ),
            )
            .onTap,
        isNull,
      );
      await tester.tap(find.byTooltip('收起终端'));
      await tester.pump();
      expect(find.byKey(const ValueKey('remote-command-input')), findsNothing);
      expect(source.cancellations, 0);
      await tester.tap(find.byTooltip('当前目录命令'));
      await tester.pump();
      await tester.tap(find.byTooltip('停止会话'));
      await tester.pumpAndSettle();
      expect(source.cancellations, 1);
      expect(find.text('会话已停止'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'inline submission remains locked after closing and reopening the panel',
    (tester) async {
      final source = _Commands();
      await _openBrowser(tester, source);
      await tester.tap(find.byTooltip('命令类型'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('提交任务'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('提交选项'));
      tester.view.viewInsets = const FakeViewPadding(bottom: 300);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.tap(find.byTooltip('提交到 Slurm'));
      await tester.pumpAndSettle();
      expect(source.calls.single, (
        '/home/u/task',
        "sbatch --parsable -- './job.sh'",
      ));
      await tester.tap(find.byTooltip('收起终端'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('当前目录命令'));
      await tester.pumpAndSettle();
      expect(find.text('新建提交').hitTestable(), findsOneWidget);
      expect(
        tester.getBottomRight(find.text('新建提交')).dy,
        lessThan(
          tester
              .getTopLeft(find.byKey(const ValueKey('remote-script-input')))
              .dy,
        ),
      );
      expect(
        tester
            .widget<IconButton>(
              find.byWidgetPredicate(
                (w) => w is IconButton && w.tooltip == '提交到 Slurm',
              ),
            )
            .onPressed,
        isNull,
      );
      expect(source.calls.length, 1);
      expect(tester.takeException(), isNull);
    },
  );
}
