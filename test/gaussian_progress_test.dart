import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:slurm_cluster_monitor/models/gaussian_progress.dart';
import 'package:slurm_cluster_monitor/services/gaussian_parser.dart';
import 'package:slurm_cluster_monitor/services/gaussian_service.dart';
import 'package:slurm_cluster_monitor/services/remote_files.dart';
import 'vasp_progress_test.dart' show MemoryVaspFiles;

const gaussianStep = '''
 SCF Done:  E(RB3LYP) =  -76.123456789 A.U. after 10 cycles
         Item               Value     Threshold  Converged?
 Maximum Force            0.004500     0.000450     NO
 RMS     Force            0.000200     0.000300     YES
 Maximum Displacement     0.018000     0.001800     NO
 RMS     Displacement     0.000120     0.001200     YES
''';
const gaussianOrientation = '''
 Standard orientation:
 ---------------------------------------------------------------------
 Center     Atomic      Atomic             Coordinates (Angstroms)
 Number     Number       Type             X           Y           Z
 ---------------------------------------------------------------------
 1 8 0 0.000000 0.000000 0.100000
 2 1 0 0.758000 0.000000 0.504000
 3 1 0 -0.758000 0.000000 0.504000
 ---------------------------------------------------------------------
''';

void main() {
  test(
    'Gaussian logs retain a complete structure and four native thresholds',
    () {
      final data = parseGaussianText('$gaussianOrientation$gaussianStep');
      expect(data.structure!.atoms.map((a) => a.element), ['O', 'H', 'H']);
      expect(data.structure!.atoms.first.position.z, .1);
      expect(data.structure!.atoms.last.sourceIndex, 3);
      expect(data.steps.single.energy, -76.123456789);
      expect(
        data.steps.single.criteria[GaussianMetric.maximumForce]!.ratio,
        10,
      );
      expect(
        data.steps.single.criteria[GaussianMetric.rmsForce]!.passed,
        isTrue,
      );
      expect(
        data.metric(GaussianMetric.maximumDisplacement).single.value,
        .018,
      );
      expect(data.converged, isFalse);
    },
  );
  test('latest complete orientation survives a half-written new geometry', () {
    final data = parseGaussianText('''$gaussianOrientation
 Input orientation:
 -----
 Center Atomic Atomic Coordinates (Angstroms)
 Number Number Type X Y Z
 -----
 1 6 0 1 2 3
''');
    expect(data.structure!.atoms.length, 3);
    expect(data.warnings, isNotEmpty);
  });
  test(
    'Bohr orientations convert units, dummy centers are skipped and ghosts stay X',
    () {
      final data = parseGaussianText('''
 Input orientation:
 -----
 Center Atomic Atomic Coordinates (Bohr)
 Number Number Type X Y Z
 -----
 1 -1 0 0 0 0
 2 0 0 1 0 0
 3 6 0 0 0 0
 -----
''');
      expect(data.structure!.atoms.map((a) => a.element), ['X', 'C']);
      expect(
        data.structure!.atoms.first.position.x,
        closeTo(.529177210903, 1e-12),
      );
    },
  );
  test(
    'correlated energies use D exponents and missing energies are not carried forward',
    () {
      final data = parseGaussianText(
        gaussianStep.replaceFirst(
              '         Item',
              ' EUMP2 = -7.625D+01\n         Item',
            ) +
            gaussianStep.substring(gaussianStep.indexOf('         Item')),
      );
      expect(data.energies.map((p) => p.value), [-76.25, null]);
    },
  );
  test(
    'invalid criteria and partial tables never become valid zero points',
    () {
      final data = parseGaussianText(
        '${gaussianStep.replaceFirst('0.004500', '********')}'
        '${gaussianStep.replaceFirst('0.001800', '0.000000')}'
        'Item Value Threshold Converged?\nMaximum Force 0.001 0.00045 NO\n',
      );
      expect(data.steps, isEmpty);
      expect(data.warnings, isNotEmpty);
    },
  );
  test(
    'termination, convergence and Link1 boundaries describe the current segment',
    () {
      var data = parseGaussianText(
        '$gaussianStep Optimization completed.\n Normal termination of Gaussian\n',
      );
      expect(data.converged, isTrue);
      expect(data.finished, isTrue);
      data = parseGaussianText(
        '$gaussianStep Optimization completed.\n Normal termination of Gaussian\n'
        ' Link1:  Proceeding to internal job step number 2.\n$gaussianStep',
      );
      expect(data.steps.length, 2);
      expect(data.segmentStart, 1);
      expect(data.finished, isFalse);
      expect(data.converged, isFalse);
      expect(parseGaussianText('Error termination via Lnk1e').failed, isTrue);
    },
  );
  test(
    'streaming handles UTF-8 splits, files beyond 2 MB and cancellation',
    () async {
      final files = MemoryVaspFiles({
        'water.log': '中文\n$gaussianStep$gaussianOrientation',
      });
      final data = await GaussianService(files).load('/work/water.log');
      expect(data.steps.length, 1);
      expect(data.structure!.atoms.length, 3);
      final large = _ChunkedGaussian(
        'header\n${'unrelated output\n' * 150000}$gaussianStep',
      );
      var total = 0;
      final full = await GaussianService(
        large,
      ).load('/work/big.log', onProgress: (read, size) => total = size);
      expect(total, greaterThan(2 * 1024 * 1024));
      expect(full.steps.single.energy, -76.123456789);
      var stop = false;
      await expectLater(
        GaussianService(large).load(
          '/work/big.log',
          cancelled: () => stop,
          onProgress: (_, _) => stop = true,
        ),
        throwsA(isA<FileReadCancelled>()),
      );
    },
  );
}

class _ChunkedGaussian extends RemoteFiles {
  _ChunkedGaussian(this.text);
  final String text;
  @override
  Future<RemoteDirectory> list(String path) async => const RemoteDirectory([]);
  @override
  Future<bool> isDirectory(String path) async => false;
  @override
  Future<RemoteText> read(String path, {bool tail = false}) async =>
      throw UnimplementedError('Use streaming');
  @override
  Stream<List<int>> readChunks(
    String path, {
    void Function(int, int)? onProgress,
    bool Function()? cancelled,
  }) async* {
    final bytes = utf8.encode(text);
    for (var start = 0; start < bytes.length; start += 65536) {
      if (cancelled?.call() == true) throw const FileReadCancelled();
      final end = (start + 65536).clamp(0, bytes.length);
      onProgress?.call(end, bytes.length);
      yield bytes.sublist(start, end);
    }
  }

  @override
  void close() {}
}
