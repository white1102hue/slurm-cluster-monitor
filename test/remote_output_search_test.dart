import 'package:flutter_test/flutter_test.dart';
import 'package:slurm_cluster_monitor/models/remote_search.dart';
import 'package:slurm_cluster_monitor/services/remote_output_search.dart';
import 'package:slurm_cluster_monitor/models/server_palette.dart';

void main() {
  test(
    'streamed find metadata handles fractional times and hostile filenames',
    () {
      final rows = OutputSearchAccumulator();
      const old = '100.0001\t10\t/work/old/OUTCAR\x00';
      const latest = '101.123456\t20\t/work/中文 with\tquote\'\nline/OUTCAR\x00';
      for (final code in '$old$latest'.split('')) {
        rows.addFindText(code);
      }
      final result = rows.finish();
      expect(result.outcar!.path, "/work/中文 with\tquote'\nline/OUTCAR");
      expect(result.outcar!.modified!.microsecondsSinceEpoch, 101123456);
      expect(result.matched, 2);
      expect(result.complete, isTrue);
    },
  );
  test(
    'large searches keep the latest OUTCAR with bounded Gaussian memory',
    () {
      final rows = OutputSearchAccumulator();
      for (var i = 0; i < 10000; i++) {
        rows.addFindText(
          '$i.1\t10\t/work/$i/OUTCAR\x00$i.2\t20\t/work/$i/a.log\x00',
        );
      }
      final result = rows.finish();
      expect(result.outcar!.path, '/work/9999/OUTCAR');
      expect(result.gaussian.length, 12);
      expect(result.matched, 20000);
      expect(result.complete, isTrue);
    },
  );
  test('malformed metadata is reported while valid matches survive', () {
    final rows = OutputSearchAccumulator();
    rows.addFindText(
      'NaN\t0\t/no/OUTCAR\x00'
      '10\t20\t/work/OUTCAR\x00unfinished',
    );
    expect(rows.finish().complete, isFalse);
    expect(rows.finish().outcar!.path, '/work/OUTCAR');
  });
  test('directory quoting preserves literal shell special characters', () {
    final command = outputSearchCommand("/work/a 'quoted' \$(touch BAD)\nnext");
    expect(command, contains('SLURM_OUTPUT_SEARCH_V2'));
    expect(command, contains('-printf'));
    expect(command, isNot(contains('-maxdepth')));
    expect(() => outputSearchCommand('relative'), throwsFormatException);
    expect(() => outputSearchCommand('/bad\x00path'), throwsFormatException);
  });
  test(
    'colliding server hashes resolve consistently across filters and restarts',
    () {
      expect(serverColorValue('a'), serverColorValue('i'));
      final colors = buildServerColors(['a', 'i', 'q', 'y']);
      expect(colors.values.toSet().length, 4);
      expect(buildServerColors(['y', 'q', 'i', 'a']), colors);
      expect(
        buildServerColors([
          for (var i = 0; i < 20; i++) 'server-$i',
        ]).values.toSet().length,
        20,
      );
    },
  );
}
