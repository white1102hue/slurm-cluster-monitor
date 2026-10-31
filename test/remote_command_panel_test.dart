import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slurm_cluster_monitor/services/remote_commands.dart';
import 'package:slurm_cluster_monitor/ui/remote_command_panel.dart';

class TestCommands extends RemoteCommands {
  int calls = 0;
  CommandResult result = const CommandResult(
    stdout: '9001\n',
    stderr: '',
    exitCode: 0,
  );
  @override
  Future<CommandResult> run(
    String directory,
    String command, {
    void Function(String, bool)? onOutput,
    Duration timeout = const Duration(seconds: 120),
  }) async {
    calls++;
    onOutput?.call(result.stdout, false);
    return result;
  }

  @override
  void cancel() {}
  @override
  void close() {}
}

void main() {
  testWidgets(
    'submission uses a deliberate button and blocks accidental duplicate submission',
    (tester) async {
      final source = TestCommands();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.bottomCenter,
              child: RemoteCommandPanel(
                directory: '/home/u/task',
                commands: source,
                initialScript: 'job.sh',
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(source.calls, 0);
      await tester.tap(find.byTooltip('提交到 Slurm'));
      // A second click can arrive before the disabled button is repainted.
      await tester.tap(find.byTooltip('提交到 Slurm'));
      await tester.pumpAndSettle();
      expect(find.text('已提交任务 #9001'), findsOneWidget);
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
      expect(source.calls, 1);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'a lost submit response asks to check the queue before re-enabling submission',
    (tester) async {
      final source = TestCommands()
        ..result = const CommandResult(
          stdout: '',
          stderr: '',
          started: true,
          error: '连接中断',
        );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.bottomCenter,
              child: RemoteCommandPanel(
                directory: '/home/u/task',
                commands: source,
                initialScript: 'job.sh',
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('提交到 Slurm'));
      await tester.pumpAndSettle();
      expect(find.text('已核对队列，允许重新提交'), findsOneWidget);
      expect(source.calls, 1);
    },
  );
}
