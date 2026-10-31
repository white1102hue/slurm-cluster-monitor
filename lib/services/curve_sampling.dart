import '../models/vasp_progress.dart';

/// Preserve spikes, endpoints and gaps while bounding the canvas workload.
/// Selection still uses the original records, never these display samples.
List<ProgressPoint> sampleCurve(
  List<ProgressPoint> points, {
  int buckets = 512,
}) {
  if (points.length <= buckets * 4) return points;
  final width = (points.length / buckets).ceil();
  final sampled = <ProgressPoint>[];
  for (var start = 0; start < points.length; start += width) {
    final end = (start + width).clamp(0, points.length);
    var min = start, max = start, gap = false;
    for (var i = start; i < end; i++) {
      final value = points[i].value;
      if (value == null || !value.isFinite) {
        gap = true;
        break;
      }
      if (value < points[min].value!) min = i;
      if (value > points[max].value!) max = i;
    }
    if (gap) {
      sampled.add(ProgressPoint(points[start].step, null));
      continue;
    }
    final indices = {start, min, max, end - 1}.toList()..sort();
    sampled.addAll(indices.map((i) => points[i]));
  }
  return sampled;
}
