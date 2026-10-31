import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slurm_cluster_monitor/models/app_skin.dart';
import 'package:slurm_cluster_monitor/ui/app_theme.dart';
import 'package:slurm_cluster_monitor/ui/gaussian_progress_page.dart';
import 'package:slurm_cluster_monitor/ui/progress_curve.dart';
import 'package:slurm_cluster_monitor/ui/optimization_status.dart';
import 'package:slurm_cluster_monitor/ui/remote_file_browser.dart';
import 'package:slurm_cluster_monitor/ui/structure_view.dart';
import 'gaussian_progress_test.dart' show gaussianStep, gaussianOrientation;
import 'vasp_progress_test.dart' show MemoryVaspFiles;

void main() {
  testWidgets(
    'Gaussian logs open curves, thresholds, geometry and original text',
    (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      tester.platformDispatcher.textScaleFactorTestValue = 1.3;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final files = MemoryVaspFiles({
        'water.log':
            '$gaussianOrientation${List.filled(12, gaussianStep).join()}',
      });
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(AppSkin.daylight),
          home: RemoteFileBrowser(
            files: files,
            directory: '/work',
            title: 'files',
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('water.log'));
      await tester.pumpAndSettle();
      expect(find.byType(GaussianProgressPage), findsOneWidget);
      expect(find.text('优化能量（Hartree）'), findsOneWidget);
      final status = tester.widget<OptimizationStatus>(
        find.byType(OptimizationStatus),
      );
      expect(find.text(status.assessment.detail), findsNothing);
      await tester.tap(find.byType(OptimizationStatus));
      await tester.pumpAndSettle();
      expect(find.text(status.assessment.detail), findsOneWidget);
      await tester.tap(find.text('关闭'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('最近 5 步'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<ProgressCurve>(find.byType(ProgressCurve).first)
            .points
            .length,
        5,
      );
      final metric = find.text('最大受力 / 收敛阈值');
      await tester.ensureVisible(metric);
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<ProgressCurve>(
              find.ancestor(of: metric, matching: find.byType(ProgressCurve)),
            )
            .threshold,
        1,
      );
      await tester.tap(find.text('最新结构'));
      await tester.pumpAndSettle();
      expect(find.byType(StructureView), findsOneWidget);
      expect(find.text('3 原子'), findsOneWidget);
      await tester.tap(find.byTooltip('查看日志原文'));
      await tester.pumpAndSettle();
      expect(find.byType(RemoteFilePage), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('ordinary .out files retain their plain text route', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: RemoteFileBrowser(
          files: MemoryVaspFiles({'slurm-42.out': 'job running'}),
          directory: '/work',
          title: 'files',
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('slurm-42.out'));
    await tester.pumpAndSettle();
    expect(find.byType(GaussianProgressPage), findsNothing);
    expect(find.text('job running'), findsOneWidget);
  });
}
