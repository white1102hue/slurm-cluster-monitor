import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:slurm_cluster_monitor/main.dart';
import 'package:slurm_cluster_monitor/services/monitor_controller.dart';
import 'package:slurm_cluster_monitor/models/app_skin.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    final iconPath = Platform.environment['SLURM_TEST_MATERIAL_ICONS'];
    if (iconPath != null && File(iconPath).existsSync()) {
      final icons = File(iconPath);
      await (FontLoader('MaterialIcons')..addFont(
            Future.value(ByteData.sublistView(await icons.readAsBytes())),
          ))
          .load();
    }
    final fontPath = Platform.environment['SLURM_TEST_FONT'];
    if (fontPath != null && File(fontPath).existsSync()) {
      final font = File(fontPath);
      final bytes = await font.readAsBytes();
      await (FontLoader(
        'Roboto',
      )..addFont(Future.value(ByteData.sublistView(bytes)))).load();
    }
  });
  for (final size in [
    const Size(390, 844),
    const Size(360, 800),
    const Size(1080, 844),
  ]) {
    for (final scale in size.width == 360 ? [2.0] : [1.0]) {
      testWidgets('three pages at ${size.width} with text scale $scale', (
        tester,
      ) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        tester.platformDispatcher.textScaleFactorTestValue = scale;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        final ctrl = MonitorController(demo: true);
        await ctrl.initialize();
        await ctrl.setSkin(AppSkin.daylight);
        addTearDown(ctrl.dispose);
        final key = GlobalKey();
        await tester.pumpWidget(
          RepaintBoundary(
            key: key,
            child: ChangeNotifierProvider.value(
              value: ctrl,
              child: const SlurmMonitorApp(),
            ),
          ),
        );
        await tester.pumpAndSettle();
        Future<void> capture(String name) async {
          expect(tester.takeException(), isNull);
          final root = Platform.environment['SLURM_SCREENSHOTS'];
          if (root == null) return;
          await tester.runAsync(() async {
            final boundary =
                key.currentContext!.findRenderObject()!
                    as RenderRepaintBoundary;
            final image = await boundary.toImage(
              pixelRatio: size.width < 500 ? 2 : 1,
            );
            final data = await image.toByteData(format: ui.ImageByteFormat.png);
            final file = File('$root/$name-${size.width.toInt()}-x$scale.png');
            await file.parent.create(recursive: true);
            await file.writeAsBytes(data!.buffer.asUint8List());
            image.dispose();
          });
        }

        await capture('dashboard');
        for (final tab in ['节点空闲', '服务器']) {
          await tester.tap(find.text(tab).last);
          await tester.pumpAndSettle();
          await capture(tab == '节点空闲' ? 'resources' : 'connections');
        }
        await tester.tap(find.text('我的作业').last);
        await tester.pumpAndSettle();
        await ctrl.setSkin(AppSkin.ocean);
        await tester.pumpAndSettle();
        await capture('dashboard-dark');
      });
    }
  }
}
