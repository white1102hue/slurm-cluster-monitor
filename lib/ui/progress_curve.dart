import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../models/vasp_progress.dart';
import '../services/curve_sampling.dart';
import 'app_theme.dart';

String curveNumber(double? value) => value == null
    ? 'NA'
    : value == 0
    ? '0'
    : value.abs() >= 1e7 || value.abs() < 1e-5
    ? value.toStringAsExponential(5)
    : value.toStringAsFixed(6).replaceFirst(RegExp(r'\.?0+$'), '');

class ProgressCurve extends StatefulWidget {
  const ProgressCurve({
    super.key,
    required this.title,
    this.subtitle = '',
    required this.points,
    required this.color,
    required this.unit,
    this.zeroFloor = false,
    this.threshold,
    this.xAxisLabel = '离子步',
  });
  final String title, subtitle, unit;
  final List<ProgressPoint> points;
  final Color color;
  final bool zeroFloor;
  final double? threshold;
  final String xAxisLabel;
  @override
  State<ProgressCurve> createState() => _ProgressCurveState();
}

class _ProgressCurveState extends State<ProgressCurve> {
  int? _selectedIndex;
  late List<ProgressPoint> _sampled;
  ProgressPoint? _latest;
  @override
  void initState() {
    super.initState();
    _prepare();
  }

