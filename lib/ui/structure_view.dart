import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../models/structure.dart';
import '../services/structure_scene.dart';
import 'app_theme.dart';
import 'atom_constraint_marker.dart';
import 'atom_labels.dart';
import 'jmol_colors.dart';

class StructureView extends StatefulWidget {
  const StructureView({super.key, required this.structure});
  final AtomicStructure structure;
  @override
  State<StructureView> createState() => _StructureViewState();
}

class _StructureViewState extends State<StructureView> {
  double _yaw = 0, _pitch = 0, _zoom = 1, _startZoom = 1;
  Offset _last = Offset.zero;
  bool _cell = true, _bonds = true, _free = false, _busy = false;
  var _viewpoint = StructureViewpoint.isometric;
  var _display = const CellDisplay();
  var _labels = AtomLabelMode.off;
  late var _scene = buildStructureScene((widget.structure, _display));
  @override
  void didUpdateWidget(StructureView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.structure != widget.structure) {
      _display = const CellDisplay();
      _scene = buildStructureScene((widget.structure, _display));
    }
  }

  void _selectView(StructureViewpoint v) => setState(() {
    _viewpoint = v;
    _yaw = 0;
    _pitch = 0;
    _zoom = 1;
    _free = false;
  });
  Future<void> _settings() async {
    var mode = _display.mode,
        nx = _display.nx,
        ny = _display.ny,
        nz = _display.nz;
    var boundaries = _display.boundaries;
    final options = await showModalBottomSheet<CellDisplay>(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      builder: (context) => StatefulBuilder(
        builder: (context, setLocal) => Padding(
          padding: EdgeInsets.fromLTRB(
            20,
            20,
            20,
            20 + MediaQuery.viewPaddingOf(context).bottom,
          ),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('晶胞显示', style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 12),
                for (final item in const [
                  (CellDisplayMode.original, '原始晶胞', '保留文件中的原子坐标和晶胞'),
                  (CellDisplayMode.inside, '胞内原子', '将周期坐标归入一个晶胞'),
                  (CellDisplayMode.boundary, '边界补全', '补显示晶胞边缘及邻胞 10% 范围的周期像'),
                  (CellDisplayMode.supercell, '超胞', '沿 a、b、c 方向重复显示'),
                ])
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(
                      mode == item.$1
                          ? Icons.radio_button_checked
                          : Icons.radio_button_off,
                      color: mode == item.$1
                          ? Theme.of(context).colorScheme.primary
                          : context.muted,
                    ),
                    title: Text(item.$2),
                    subtitle: Text(item.$3),
                    onTap: () => setLocal(() => mode = item.$1),
                  ),
                if (mode == CellDisplayMode.supercell) ...[
                  Row(
                    children: [
                      for (final pair in [('a', nx), ('b', ny), ('c', nz)])
                        Expanded(
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Text('${pair.$1} × '),
                              DropdownButton<int>(
                                value: pair.$2,
                                items: [
                                  for (var i = 1; i <= 4; i++)
                                    DropdownMenuItem(
                                      value: i,
                                      child: Text('$i'),
                                    ),
                                ],
                                onChanged: (n) => setLocal(() {
                                  if (pair.$1 == 'a') {
                                    nx = n!;
                                  } else if (pair.$1 == 'b') {
                                    ny = n!;
                                  } else {
                                    nz = n!;
                                  }
                                }),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('补全外边界原子'),
                    value: boundaries,
                    onChanged: (v) => setLocal(() => boundaries = v),
                  ),
                ],
                const SizedBox(height: 12),
                FilledButton(
                  onPressed: () => Navigator.pop(
                    context,
                    CellDisplay(
                      mode: mode,
                      nx: nx,
                      ny: ny,
                      nz: nz,
                      boundaries: boundaries,
                    ),
                  ),
                  child: const Text('应用显示'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    if (options == null || !mounted) return;
    setState(() => _busy = true);
    try {
      final scene = await compute(buildStructureScene, (
        widget.structure,
        options,
      ));
      if (mounted) {
        setState(() {
          _scene = scene;
          _display = options;
          _zoom = 1;
        });
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(e is FormatException ? e.message : '无法生成此显示，请减小超胞倍数'),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final structure = widget.structure;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
          child: Wrap(
            spacing: 12,
            runSpacing: 4,
            alignment: WrapAlignment.center,
            children: [
              Text(
                '${structure.atoms.length} 原子',
                style: TextStyle(color: context.muted),
              ),
              if (_display.mode != CellDisplayMode.original)
                Text(
                  '显示 ${_scene.atoms.length}',
                  style: TextStyle(color: context.muted),
                ),
              Text(
                structure.composition.entries
                    .map((e) => '${e.key}${e.value == 1 ? '' : e.value}')
                    .join(' '),
              ),
              if (structure.atoms.any((a) => a.isConstrained))
                ConstraintLegend(
                  full: structure.atoms.where((a) => a.isFullyFixed).length,
                  partial: structure.atoms
                      .where((a) => a.isConstrained && !a.isFullyFixed)
                      .length,
                ),
            ],
          ),
        ),
        Expanded(
          child: Stack(
            children: [
              Semantics(
                label: '三维结构，拖动旋转，双指缩放',
                child: GestureDetector(
                  onDoubleTap: () => _selectView(_viewpoint),
                  onScaleStart: (d) {
                    _last = d.focalPoint;
                    _startZoom = _zoom;
                  },
                  onScaleUpdate: (d) => setState(() {
                    final delta = d.focalPoint - _last;
                    if (d.pointerCount == 1) {
                      _yaw += delta.dx * .012;
                      _pitch += delta.dy * .012;
                      _free = true;
                    }
                    _zoom = (_startZoom * d.scale).clamp(.25, 5.0);
                    _last = d.focalPoint;
                  }),
                  child: CustomPaint(
                    painter: _StructurePainter(
                      _scene,
                      structure.cell,
                      structureCamera(_viewpoint, structure.cell),
                      _bonds,
                      _yaw,
                      _pitch,
                      _zoom,
                      _cell,
                      context.muted,
                      _labels,
                    ),
                    child: const SizedBox.expand(),
                  ),
                ),
              ),
              if (_busy) const Center(child: CircularProgressIndicator()),
            ],
          ),
        ),
        if (structure.notes.isNotEmpty || _scene.note != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Text(
              [
                ...structure.notes,
                if (_scene.note != null) _scene.note!,
              ].join('\n'),
              style: TextStyle(fontSize: 11, color: context.muted),
            ),
          ),
        ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 156),
          child: SingleChildScrollView(
            child: Column(
              children: [
                Wrap(
                  spacing: 8,
                  alignment: WrapAlignment.center,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    PopupMenuButton<StructureViewpoint>(
                      tooltip: '切换视角',
                      initialValue: _viewpoint,
                      onSelected: _selectView,
                      itemBuilder: (_) => [
                        for (final v in StructureViewpoint.values)
                          if (structure.cell != null ||
                              [
                                StructureViewpoint.isometric,
                                StructureViewpoint.x,
                                StructureViewpoint.y,
                                StructureViewpoint.z,
                              ].contains(v))
                            PopupMenuItem(value: v, child: Text(v.label)),
                      ],
                      child: Chip(
                        avatar: const Icon(Icons.explore_outlined, size: 18),
                        label: Text(_free ? '自由' : _viewpoint.label),
                      ),
                    ),
                    PopupMenuButton<AtomLabelMode>(
                      tooltip: '原子标签',
                      initialValue: _labels,
                      onSelected: (value) => setState(() => _labels = value),
                      itemBuilder: (_) => [
                        for (final mode in AtomLabelMode.values)
                          PopupMenuItem(value: mode, child: Text(mode.label)),
                      ],
                      child: Chip(
                        avatar: const Icon(Icons.label_outline, size: 18),
                        label: Text(_labels.label),
                      ),
                    ),
                    if (structure.cell != null)
                      ActionChip(
                        avatar: const Icon(Icons.grid_view_outlined, size: 18),
                        label: Text(_display.label),
                        onPressed: _busy ? null : _settings,
                        tooltip: '晶胞显示',
                      ),
                  ],
                ),
                Wrap(
                  spacing: 4,
                  alignment: WrapAlignment.center,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    IconButton(
                      tooltip: '缩小',
                      onPressed: () =>
                          setState(() => _zoom = (_zoom / 1.2).clamp(.25, 5.0)),
                      icon: const Icon(Icons.remove),
                    ),
                    IconButton(
                      tooltip: '重置视角',
                      onPressed: () =>
                          _selectView(StructureViewpoint.isometric),
                      icon: const Icon(Icons.center_focus_strong),
                    ),
                    IconButton(
                      tooltip: '放大',
                      onPressed: () =>
                          setState(() => _zoom = (_zoom * 1.2).clamp(.25, 5.0)),
                      icon: const Icon(Icons.add),
                    ),
                    if (structure.cell != null)
                      FilterChip(
                        label: const Text('晶胞'),
                        selected: _cell,
                        onSelected: (v) => setState(() => _cell = v),
                      ),
                    FilterChip(
                      label: const Text('连线'),
                      selected: _bonds,
                      onSelected: (v) => setState(() => _bonds = v),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 8),
      ],
    );
  }
}

class _StructurePainter extends CustomPainter {
  _StructurePainter(
    this.scene,
    this.axes,
    this.frame,
    this.bonds,
    this.yaw,
    this.pitch,
    this.zoom,
    this.showCell,
    this.lineColor,
    this.labels,
  );
  final StructureScene scene;
  final List<Vec3>? axes;
  final CameraFrame frame;
  final bool bonds, showCell;
  final double yaw, pitch, zoom;
  final Color lineColor;
  final AtomLabelMode labels;
  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty || scene.atoms.isEmpty) return;
    final center = scene.center;
    final scale = math.min(size.width, size.height) * .78 / scene.span * zoom;
    final cy = math.cos(yaw),
        sy = math.sin(yaw),
        cp = math.cos(pitch),
        sp = math.sin(pitch);
    Vec3 rotateVector(Vec3 v) {
      v = frame.project(v);
      final x = v.x * cy + v.z * sy, z = -v.x * sy + v.z * cy;
      return Vec3(x, v.y * cp - z * sp, v.y * sp + z * cp);
    }

    Vec3 rotate(Vec3 v) => rotateVector(v - center);
    Offset project(Vec3 p) =>
        Offset(size.width / 2 + p.x * scale, size.height / 2 - p.y * scale);
    final points = scene.atoms.map((a) => rotate(a.position)).toList();
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    if (showCell) {
      final paint = Paint()
        ..color = lineColor.withValues(alpha: .4)
        ..strokeWidth = 1;
      for (final corners in scene.cells) {
        for (var i = 0; i < corners.length; i++) {
          for (final bit in [1, 2, 4]) {
            if ((i & bit) == 0) {
              canvas.drawLine(
                project(rotate(corners[i])),
                project(rotate(corners[i | bit])),
                paint,
              );
            }
          }
        }
      }
    }
    if (bonds) {
      final paint = Paint()
        ..color = lineColor.withValues(alpha: .5)
        ..strokeWidth = (scale * .09).clamp(1, 5)
        ..strokeCap = StrokeCap.round;
      for (final (a, b) in scene.links) {
        canvas.drawLine(project(points[a]), project(points[b]), paint);
      }
    }
    final order = List.generate(points.length, (i) => i)
      ..sort((a, b) => points[a].z.compareTo(points[b].z));
    for (final i in order) {
      final atom = scene.atoms[i], p = project(points[i]);
      final r = ((atomRadius(atom.element) * .32 + .15) * scale).clamp(
        2.0,
        50.0,
      );
      final color = jmolColor(atom.element);
      final paint = Paint()
        ..shader = RadialGradient(
          colors: [
            Color.lerp(color, Colors.white, .45)!,
            color,
            Color.lerp(color, Colors.black, .35)!,
          ],
          stops: const [0, .55, 1],
          center: const Alignment(-.35, -.4),
        ).createShader(Rect.fromCircle(center: p, radius: r));
      drawAtomConstraintGlow(canvas, p, r, atom.fixedAxes);
      canvas.drawCircle(p, r, paint);
      canvas.drawCircle(
        p,
        r,
        Paint()
          ..color = lineColor.withValues(alpha: .35)
          ..style = PaintingStyle.stroke
          ..strokeWidth = .6,
      );
      drawAtomLabel(canvas, p, r, atomLabel(atom, labels, i + 1), color);
    }
    final origin = Offset(40, size.height - 40);
    final vectors = axes ?? const [Vec3(1, 0, 0), Vec3(0, 1, 0), Vec3(0, 0, 1)];
    for (var i = 0; i < 3; i++) {
      final p = rotateVector(vectors[i] * (1 / vectors[i].length));
      final end = origin + Offset(p.x * 25, -p.y * 25);
      final color = const [
        Color(0xFFDD6464),
        Color(0xFF45A36D),
        Color(0xFF508AD4),
      ][i];
      canvas.drawLine(
        origin,
        end,
        Paint()
          ..color = color
          ..strokeWidth = 2,
      );
      final text = TextPainter(
        text: TextSpan(
          text: (axes == null ? 'xyz' : 'abc')[i],
          style: TextStyle(color: color, fontSize: 11),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      text.paint(canvas, end + const Offset(2, -5));
      text.dispose();
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_StructurePainter old) {
    bool same(Vec3 a, Vec3 b) => a.x == b.x && a.y == b.y && a.z == b.z;
    final sameAxes =
        axes == null && old.axes == null ||
        axes != null &&
            old.axes != null &&
            axes!.length == old.axes!.length &&
            List.generate(
              axes!.length,
              (i) => same(axes![i], old.axes![i]),
            ).every((v) => v);
    return scene != old.scene ||
        !sameAxes ||
        !same(frame.right, old.frame.right) ||
        !same(frame.up, old.frame.up) ||
        !same(frame.forward, old.frame.forward) ||
        yaw != old.yaw ||
        pitch != old.pitch ||
        zoom != old.zoom ||
        bonds != old.bonds ||
        showCell != old.showCell ||
        labels != old.labels ||
        lineColor != old.lineColor;
  }
}
