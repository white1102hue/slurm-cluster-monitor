import 'dart:math' as math;
import '../models/structure.dart';
import '../models/vasp_progress.dart';

const _numeric = r'[+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:[EeDd][+-]?\d+)?';
final _sigmaEnergy = RegExp(
  r'energy\(sigma->0\)\s*=\s*(' + _numeric + r')(?=\s|$)',
);
final _oszicarEnergy = RegExp(r'\bE0\s*=\s*(' + _numeric + r')(?=\s|$)');
final _e0Marker = RegExp(r'\bE0\s*=');
final _ionicLine = RegExp(r'^\s*\d+\s');
final _nions = RegExp(r'\bNIONS\s*=\s*(\d+)');
final _forceHeader = RegExp(r'\bPOSITION\s+TOTAL-FORCE');
final _separator = RegExp(r'^-{3,}$');
final _vaspStart = RegExp(r'^\s*vasp\.\d', caseSensitive: false);
final _ibrion = RegExp(r'\bIBRION\s*=\s*(-?\d+)');
const maxProgressRecords = 200000;

double? _number(String? token) {
  if (token == null) return null;
  final result = double.tryParse(token.replaceAll(RegExp('[dD]'), 'e'));
  return result != null && result.isFinite ? result : null;
}

void _checkRecords(int count) {
  if (count >= maxProgressRecords) {
    throw const FormatException('优化记录超过 200000 条，请在电脑上查看');
  }
}

class OszicarProgressParser {
  final energies = <ProgressPoint>[];
  int segmentStart = 0;
  int? _previousIonicStep;
  void addLine(String line) {
    if (_ionicLine.hasMatch(line) && _e0Marker.hasMatch(line)) {
      final printed = int.tryParse(line.trimLeft().split(RegExp(r'\s+')).first);
      if (printed != null &&
          _previousIonicStep != null &&
          printed <= _previousIonicStep!) {
        segmentStart = energies.length;
      }
      _previousIonicStep = printed;
      _checkRecords(energies.length);
      energies.add(
        ProgressPoint(
          energies.length + 1,
          _number(_oszicarEnergy.firstMatch(line)?[1]),
        ),
      );
    }
  }
}

/// Same allowed-DIRECT-displacement projection as the supplied vasp_data.py.
List<Vec3> allowedForceBasis(List<Vec3> cell, int fixedAxes) {
  final basis = <Vec3>[];
  for (var axis = 0; axis < 3; axis++) {
    if (fixedAxes & (1 << axis) != 0) continue;
    var residual = cell[axis];
    for (final q in basis) {
      residual = residual - q * residual.dot(q);
    }
    final length = residual.length;
    if (!length.isFinite || length < 1e-14) {
      throw const FormatException('晶格的可动方向退化，不能计算约束后受力');
    }
    basis.add(residual * (1 / length));
  }
  return basis;
}

class OutcarProgressParser {
  OutcarProgressParser({this.structure}) {
    _expected = structure?.atoms.length;
    _cell = structure?.cell;
  }
  final AtomicStructure? structure;
  final energies = <ProgressPoint>[];
  final forces = <ForceRecord>[];
  bool finished = false, converged = false;
  int segmentStart = 0;
  int? ibrion;
  int? _expected;
  List<Vec3>? _cell, _lattice;
  bool _inBlock = false, _invalid = false;
  int _blockStep = 0, _count = 0, _ignored = 0;
  double _raw = 0;
  double? _allowed;
  final _basis = <int, List<Vec3>>{};

  void addLine(String line) {
    if (line.contains('\x00')) throw const FormatException('OUTCAR 不是有效的文本文件');
    if (_vaspStart.hasMatch(line)) {
      segmentStart = energies.length;
      finished = converged = false;
      ibrion = null;
    }
    final mode = _ibrion.firstMatch(line);
    if (mode != null) ibrion = int.tryParse(mode[1]!);
    if (line.trimLeft().startsWith('General timing')) finished = true;
    if (line.contains('reached required accuracy')) converged = true;
    if (line.contains('energy(sigma->0)')) {
      _checkRecords(energies.length);
      energies.add(
        ProgressPoint(
          energies.length + 1,
          _number(_sigmaEnergy.firstMatch(line)?[1]),
        ),
      );
    }
    final nions = _nions.firstMatch(line);
    if (nions != null) _expected = int.tryParse(nions[1]!);
    if (line.toLowerCase().contains('direct lattice vectors')) {
      _lattice = [];
      return;
    }
    if (_lattice != null) {
      final row = line
          .trim()
          .split(RegExp(r'\s+'))
          .take(3)
          .map(_number)
          .toList();
      if (row.length != 3 || row.any((v) => v == null)) {
        _lattice = null;
      } else {
        _lattice!.add(Vec3(row[0]!, row[1]!, row[2]!));
        if (_lattice!.length == 3) {
          _cell = _lattice;
          _lattice = null;
        }
      }
      return;
    }
    if (_forceHeader.hasMatch(line)) {
      if (_inBlock) _ignored++;
      _checkRecords(_blockStep);
      _blockStep++;
      _inBlock = true;
      _invalid = false;
      _count = 0;
      _raw = 0;
      _allowed = structure == null ? null : 0;
      _basis.clear();
      return;
    }
    if (!_inBlock) return;
    final stripped = line.trim();
    if (line.contains('total drift') || _separator.hasMatch(stripped)) {
      if (_count == 0 && !line.contains('total drift') && !_invalid) return;
      if (_count > 0 &&
          !_invalid &&
          (_expected == null || _count == _expected)) {
        forces.add(
          ForceRecord(
            _blockStep,
            structure?.atoms.length == _count ? _allowed : null,
            _raw,
          ),
        );
      } else {
        _ignored++;
      }
      _inBlock = false;
      return;
    }
    if (stripped.isEmpty) return;
    final fields = stripped.split(RegExp(r'\s+'));
    if (fields.length != 6) {
      _invalid = true;
      return;
    }
    final values = fields.map(_number).toList();
    if (values.any((v) => v == null)) {
      _invalid = true;
      return;
    }
    final force = Vec3(values[3]!, values[4]!, values[5]!);
    if (!force.length.isFinite) {
      _invalid = true;
      return;
    }
    _raw = math.max(_raw, force.length);
    if (_allowed != null) {
      if (_count >= structure!.atoms.length) {
        _allowed = null;
      } else {
        final fixed = structure!.atoms[_count].fixedAxes;
        if (fixed == 0) {
          _allowed = math.max(_allowed!, force.length);
        } else if (fixed != 7) {
          try {
            if (_cell == null) throw const FormatException('没有晶格');
            final basis = _basis.putIfAbsent(
              fixed,
              () => allowedForceBasis(_cell!, fixed),
            );
            final magnitude = math.sqrt(
              basis.fold(0.0, (v, q) => v + math.pow(force.dot(q), 2)),
            );
            _allowed = math.max(_allowed!, magnitude);
          } on FormatException {
            _allowed = null;
          }
        }
      }
    }
    _count++;
  }

  List<String> get warnings => [
    if (_ignored + (_inBlock ? 1 : 0) > 0)
      '已忽略 ${_ignored + (_inBlock ? 1 : 0)} 个无效或未写完的受力块。',
    if (forces.any((f) => f.allowed == null)) '约束信息缺失或原子数不匹配；对应记录只保留原始受力。',
  ];
}
