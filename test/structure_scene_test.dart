import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slurm_cluster_monitor/models/structure.dart';
import 'package:slurm_cluster_monitor/services/structure_scene.dart';
import 'package:slurm_cluster_monitor/ui/structure_view.dart';

const cube = AtomicStructure(
  title: 'cube',
  atoms: [StructureAtom('C', Vec3(0, 0, 0))],
  cell: [Vec3(4, 0, 0), Vec3(0, 4, 0), Vec3(0, 0, 4)],
);

void main() {
  test(
    'constraint metadata survives all cell modes and periodic-image generation',
    () {
      final structure = AtomicStructure(
        title: 'fixed',
        cell: cube.cell,
        atoms: const [
          StructureAtom('C', Vec3(0, 0, 0), fixedAxes: 7),
          StructureAtom('C', Vec3(2, 2, 2), fixedAxes: 2),
          StructureAtom('C', Vec3(1, 1, 1)),
        ],
      );
      for (final mode in CellDisplayMode.values) {
        final scene = buildStructureScene((structure, CellDisplay(mode: mode)));
        expect(scene.atoms.any((a) => a.isFullyFixed), isTrue);
        expect(scene.atoms.any((a) => a.fixedAxes == 2), isTrue);
        expect(scene.atoms.any((a) => a.fixedAxes == 0), isTrue);
        if (mode == CellDisplayMode.boundary ||
            mode == CellDisplayMode.supercell) {
          expect(
            scene.atoms.where((a) => a.periodicImage && a.isFullyFixed),
            isNotEmpty,
          );
        }
      }
      expect(structure.atoms.first.fixedAxes, 7);
    },
  );
  test(
    'wrapping does not discard coincident sites with different constraints',
    () {
      final structure = AtomicStructure(
        title: 'overlap',
        cell: cube.cell,
        atoms: const [
          StructureAtom('C', Vec3(0, 0, 0), fixedAxes: 7),
          StructureAtom('C', Vec3(4, 0, 0)),
        ],
      );
      final scene = buildStructureScene((
        structure,
        const CellDisplay(mode: CellDisplayMode.inside),
      ));
      expect(scene.atoms.map((a) => a.fixedAxes), [7, 0]);
    },
  );
  test(
    'original, boundary completion and supercell keep physical data intact',
    () {
      expect(
        buildStructureScene((cube, const CellDisplay())).atoms,
        hasLength(1),
      );
      final boundary = buildStructureScene((
        cube,
        const CellDisplay(mode: CellDisplayMode.boundary),
      ));
      expect(boundary.atoms, hasLength(8));
      expect(boundary.atoms.where((a) => a.periodicImage), hasLength(7));
      final supercell = buildStructureScene((
        cube,
        const CellDisplay(mode: CellDisplayMode.supercell, boundaries: false),
      ));
      expect(supercell.atoms, hasLength(8));
      expect(supercell.cells, hasLength(8));
      expect(supercell.cells.last.last.x, 8);
      expect(
        buildStructureScene((
          cube,
          const CellDisplay(mode: CellDisplayMode.supercell),
        )).atoms,
        hasLength(27),
      );
      expect(cube.atoms, hasLength(1));
      expect(cube.cell!.first.length, 4);
    },
  );
  test(
    'skew cell wraps fractional coordinates and deduplicates periodic copies',
    () {
      const cell = [Vec3(2, 0, 0), Vec3(1, 2, 0), Vec3(.5, .2, 3)];
      Vec3 cart(double x, double y, double z) =>
          cell[0] * x + cell[1] * y + cell[2] * z;
      final structure = AtomicStructure(
        title: 'skew',
        cell: cell,
        atoms: [
          StructureAtom('Si', cart(1.25, -.25, .5)),
          StructureAtom('Si', cart(.25, .75, .5)),
        ],
      );
      final scene = buildStructureScene((
        structure,
        const CellDisplay(mode: CellDisplayMode.inside),
      ));
      expect(scene.atoms, hasLength(1));
      expect(
        (scene.atoms.single.position - cart(.25, .75, .5)).length,
        lessThan(1e-8),
      );
      expect(structure.atoms, hasLength(2));
    },
  );
  test('boundary display includes the adjacent image of atoms near a face', () {
    final structure = AtomicStructure(
      title: 'edge',
      cell: cube.cell,
      atoms: const [StructureAtom('C', Vec3(3.8, 2, 2))],
    );
    final scene = buildStructureScene((
      structure,
      const CellDisplay(mode: CellDisplayMode.boundary),
    ));
    expect(scene.atoms, hasLength(2));
    expect(scene.atoms.first.position.x, closeTo(-.2, 1e-8));
    expect(scene.atoms.last.position.x, closeTo(3.8, 1e-8));
  });
  test(
    'camera aligns with lattice vectors and plane normals for skew cells',
    () {
      const cell = [Vec3(2, 0, 0), Vec3(1, 2, 0), Vec3(.5, .2, 3)];
      final alongB = structureCamera(StructureViewpoint.b, cell);
      final p = alongB.project(cell[1]);
      expect(p.x.abs(), lessThan(1e-8));
      expect(p.y.abs(), lessThan(1e-8));
      final ab = structureCamera(StructureViewpoint.ab, cell);
      expect(ab.forward.dot(cell[0]).abs(), lessThan(1e-8));
      expect(ab.forward.dot(cell[1]).abs(), lessThan(1e-8));
      for (final view in StructureViewpoint.values) {
        final camera = structureCamera(view, cell);
        expect(camera.right.length, closeTo(1, 1e-8));
        expect(camera.up.dot(camera.forward).abs(), lessThan(1e-8));
      }
    },
  );
  test('large display and invalid repeats are rejected before rendering', () {
    final many = AtomicStructure(
      title: 'many',
      cell: cube.cell,
      atoms: [
        for (var i = 0; i < 250; i++) StructureAtom('C', Vec3(i / 100, 1, 1)),
      ],
    );
    expect(
      () => buildStructureScene((
        many,
        const CellDisplay(
          mode: CellDisplayMode.supercell,
          nx: 4,
          ny: 4,
          nz: 4,
          boundaries: false,
        ),
      )),
      throwsFormatException,
    );
    expect(
      () => buildStructureScene((
        cube,
        const CellDisplay(mode: CellDisplayMode.supercell, nx: 0),
      )),
      throwsFormatException,
    );
  });
  testWidgets(
    'view presets and boundary display are usable on a small screen',
    (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      tester.view.viewPadding = const FakeViewPadding(bottom: 48);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetViewPadding);
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: SafeArea(child: StructureView(structure: cube)),
          ),
        ),
      );
      await tester.tap(find.byTooltip('切换视角'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('沿 c'));
      await tester.pumpAndSettle();
      expect(find.text('沿 c'), findsOneWidget);
      await tester.tap(find.byTooltip('晶胞显示'));
      await tester.pumpAndSettle();
      expect(tester.getBottomRight(find.text('应用显示')).dy, lessThan(752));
      await tester.tap(find.text('边界补全'));
      await tester.tap(find.text('应用显示'));
      await tester.pump();
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 300));
      });
      await tester.pumpAndSettle();
      expect(find.text('显示 8'), findsOneWidget);
      expect(find.text('边界补全'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
