import 'dart:math' as math;
import '../models/vasp_progress.dart';

enum OptimizationState {
  insufficient,
  progressing,
  oscillating,
  converged,
  ended,
}

class OptimizationAssessment {
  const OptimizationAssessment(this.state, this.title, this.detail);
  final OptimizationState state;
  final String title, detail;
}

/// Never replaces program convergence criteria. Use only the current run and
/// a contiguous valid suffix, so restarts and missing records do not join up.
OptimizationAssessment assessOptimization({
  required List<ProgressPoint> energies,
  double energyNoise = 1e-6,
  String energyUnit = 'eV',
  bool converged = false,
  bool finished = false,
}) {
  if (converged) {
    return const OptimizationAssessment(
      OptimizationState.converged,
      '优化已收敛',
      '日志中已出现程序的优化收敛标记。',
    );
  }
  if (finished) {
    return const OptimizationAssessment(
      OptimizationState.ended,
      '计算已结束',
      '未见当前计算的优化收敛标记。',
    );
  }
  final recent = <double>[];
  int? previousStep;
  for (final p in energies.reversed.take(12)) {
    if (p.value == null ||
        !p.value!.isFinite ||
        (previousStep != null && p.step != previousStep - 1)) {
      break;
    }
    recent.add(p.value!);
    previousStep = p.step;
  }
  if (recent.length < 8) {
    return OptimizationAssessment(
      OptimizationState.insufficient,
      '优化数据不足',
      '当前计算只有 ${recent.length} 个连续有效能量点；至少需要 8 步判断趋势。',
    );
  }
  final values = recent.reversed.toList();
  var reversals = 0, previousSign = 0, significant = 0;
  for (var i = 1; i < values.length; i++) {
    final difference = values[i] - values[i - 1];
    if (difference.abs() <= energyNoise) continue;
    significant++;
    final sign = difference > 0 ? 1 : -1;
    if (previousSign != 0 && sign != previousSign) reversals++;
    previousSign = sign;
  }
  double range(Iterable<double> list) {
    final rows = list.toList();
    return rows.reduce(math.max) - rows.reduce(math.min);
  }

  final half = values.length ~/ 2;
  final firstRange = range(values.take(half));
  final lastRange = range(values.skip(half));
  final spread = range(values);
  double mean(Iterable<double> list) {
    final rows = list.toList();
    return rows.reduce((a, b) => a + b) / rows.length;
  }

  final drift = (mean(values.take(half)) - mean(values.skip(half))).abs();
  if (significant >= 6 &&
      reversals >= 4 &&
      reversals / math.max(1, significant - 1) >= .65 &&
      spread > energyNoise * 10 &&
      lastRange >= firstRange * .7 &&
      drift <= spread * .5) {
    return OptimizationAssessment(
      OptimizationState.oscillating,
      '疑似优化震荡',
      '最近 ${values.length} 步能量反转 $reversals 次，振幅未明显减小'
          '（范围 ${spread.toStringAsExponential(2)} $energyUnit）。'
          '这是趋势提示，请结合受力、位移及所用优化算法确认。',
    );
  }
  return OptimizationAssessment(
    OptimizationState.progressing,
    '优化进行中',
    '最近 ${values.length} 步未满足震荡判据；这不代表已收敛。',
  );
}

OptimizationAssessment assessVaspOptimization(VaspProgress data) {
  if (data.converged || data.finished) {
    return assessOptimization(
      energies: data.energies,
      converged: data.converged,
      finished: data.finished,
    );
  }
  if (!const {1, 2, 3}.contains(data.ibrion)) {
    return OptimizationAssessment(
      OptimizationState.insufficient,
      data.ibrion == null ? '运行中 · 优化类型待确认' : '运行中 · 非常规结构优化',
      data.ibrion == null
          ? '未读到 OUTCAR 的 IBRION，保留曲线，不对优化震荡下结论。'
          : 'OUTCAR 中 IBRION = ${data.ibrion}；分子动力学、频率和反应路径等计算不使用常规优化震荡判据。',
    );
  }
  return assessOptimization(
    energies: data.energies.skip(data.segmentStart).toList(),
  );
}
