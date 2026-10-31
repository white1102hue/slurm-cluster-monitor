class RemoteFileMatch {
  const RemoteFileMatch(this.path, {this.size, this.modified});
  final String path;
  final int? size;
  final DateTime? modified;
}

class RemoteOutputSearch {
  const RemoteOutputSearch({
    this.outcar,
    this.gaussian = const [],
    this.matched = 0,
    this.complete = true,
    this.warnings = const [],
  });
  final RemoteFileMatch? outcar;
  final List<RemoteFileMatch> gaussian;
  final int matched;
  final bool complete;
  final List<String> warnings;
}

/// Keep one OUTCAR and a short Gaussian fallback list, not the entire tree.
class OutputSearchAccumulator {
  RemoteFileMatch? outcar;
  final gaussian = <RemoteFileMatch>[];
  int matched = 0;
  bool malformed = false;
  String _pending = '';

  static int compare(RemoteFileMatch a, RemoteFileMatch b) {
    final time = (b.modified?.microsecondsSinceEpoch ?? -1).compareTo(
      a.modified?.microsecondsSinceEpoch ?? -1,
    );
    return time != 0 ? time : a.path.compareTo(b.path);
  }

  void add(RemoteFileMatch file) {
    matched++;
    final name = file.path.split('/').last.toLowerCase();
    if (name == 'outcar') {
      if (outcar == null || compare(file, outcar!) < 0) outcar = file;
    } else if (name.endsWith('.log') || name.endsWith('.out')) {
      gaussian.add(file);
      gaussian.sort(compare);
      if (gaussian.length > 12) gaussian.removeLast();
    }
  }

  /// GNU find's NUL-terminated timestamp/size/path records are safe for spaces, tabs,
  /// quotes, Unicode and embedded newlines in filenames.
  void addFindText(String text) {
    _pending += text;
    var end = _pending.indexOf('\x00');
    while (end >= 0) {
      final row = _pending.substring(0, end);
      _pending = _pending.substring(end + 1);
      final first = row.indexOf('\t'),
          second = row.indexOf('\t', row.indexOf('\t') + 1);
      final seconds = first < 0
          ? null
          : double.tryParse(row.substring(0, first).split('\n').last.trim());
      final size = second < 0
          ? null
          : int.tryParse(row.substring(first + 1, second));
      if (first <= 0 ||
          second <= first ||
          seconds == null ||
          !seconds.isFinite ||
          seconds.abs() > 8e12 ||
          size == null ||
          size < 0 ||
          !row.substring(second + 1).startsWith('/')) {
        malformed = true;
      } else {
        add(
          RemoteFileMatch(
            row.substring(second + 1),
            size: size,
            modified: DateTime.fromMicrosecondsSinceEpoch(
              (seconds * 1000000).round(),
              isUtc: true,
            ),
          ),
        );
      }
      end = _pending.indexOf('\x00');
    }
    if (_pending.length > 65536) {
      malformed = true;
      _pending = '';
    }
  }

  RemoteOutputSearch finish({
    bool complete = true,
    List<String> warnings = const [],
  }) => RemoteOutputSearch(
    outcar: outcar,
    gaussian: List.unmodifiable(gaussian),
    matched: matched,
    complete: complete && !malformed && _pending.isEmpty,
    warnings: [
      ...warnings,
      if (malformed || _pending.isNotEmpty) '部分输出元数据无效，已保留可读取的结果。',
    ],
  );
}
