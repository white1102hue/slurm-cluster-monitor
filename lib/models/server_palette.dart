// Stable across app restarts, server filters, Dart and Android widget rendering.
const serverPalette = <int>[
  0xFF6289C6,
  0xFF5C9E87,
  0xFFAC81B9,
  0xFFC19B55,
  0xFFC47F88,
  0xFF659DAA,
  0xFF8C98BD,
  0xFF9B9B67,
];

int serverColorValue(String id) {
  var hash = 0;
  for (final code in id.codeUnits) {
    hash = (hash * 31 + code) & 0x7fffffff;
  }
  return serverPalette[hash % serverPalette.length];
}

/// Resolve collisions against the full enabled server set, before filtering.
/// Sorted IDs make the app, foreground service and widget use the same map.
Map<String, int> buildServerColors(Iterable<String> serverIds) {
  final ids = serverIds.toSet().toList()..sort();
  final result = <String, int>{}, used = <int>{};
  for (final id in ids) {
    final preferred = serverColorValue(id);
    final start = serverPalette.indexOf(preferred);
    var color = preferred;
    for (var offset = 0; offset < serverPalette.length; offset++) {
      color = serverPalette[(start + offset) % serverPalette.length];
      if (!used.contains(color)) break;
    }
    while (used.contains(color)) {
      color = 0xff000000 | ((color + 0x000b17) & 0x00ffffff);
    }
    used.add(color);
    result[id] = color;
  }
  return Map.unmodifiable(result);
}
