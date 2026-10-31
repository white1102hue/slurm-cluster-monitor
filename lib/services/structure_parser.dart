import 'dart:math' as math;
import '../models/structure.dart';

const _maxAtoms = 5000;

double _number(String raw) {
  final value = double.tryParse(
    raw.replaceAll(RegExp(r'\(\d+\)'), '').replaceAll(RegExp('[dD]'), 'e'),
  );
  if (value == null || !value.isFinite) {
    throw const FormatException('结构中含无效坐标或晶胞参数');
  }
  return value;
}

List<String> _fields(String s) => s.trim().split(RegExp(r'\s+'));
Vec3 _vector(String s) {
  final p = _fields(s);
  if (p.length < 3) throw const FormatException('结构坐标不完整');
  return Vec3(_number(p[0]), _number(p[1]), _number(p[2]));
}

Vec3 _cart(Vec3 f, List<Vec3> cell) =>
    cell[0] * f.x + cell[1] * f.y + cell[2] * f.z;
String _element(String raw) {
  final z = int.tryParse(raw);
  if (z != null && z > 0 && z < elementSymbols.length) return elementSymbols[z];
  final name = RegExp(r'^[A-Za-z]{1,2}').firstMatch(raw)?.group(0) ?? '';
  for (final e in elementSymbols) {
    if (e.toLowerCase() == name.toLowerCase()) return e;
  }
  if (name.length > 1 && elementSymbols.contains(name[0].toUpperCase())) {
    return name[0].toUpperCase();
  }
  return 'X';
}

void _atomCount(int count, {int maximum = _maxAtoms}) {
  if (count <= 0) throw const FormatException('文件中没有可预览的原子');
  if (count > maximum) {
    throw FormatException('原子超过 $maximum 个，请查看原文或在电脑上打开');
  }
}

/// Runs in an isolate. Never evaluates CIF expressions as executable code.
AtomicStructure parseStructure((String, String) input) {
  final (name, text) = input;
  if (text.length > 2 * 1024 * 1024) {
    throw const FormatException('结构文件超过预览大小限制');
  }
  final normalized = text.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
  try {
    final structure = switch (StructureFormat.detect(name)) {
      StructureFormat.poscar => _poscar(normalized),
      StructureFormat.gaussian => _gaussian(normalized),
      StructureFormat.cif => _cif(normalized),
      StructureFormat.xyz => _xyz(normalized),
      null => throw const FormatException('此文件可查看原文，暂不支持结构预览'),
    };
    for (final p in [
      ...structure.atoms.map((a) => a.position),
      ...?structure.cell,
    ]) {
      if ([p.x, p.y, p.z].any((v) => !v.isFinite || v.abs() > 1e9)) {
        throw const FormatException('结构坐标或晶胞超出可预览范围');
      }
    }
    return structure;
  } on RangeError {
    throw const FormatException('结构文件内容不完整，请查看原文');
  }
}

/// Force analysis does not inherit the 5000-atom visualization limit.
AtomicStructure parseVaspForceConstraints(String text) {
  if (text.length > 2 * 1024 * 1024) {
    throw const FormatException('约束文件超过读取大小限制');
  }
  try {
    return _poscar(
      text.replaceAll('\r\n', '\n').replaceAll('\r', '\n'),
      maximumAtoms: 200000,
    );
  } on RangeError {
    throw const FormatException('POSCAR 约束内容不完整');
  }
}

