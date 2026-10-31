import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:slurm_cluster_monitor/services/optimization_analysis.dart';
import 'package:slurm_cluster_monitor/services/optimization_check_service.dart';
import 'package:slurm_cluster_monitor/services/remote_files.dart';
import 'gaussian_progress_test.dart' show gaussianStep, gaussianOrientation;

class TreeFiles extends RemoteFiles {
  final listings = <String, RemoteDirectory>{};
  final contents = <String, String>{};
  final reads = <String>[], listed = <String>[];
  @override
  Future<RemoteDirectory> list(String path) async {
    listed.add(path);
    return listings[path] ??
        (throw const FormatException('unreadable directory'));
  }

  @override
  Future<bool> isDirectory(String path) async => listings.containsKey(path);
  @override
  Future<RemoteText> read(String path, {bool tail = false}) async {
    reads.add('$tail:$path');
    final text = contents[path];
    if (text == null) throw const FormatException('unreadable file');
    return RemoteText(text, size: utf8.encode(text).length, tail: tail);
  }

  @override
  void close() {}
}

void main() {
  final now = DateTime.utc(2026, 10, 28, 10);
  void addVasp(
    TreeFiles files,
    String path,
    DateTime? time, {
    bool done = false,
    int mode = 2,
    DateTime? oszicarTime,
  }) {
    final energies = [
      for (var i = 1; i <= 12; i++) ' $i F= -10 E0= ${i.isEven ? -10 : -9}',
    ].join('\n');
    files.listings[path] = RemoteDirectory([
      RemoteEntry('OUTCAR', size: 100, modified: time),
      RemoteEntry('OSZICAR', size: 300, modified: oszicarTime ?? time),
    ]);
    files.contents['$path/OUTCAR'] =
        'vasp.6.3\nIBRION = $mode\n${done ? 'General timing and accounting information' : ''}';
    files.contents['$path/OSZICAR'] = energies;
  }

  test(
    'serial scripts select the latest OUTCAR and reuse unchanged log bytes',
    () async {
      final files = TreeFiles();
      files.listings['/batch'] = const RemoteDirectory([
        RemoteEntry('old', directory: true),
        RemoteEntry('current', directory: true),
        RemoteEntry('previous', directory: true),
        RemoteEntry('cycle', directory: true, link: true),
      ]);
      addVasp(files, '/batch/old', now.subtract(const Duration(hours: 2)));
      addVasp(
        files,
        '/batch/previous',
        now.subtract(const Duration(minutes: 10)),
        done: true,
      );
      addVasp(files, '/batch/current', now);
      final service = OptimizationCheckService(files);
      final result = await service.check('/batch');
      expect(result.path, '/batch/current/OUTCAR');
      expect(result.assessment!.state, OptimizationState.oscillating);
      expect(files.reads.every((p) => p.contains('/current/')), isTrue);
      final count = files.reads.length;
      await service.check('/batch');
      expect(files.reads.length, count);
    },
  );
  test(
    'latest completed OUTCAR stays visible without selecting old unfinished files',
    () async {
      final files = TreeFiles();
      files.listings['/batch'] = const RemoteDirectory([
        RemoteEntry('old', directory: true),
        RemoteEntry('finished', directory: true),
      ]);
      addVasp(files, '/batch/old', now.subtract(const Duration(minutes: 10)));
      addVasp(files, '/batch/finished', now, done: true);
      final result = await OptimizationCheckService(files).check('/batch');
      expect(result.path, '/batch/finished/OUTCAR');
      expect(result.assessment!.state, OptimizationState.ended);
      expect(result.message, contains('本轮计算已结束'));
    },
  );
  test('OUTCAR mtime wins over a newer unrelated OSZICAR or log', () async {
    final files = TreeFiles();
    files.listings['/batch'] = RemoteDirectory([
      const RemoteEntry('a', directory: true),
      const RemoteEntry('b', directory: true),
      RemoteEntry('unreadable.log', size: 10, modified: now),
    ]);
    addVasp(
      files,
      '/batch/a',
      now.subtract(const Duration(hours: 2)),
      oszicarTime: now,
    );
    addVasp(files, '/batch/b', now.subtract(const Duration(minutes: 10)));
    final result = await OptimizationCheckService(files).check('/batch');
    expect(result.path, '/batch/b/OUTCAR');
    expect(result.modified, now.subtract(const Duration(minutes: 10)));
    expect(files.reads.any((p) => p.endsWith('unreadable.log')), isFalse);
  });
  test(
    'equal times resolve deterministically and old logs are still analyzed',
    () async {
      final files = TreeFiles();
      files.listings['/batch'] = const RemoteDirectory([
        RemoteEntry('b', directory: true),
        RemoteEntry('a', directory: true),
      ]);
      addVasp(files, '/batch/a', now.subtract(const Duration(days: 2)));
      addVasp(files, '/batch/b', now.subtract(const Duration(days: 2)));
      final result = await OptimizationCheckService(files).check('/batch');
      expect(result.path, '/batch/a/OUTCAR');
      expect(result.assessment!.state, OptimizationState.oscillating);
    },
  );
  test(
    'all subdirectories are searched beyond 48 folders and depth 3',
    () async {
      final files = TreeFiles();
      files.listings['/batch'] = RemoteDirectory([
        for (var i = 0; i < 80; i++) RemoteEntry('calc-$i', directory: true),
      ]);
      for (var i = 0; i < 79; i++) {
        addVasp(files, '/batch/calc-$i', now.subtract(Duration(hours: i + 1)));
      }
      var path = '/batch/calc-79';
      for (var i = 0; i < 10; i++) {
        files.listings[path] = const RemoteDirectory([
          RemoteEntry('relax', directory: true),
        ]);
        path += '/relax';
      }
      addVasp(files, path, now);
      final result = await OptimizationCheckService(files).check('/batch');
      expect(result.path, '$path/OUTCAR');
      expect(result.searchComplete, isTrue);
      expect(files.listed.length, greaterThan(80));
    },
  );
  test(
    'partial or unreadable directories retain the best OUTCAR with a warning',
    () async {
      final files = TreeFiles();
      addVasp(files, '/batch', now);
      files.listings['/batch'] = RemoteDirectory([
        ...files.listings['/batch']!.entries,
        const RemoteEntry('denied', directory: true),
      ], truncated: true);
      final result = await OptimizationCheckService(files).check('/batch');
      expect(result.path, '/batch/OUTCAR');
      expect(result.searchComplete, isFalse);
      expect(result.warnings, isNotEmpty);
    },
  );
  test(
    'unknown timestamps and unreadable selected logs do not hide the file',
    () async {
      final files = TreeFiles();
      addVasp(files, '/batch', null);
      files.contents.remove('/batch/OUTCAR');
      final result = await OptimizationCheckService(files).check('/batch');
      expect(result.path, '/batch/OUTCAR');
      expect(result.modified, isNull);
      expect(result.assessment, isNull);
      expect(result.message, contains('修改时间未知'));
    },
  );
  test(
    'Gaussian fallback and ordinary Slurm logs keep their previous behavior',
    () async {
      final files = TreeFiles();
      files.listings['/batch'] = RemoteDirectory([
        RemoteEntry('water.log', size: 100, modified: now),
        RemoteEntry('slurm-42.out', size: 100, modified: now),
      ]);
      files.contents['/batch/water.log'] = '$gaussianOrientation$gaussianStep';
      files.contents['/batch/slurm-42.out'] = 'job running';
      final result = await OptimizationCheckService(files).check('/batch');
      expect(result.kind, CalculationKind.gaussian);
      expect(result.path, '/batch/water.log');
    },
  );
  test(
    'MD and cancellation never produce a false optimization alarm',
    () async {
      final files = TreeFiles();
      addVasp(files, '/batch', now, mode: 0);
      final service = OptimizationCheckService(files);
      expect(
        (await service.check('/batch')).assessment!.state,
        OptimizationState.insufficient,
      );
      await expectLater(
        service.check('/batch', cancelled: () => true),
        throwsA(isA<FileReadCancelled>()),
      );
    },
  );
}
