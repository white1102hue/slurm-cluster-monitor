import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:slurm_cluster_monitor/main.dart';
import 'package:slurm_cluster_monitor/models/app_skin.dart';
import 'package:slurm_cluster_monitor/services/monitor_controller.dart';
import 'package:slurm_cluster_monitor/ui/server_editor.dart';
import 'package:slurm_cluster_monitor/ui/job_card.dart';
import 'package:slurm_cluster_monitor/models/slurm_models.dart';

void main() {
  Future<MonitorController> pump(
    WidgetTester tester, {
    Size size = const Size(390, 844),
    double scale = 1,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    tester.platformDispatcher.textScaleFactorTestValue = scale;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final ctrl = MonitorController(demo: true);
    await ctrl.initialize();
    addTearDown(ctrl.dispose);
    await tester.pumpWidget(
      ChangeNotifierProvider.value(value: ctrl, child: const SlurmMonitorApp()),
    );
    await tester.pumpAndSettle();
    return ctrl;
  }

  testWidgets('phone dashboard filters jobs and navigates all three tabs', (
    tester,
  ) async {
    await pump(tester);
    expect(find.text('作业总览'), findsOneWidget);
    expect(find.text('mof_adsorption_298K'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('job-filter-排队中')));
    await tester.pumpAndSettle();
    expect(find.text('ligand_screening'), findsOneWidget);
    expect(find.text('mof_adsorption_298K'), findsNothing);
    await tester.tap(find.text('节点空闲').last);
    await tester.pumpAndSettle();
    expect(find.text('集群资源'), findsOneWidget);
    expect(find.text('compute'), findsOneWidget);
    await tester.tap(find.text('服务器').last);
    await tester.pumpAndSettle();
    expect(find.text('连接管理'), findsOneWidget);
    expect(find.text('researcher@atlas.example.org:22'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets('refresh interval validates and applies a preset', (
    tester,
  ) async {
    final ctrl = await pump(tester);
    await tester.tap(find.byTooltip('更多操作'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('监控设置'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '0');
    await tester.tap(find.text('保存刷新间隔'));
    await tester.pumpAndSettle();
    expect(find.text('请输入 2–3600 之间的整数'), findsOneWidget);
    await tester.tap(find.widgetWithText(ChoiceChip, '3s'));
    await tester.tap(find.text('保存刷新间隔'));
    await tester.pumpAndSettle();
    expect(ctrl.refreshIntervalSeconds, 3);
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'wide screens use compact server-tinted columns and large lists stay lazy',
    (tester) async {
      final ctrl = await pump(tester, size: const Size(1080, 844));
      final cards = tester.widgetList<JobCard>(find.byType(JobCard)).toList();
      expect(cards.length, greaterThanOrEqualTo(2));
      expect(cards.map((c) => c.serverColor).toSet().length, greaterThan(1));
      expect(tester.getSize(find.byType(JobCard).first).width, lessThan(400));
      // Includes a directly accessible file action with its full touch target.
      expect(tester.getSize(find.byType(JobCard).first).height, lessThan(230));
      expect(
        tester.getSize(find.byTooltip('打开文件夹').first).shortestSide,
        greaterThanOrEqualTo(48),
      );
      ctrl.snapshots['demo-a']!.jobs.addAll([
        for (var i = 0; i < 2000; i++)
          SlurmJob(
            serverId: 'demo-a',
            serverName: 'Atlas',
            jobId: 'lazy-$i',
            jobName: 'large list $i',
            state: 'RUNNING',
          ),
      ]);
      ctrl.selectServer(null);
      await tester.pumpAndSettle();
      expect(find.byType(JobCard).evaluate().length, lessThan(30));
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('optimization entry lists currently running jobs only', (
    tester,
  ) async {
    await pump(tester);
    await tester.tap(find.byTooltip('更多操作'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('优化检测'));
    // Do not wait for native compute isolates under the widget fake clock.
    // The service tests separately await and validate the complete inspection.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('优化检测'), findsOneWidget);
    expect(find.text('mof_adsorption_298K'), findsOneWidget);
    expect(find.text('ligand_screening'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
  testWidgets('settings opens the Xiaomi widget setup page', (tester) async {
    await pump(tester);
    await tester.tap(find.byTooltip('更多操作'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('监控设置'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('小米负一屏与桌面卡片'));
    await tester.tap(find.text('小米负一屏与桌面卡片'));
    await tester.pumpAndSettle();
    expect(find.text('集群概览 · 4×2'), findsOneWidget);
    expect(find.textContaining('尚未完成平台上架审核'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets('small screen with enlarged text does not overflow', (
    tester,
  ) async {
    await pump(tester, size: const Size(360, 800), scale: 1.3);
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('节点空闲').last);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'white and violet skins update all pages without losing job data',
    (tester) async {
      final ctrl = await pump(tester, size: const Size(360, 800), scale: 1.3);
      await tester.tap(find.byTooltip('更多操作'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('监控设置'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('纯白'));
      await tester.pumpAndSettle();
      expect(ctrl.skin, AppSkin.daylight);
      expect(
        Theme.of(tester.element(find.byType(SettingsSheet))).brightness,
        Brightness.light,
      );
      expect(
        Theme.of(
          tester.element(find.byType(SettingsSheet)),
        ).scaffoldBackgroundColor,
        Colors.white,
      );
      await tester.tap(find.text('紫夜'));
      await tester.pumpAndSettle();
      expect(ctrl.skin, AppSkin.violet);
      expect(
        Theme.of(tester.element(find.byType(SettingsSheet))).brightness,
        Brightness.dark,
      );
      await tester.tap(find.text('纯白'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('保存刷新间隔'));
      await tester.tap(find.text('保存刷新间隔'));
      await tester.pumpAndSettle();
      expect(find.text('mof_adsorption_298K'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('节点空闲').last);
      await tester.pumpAndSettle();
      expect(find.text('计算节点内存与磁盘'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('server editor validates fields before any network access', (
    tester,
  ) async {
    final ctrl = await pump(tester);
    await tester.pumpWidget(MaterialApp(home: ServerEditor(controller: ctrl)));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('验证并保存服务器'));
    await tester.tap(find.text('验证并保存服务器'));
    await tester.pumpAndSettle();
    expect(find.text('此项不能为空'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'search and abnormal-ended filters operate on the current local snapshot',
    (tester) async {
      final ctrl = await pump(tester);
      await tester.tap(find.byTooltip('搜索作业'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '9107');
      await tester.pumpAndSettle();
      expect(find.text('graph_model_training'), findsOneWidget);
      expect(find.text('mof_adsorption_298K'), findsNothing);
      await tester.tap(find.byTooltip('搜索作业'));
      await tester.pumpAndSettle();
      ctrl.snapshots['demo-a']!.jobs.add(
        SlurmJob(
          serverId: 'demo-a',
          serverName: 'Atlas',
          jobId: 'failed',
          jobName: 'regression_failed',
          state: 'FAILED',
          endTime: DateTime.now(),
        ),
      );
      ctrl.selectServer(null);
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const ValueKey('job-filter-最近结束')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('job-filter-最近结束')));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ChoiceChip, '异常结束'));
      await tester.pumpAndSettle();
      expect(find.text('regression_failed'), findsOneWidget);
      expect(
        tester
            .widgetList<JobCard>(find.byType(JobCard))
            .every((c) => c.job.isAbnormalEnd),
        isTrue,
      );
    },
  );

  testWidgets('expanded card survives insertion and temporary filtering', (
    tester,
  ) async {
    final ctrl = await pump(tester);
    final original = ctrl.activeJobs.first;
    await tester.tap(find.text(original.jobName));
    await tester.pumpAndSettle();
    expect(find.byTooltip('统计说明'), findsOneWidget);
    ctrl.snapshots[original.serverId]!.jobs.insert(
      0,
      SlurmJob(
        serverId: original.serverId,
        serverName: original.serverName,
        jobId: '0',
        jobName: 'inserted',
        state: 'RUNNING',
      ),
    );
    ctrl.selectServer(null);
    await tester.pumpAndSettle();
    expect(find.byTooltip('统计说明'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('job-filter-排队中')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('job-filter-活跃作业')));
    await tester.pumpAndSettle();
    expect(find.byTooltip('统计说明'), findsOneWidget);
  });

  testWidgets('tab changes restore a long job list scroll position', (
    tester,
  ) async {
    final ctrl = await pump(tester);
    ctrl.snapshots['demo-a']!.jobs.addAll([
      for (var i = 0; i < 60; i++)
        SlurmJob(
          serverId: 'demo-a',
          serverName: 'Atlas',
          jobId: 'long-$i',
          jobName: 'long $i',
          state: 'RUNNING',
        ),
    ]);
    ctrl.selectServer(null);
    await tester.pumpAndSettle();
    final list = find.byKey(const PageStorageKey<int>(0));
    await tester.drag(list, const Offset(0, -1200));
    await tester.pumpAndSettle();
    double pixels() => tester
        .state<ScrollableState>(
          find.descendant(of: list, matching: find.byType(Scrollable)).first,
        )
        .position
        .pixels;
    final before = pixels();
    expect(before, greaterThan(100));
    await tester.tap(find.text('节点空闲').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('我的作业').last);
    await tester.pumpAndSettle();
    expect(pixels(), closeTo(before, 1));
  });

  testWidgets(
    'server files entry is available without any jobs and includes a terminal',
    (tester) async {
      final ctrl = await pump(tester);
      for (final snapshot in ctrl.snapshots.values) {
        snapshot.jobs.clear();
      }
      ctrl.selectServer(null);
      await tester.pumpAndSettle();
      await tester.tap(find.text('服务器').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('文件与提交').first);
      await tester.pumpAndSettle();
      expect(find.byTooltip('当前目录命令'), findsOneWidget);
      expect(find.text('POSCAR'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