AtomicStructure _poscar(String text, {int maximumAtoms = _maxAtoms}) {
  final lines = text.trimRight().split('\n');
  final scales = _fields(lines[1]).map(_number).toList();
  if (scales.length != 1 && scales.length != 3) {
    throw const FormatException('POSCAR 缩放因子须为 1 个或 3 个数');
  }
  var cell = [for (var i = 2; i < 5; i++) _vector(lines[i])];
  final volume = cell[0].dot(cell[1].cross(cell[2])).abs();
  if (volume < 1e-10) throw const FormatException('POSCAR 晶胞体积为零');
  double sx, sy, sz;
  if (scales.length == 1) {
    final s = scales.single;
    if (s == 0) throw const FormatException('POSCAR 缩放因子不能为零');
    sx = sy = sz = s < 0 ? math.pow(-s / volume, 1 / 3).toDouble() : s;
  } else {
    if (scales.any((s) => s <= 0)) throw const FormatException('三个缩放因子须为正数');
    sx = scales[0];
    sy = scales[1];
    sz = scales[2];
  }
  Vec3 scale(Vec3 v) => Vec3(v.x * sx, v.y * sy, v.z * sz);
  cell = cell.map(scale).toList();
  var index = 5;
  var symbols = _fields(lines[index]);
  final notes = <String>[];
  if (symbols.every((s) => int.tryParse(s) != null)) {
    final inferred = _fields(lines.first);
    symbols =
        inferred.length == symbols.length &&
            inferred.every(elementSymbols.contains)
        ? inferred
        : List.filled(symbols.length, 'X');
    if (symbols.contains('X')) notes.add('VASP 4 文件未标明元素，以 X 显示；原子坐标保持原值');
  } else {
    index++;
  }
  final counts = _fields(lines[index++]).map(int.tryParse).toList();
  if (counts.length != symbols.length ||
      counts.any((n) => n == null || n < 0)) {
    throw const FormatException('POSCAR 元素和原子数不匹配');
  }
  final count = counts.fold(0, (a, b) => a + b!);
  _atomCount(count, maximum: maximumAtoms);
  final selective = lines[index].trim().toLowerCase().startsWith('s');
  if (selective) index++;
  final mode = lines[index++].trim().toLowerCase();
  final direct = mode.startsWith('d');
  if (!direct && !mode.startsWith('c') && !mode.startsWith('k')) {
    throw const FormatException('POSCAR 坐标类型应为 Direct 或 Cartesian');
  }
  final atoms = <StructureAtom>[];
  for (var species = 0; species < symbols.length; species++) {
    for (var j = 0; j < counts[species]!; j++) {
      final row = _fields(lines[index++]);
      final p = _vector(row.join(' '));
      var fixedAxes = 0;
      if (selective) {
        if (row.length < 6) {
          throw const FormatException('Selective dynamics 原子缺少 T/F 固定标记，请查看原文');
        }
        for (var axis = 0; axis < 3; axis++) {
          final flag = row[axis + 3].toLowerCase();
          if (const {'f', '.f.', 'false', '.false.'}.contains(flag)) {
            fixedAxes |= 1 << axis;
          } else if (!const {'t', '.t.', 'true', '.true.'}.contains(flag)) {
            throw const FormatException('Selective dynamics 固定标记无效，请查看原文');
          }
        }
      }
      atoms.add(
        StructureAtom(
          _element(symbols[species]),
          direct ? _cart(p, cell) : scale(p),
          fixedAxes: fixedAxes,
        ),
      );
    }
  }
  return AtomicStructure(
    title: lines.first,
    atoms: atoms,
    cell: cell,
    notes: notes,
  );
}

AtomicStructure _xyz(String text) {
  final lines = text.split('\n');
  final count = int.tryParse(lines.first.trim()) ?? 0;
  _atomCount(count);
  final atoms = <StructureAtom>[];
  for (var i = 2; i < count + 2; i++) {
    final p = _fields(lines[i]);
    atoms.add(StructureAtom(_element(p[0]), _vector(p.skip(1).join(' '))));
  }
  return AtomicStructure(title: lines[1], atoms: atoms);
}

AtomicStructure _gaussian(String text) {
  final lines = text.split('\n');
  var index = lines.indexWhere((s) => s.trimLeft().startsWith('#'));
  if (index < 0) throw const FormatException('GJF 缺少计算指令行');
  final route = <String>[];
  while (index < lines.length && lines[index].trim().isNotEmpty) {
    route.add(lines[index++]);
  }
  while (index < lines.length && lines[index].trim().isEmpty) {
    index++;
  }
  final title = index < lines.length ? lines[index] : '';
  while (index < lines.length && lines[index].trim().isNotEmpty) {
    index++;
  }
  while (index < lines.length && lines[index].trim().isEmpty) {
    index++;
  }
  if (index >= lines.length ||
      !RegExp(
        r'^\s*[+-]?\d+\s+\d+(?:\s+[+-]?\d+\s+\d+)*\s*$',
      ).hasMatch(lines[index++])) {
    throw const FormatException('GJF 中没有显式几何坐标，请查看原文');
  }
  final bohr = RegExp(
    r'units\s*=\s*\(?\s*(bohr|au)\b',
    caseSensitive: false,
  ).hasMatch(route.join(' '));
  final atoms = <StructureAtom>[];
  while (index < lines.length && lines[index].trim().isNotEmpty) {
    final line = lines[index++]
        .replaceAll(RegExp(r'\([^)]*\)'), '')
        .replaceAll(',', ' ');
    final p = _fields(line);
    if (p.length != 4 && p.length != 5) {
      throw const FormatException('此 GJF 使用 Z 矩阵或混合坐标；目前可查看原文');
    }
    final start = p.length == 5 ? 2 : 1;
    if (start == 2 && int.tryParse(p[1]) == null) {
      throw const FormatException('GJF 坐标格式不受支持');
    }
    final pos =
        _vector(p.skip(start).join(' ')) * (bohr ? 0.529177210903 : 1.0);
    atoms.add(StructureAtom(_element(p[0]), pos));
    if (atoms.length > _maxAtoms) _atomCount(atoms.length);
  }
  _atomCount(atoms.length);
  return AtomicStructure(title: title, atoms: atoms);
}

