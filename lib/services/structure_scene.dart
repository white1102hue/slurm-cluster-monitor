import 'dart:math' as math;
import '../models/structure.dart';

enum StructureViewpoint {
  isometric('等轴'),
  x('沿 X'),
  y('沿 Y'),
  z('沿 Z'),
  a('沿 a'),
  b('沿 b'),
  c('沿 c'),
  ab('正对 ab 面'),
  ac('正对 ac 面'),
  bc('正对 bc 面');

  const StructureViewpoint(this.label);
  final String label;
}

class CameraFrame {
  const CameraFrame(this.right, this.up, this.forward);
  final Vec3 right, up, forward;
  Vec3 project(Vec3 p) => Vec3(p.dot(right), p.dot(up), p.dot(forward));
}

Vec3 _unit(Vec3 p) {
  if (p.length < 1e-12) throw const FormatException('晶胞方向无效');
  return p * (1 / p.length);
}

CameraFrame structureCamera(StructureViewpoint view, List<Vec3>? cell) {
  final a = cell?[0] ?? const Vec3(1, 0, 0),
      b = cell?[1] ?? const Vec3(0, 1, 0),
      c = cell?[2] ?? const Vec3(0, 0, 1);
  final (direction, reference) = switch (view) {
    StructureViewpoint.isometric => (const Vec3(1, 1, 1), const Vec3(0, 0, 1)),
    StructureViewpoint.x => (const Vec3(1, 0, 0), const Vec3(0, 0, 1)),
    StructureViewpoint.y => (const Vec3(0, 1, 0), const Vec3(0, 0, 1)),
    StructureViewpoint.z => (const Vec3(0, 0, 1), const Vec3(0, 1, 0)),
    StructureViewpoint.a => (a, c),
    StructureViewpoint.b => (b, c),
    StructureViewpoint.c => (c, b),
    StructureViewpoint.ab => (a.cross(b), b),
    StructureViewpoint.ac => (a.cross(c), c),
    StructureViewpoint.bc => (b.cross(c), c),
  };
  final forward = _unit(direction);
  var right = reference.cross(forward);
  if (right.length < 1e-9) right = const Vec3(0, 1, 0).cross(forward);
  right = _unit(right);
  return CameraFrame(right, _unit(forward.cross(right)), forward);
}

enum CellDisplayMode { original, inside, boundary, supercell }

class CellDisplay {
  const CellDisplay({
    this.mode = CellDisplayMode.original,
    this.nx = 2,
    this.ny = 2,
    this.nz = 2,
    this.boundaries = true,
  });
  final CellDisplayMode mode;
  final int nx, ny, nz;
  final bool boundaries;
  String get label => switch (mode) {
    CellDisplayMode.original => '原始晶胞',
    CellDisplayMode.inside => '胞内原子',
    CellDisplayMode.boundary => '边界补全',
    CellDisplayMode.supercell => '$nx×$ny×$nz 超胞',
  };
}

class StructureScene {
  StructureScene(this.atoms, this.cells, this.links, {this.note}) {
    final points = [...atoms.map((a) => a.position), ...cells.expand((c) => c)];
    if (points.isEmpty) {
      center = const Vec3(0, 0, 0);
      span = 2;
      return;
    }
    var low = points.first, high = points.first;
    for (final p in points) {
      low = Vec3(
        math.min(low.x, p.x),
        math.min(low.y, p.y),
        math.min(low.z, p.z),
      );
      high = Vec3(
        math.max(high.x, p.x),
        math.max(high.y, p.y),
        math.max(high.z, p.z),
      );
    }
    center = (low + high) * .5;
    span = math.max((high - low).length, 2.0);
  }
  late final Vec3 center;
  late final double span;
  final List<StructureAtom> atoms;

  /// Each cell's eight corners, ordered by the three index bits.
  final List<List<Vec3>> cells;
  final List<(int, int)> links;
  final String? note;
}

