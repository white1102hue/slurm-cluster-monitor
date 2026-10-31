import 'package:flutter/material.dart';
import '../models/gaussian_progress.dart';
import '../models/vasp_progress.dart';
import '../services/gaussian_service.dart';
import '../services/optimization_analysis.dart';
import '../services/remote_files.dart';
import 'app_theme.dart';
import 'optimization_status.dart';
import 'progress_curve.dart';
import 'structure_view.dart';

class GaussianProgressPage extends StatefulWidget {
  const GaussianProgressPage({
    super.key,
    required this.files,
    required this.path,
    required this.onOpenText,
  });
  final RemoteFiles files;
  final String path;
  final VoidCallback onOpenText;
  @override
  State<GaussianProgressPage> createState() => _GaussianProgressPageState();
}

class _GaussianProgressPageState extends State<GaussianProgressPage> {
  GaussianProgress? _data;
  String? _error;
  bool _busy = true, _lastFive = false, _structure = false;
  int _revision = 0, _read = 0, _total = 0;
  List<ProgressPoint> _energies = const [];
  Map<GaussianMetric, List<ProgressPoint>> _metrics = const {};
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
      final data = await GaussianService(widget.files).load(
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
          _energies = data.energies;
          _metrics = {
            for (final metric in GaussianMetric.values)
              metric: data.metric(metric, ratio: true),
          };
          _assessment = assessOptimization(
            energies: _energies.skip(data.segmentStart).toList(),
            energyNoise: 1e-7,
            energyUnit: 'Hartree',
            converged: data.converged,
            finished: data.finished,
          );
          _busy = false;
        });
      }
    } on FileReadCancelled {
      if (mounted && revision == _revision) {
        setState(() {
          _busy = false;
          _error = '已停止读取，可刷新后继续';
        });
      }
    } catch (e) {
      if (mounted && revision == _revision) {
        setState(() {
          _busy = false;
          _error = fileError(e);
        });
      }
    }
  }

  List<ProgressPoint> _window(List<ProgressPoint> points) =>
      _lastFive && points.length > 5
      ? points.sublist(points.length - 5)
      : points;

  @override
  Widget build(BuildContext context) {
    final data = _data;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Gaussian · 优化'),
        actions: [
          IconButton(
            tooltip: '优化数据说明',
            onPressed: () => showDialog<void>(
              context: context,
              builder: (context) => AlertDialog(
                title: const Text('优化数据说明'),
                content: const Text(
                  '优化步按完整四项收敛表记录，能量取该步最后的电子能量。\n\n'
                  '受力与位移曲线显示数值 / 日志阈值，虚线为比值 1；'
                  '≤ 1 表示该项达到阈值。最终收敛仍以 Gaussian 的显式标记为准。',
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('关闭'),
                  ),
                ],
              ),
            ),
            icon: const Icon(Icons.info_outline),
          ),
          IconButton(
            tooltip: '查看日志原文',
            onPressed: _busy ? null : widget.onOpenText,
            icon: const Icon(Icons.description_outlined),
          ),
          IconButton(
            tooltip: _busy ? '停止读取' : '刷新优化进度',
            onPressed: _busy
                ? () => setState(() {
                    _revision++;
                    _busy = false;
                    _error = '已停止读取，可刷新后继续';
                  })
                : _load,
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
            if (data != null)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Row(
                  children: [
                    ChoiceChip(
                      label: const Text('收敛曲线'),
                      selected: !_structure,
                      onSelected: (_) => setState(() => _structure = false),
                    ),
                    const SizedBox(width: 8),
                    ChoiceChip(
                      label: const Text('最新结构'),
                      selected: _structure,
                      onSelected: (_) => setState(() => _structure = true),
                    ),
                  ],
                ),
              ),
            Expanded(
              child: _error != null
                  ? Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Padding(
                            padding: const EdgeInsets.all(16),
                            child: Text(_error!),
                          ),
                          TextButton(
                            onPressed: _load,
                            child: const Text('重新读取'),
                          ),
                        ],
                      ),
                    )
                  : data == null
                  ? Center(
                      child: Text(
                        _total == 0
                            ? '读取 Gaussian 日志…'
                            : '读取 ${(_read / 1048576).toStringAsFixed(1)} / ${(_total / 1048576).toStringAsFixed(1)} MB',
                      ),
                    )
                  : _structure
                  ? data.structure != null
                        ? StructureView(
                            key: ValueKey(data.structure),
                            structure: data.structure!,
                          )
                        : const Center(
                            child: Padding(
                              padding: EdgeInsets.all(20),
                              child: Text('尚无完整坐标块。也可打开 .gjf / .com 输入文件查看结构。'),
                            ),
                          )
                  : _curves(data),
            ),
          ],
        ),
      ),
    );
  }

  Widget _curves(GaussianProgress data) {
    final colors = Theme.of(context).colorScheme;
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        Text(widget.path, style: TextStyle(fontSize: 11, color: context.muted)),
        OptimizationStatus(assessment: _assessment!),
        if (data.failed)
          Text(
            'Gaussian 报告异常终止，请查看原文。',
            style: TextStyle(color: colors.error, fontSize: 12),
          ),
        if (data.warnings.isNotEmpty)
          Text(
            data.warnings.join('\n'),
            style: TextStyle(color: context.muted, fontSize: 11),
          ),
        Wrap(
          spacing: 8,
          children: [
            ChoiceChip(
              label: const Text('全部步'),
              selected: !_lastFive,
              onSelected: (_) => setState(() => _lastFive = false),
            ),
            ChoiceChip(
              label: const Text('最近 5 步'),
              selected: _lastFive,
              onSelected: (_) => setState(() => _lastFive = true),
            ),
          ],
        ),
        ProgressCurve(
          title: '优化能量（Hartree）',
          points: _window(_energies),
          color: colors.primary,
          unit: 'Hartree',
          xAxisLabel: '优化步',
        ),
        for (final metric in GaussianMetric.values) ...[
          ProgressCurve(
            title: '${metric.label} / 收敛阈值',
            subtitle: data.steps.isEmpty
                ? ''
                : '${curveNumber(data.steps.last.criteria[metric]?.value)} '
                      '${metric.unit} · 阈值 ${curveNumber(data.steps.last.criteria[metric]?.threshold)}',
            points: _window(_metrics[metric]!),
            color: metric.index.isEven ? colors.secondary : colors.tertiary,
            unit: '倍',
            zeroFloor: true,
            threshold: 1,
            xAxisLabel: '优化步',
          ),
        ],
      ],
    );
  }
}
