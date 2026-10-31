import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slurm_cluster_monitor/ui/atom_constraint_marker.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  Future<(int, int, int)> sample(int mask) async {
    final recorder = ui.PictureRecorder();
    final drawing = Canvas(recorder);
    drawAtomConstraintGlow(drawing, const Offset(32, 32), 16, mask);
    drawing.drawCircle(const Offset(32, 32), 16, Paint()..color = Colors.grey);
    final picture = recorder.endRecording(),
        image = await picture.toImage(64, 64);
    final data = (await image.toByteData(
      format: ui.ImageByteFormat.rawStraightRgba,
    ))!;
    var red = 0;
    for (var i = 0; i < data.lengthInBytes; i += 4) {
      if (data.getUint8(i) > 180 &&
          data.getUint8(i + 1) < 100 &&
          data.getUint8(i + 3) > 10) {
        red++;
      }
    }
    final near = data.getUint8((32 * 64 + 49) * 4 + 3),
        far = data.getUint8((32 * 64 + 55) * 4 + 3);
    image.dispose();
    picture.dispose();
    return (red, near, far);
  }

  test(
    'constraint halo is visible near the atom and fades before becoming distant haze',
    () async {
      expect((await sample(0)).$1, 0);
      final full = await sample(7), partial = await sample(2);
      expect(full.$1, greaterThan(0));
      expect(partial.$1, greaterThan(0));
      // Ensure the visible part outside the opaque atom stays strong enough
      // to distinguish fixed atoms, while remaining softer for partial fixes.
      expect(full.$2, inInclusiveRange(75, 140));
      expect(partial.$2, inInclusiveRange(45, 90));
      expect(full.$2, greaterThan(full.$3));
      expect(full.$3, 0);
      expect(full.$2, greaterThan(partial.$2));
    },
  );
}
