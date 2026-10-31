class NodeResources {
  const NodeResources({required this.name, this.totalMemoryMb});
  final String name;
  final double? totalMemoryMb;
  Map<String, dynamic> toJson() => {
    'name': name,
    'totalMemoryMb': totalMemoryMb,
  };
  factory NodeResources.fromJson(Map<String, dynamic> j) => NodeResources(
    name: j['name'] as String,
    totalMemoryMb: (j['totalMemoryMb'] as num?)?.toDouble(),
  );
}

/// Slurm hostlists support comma-separated groups, numeric ranges and padding.
/// Bound expansion and reject invalid names before looking up node capacity.
List<String> expandNodeList(String value, {int limit = 4096}) {
  final result = <String>[];
  void expand(String group) {
    if (result.length >= limit) return;
    final open = group.indexOf('[');
    if (open < 0) {
      if (RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]*$').hasMatch(group)) {
        result.add(group);
      }
      return;
    }
    final close = group.indexOf(']', open);
    if (close < 0) return;
    for (final item in group.substring(open + 1, close).split(',')) {
      final range = RegExp(r'^(\d+)(?:-(\d+))?$').firstMatch(item);
      if (range == null) continue;
      final first = int.tryParse(range[1]!);
      final last = int.tryParse(range[2] ?? range[1]!);
      if (first == null || last == null || last < first) continue;
      for (var i = first; i <= last && result.length < limit; i++) {
        final number = range[1]!.startsWith('0')
            ? '$i'.padLeft(range[1]!.length, '0')
            : '$i';
        expand(
          '${group.substring(0, open)}$number${group.substring(close + 1)}',
        );
      }
    }
  }

  var depth = 0, start = 0;
  for (var i = 0; i < value.length; i++) {
    if (value[i] == '[') depth++;
    if (value[i] == ']') depth--;
    if (value[i] == ',' && depth == 0) {
      expand(value.substring(start, i).trim());
      start = i + 1;
    }
  }
  expand(value.substring(start).trim());
  return result.toSet().toList();
}
