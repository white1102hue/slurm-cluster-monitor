import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slurm_cluster_monitor/models/app_skin.dart';
import 'package:slurm_cluster_monitor/services/remote_files.dart';
import 'package:slurm_cluster_monitor/ui/app_theme.dart';
import 'package:slurm_cluster_monitor/ui/remote_file_browser.dart';
import 'package:slurm_cluster_monitor/ui/structure_view.dart';
import 'package:slurm_cluster_monitor/ui/remote_file_row.dart';

void main() {
  testWidgets(
    'file browser filters files, opens structure, rotates and shows raw text',
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
            title: 'Task files',
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'POS');
      await tester.pumpAndSettle();
      expect(find.text('POSCAR'), findsOneWidget);
      expect(find.text('water.gjf'), findsNothing);
      await tester.tap(find.text('POSCAR'));
      await tester.pump();
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 400));
      });
      await tester.pumpAndSettle();
      expect(find.byType(StructureView), findsOneWidget);
      expect(find.text('8 原子'), findsOneWidget);
      await tester.drag(find.byType(CustomPaint).last, const Offset(40, 30));
      await tester.pumpAndSettle();
      await tester.tap(find.text('原文'));
      await tester.pumpAndSettle();
      expect(find.text('Silicon'), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'Direct');
      await tester.pumpAndSettle();
      expect(find.text('1/1'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('plain text file shows text and has no structure toggle', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: RemoteFilePage(files: DemoRemoteFiles(), path: '/home/INCAR'),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('SYSTEM = Silicon'), findsOneWidget);
    expect(find.text('结构'), findsNothing);
    await tester.tap(find.byTooltip('读取位置'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(CheckedPopupMenuItem<bool>, '文件末尾'));
    await tester.pumpAndSettle();
    expect(find.text('SYSTEM = Silicon'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'file list shows a modification column and sorts both ways on enlarged text',
    (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = 1.3;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(AppSkin.daylight),
          home: RemoteFileBrowser(
            files: _Dates(),
            directory: '/work',
            title: 'Files',
          ),
        ),
      );
      await tester.pumpAndSettle();
      List<String> names() => tester
          .widgetList<RemoteFileRow>(find.byType(RemoteFileRow))
          .map((row) => row.entry.name)
          .toList();
      expect(find.text('最近修改'), findsOneWidget);
      expect(find.text('2026-10-28\n12:30'), findsOneWidget);
      expect(names(), ['folder', 'b-new.OUTCAR', 'a-old.txt', 'c-unknown.txt']);
      await tester.tap(find.text('最近修改'));
      await tester.pumpAndSettle();
      expect(names(), ['folder', 'a-old.txt', 'b-new.OUTCAR', 'c-unknown.txt']);
      await tester.tap(find.text('名称'));
      await tester.pumpAndSettle();
      expect(names(), ['folder', 'a-old.txt', 'b-new.OUTCAR', 'c-unknown.txt']);
      await tester.enterText(find.byType(TextField), 'new');
      await tester.pumpAndSettle();
      expect(names(), ['b-new.OUTCAR']);
      expect(tester.takeException(), isNull);
    },
  );
}

class _Dates extends DemoRemoteFiles {
  @override
  Future<RemoteDirectory> list(String path) async => RemoteDirectory([
    const RemoteEntry('c-unknown.txt', size: 10),
    RemoteEntry('a-old.txt', size: 20, modified: DateTime(2026, 10, 27, 10)),
    RemoteEntry(
      'b-new.OUTCAR',
      size: 102400,
      modified: DateTime(2026, 10, 28, 12, 30),
    ),
    RemoteEntry(
      'folder',
      directory: true,
      modified: DateTime(2026, 10, 20, 10),
    ),
  ]);
}
