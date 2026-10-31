import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slurm_cluster_monitor/models/structure.dart';
import 'package:slurm_cluster_monitor/services/structure_scene.dart';
import 'package:slurm_cluster_monitor/ui/atom_labels.dart';
import 'package:slurm_cluster_monitor/ui/jmol_colors.dart';
import 'package:slurm_cluster_monitor/ui/structure_view.dart';

void main() {
  const s = AtomicStructure(
    title: 'labels',
    atoms: [
      StructureAtom('Si', Vec3(0, 0, 0)),
      StructureAtom('O', Vec3(1, 1, 1)),
    ],
    cell: [Vec3(4, 0, 0), Vec3(0, 4, 0), Vec3(0, 0, 4)],
  );
  test('periodic copies keep original 1-based atom indices', () {
    for (final mode in CellDisplayMode.values) {
      final scene = buildStructureScene((s, CellDisplay(mode: mode)));
      for (final atom in scene.atoms) {
        expect(atom.sourceIndex, atom.element == 'Si' ? 1 : 2);
      }
      expect(
        atomLabel(scene.atoms.first, AtomLabelMode.elementAndIndex, 99),
        'Si1',
      );
      expect(atomLabel(scene.atoms.first, AtomLabelMode.indexOnly, 99), '1');
      expect(atomLabel(scene.atoms.first, AtomLabelMode.off, 99), '');
    }
  });
  test('Jmol colors match the published defaults for common elements', () {
    expect(jmolColor('C'), const Color(0xFF909090));
    expect(jmolColor('H'), Colors.white);
    expect(jmolColor('O'), const Color(0xFFFF0D0D));
    expect(jmolColor('Si'), const Color(0xFFF0C8A0));
  });
  testWidgets('label switch offers off, element plus index, and index only', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: StructureView(structure: s)),
      ),
    );
    await tester.tap(find.byTooltip('原子标签'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('元素+序号'));
    await tester.pumpAndSettle();
    expect(find.text('元素+序号'), findsOneWidget);
    await tester.tap(find.byTooltip('原子标签'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('仅序号'));
    await tester.pumpAndSettle();
    expect(find.text('仅序号'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  test(
    'painted labels stay on the atom across zoom levels and long indices',
    () async {
      for (final radius in [3.0, 16.0, 50.0]) {
        final recorder = ui.PictureRecorder();
        drawAtomLabel(
          Canvas(recorder),
          const Offset(64, 64),
          radius,
          'Si12000',
          jmolColor('Si'),
        );
        final picture = recorder.endRecording();
        final image = await picture.toImage(128, 128);
        final data = (await image.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        ))!;
        var pixels = 0;
        for (var y = 0; y < 128; y++) {
          for (var x = 0; x < 128; x++) {
            if (data.getUint8((y * 128 + x) * 4 + 3) == 0) continue;
            pixels++;
            expect(
              (Offset(x + .5, y + .5) - const Offset(64, 64)).distance,
              lessThanOrEqualTo(radius + 1.5),
            );
          }
        }
        expect(pixels, greaterThan(0));
        image.dispose();
        picture.dispose();
      }
    },
  );
}
