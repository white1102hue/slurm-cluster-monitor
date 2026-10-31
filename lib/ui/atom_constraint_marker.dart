import 'package:flutter/material.dart';

const atomConstraintColor = Color(0xFFE53935);

void drawAtomConstraintGlow(
  Canvas canvas,
  Offset center,
  double atomRadius,
  int fixedAxes,
) {
  if (fixedAxes == 0) return;
  final width = (atomRadius * .36).clamp(3.5, 7.0);
  final radius = atomRadius + width;
  final peak = atomRadius / radius;
  final alpha = fixedAxes == 7 ? .56 : .37;
  final paint = Paint()
    ..shader = RadialGradient(
      colors: [
        atomConstraintColor.withValues(alpha: 0),
        atomConstraintColor.withValues(alpha: alpha),
        atomConstraintColor.withValues(alpha: 0),
      ],
      stops: [0, peak, 1],
    ).createShader(Rect.fromCircle(center: center, radius: radius));
  canvas.drawCircle(center, radius, paint);
}

class ConstraintLegend extends StatelessWidget {
  const ConstraintLegend({
    super.key,
    required this.full,
    required this.partial,
  });
  final int full, partial;
  @override
  Widget build(BuildContext context) => Tooltip(
    message: '原子边缘的红色柔光表示固定；完全固定较亮，部分固定较柔。方向按晶格 a/b/c。',
    child: Text(
      [if (full > 0) '固定 $full', if (partial > 0) '部分固定 $partial'].join(' · '),
      style: const TextStyle(fontSize: 11, color: atomConstraintColor),
    ),
  );
}
