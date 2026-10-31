import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../models/structure.dart';

enum AtomLabelMode {
  off('无标签'),
  elementAndIndex('元素+序号'),
  indexOnly('仅序号');

  const AtomLabelMode(this.label);
  final String label;
}

String atomLabel(StructureAtom atom, AtomLabelMode mode, int fallback) =>
    switch (mode) {
      AtomLabelMode.off => '',
      AtomLabelMode.elementAndIndex =>
        '${atom.element}${atom.sourceIndex ?? fallback}',
      AtomLabelMode.indexOnly => '${atom.sourceIndex ?? fallback}',
    };

/// Fit labels to the ball and paint them at its projected centre. Painting each
/// label with its atom lets nearer atoms occlude both the ball and its label.
void drawAtomLabel(
  Canvas canvas,
  Offset center,
  double radius,
  String text,
  Color atomColor,
) {
  if (text.isEmpty) return;
  final color = atomColor.computeLuminance() > .4 ? Colors.black : Colors.white;
  final style = TextStyle(
    fontSize: (radius * .9).clamp(9.0, 13.0),
    fontWeight: FontWeight.w600,
  );
  final foreground = TextPainter(
    text: TextSpan(
      text: text,
      style: style.copyWith(color: color),
    ),
    textDirection: TextDirection.ltr,
  )..layout();
  final outline = TextPainter(
    text: TextSpan(
      text: text,
      style: style.copyWith(
        foreground: Paint()
          ..color = (color == Colors.black ? Colors.white : Colors.black)
              .withValues(alpha: .65)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5,
      ),
    ),
    textDirection: TextDirection.ltr,
  )..layout();
  final scale = math.min(
    1.0,
    radius * 1.6 / math.max(foreground.width, foreground.height),
  );
  canvas.save();
  canvas.translate(center.dx, center.dy);
  canvas.scale(scale);
  final offset = Offset(-foreground.width / 2, -foreground.height / 2);
  outline.paint(canvas, offset);
  foreground.paint(canvas, offset);
  canvas.restore();
  outline.dispose();
  foreground.dispose();
}
