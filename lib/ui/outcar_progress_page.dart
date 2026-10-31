import 'package:flutter/material.dart';
import '../models/vasp_progress.dart';
import '../services/remote_files.dart';
import '../services/vasp_progress_service.dart';
import 'app_theme.dart';
import 'progress_curve.dart';
import '../services/optimization_analysis.dart';
import 'optimization_status.dart';

class OutcarProgressPage extends StatefulWidget {
  const OutcarProgressPage({
    super.key,
    required this.files,
    required this.path,
    required this.onOpenText,
  });
  final RemoteFiles files;
  final String path;
  final VoidCallback onOpenText;
  @override
  State<OutcarProgressPage> createState() => _OutcarProgressPageState();
}

class _OutcarProgressPageState extends State<OutcarProgressPage> {
  VaspProgress? _data;
  String? _error;
  bool _busy = true, _lastFive = false, _raw = false;
  int _revision = 0, _read = 0, _total = 0;
  List<ProgressPoint> _rawForces = const [], _allowedForces = const [];
  OptimizationAssessment? _assessment;
  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _revision++;
    super.dispose();
  }

  Future<void> _load() async {
    final revision = ++_revision;
    setState(() {
      _busy = true;
      _error = null;
      _read = 0;
      _total = 0;
    });
    final watch = Stopwatch()..start();
    try {
      final data = await VaspProgressService(widget.files).load(
        widget.path,
        cancelled: () => !mounted || revision != _revision,
        onProgress: (read, total) {
          if (mounted &&
              revision == _revision &&
              (read == 0 || read == total || watch.elapsedMilliseconds > 100)) {
            setState(() {
              _read = read;
              _total = total;
            });
            watch.reset();
          }
        },
      );
      if (mounted && revision == _revision) {
        setState(() {
          _data = data;
          _rawForces = [
            for (final record in data.forces)
              ProgressPoint(record.step, record.raw),
          ];
          _allowedForces = [
            for (final record in data.forces)
              ProgressPoint(record.step, record.allowed),
          ];
          _assessment = assessVaspOptimization(data);
          _busy = false;
        });
      }
    } on FileReadCancelled {
      // The page was closed or the user explicitly stopped this scan.
      if (mounted && revision == _revision) {
        setState(() {
          _busy = false;
          _error = '已停止读取，可刷新后继续';
        });
      }
    } catch (e) {
      if (mounted && revision == _revision) {
        setState(() {
          _error = fileError(e);
          _busy = false;
        });
      }
    }
  }

  void _stop() => setState(() {
    _revision++;
    _busy = false;
    _error = '已停止读取，可刷新后继续';
  });
  void _explain() => showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('优化数据口径'),
      content: SingleChildScrollView(
        child: Text(
          [
            '能量优先读取同目录 OSZICAR 的 E0，缺失时使用 OUTCAR 的 energy(sigma->0)。',
            '最大受力按完整 POSITION / TOTAL-FORCE 块计算。优先使用 POSCAR 的固定约束，回退 CONTCAR；部分约束按当步晶格的可动方向投影。约束未知时仅显示原始受力。',
            '横轴按记录出现顺序累计，续算编号重置也不覆盖旧记录。文件读取到开始扫描时的大小，未写完的受力块不计入。点击或拖动曲线查看数值；刷新读取最新进度。',
            ...?_data?.warnings,
          ].join('\n\n'),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('知道了'),
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final data = _data;
    final raw = _raw || data?.hasAllowedForces != true;
    List<ProgressPoint> window(List<ProgressPoint> points) =>
        _lastFive && points.length > 5
        ? points.sublist(points.length - 5)
        : points;
    return Scaffold(
      appBar: AppBar(
        title: const Text('OUTCAR · 优化进度'),
        actions: [
          IconButton(
            tooltip: '查看 OUTCAR 原文',
            onPressed: _busy ? null : widget.onOpenText,
            icon: const Icon(Icons.description_outlined),
          ),
          IconButton(
            tooltip: _busy ? '停止读取' : '刷新优化进度',
            onPressed: _busy ? _stop : _load,
            icon: Icon(_busy ? Icons.stop_circle_outlined : Icons.refresh),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            if (_busy)
              LinearProgressIndicator(
                value: _total == 0 ? null : (_read / _total).clamp(0, 1),
                minHeight: 3,
              ),
            Expanded(
              child: _error != null
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(_error!, textAlign: TextAlign.center),
                            TextButton(
                              onPressed: _load,
                              child: const Text('重新读取'),
                            ),
                          ],
                        ),
                      ),
                    )
                  : data == null
                  ? Center(
                      child: Text(
                        _total == 0
                            ? '读取优化记录…'
                            : '读取 OUTCAR ${(_read / 1048576).toStringAsFixed(1)} / ${(_total / 1048576).toStringAsFixed(1)} MB',
                      ),
                    )
                  : ListView(
                      padding: const EdgeInsets.all(12),
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                widget.path,
                                style: TextStyle(
                                  fontSize: 11,
                                  color: context.muted,
                                ),
                              ),
                            ),
                            IconButton(
                              tooltip: '优化数据说明',
                              onPressed: _explain,
                              icon: Badge(
                                isLabelVisible: data.warnings.isNotEmpty,
                                child: const Icon(Icons.info_outline, size: 20),
                              ),
                            ),
                          ],
                        ),
                        OptimizationStatus(assessment: _assessment!),
                        Wrap(
                          spacing: 8,
                          children: [
                            ChoiceChip(
                              label: const Text('全部步'),
                              selected: !_lastFive,
                              onSelected: (_) =>
                                  setState(() => _lastFive = false),
                            ),
                            ChoiceChip(
                              label: const Text('最近 5 步'),
                              selected: _lastFive,
                              onSelected: (_) =>
                                  setState(() => _lastFive = true),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        ProgressCurve(
                          key: ValueKey(('energy', _lastFive, data)),
                          title: '能量 E0（eV）',
                          subtitle: data.energySource,
                          points: window(data.energies),
                          color: Theme.of(context).colorScheme.primary,
                          unit: 'eV',
                        ),
                        if (data.hasAllowedForces)
                          Wrap(
                            spacing: 8,
                            children: [
                              ChoiceChip(
                                label: const Text('约束后受力'),
                                selected: !_raw,
                                onSelected: (_) => setState(() => _raw = false),
                              ),
                              ChoiceChip(
                                label: const Text('原始受力'),
                                selected: _raw,
                                onSelected: (_) => setState(() => _raw = true),
                              ),
                            ],
                          ),
                        const SizedBox(height: 4),
                        ProgressCurve(
                          key: ValueKey(('force', _lastFive, raw, data)),
                          title: '最大受力（eV/Å）',
                          subtitle: raw
                              ? data.hasAllowedForces
                                    ? '原始受力'
                                    : '原始受力 · 约束未知'
                              : '可动方向投影',
                          points: window(raw ? _rawForces : _allowedForces),
                          color: Theme.of(context).colorScheme.tertiary,
                          unit: 'eV/Å',
                          zeroFloor: true,
                        ),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
