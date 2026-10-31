import 'package:flutter_test/flutter_test.dart';
import 'package:slurm_cluster_monitor/models/structure.dart';
import 'package:slurm_cluster_monitor/services/structure_parser.dart';
import 'package:slurm_cluster_monitor/services/remote_files.dart';

void main() {
  test('VASP direct coordinates, selective dynamics and CONTCAR', () {
    final s = parseStructure((
      'CONTCAR',
      '''silicon
2
1 0 0
0 2 0
0 0 3
Si H
1 1
Selective dynamics
Direct
.5 .5 .5 T F T
0 0 0 F F F
''',
    ));
    expect(s.cell!.map((v) => v.length), [2, 4, 6]);
    expect(s.atoms.first.element, 'Si');
    expect(s.atoms.first.position.x, 1);
    expect(s.atoms.first.position.y, 2);
    expect(s.atoms.first.position.z, 3);
    expect(s.composition, {'Si': 1, 'H': 1});
    expect(s.atoms.first.fixedAxes, 2);
    expect(s.atoms.first.isFullyFixed, isFalse);
    expect(s.atoms.last.isFullyFixed, isTrue);
  });
  test(
    'Selective dynamics preserves all flag combinations in Direct and Cartesian',
    () {
      for (final mode in ['Direct', 'Cartesian']) {
        final rows = [
          for (var mask = 0; mask < 8; mask++)
            '.1 .2 .3 ${[for (var axis = 0; axis < 3; axis++) mask & (1 << axis) == 0 ? 'T' : 'F'].join(' ')}',
        ];
        final s = parseStructure((
          'POSCAR',
          '''C
1
5 0 0
0 5 0
0 0 5
C
8
Selective dynamics
$mode
${rows.join('\n')}
''',
        ));
        expect(s.atoms.map((a) => a.fixedAxes), List.generate(8, (i) => i));
        expect(s.atoms.where((a) => a.isFullyFixed), hasLength(1));
        expect(s.atoms.where((a) => a.isConstrained), hasLength(7));
      }
    },
  );
  test(
    'only an enabled Selective dynamics section applies flags; invalid flags fail explicitly',
    () {
      const header = 'C\n1\n5 0 0\n0 5 0\n0 0 5\nC\n1\n';
      expect(
        parseStructure((
          'CONTCAR',
          '${header}Direct\n0 0 0 F F F\n',
        )).atoms.single.fixedAxes,
        0,
      );
      expect(
        parseStructure((
          'CONTCAR',
          '${header}selective dynamics\nCartesian\n0 0 0 f .TRUE. .FALSE.\n',
        )).atoms.single.fixedAxes,
        5,
      );
      expect(
        () => parseStructure((
          'POSCAR',
          '${header}Selective dynamics\nDirect\n0 0 0\n',
        )),
        throwsFormatException,
      );
      expect(
        () => parseStructure((
          'POSCAR',
          '${header}Selective dynamics\nDirect\n0 0 0 T unknown F\n',
        )),
        throwsFormatException,
      );
    },
  );
  test('VASP negative volume, Cartesian scaling and three scale factors', () {
    String poscar(String scale) =>
        '''H
$scale
1 0 0
0 1 0
0 0 1
1
Cartesian
.5 .25 .125
''';
    final negative = parseStructure(('POSCAR', poscar('-8')));
    expect(negative.atoms.single.element, 'H');
    expect(negative.cell!.first.length, closeTo(2, 1e-9));
    expect(negative.atoms.single.position.z, closeTo(.25, 1e-9));
    final triple = parseStructure(('input.vasp', poscar('2 4 8')));
    expect(triple.atoms.single.position.x, 1);
    expect(triple.atoms.single.position.y, 1);
    expect(triple.atoms.single.position.z, 1);
  });
  test('Gaussian Cartesian, atomic numbers, freeze flags and Bohr units', () {
    final s = parseStructure((
      'test.gjf',
      '''# HF/3-21G units=bohr

water

0 1
8 0 0 0
H -1 1.0 0.0 0.0
H 0 -1.0 0.0 0.0

''',
    ));
    expect(s.atoms.map((a) => a.element), ['O', 'H', 'H']);
    expect(s.atoms[1].position.x, closeTo(.529177210903, 1e-10));
    expect(s.atoms[2].position.x, closeTo(-.529177210903, 1e-10));
    expect(
      parseStructure(('water.com', demoFiles['water.gjf']!)).atoms,
      hasLength(3),
    );
  });
  test(
    'Gaussian Z matrix fails explicitly instead of drawing incorrect atoms',
    () {
      expect(
        () => parseStructure((
          'zmat.gjf',
          '''# HF/STO-3G

water

0 1
O
H 1 R
H 1 R 2 A

R=0.96
A=104.5
''',
        )),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('Z 矩阵'),
          ),
        ),
      );
    },
  );
  test(
    'CIF quoted loop values, uncertainty, multiline fields and symmetry expansion',
    () {
      final s = parseStructure((
        'crystal.cif',
        '''data_test
_chemical_name_common
;two line
name
;
_cell_length_a 10.0(2)
_cell_length_b 10
_cell_length_c 10
_cell_angle_alpha 90
_cell_angle_beta 90
_cell_angle_gamma 90
loop_
_space_group_symop.operation_xyz
'x,y,z'
'-x+1/2, -y, -z'
loop_
_atom_site_label
_atom_site_type_symbol
_atom_site_fract_x
_atom_site_fract_y
_atom_site_fract_z
C1 C .1 .2 .3
O1 O .25 0 0
data_ignored
_cell_length_a 99
''',
      ));
      expect(
        s.atoms,
        hasLength(3),
      ); // O lies on this operation's special position.
      expect(s.cell!.first.length, 10);
      expect(s.atoms[1].position.x, closeTo(4, 1e-9));
      expect(s.atoms[1].position.y, closeTo(8, 1e-9));
      expect(s.atoms[1].position.z, closeTo(7, 1e-9));
    },
  );
  test('CIF without symmetry reports that only file sites are shown', () {
    final noSymmetry = demoFiles['silicon.cif']!.replaceAll(
      "loop_\n_space_group_symop_operation_xyz\n'x,y,z'\n'-x,-y,-z'\n",
      '',
    );
    final s = parseStructure(('silicon.cif', noSymmetry));
    expect(s.atoms, hasLength(1));
    expect(s.notes.single, contains('仅显示'));
  });
  test(
    'invalid or unsupported structures do not produce fabricated previews',
    () {
      expect(() => parseStructure(('POSCAR', 'bad')), throwsFormatException);
      expect(
        () => parseStructure(('test.xyz', '5001\nlarge\n')),
        throwsFormatException,
      );
      expect(
        () => parseStructure(('test.cif', "data_x\nloop_\n_a\n_b\n1\n")),
        throwsFormatException,
      );
      expect(
        () => parseStructure(('test.txt', 'plain text')),
        throwsFormatException,
      );
      final xyz = parseStructure(('test.xyz', '2\nCO\nC 0 0 0\nO 1.2 0 0\n'));
      expect(xyz.atoms.last.position.x, 1.2);
      expect(StructureFormat.detect('POSCAR.initial'), StructureFormat.poscar);
    },
  );
}
