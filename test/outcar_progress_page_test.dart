import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slurm_cluster_monitor/models/app_skin.dart';
import 'package:slurm_cluster_monitor/services/remote_files.dart';
import 'package:slurm_cluster_monitor/ui/app_theme.dart';
import 'package:slurm_cluster_monitor/ui/outcar_progress_page.dart';
import 'package:slurm_cluster_monitor/ui/progress_curve.dart';
import 'package:slurm_cluster_monitor/ui/remote_file_browser.dart';
import 'vasp_progress_test.dart' show MemoryVaspFiles;

void main() {
  testWidgets(
    'OUTCAR click opens both curves, supports last five and point inspection, and keeps raw text accessible',
    (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(AppSkin.daylight),
          home: RemoteFileBrowser(
            files: DemoRemoteFiles(),
            directory: '/home/demo',
            title: 'files',
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('OUTCAR'));
      await tester.tap(find.text('OUTCAR'));
      await tester.pumpAndSettle();
      expect(find.byType(OutcarProgressPage), findsOneWidget);
      expect(find.text('能量 E0（eV）'), findsOneWidget);
      expect(find.text('最大受力（eV/Å）'), findsOneWidget);
      expect(
        tester
            .widget<ProgressCurve>(find.byType(ProgressCurve).first)
            .points
            .length,
        12,
      );
      await tester.tap(find.text('最近 5 步'));
      await tester.pumpAndSettle();
      final curve = tester.widget<ProgressCurve>(
        find.byType(ProgressCurve).first,
      );
      expect(curve.points.length, 5);
      expect(curve.points.first.step, 8);
      final paint = find.descendant(
        of: find.byType(ProgressCurve).first,
        matching: find.byKey(const ValueKey('progress-curve-canvas')),
      );
      final rect = tester.getRect(paint);
      await tester.tapAt(Offset(rect.left + 76, rect.center.dy));
      await tester.pumpAndSettle();
      expect(find.textContaining('第 8 步 ·'), findsOneWidget);
      await tester.tap(find.byTooltip('查看 OUTCAR 原文'));
      await tester.pumpAndSettle();
      expect(find.byType(RemoteFilePage), findsOneWidget);
      expect(find.text('NIONS = 8'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'unknown constraints are labeled as raw force and empty live output is not a zero curve',
    (tester) async {
      final files = MemoryVaspFiles({
        'OUTCAR':
            'NIONS = 1\nPOSITION TOTAL-FORCE\n------\n0 0 0 3 4 0\n------\n',
      });
      await tester.pumpWidget(
        MaterialApp(
          home: OutcarProgressPage(
            files: files,
            path: '/home/u/OUTCAR',
            onOpenText: () {},
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('原始受力 · 约束未知'), findsOneWidget);
      expect(find.text('暂无完整有效数据'), findsOneWidget);
      expect(find.text('第 1 步 · 5 eV/Å'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
