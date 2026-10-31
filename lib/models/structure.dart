import 'dart:math' as math;

class Vec3 {
  const Vec3(this.x, this.y, this.z);
  final double x, y, z;
  Vec3 operator +(Vec3 v) => Vec3(x + v.x, y + v.y, z + v.z);
  Vec3 operator -(Vec3 v) => Vec3(x - v.x, y - v.y, z - v.z);
  Vec3 operator *(double s) => Vec3(x * s, y * s, z * s);
  double get length => math.sqrt(x * x + y * y + z * z);
  double dot(Vec3 v) => x * v.x + y * v.y + z * v.z;
  Vec3 cross(Vec3 v) =>
      Vec3(y * v.z - z * v.y, z * v.x - x * v.z, x * v.y - y * v.x);
}

class StructureAtom {
  const StructureAtom(
    this.element,
    this.position, {
    this.periodicImage = false,
    this.fixedAxes = 0,
    this.sourceIndex,
  }) : assert(fixedAxes >= 0 && fixedAxes <= 7);
  final String element;
  final Vec3 position;
  final bool periodicImage;

  /// Selective dynamics F flags, bits 0/1/2 for lattice a/b/c directions.
  final int fixedAxes;
  final int? sourceIndex;
  bool get isConstrained => fixedAxes != 0;
  bool get isFullyFixed => fixedAxes == 7;
  StructureAtom withIndex(int index) => StructureAtom(
    element,
    position,
    periodicImage: periodicImage,
    fixedAxes: fixedAxes,
    sourceIndex: sourceIndex ?? index,
  );
}

class AtomicStructure {
  const AtomicStructure({
    required this.title,
    required this.atoms,
    this.cell,
    this.notes = const [],
  });
  final String title;
  final List<StructureAtom> atoms;
  final List<Vec3>? cell;
  final List<String> notes;
  Map<String, int> get composition {
    final counts = <String, int>{};
    for (final atom in atoms) {
      counts.update(atom.element, (n) => n + 1, ifAbsent: () => 1);
    }
    return counts;
  }
}

const elementSymbols = <String>[
  'X',
  'H',
  'He',
  'Li',
  'Be',
  'B',
  'C',
  'N',
  'O',
  'F',
  'Ne',
  'Na',
  'Mg',
  'Al',
  'Si',
  'P',
  'S',
  'Cl',
  'Ar',
  'K',
  'Ca',
  'Sc',
  'Ti',
  'V',
  'Cr',
  'Mn',
  'Fe',
  'Co',
  'Ni',
  'Cu',
  'Zn',
  'Ga',
  'Ge',
  'As',
  'Se',
  'Br',
  'Kr',
  'Rb',
  'Sr',
  'Y',
  'Zr',
  'Nb',
  'Mo',
  'Tc',
  'Ru',
  'Rh',
  'Pd',
  'Ag',
  'Cd',
  'In',
  'Sn',
  'Sb',
  'Te',
  'I',
  'Xe',
  'Cs',
  'Ba',
  'La',
  'Ce',
  'Pr',
  'Nd',
  'Pm',
  'Sm',
  'Eu',
  'Gd',
  'Tb',
  'Dy',
  'Ho',
  'Er',
  'Tm',
  'Yb',
  'Lu',
  'Hf',
  'Ta',
  'W',
  'Re',
  'Os',
  'Ir',
  'Pt',
  'Au',
  'Hg',
  'Tl',
  'Pb',
  'Bi',
  'Po',
  'At',
  'Rn',
  'Fr',
  'Ra',
  'Ac',
  'Th',
  'Pa',
  'U',
  'Np',
  'Pu',
  'Am',
  'Cm',
  'Bk',
  'Cf',
  'Es',
  'Fm',
  'Md',
  'No',
  'Lr',
  'Rf',
  'Db',
  'Sg',
  'Bh',
  'Hs',
  'Mt',
  'Ds',
  'Rg',
  'Cn',
  'Nh',
  'Fl',
  'Mc',
  'Lv',
  'Ts',
  'Og',
];

enum StructureFormat {
  poscar,
  gaussian,
  cif,
  xyz;

  static StructureFormat? detect(String name) {
    final lower = name.toLowerCase();
    if (lower.startsWith('poscar') ||
        lower.startsWith('contcar') ||
        lower.endsWith('.vasp')) {
      return poscar;
    }
    if (lower.endsWith('.gjf') || lower.endsWith('.com')) return gaussian;
    if (lower.endsWith('.cif')) return cif;
    if (lower.endsWith('.xyz')) return xyz;
    return null;
  }
}