  @override
  void didUpdateWidget(ProgressCurve oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.points != widget.points) _prepare();
  }

  void _prepare() {
    _sampled = sampleCurve(widget.points);
    _latest = widget.points.reversed
        .where((p) => p.value != null && p.value!.isFinite)
        .firstOrNull;
    _selectedIndex = null;
  }

  void _select(double x, double width) {
    if (widget.points.isEmpty) return;
    final first = widget.points.first.step, last = widget.points.last.step;
    final target =
        first +
        ((x - 76) / math.max(1, width - 90)).clamp(0, 1) * (last - first);
    var lo = 0, hi = widget.points.length - 1;
    while (lo < hi) {
      final mid = (lo + hi) ~/ 2;
      if (widget.points[mid].step < target) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    if (lo > 0 &&
        (widget.points[lo - 1].step - target).abs() <
            (widget.points[lo].step - target).abs()) {
      lo--;
    }
    if (_selectedIndex != lo) setState(() => _selectedIndex = lo);
  }

  @override
  Widget build(BuildContext context) {
    final selected = _selectedIndex == null
        ? _latest
        : widget.points[_selectedIndex!];
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              widget.title,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            if (widget.subtitle.isNotEmpty)
              Text(
                widget.subtitle,
                style: TextStyle(fontSize: 11, color: context.muted),
              ),
            if (_latest == null)
              const SizedBox(
                height: 150,
                child: Center(child: Text('暂无完整有效数据')),
              )
            else ...[
              SizedBox(
                height: 156,
                child: LayoutBuilder(
                  builder: (context, constraints) => GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTapDown: (e) =>
                        _select(e.localPosition.dx, constraints.maxWidth),
                    onPanUpdate: (e) =>
                        _select(e.localPosition.dx, constraints.maxWidth),
                    child: RepaintBoundary(
                      child: CustomPaint(
                        key: const ValueKey('progress-curve-canvas'),
                        size: Size.infinite,
                        painter: _CurvePainter(
                          _sampled,
                          selected,
                          widget.color,
                          context.muted,
                          Theme.of(context).colorScheme.outlineVariant,
                          widget.zeroFloor,
                          widget.threshold,
                          widget.xAxisLabel,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              Text(
                '第 ${selected?.step ?? '—'} 步 · ${curveNumber(selected?.value)} ${widget.unit}',
                style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _CurvePainter extends CustomPainter {
  _CurvePainter(
    this.points,
    this.selected,
    this.color,
    this.textColor,
    this.gridColor,
    this.zeroFloor,
    this.threshold,
    this.xAxisLabel,
  );
  final List<ProgressPoint> points;
  final ProgressPoint? selected;
  final Color color, textColor, gridColor;
  final bool zeroFloor;
  final double? threshold;
  final String xAxisLabel;
  @override
  void paint(Canvas canvas, Size size) {
    final valid = points.where((p) => p.value != null && p.value!.isFinite);
    if (valid.isEmpty || size.width <= 100) return;
    var low = valid.first.value!, high = low;
    for (final point in valid) {
      low = math.min(low, point.value!);
      high = math.max(high, point.value!);
    }
    if (threshold != null) {
      low = math.min(low, threshold!);
      high = math.max(high, threshold!);
    }
    final padding = high == low
        ? math.max(low.abs() * 1e-6, 0.001)
        : (high - low) * .08;
    low -= padding;
    high += padding;
    if (zeroFloor) low = math.max(0, low);
    if (!low.isFinite || !high.isFinite || !(high - low).isFinite) return;
    final rect = Rect.fromLTRB(76, 12, size.width - 14, size.height - 34);
    final first = points.first.step, last = points.last.step;
    double x(int step) => first == last
        ? rect.center.dx
        : rect.left + (step - first) / (last - first) * rect.width;
    double y(double value) =>
        rect.bottom - (value - low) / (high - low) * rect.height;
    void label(
      String value,
      Offset position, {
      bool right = false,
      bool center = false,
    }) {
      final text = TextPainter(
        text: TextSpan(
          text: value,
          style: TextStyle(color: textColor, fontSize: 9),
        ),
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: right ? 74 : 150);
      text.paint(
        canvas,
        Offset(
          position.dx -
              (right
                  ? text.width
                  : center
                  ? text.width / 2
                  : 0),
          position.dy,
        ),
      );
    }

    final grid = Paint()
      ..color = gridColor
      ..strokeWidth = .7;
    for (var i = 0; i < 3; i++) {
      final value = low + (high - low) * i / 2;
      canvas.drawLine(
        Offset(rect.left, y(value)),
        Offset(rect.right, y(value)),
        grid,
      );
      label(
        curveNumber(value),
        Offset(rect.left - 5, y(value) - 6),
        right: true,
      );
    }
    final steps = {first, ((first + last) / 2).round(), last};
    for (final step in steps) {
      label('$step', Offset(x(step), rect.bottom + 4), center: true);
    }
    label(xAxisLabel, Offset(rect.center.dx, rect.bottom + 18), center: true);
    if (threshold != null) {
      final paint = Paint()
        ..color = textColor.withValues(alpha: .8)
        ..strokeWidth = 1;
      for (var dx = rect.left; dx < rect.right; dx += 8) {
        canvas.drawLine(
          Offset(dx, y(threshold!)),
          Offset(math.min(dx + 4, rect.right), y(threshold!)),
          paint,
        );
      }
    }
    final path = Path();
    var started = false;
    for (final point in points) {
      final value = point.value;
      if (value == null || !value.isFinite) {
        started = false;
        continue;
      }
      if (started) {
        path.lineTo(x(point.step), y(value));
      } else {
        path.moveTo(x(point.step), y(value));
        started = true;
      }
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..strokeWidth = 1.8
        ..style = PaintingStyle.stroke,
    );
    final dot = Paint()..color = color;
    if (points.length <= 80) {
      for (final point in valid) {
        canvas.drawCircle(Offset(x(point.step), y(point.value!)), 2.2, dot);
      }
    }
    if (selected?.value != null) {
      final center = Offset(x(selected!.step), y(selected!.value!));
      canvas.drawCircle(
        center,
        5,
        Paint()..color = color.withValues(alpha: .2),
      );
      canvas.drawCircle(center, 3, dot);
    }
  }

  @override
  bool shouldRepaint(covariant _CurvePainter oldDelegate) =>
      oldDelegate.points != points ||
      oldDelegate.selected != selected ||
      oldDelegate.color != color ||
      oldDelegate.textColor != textColor ||
      oldDelegate.gridColor != gridColor ||
      oldDelegate.zeroFloor != zeroFloor ||
      oldDelegate.threshold != threshold ||
      oldDelegate.xAxisLabel != xAxisLabel;
}
