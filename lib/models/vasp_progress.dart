class ProgressPoint {
  const ProgressPoint(this.step, this.value);
  final int step;
  final double? value;
}

class ForceRecord {
  const ForceRecord(this.step, this.allowed, this.raw);
  final int step;
  final double? allowed;
  final double raw;
}

class VaspProgress {
  const VaspProgress({
    required this.energies,
    required this.forces,
    required this.energySource,
    this.finished = false,
    this.converged = false,
    this.warnings = const [],
    this.segmentStart = 0,
    this.ibrion,
  });
  final List<ProgressPoint> energies;
  final List<ForceRecord> forces;
  final String energySource;
  final bool finished, converged;
  final List<String> warnings;
  final int segmentStart;
  final int? ibrion;
  bool get hasAllowedForces => forces.any((f) => f.allowed != null);
}
