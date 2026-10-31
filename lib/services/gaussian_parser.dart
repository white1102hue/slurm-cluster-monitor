import '../models/gaussian_progress.dart';
import '../models/structure.dart';

const _numeric = r'[+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:[EeDd][+-]?\d+)?';
final _scf = RegExp(r'SCF Done:.*?=\s*(' + _numeric + r')(?=\s|$)');
final _correlated = RegExp(
  r'(?:EUMP[234]|E\([RU]?MP[234]\)|CCSD\(T\)|E\(CORR\))\s*=\s*(' +
      _numeric +
      r')(?=\s|$)',
);
final _criterion = RegExp(
  r'^\s*(Maximum|RMS)\s+(Force|Displacement)\s*(' +
      _numeric +
      r')\s+(' +
      _numeric +
      r')\s+(YES|NO)\b',
);
final _separator = RegExp(r'^\s*-{5,}\s*$');
final _orientation = RegExp(r'(Standard|Input|Z-Matrix) orientation:');
final _link1 = RegExp(r'Link1:\s+Proceeding to internal job step');

double? gaussianNumber(String? raw) {
  final n = double.tryParse((raw ?? '').replaceAll(RegExp('[dD]'), 'e'));
  return n != null && n.isFinite ? n : null;
}

/// Retains complete convergence tables and only the last complete geometry.
/// A partial orientation at EOF never replaces a valid preceding geometry.
class GaussianParser {
  final steps = <GaussianStep>[];
  final _criteria = <GaussianMetric, GaussianCriterion>{};
  List<StructureAtom>? _atoms;
  AtomicStructure? _structure;
  String _orientationName = '';
  int _separators = 0, _ignoredTables = 0, _ignoredGeometries = 0;
  int _segmentStart = 0;
  double? _energy;
  bool _invalidGeometry = false, _bohr = false;
  bool _finished = false, _failed = false, _converged = false;

  void addLine(String line) {
    if (line.contains('\x00')) {
      throw const FormatException('Gaussian 日志不是有效文本');
    }
    if (line.contains('Entering Gaussian System') ||
        _link1.hasMatch(line) ||
        line.trim() == '--Link1--') {
      _segmentStart = steps.length;
      _finished = _failed = _converged = false;
      _energy = null;
      _criteria.clear();
    }
    if (line.contains('Normal termination of Gaussian')) _finished = true;
    if (line.contains('Error termination')) {
      _finished = _failed = true;
    }
    if (line.contains('Optimization completed.') ||
        line.contains('Stationary point found.')) {
      _converged = true;
    }
    final energy = _scf.firstMatch(line) ?? _correlated.firstMatch(line);
    if (energy != null) _energy = gaussianNumber(energy[1]);
    if (line.contains('Converged?') && line.contains('Threshold')) {
      if (_criteria.isNotEmpty) _ignoredTables++;
      _criteria.clear();
    }
    final match = _criterion.firstMatch(line);
    if (match != null) {
      final metric = match[2] == 'Force'
          ? match[1] == 'Maximum'
                ? GaussianMetric.maximumForce
                : GaussianMetric.rmsForce
          : match[1] == 'Maximum'
          ? GaussianMetric.maximumDisplacement
          : GaussianMetric.rmsDisplacement;
      final value = gaussianNumber(match[3]);
      final threshold = gaussianNumber(match[4]);
      if (value != null && value >= 0 && threshold != null && threshold > 0) {
        _criteria[metric] = GaussianCriterion(
          value,
          threshold,
          match[5] == 'YES',
        );
      }
      if (metric == GaussianMetric.rmsDisplacement) {
        if (_criteria.length == 4) {
          if (steps.length >= 200000) {
            throw const FormatException('优化记录超过 200000 条，请在电脑上查看');
          }
          steps.add(GaussianStep(steps.length + 1, _energy, Map.of(_criteria)));
          _energy = null;
        } else {
          _ignoredTables++;
        }
        _criteria.clear();
      }
    }
    final orientation = _orientation.firstMatch(line);
    if (orientation != null) {
      if (_atoms != null) _ignoredGeometries++;
      _atoms = [];
      _separators = 0;
      _invalidGeometry = false;
      _bohr = false;
      _orientationName = orientation[1]!;
      return;
    }
    if (_atoms == null) return;
    if (line.contains('Coordinates (Bohr)')) _bohr = true;
    if (_separator.hasMatch(line)) {
      _separators++;
      if (_separators == 3) {
        if (!_invalidGeometry && _atoms!.isNotEmpty) {
          _structure = AtomicStructure(
            title: 'Gaussian · $_orientationName orientation',
            atoms: List.of(_atoms!),
            notes: const ['显示日志中最后一个完整坐标块；单位 Å。'],
          );
        } else {
          _ignoredGeometries++;
        }
        _atoms = null;
      }
      return;
    }
    if (_separators != 2 || line.trim().isEmpty) return;
    final row = line.trim().split(RegExp(r'\s+'));
    if (row.length != 6) {
      _invalidGeometry = true;
      return;
    }
    final center = int.tryParse(row[0]), atomic = int.tryParse(row[1]);
    final x = gaussianNumber(row[3]), y = gaussianNumber(row[4]);
    final z = gaussianNumber(row[5]);
    if (center == null ||
        atomic == null ||
        x == null ||
        y == null ||
        z == null ||
        [x, y, z].any((v) => v.abs() > 1e9)) {
      _invalidGeometry = true;
      return;
    }
    if (atomic == -1) return;
    if (atomic < 0 || atomic >= elementSymbols.length) {
      _invalidGeometry = true;
      return;
    }
    if (_atoms!.length >= 5000) {
      _invalidGeometry = true;
      return;
    }
    _atoms!.add(
      StructureAtom(
        elementSymbols[atomic],
        Vec3(x, y, z) * (_bohr ? 0.529177210903 : 1),
        sourceIndex: center,
      ),
    );
  }

  GaussianProgress get result => GaussianProgress(
    steps: List.of(steps),
    structure: _structure,
    latestEnergy: _energy ?? (steps.isEmpty ? null : steps.last.energy),
    segmentStart: _segmentStart,
    finished: _finished,
    failed: _failed,
    converged: _converged,
    warnings: [
      if (_ignoredTables > 0 || _criteria.isNotEmpty)
        '已忽略 ${_ignoredTables + (_criteria.isNotEmpty ? 1 : 0)} 个不完整或无效收敛表。',
      if (_ignoredGeometries > 0 || _atoms != null)
        '已忽略 ${_ignoredGeometries + (_atoms != null ? 1 : 0)} 个不完整、无效或超过 5000 原子的坐标块。',
    ],
  );
}

GaussianProgress parseGaussianText(String text) {
  final parser = GaussianParser();
  for (final line in text.split('\n')) {
    parser.addLine(
      line.endsWith('\r') ? line.substring(0, line.length - 1) : line,
    );
  }
  return parser.result;
}

bool isGaussianLog(String name) =>
    RegExp(r'\.(log|out)$', caseSensitive: false).hasMatch(name);
