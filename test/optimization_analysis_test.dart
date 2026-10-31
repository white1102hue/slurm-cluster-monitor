import 'dart:math' as math;
import 'package:flutter_test/flutter_test.dart';
import 'package:slurm_cluster_monitor/models/vasp_progress.dart';
import 'package:slurm_cluster_monitor/services/curve_sampling.dart';
import 'package:slurm_cluster_monitor/services/optimization_analysis.dart';
import 'package:slurm_cluster_monitor/services/vasp_progress_parser.dart';

List<ProgressPoint> points(List<double?> values) => [
  for (var i = 0; i < values.length; i++) ProgressPoint(i + 1, values[i]),
];
void main() {
  test('sustained reversals are a suspicion, never a convergence claim', () {
    final result = assessOptimization(
      energies: points([
        -10,
        -9.8,
        -10.01,
        -9.79,
        -10.02,
        -9.8,
        -10.01,
        -9.79,
        -10,
        -9.8,
      ]),
    );
    expect(result.state, OptimizationState.oscillating);
    expect(result.title, contains('疑似'));
    expect(result.detail, contains('反转'));
  });
  test(
    'monotonic relaxation, damping and numerical noise are not oscillations',
    () {
      for (final values in [
        [for (var i = 1; i <= 12; i++) -10 + 1 / i],
        [for (var i = 1; i <= 12; i++) -10 + math.pow(-.6, i).toDouble()],
        [for (var i = 1; i <= 12; i++) -10 + (i.isEven ? 1e-8 : -1e-8)],
      ]) {
        expect(
          assessOptimization(energies: points(values)).state,
          OptimizationState.progressing,
        );
      }
    },
  );
  test(
    'gaps, restarts and explicit program completion override the heuristic',
    () {
      expect(
        assessOptimization(energies: points([1, 2, null, 1, 2, 1, 2])).state,
        OptimizationState.insufficient,
      );
      expect(
        assessOptimization(energies: points([1, 2]), converged: true).state,
        OptimizationState.converged,
      );
      expect(
        assessOptimization(energies: points([1, 2]), finished: true).state,
        OptimizationState.ended,
      );
      final parser = OszicarProgressParser();
      for (var i = 1; i <= 10; i++) {
        parser.addLine(' $i F= -10 E0= ${i.isEven ? -10 : -9}');
      }
      parser.addLine(' 1 F= -10 E0= -10');
      expect(parser.segmentStart, 10);
      expect(
        assessOptimization(
          energies: parser.energies.skip(parser.segmentStart).toList(),
        ).state,
        OptimizationState.insufficient,
      );
    },
  );
  test(
    'MD, phonons and unknown VASP modes are excluded from optimization diagnoses',
    () {
      final energies = points([
        for (var i = 0; i < 12; i++) i.isEven ? -10 : -9,
      ]);
      for (final mode in [null, 0, -1, 5, 6, 7, 8, 40, 44]) {
        expect(
          assessVaspOptimization(
            VaspProgress(
              energies: energies,
              forces: [],
              energySource: 'test',
              ibrion: mode,
            ),
          ).state,
          OptimizationState.insufficient,
        );
      }
      expect(
        assessVaspOptimization(
          VaspProgress(
            energies: energies,
            forces: [],
            energySource: 'test',
            ibrion: 2,
          ),
        ).state,
        OptimizationState.oscillating,
      );
    },
  );
  test('200000-point rendering is bounded and preserves narrow extrema', () {
    final values = [
      for (var i = 0; i < 200000; i++)
        ProgressPoint(
          i + 1,
          i == 10101
              ? 100
              : i == 10999
              ? -50
              : 1,
        ),
    ];
    final sampled = sampleCurve(values);
    expect(sampled.length, lessThanOrEqualTo(2048));
    expect(sampled.first.step, 1);
    expect(sampled.last.step, 200000);
    expect(sampled.map((p) => p.value), containsAll([100, -50]));
  });
  test(
    'sampling preserves gaps rather than drawing across missing records',
    () {
      final values = [
        for (var i = 0; i < 10000; i++)
          ProgressPoint(i + 1, i == 5000 ? null : 1),
      ];
      final sampled = sampleCurve(values);
      expect(sampled.where((p) => p.value == null), isNotEmpty);
    },
  );
}