class _Token {
  const _Token(this.value, [this.quoted = false]);
  final String value;
  final bool quoted;
  bool get reserved =>
      !quoted &&
      (value.startsWith('_') ||
          RegExp(
            r'^(loop_|stop_|data_|save_|global_)',
            caseSensitive: false,
          ).hasMatch(value));
}

List<_Token> _tokens(String text) {
  final out = <_Token>[];
  var i = 0;
  while (i < text.length) {
    final c = text[i];
    if (RegExp(r'\s').hasMatch(c)) {
      i++;
      continue;
    }
    if (c == '#') {
      while (i < text.length && text[i] != '\n') {
        i++;
      }
      continue;
    }
    if (c == ';' && (i == 0 || text[i - 1] == '\n')) {
      final end = text.indexOf('\n;', i + 1);
      if (end < 0) throw const FormatException('CIF 多行文本未闭合');
      out.add(_Token(text.substring(i + 1, end), true));
      i = end + 2;
    } else if (c == "'" || c == '"') {
      final start = ++i;
      while (i < text.length &&
          !(text[i] == c &&
              (i + 1 == text.length || RegExp(r'\s').hasMatch(text[i + 1])))) {
        i++;
      }
      if (i == text.length) throw const FormatException('CIF 引号未闭合');
      out.add(_Token(text.substring(start, i++), true));
    } else {
      final start = i;
      while (i < text.length && !RegExp(r'\s').hasMatch(text[i])) {
        i++;
      }
      out.add(_Token(text.substring(start, i)));
    }
    if (out.length > 250000) throw const FormatException('CIF 数据量超过预览限制');
  }
  return out;
}

List<Vec3> _cell(Map<String, String> tags) {
  double get(String name) => _number(tags['_cell_$name'] ?? '?');
  final a = get('length_a'), b = get('length_b'), c = get('length_c');
  final alpha = get('angle_alpha') * math.pi / 180;
  final beta = get('angle_beta') * math.pi / 180;
  final gamma = get('angle_gamma') * math.pi / 180;
  if ([a, b, c].any((v) => v <= 0) ||
      [alpha, beta, gamma].any((v) => v <= 0 || v >= math.pi)) {
    throw const FormatException('CIF 晶胞参数无效');
  }
  final cy =
      c *
      (math.cos(alpha) - math.cos(beta) * math.cos(gamma)) /
      math.sin(gamma);
  final cz2 = c * c - math.pow(c * math.cos(beta), 2) - cy * cy;
  if (cz2 <= 1e-10) throw const FormatException('CIF 晶胞体积无效');
  return [
    Vec3(a, 0, 0),
    Vec3(b * math.cos(gamma), b * math.sin(gamma), 0),
    Vec3(c * math.cos(beta), cy, math.sqrt(cz2)),
  ];
}

double _symmetryAxis(String expression, Vec3 p) {
  final clean = expression.toLowerCase().replaceAll(' ', '');
  final terms = RegExp(
    r'[+-]?[^+-]+',
  ).allMatches(clean).map((m) => m[0]!).toList();
  if (terms.isEmpty || terms.join() != clean) {
    throw const FormatException('CIF 对称操作格式不受支持');
  }
  var result = 0.0;
  for (var t in terms) {
    final sign = t.startsWith('-') ? -1.0 : 1.0;
    if (t.startsWith('-') || t.startsWith('+')) t = t.substring(1);
    final variable = RegExp(
      r'^(?:(\d+(?:\.\d+)?)\*?)?([xyz])(?:/(\d+))?$',
    ).firstMatch(t);
    if (variable != null) {
      final base = switch (variable[2]) {
        'x' => p.x,
        'y' => p.y,
        _ => p.z,
      };
      result +=
          sign *
          _number(variable[1] ?? '1') *
          base /
          _number(variable[3] ?? '1');
    } else {
      final f = t.split('/');
      if (f.length > 2) throw const FormatException('CIF 对称操作格式不受支持');
      result += sign * _number(f[0]) / (f.length == 2 ? _number(f[1]) : 1);
    }
  }
  if (!result.isFinite) throw const FormatException('CIF 对称操作无效');
  return result;
}

