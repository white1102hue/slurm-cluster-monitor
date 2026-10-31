import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:slurm_cluster_monitor/services/remote_files.dart';
import 'package:slurm_cluster_monitor/services/structure_parser.dart';
import 'package:slurm_cluster_monitor/services/vasp_progress_parser.dart';
import 'package:slurm_cluster_monitor/services/vasp_progress_service.dart';

class MemoryVaspFiles extends RemoteFiles {
  MemoryVaspFiles(this.contents);
  final Map<String, String> contents;
  bool failOszicar = false;
  @override
  Future<RemoteDirectory> list(String path) async =>
      RemoteDirectory([for (final name in contents.keys) RemoteEntry(name)]);
  @override
  Future<bool> isDirectory(String path) async => false;
  @override
  Future<RemoteText> read(String path, {bool tail = false}) async {
    final text = contents[remoteName(path)];
    if (text == null) throw const FormatException('missing');
    return RemoteText(text, size: utf8.encode(text).length);
  }

  @override
  Stream<List<int>> readChunks(
    String path, {
    void Function(int, int)? onProgress,
    bool Function()? cancelled,
  }) async* {
    final bytes = utf8.encode((await read(path)).text);
    for (var i = 0; i < bytes.length; i += 7) {
      if (cancelled?.call() == true) throw const FileReadCancelled();
      final end = (i + 7).clamp(0, bytes.length);
      onProgress?.call(end, bytes.length);
      yield bytes.sublist(i, end);
    }
    if (failOszicar && remoteName(path) == 'OSZICAR') {
      throw const FormatException('connection interrupted');
    }
  }

  @override
  void close() {}
}

void main() {
  final references =
      jsonDecode(File('test/fixtures/vasp_reference.json').readAsStringSync())
          as List;
  for (final reference in references.cast<Map>()) {
    test('matches provided Python reader: ${reference['name']}', () {
      final parser = OutcarProgressParser(
        structure: reference['poscar'] == null
            ? null
            : parseStructure(('POSCAR', reference['poscar'] as String)),
      );
      const LineSplitter()
          .convert(reference['outcar'] as String)
          .forEach(parser.addLine);
      final forces = reference['forces'] as List;
      expect(parser.forces.length, forces.length);
      for (var i = 0; i < forces.length; i++) {
        final expected = forces[i] as List, actual = parser.forces[i];
        expect(actual.step, expected[0]);
        expect(
          actual.allowed,
          expected[1] == null
              ? isNull
              : closeTo((expected[1] as num).toDouble(), 1e-12),
        );
        expect(actual.raw, closeTo((expected[2] as num).toDouble(), 1e-12));
      }
      final oszicar = OszicarProgressParser();
      const LineSplitter()
          .convert(reference['oszicar'] as String)
          .forEach(oszicar.addLine);
      expect([
        for (final p in oszicar.energies) [p.step, p.value],
      ], reference['energies']);
      expect(parser.finished, reference['finished']);
      expect(parser.converged, reference['converged']);
    });
  }

  test(
    'streamed service prefers OSZICAR, falls back without splicing partial reads and supports cancellation',
    () async {
      final files = MemoryVaspFiles({
        'POSCAR': references.first['poscar'] as String,
        'OUTCAR':
            '中文注释\n${references.first['outcar']}\nenergy(sigma->0) = -11.0\n',
        'OSZICAR': ' 1 F= -10 E0= -20.0\n 1 F= -11 E0= -21.0\n',
      });
      var data = await VaspProgressService(files).load('/home/u/OUTCAR');
      expect(data.energySource, 'OSZICAR · E0');
      expect(data.energies.map((p) => p.value), [-20, -21]);
      expect(data.forces.single.allowed, 5);
      files.failOszicar = true;
      data = await VaspProgressService(files).load('/home/u/OUTCAR');
      expect(data.energySource, 'OUTCAR · E0');
      expect(data.energies.map((p) => p.value), [-10, -11]);
      files.contents.remove('OSZICAR');
      files.contents.remove('POSCAR');
      data = await VaspProgressService(files).load('/home/u/OUTCAR');
      expect(data.hasAllowedForces, isFalse);
      expect(data.forces.single.raw, closeTo(40.311288741492746, 1e-12));
      var cancelled = false;
      await expectLater(
        VaspProgressService(files).load(
          '/home/u/OUTCAR',
          cancelled: () => cancelled,
          onProgress: (read, total) => cancelled = true,
        ),
        throwsA(isA<FileReadCancelled>()),
      );
    },
  );

  test(
    'invalid or unfinished numbers remain missing and do not become zeros',
    () {
      final parser = OutcarProgressParser();
      for (final line in [
        'energy(sigma->0) = -1.1D+02',
        'energy(sigma->0) = -1.0E+',
        'energy(sigma->0) = ********',
      ]) {
        parser.addLine(line);
      }
      expect(parser.energies.map((p) => p.value), [-110, null, null]);
      expect(isOutcar('OUTCAR'), isTrue);
      expect(isOutcar('outcar'), isTrue);
      expect(isOutcar('OUTCAR.gz'), isFalse);
    },
  );
  test('force constraints are available above the visualization atom limit', () {
    final text =
        'large test\n1\n2 0 0\n0 2 0\n0 0 2\nSi\n5001\nSelective dynamics\nDirect\n${List.filled(5001, '0 0 0 F F F').join('\n')}';
    final constraints = parseVaspForceConstraints(text);
    final parser = OutcarProgressParser(structure: constraints);
    parser.addLine('NIONS = 5001');
    parser.addLine('POSITION TOTAL-FORCE');
    parser.addLine('------');
    for (var i = 0; i < 5001; i++) {
      parser.addLine('0 0 0 3 4 0');
    }
    parser.addLine('------');
    expect(parser.forces.single.allowed, 0);
    expect(parser.forces.single.raw, 5);
  });
}