/// Creates display copies only. Original coordinates/cell and file are retained.
StructureScene buildStructureScene((AtomicStructure, CellDisplay) args) {
  final (structure, options) = args;
  final atoms = <StructureAtom>[], cells = <List<Vec3>>[];
  final cell = structure.cell;
  var nx = 1, ny = 1, nz = 1;
  if (cell == null || options.mode == CellDisplayMode.original) {
    atoms.addAll([
      for (final (i, atom) in structure.atoms.indexed) atom.withIndex(i + 1),
    ]);
  } else {
    if (options.mode == CellDisplayMode.supercell) {
      nx = options.nx;
      ny = options.ny;
      nz = options.nz;
      if ([nx, ny, nz].any((n) => n < 1 || n > 4)) {
        throw const FormatException('超胞倍数范围为 1–4');
      }
    }
    final volume = cell[0].dot(cell[1].cross(cell[2]));
    if (volume.abs() < 1e-9) throw const FormatException('晶胞体积无效，不能生成周期像');
    Vec3 fractional(Vec3 p) => Vec3(
      p.dot(cell[1].cross(cell[2])) / volume,
      p.dot(cell[2].cross(cell[0])) / volume,
      p.dot(cell[0].cross(cell[1])) / volume,
    );
    double wrap(double v) {
      final f = v - v.floor();
      return f > 1 - 1e-6 || f < 1e-6 ? 0 : f;
    }

    final seen = <String>{};
    final sites = <(StructureAtom, Vec3)>[];
    for (final (index, original) in structure.atoms.indexed) {
      final atom = original.withIndex(index + 1);
      final p = fractional(atom.position),
          f = Vec3(wrap(p.x), wrap(p.y), wrap(p.z));
      final key =
          '${atom.element}:${(f.x * 1e6).round()},${(f.y * 1e6).round()},${(f.z * 1e6).round()}:${atom.fixedAxes}';
      if (seen.add(key)) sites.add((atom, f));
    }
    final boundary =
        options.mode == CellDisplayMode.boundary ||
        options.mode == CellDisplayMode.supercell && options.boundaries;
    final margin = options.mode == CellDisplayMode.boundary ? .1 : 0.0;
    final lo = boundary ? -1 : 0,
        hx = boundary ? nx : nx - 1,
        hy = boundary ? ny : ny - 1,
        hz = boundary ? nz : nz - 1;
    for (final (source, f) in sites) {
      for (var x = lo; x <= hx; x++) {
        for (var y = lo; y <= hy; y++) {
          for (var z = lo; z <= hz; z++) {
            final p = f + Vec3(x.toDouble(), y.toDouble(), z.toDouble());
            if (p.x < -margin - 1e-6 ||
                p.y < -margin - 1e-6 ||
                p.z < -margin - 1e-6 ||
                p.x > nx + margin + 1e-6 ||
                p.y > ny + margin + 1e-6 ||
                p.z > nz + margin + 1e-6) {
              continue;
            }
            atoms.add(
              StructureAtom(
                source.element,
                cell[0] * p.x + cell[1] * p.y + cell[2] * p.z,
                fixedAxes: source.fixedAxes,
                sourceIndex: source.sourceIndex,
                periodicImage:
                    p.x < 0 ||
                    p.y < 0 ||
                    p.z < 0 ||
                    p.x >= nx - 1e-6 ||
                    p.y >= ny - 1e-6 ||
                    p.z >= nz - 1e-6,
              ),
            );
            if (atoms.length > 12000) {
              throw const FormatException('显示原子超过 12000 个，请减小超胞倍数或关闭边界原子');
            }
          }
        }
      }
    }
  }
  if (cell != null) {
    for (var x = 0; x < nx; x++) {
      for (var y = 0; y < ny; y++) {
        for (var z = 0; z < nz; z++) {
          final origin =
              cell[0] * x.toDouble() +
              cell[1] * y.toDouble() +
              cell[2] * z.toDouble();
          cells.add([
            for (var i = 0; i < 8; i++)
              origin +
                  cell[0] * ((i & 1) == 0 ? 0.0 : 1.0) +
                  cell[1] * ((i & 2) == 0 ? 0.0 : 1.0) +
                  cell[2] * ((i & 4) == 0 ? 0.0 : 1.0),
          ]);
        }
      }
    }
  }
  final links = _findBonds(atoms);
  return StructureScene(
    atoms,
    cells,
    links.$1,
    note: links.$2 ? '连线较多，已简化显示' : null,
  );
}

double atomRadius(String e) => switch (e) {
  'H' => .31,
  'C' => .76,
  'N' => .71,
  'O' => .66,
  'F' => .57,
  'Si' => 1.11,
  'P' => 1.07,
  'S' => 1.05,
  'Cl' => 1.02,
  'Fe' => 1.32,
  'Cu' => 1.32,
  'Zn' => 1.22,
  'Zr' => 1.75,
  _ => 1.25,
};

(List<(int, int)>, bool) _findBonds(List<StructureAtom> atoms) {
  final bins = <(int, int, int), List<int>>{}, links = <(int, int)>[];
  var comparisons = 0;
  for (var i = 0; i < atoms.length; i++) {
    final p = atoms[i].position;
    final x = (p.x / 4).floor(), y = (p.y / 4).floor(), z = (p.z / 4).floor();
    for (var dx = -1; dx <= 1; dx++) {
      for (var dy = -1; dy <= 1; dy++) {
        for (var dz = -1; dz <= 1; dz++) {
          for (final j in bins[(x + dx, y + dy, z + dz)] ?? <int>[]) {
            if (++comparisons > 2000000) return (links, true);
            final distance = (p - atoms[j].position).length;
            if (distance > .3 &&
                distance <
                    (atomRadius(atoms[i].element) +
                            atomRadius(atoms[j].element)) *
                        1.18) {
              links.add((i, j));
              if (links.length >= 25000) return (links, true);
            }
          }
        }
      }
    }
    (bins[(x, y, z)] ??= []).add(i);
  }
  return (links, false);
}
