import 'structure.dart';
import 'vasp_progress.dart';

enum GaussianMetric {
  maximumForce('最大受力', 'Hartree/Bohr'),
  rmsForce('RMS 受力', 'Hartree/Bohr'),
  maximumDisplacement('最大位移', 'Bohr'),
  rmsDisplacement('RMS 位移', 'Bohr');

  const GaussianMetric(this.label, this.unit);
  final String label, unit;
}

class GaussianCriterion {
  const GaussianCriterion(this.value, this.threshold, this.passed);
  final double value, threshold;
  final bool passed;
  double get ratio => value / threshold;
}

class GaussianStep {
  const GaussianStep(this.step, this.energy, this.criteria);
  final int step;
  final double? energy;
  final Map<GaussianMetric, GaussianCriterion> criteria;
}

class GaussianProgress {
  const GaussianProgress({
    required this.steps,
    this.structure,
    this.latestEnergy,
    this.segmentStart = 0,
    this.finished = false,
    this.failed = false,
    this.converged = false,
    this.warnings = const [],
  });
  final List<GaussianStep> steps;
  final AtomicStructure? structure;
  final double? latestEnergy;
  final int segmentStart;
  final bool finished, failed, converged;
  final List<String> warnings;
  List<ProgressPoint> get energies => [
    for (final step in steps) ProgressPoint(step.step, step.energy),
  ];
  List<ProgressPoint> metric(GaussianMetric metric, {bool ratio = false}) => [
    for (final step in steps)
      ProgressPoint(
        step.step,
        ratio ? step.criteria[metric]?.ratio : step.criteria[metric]?.value,
      ),
  ];
}
