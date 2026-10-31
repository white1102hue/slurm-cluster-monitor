import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slurm_cluster_monitor/models/slurm_models.dart';
import 'package:slurm_cluster_monitor/models/app_skin.dart';
import 'package:slurm_cluster_monitor/ui/app_theme.dart';
import 'package:slurm_cluster_monitor/ui/job_card.dart';
import 'package:slurm_cluster_monitor/ui/refresh_age.dart';
import 'package:slurm_cluster_monitor/models/server_palette.dart';

const job = SlurmJob(
  serverId: 'a',
  serverName: 'A',
  jobId: '42',
  jobName: 'test-job',
  state: 'RUNNING',
  partition: 'compute',
  nodeList: 'cn01',
  allocatedNodes: 1,
  usedMemMb: 4096,
  usedCpus: 2,
  allocatedCpus: 8,
  workDir: '/home/u/project',
  metricNote: 'long explanation',
  nodes: [NodeResources(name: 'cn01', totalMemoryMb: 262144)],
);

void main() {
  test(
    'server border colors and relative refresh ages distinguish hosts and stale data',
    () {
      expect(serverColorValue('a'), isNot(serverColorValue('b')));
      final now = DateTime.utc(2026, 10, 25, 10);
      expect(
        refreshAge(now.subtract(const Duration(seconds: 15)), now),
        '15 秒前刷新',
      );
      expect(
        refreshAge(now.subtract(const Duration(minutes: 2)), now),
        '2 分钟前刷新',
      );
    },
  );
  testWidgets(
    'jobs start compact, expand on click and retain state when data refreshes',
    (tester) async {
      var opened = 0;
      Future<void> pump(SlurmJob j) => tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(AppSkin.daylight),
          home: Scaffold(
            body: SingleChildScrollView(
              child: JobCard(
                key: const ValueKey('a/42'),
                job: j,
                onOpenFiles: () => opened++,
              ),
            ),
          ),
        ),
      );
      await pump(job);
      expect(find.text('test-job'), findsOneWidget);
      expect(find.text('25.0%'), findsOneWidget);
      expect(find.text('1.6%'), findsOneWidget);
      expect(find.text('/home/u/project'), findsNothing);
      expect(find.text('long explanation'), findsNothing);
      await tester.tap(find.text('test-job'));
      await tester.pumpAndSettle();
      expect(find.text('/home/u/project'), findsOneWidget);
      expect(find.textContaining('磁盘'), findsNothing);
      await tester.tap(find.text('文件'));
      expect(opened, 1);
      await pump(SlurmJob.fromJson(job.toJson()));
      expect(find.text('/home/u/project'), findsOneWidget);
      await tester.tap(find.byTooltip('统计说明'));
      await tester.pumpAndSettle();
      expect(find.textContaining('long explanation'), findsOneWidget);
      await tester.tap(find.text('关闭'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('test-job'));
      await tester.pumpAndSettle();
      expect(find.text('/home/u/project'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}
