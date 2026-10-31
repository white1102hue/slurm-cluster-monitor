import 'package:flutter/foundation.dart';
import '../models/vasp_progress.dart';
import 'gaussian_parser.dart';
import 'optimization_analysis.dart';
import 'remote_files.dart';
import 'vasp_progress_parser.dart';

enum CalculationKind { vasp, gaussian }

class CurrentCalculation {
  const CurrentCalculation({
    required this.message,
    this.path,
    this.kind,
    this.assessment,
    this.modified,
    this.matchedOutputs = 0,
    this.searchComplete = true,
    this.warnings = const [],
  });
  final String message;
  final String? path;
  final CalculationKind? kind;
  final OptimizationAssessment? assessment;
  final DateTime? modified;
  final int matchedOutputs;
  final bool searchComplete;
  final List<String> warnings;
}

class _CachedText {
  _CachedText(this.size, this.modified, this.text);
  final int? size;
  final DateTime? modified;
  final String text;
}

final _gaussianMarker = RegExp(
  r'Gaussian, Inc\.|Entering Gaussian System|SCF Done:|'
  r'(?:Standard|Input|Z-Matrix) orientation:|Normal termination of Gaussian',
);
bool looksLikeGaussian(String text) => _gaussianMarker.hasMatch(text);

OptimizationAssessment _gaussianAssessment(String text) {
  final data = parseGaussianText(text);
  return assessOptimization(
    energies: data.energies.skip(data.segmentStart).toList(),
    energyNoise: 1e-7,
    energyUnit: 'Hartree',
    converged: data.converged,
    finished: data.finished,
  );
}

OptimizationAssessment _vaspAssessment((String, String, String) text) {
  final ionic = OszicarProgressParser();
  for (final line in text.$1.split('\n')) {
    ionic.addLine(line);
  }
  final outcar = OutcarProgressParser();
  for (final line in text.$2.split('\n')) {
    outcar.addLine(line);
  }
  final energies = ionic.energies.isEmpty
      ? outcar.energies.skip(outcar.segmentStart).toList()
      : ionic.energies.skip(ionic.segmentStart).toList();
  final mode = RegExp(r'\bIBRION\s*=\s*(-?\d+)').allMatches(text.$3).lastOrNull;
  return assessVaspOptimization(
    VaspProgress(
      energies: energies,
      forces: const [],
      energySource: '最近输出',
      converged: outcar.converged,
      finished: outcar.finished,
      ibrion: outcar.ibrion ?? int.tryParse(mode?[1] ?? ''),
    ),
  );
}

/// Select by OUTCAR's own mtime across the full accessible directory tree.
/// Age, equal timestamps and unrelated unreadable directories do not hide it.
class OptimizationCheckService {
  OptimizationCheckService(this.files);
  final RemoteFiles files;
  final _cache = <String, _CachedText>{};

  Future<String> _text(RemoteFileMatch entry, {bool tail = true}) async {
    final key = '$tail:${entry.path}';
    final cached = _cache.remove(key);
    if (entry.modified != null &&
        entry.size != null &&
        cached?.size == entry.size &&
        cached?.modified == entry.modified) {
      _cache[key] = cached!;
      return cached.text;
    }
    final data = tail
        ? await files.read(entry.path, tail: true)
        : await files.sample(entry.path);
    if (_cache.length >= 8) _cache.remove(_cache.keys.first);
    _cache[key] = _CachedText(entry.size, entry.modified, data.text);
    return data.text;
  }

  Future<CurrentCalculation> check(
    String directory, {
    bool Function()? cancelled,
    void Function(int matched)? onProgress,
  }) async {
    void ensureActive() {
      if (cancelled?.call() == true) throw const FileReadCancelled();
    }

    ensureActive();
    final search = await files.findOutputs(
      directory,
      cancelled: cancelled,
      onProgress: onProgress,
    );
    ensureActive();
    final warnings = [...search.warnings];
    final outcar = search.outcar;
    if (outcar != null) {
      OptimizationAssessment? assessment;
      try {
        final tail = await _text(outcar);
        ensureActive();
        final head = await _text(outcar, tail: false);
        var oszicar = '';
        try {
          final path = remoteJoin(remoteParent(outcar.path), 'OSZICAR');
          final entry = await files.stat(path);
          if (entry != null) {
            oszicar = await _text(
              RemoteFileMatch(path, size: entry.size, modified: entry.modified),
            );
          }
        } on FileReadCancelled {
          rethrow;
        } catch (_) {
          warnings.add('同目录 OSZICAR 暂不可读，使用 OUTCAR 能量。');
        }
        ensureActive();
        assessment = await compute(_vaspAssessment, (oszicar, tail, head));
      } on FileReadCancelled {
        rethrow;
      } catch (_) {
        warnings.add('已找到最新 OUTCAR，但暂不能解析，请打开文件或重新检测。');
      }
      ensureActive();
      return CurrentCalculation(
        message: outcar.modified == null
            ? '找到 OUTCAR · 修改时间未知'
            : '最新 OUTCAR · ${switch (assessment?.state) {
                OptimizationState.converged => '优化已收敛',
                OptimizationState.ended => '本轮计算已结束',
                OptimizationState.oscillating => '疑似优化震荡',
                _ => '当前计算输出',
              }}',
        path: outcar.path,
        kind: CalculationKind.vasp,
        assessment: assessment,
        modified: outcar.modified,
        matchedOutputs: search.matched,
        searchComplete: search.complete,
        warnings: warnings,
      );
    }
    // Gaussian remains available when the tree contains no OUTCAR.
    for (final file in search.gaussian) {
      ensureActive();
      try {
        final text = await _text(file);
        if (!looksLikeGaussian(text)) continue;
        final assessment = await compute(_gaussianAssessment, text);
        ensureActive();
        return CurrentCalculation(
          message: '最近更新的 Gaussian 输出',
          path: file.path,
          kind: CalculationKind.gaussian,
          assessment: assessment,
          modified: file.modified,
          matchedOutputs: search.matched,
          searchComplete: search.complete,
          warnings: warnings,
        );
      } on FileReadCancelled {
        rethrow;
      } catch (_) {
        warnings.add('部分 Gaussian 日志暂不可读。');
      }
    }
    return CurrentCalculation(
      message: '脚本运行中 · 尚未找到 OUTCAR / Gaussian 输出',
      matchedOutputs: search.matched,
      searchComplete: search.complete,
      warnings: warnings,
    );
  }
}