AtomicStructure _cif(String text) {
  final tokens = _tokens(text);
  final tags = <String, String>{};
  final loops = <(List<String>, List<String>)>[];
  var title = '', started = false;
  String key(String s) => s.toLowerCase().replaceAll('.', '_');
  var i = 0;
  while (i < tokens.length) {
    final t = tokens[i++];
    if (!t.quoted && t.value.toLowerCase().startsWith('data_')) {
      if (started) break;
      title = t.value.substring(5);
      started = true;
    } else if (!t.quoted && t.value.toLowerCase() == 'loop_') {
      final keys = <String>[], values = <String>[];
      while (i < tokens.length &&
          !tokens[i].quoted &&
          tokens[i].value.startsWith('_')) {
        keys.add(key(tokens[i++].value));
      }
      while (i < tokens.length && !tokens[i].reserved) {
        values.add(tokens[i++].value);
      }
      if (keys.isEmpty || values.length % keys.length != 0) {
        throw const FormatException('CIF 循环表格不完整');
      }
      loops.add((keys, values));
    } else if (!t.quoted && t.value.startsWith('_')) {
      if (i == tokens.length || tokens[i].reserved) {
        throw const FormatException('CIF 数据项缺少数值');
      }
      tags[key(t.value)] = tokens[i++].value;
    }
  }
  final notes = <String>[];
  final operations = <String>[];
  final sites = <(String, Vec3, bool)>[];
  for (final (keys, values) in loops) {
    final sym = keys.indexWhere(
      (s) =>
          s == '_space_group_symop_operation_xyz' ||
          s == '_symmetry_equiv_pos_as_xyz',
    );
    if (sym >= 0) {
      for (var n = sym; n < values.length; n += keys.length) {
        operations.add(values[n]);
      }
    }
    final fx = keys.indexOf('_atom_site_fract_x'),
        cx = keys.indexOf('_atom_site_cartn_x');
    final fractional = fx >= 0;
    final x = fractional ? fx : cx;
    if (x < 0) continue;
    final y = keys.indexOf(
      fractional ? '_atom_site_fract_y' : '_atom_site_cartn_y',
    );
    final z = keys.indexOf(
      fractional ? '_atom_site_fract_z' : '_atom_site_cartn_z',
    );
    final symbol = keys.indexOf('_atom_site_type_symbol');
    final label = symbol >= 0 ? symbol : keys.indexOf('_atom_site_label');
    final occupancy = keys.indexOf('_atom_site_occupancy');
    if (y < 0 || z < 0 || label < 0) {
      throw const FormatException('CIF 原子表格缺少元素或坐标');
    }
    for (var n = 0; n < values.length; n += keys.length) {
      if (occupancy >= 0 &&
          values[n + occupancy] != '?' &&
          values[n + occupancy] != '.') {
        final occ = _number(values[n + occupancy]);
        if (occ <= 0) continue;
        if (occ < 1 && !notes.contains('含部分占据位点，按文件坐标显示')) {
          notes.add('含部分占据位点，按文件坐标显示');
        }
      }
      sites.add((
        _element(values[n + label]),
        Vec3(
          _number(values[n + x]),
          _number(values[n + y]),
          _number(values[n + z]),
        ),
        fractional,
      ));
      _atomCount(sites.length);
    }
  }
  if (operations.isEmpty) {
    final op =
        tags['_space_group_symop_operation_xyz'] ??
        tags['_symmetry_equiv_pos_as_xyz'];
    if (op != null) operations.add(op);
  }
  final cell = tags.containsKey('_cell_length_a') ? _cell(tags) : null;
  if (sites.any((s) => s.$3) && cell == null) {
    throw const FormatException('CIF 分数坐标缺少晶胞参数');
  }
  if (operations.length > 384) throw const FormatException('CIF 对称操作过多，暂不支持预览');
  if (operations.isEmpty) {
    operations.add('x,y,z');
    final sg =
        tags['_space_group_it_number'] ?? tags['_symmetry_int_tables_number'];
    if (sites.any((s) => s.$3) && sg != '1') notes.add('未提供对称操作，仅显示文件中的原子位点');
  }
  final atoms = <StructureAtom>[], seen = <String>{};
  for (final (symbol, p, fractional) in sites) {
    if (!fractional) {
      atoms.add(StructureAtom(symbol, p));
      continue;
    }
    for (final op in operations) {
      final axes = op.split(',');
      if (axes.length != 3) throw const FormatException('CIF 对称操作须有三个分量');
      double wrap(double v) {
        final n = v - v.floor();
        return n > 1 - 1e-6 || n < 1e-6 ? 0 : n;
      }

      final f = Vec3(
        wrap(_symmetryAxis(axes[0], p)),
        wrap(_symmetryAxis(axes[1], p)),
        wrap(_symmetryAxis(axes[2], p)),
      );
      final id =
          '$symbol:${(f.x * 1e5).round()},${(f.y * 1e5).round()},${(f.z * 1e5).round()}';
      if (seen.add(id)) atoms.add(StructureAtom(symbol, _cart(f, cell!)));
      _atomCount(atoms.length);
    }
  }
  _atomCount(atoms.length);
  return AtomicStructure(title: title, atoms: atoms, cell: cell, notes: notes);
}
