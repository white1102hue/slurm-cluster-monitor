String fileDate(DateTime? value, {bool seconds = false}) {
  if (value == null) return '—';
  final date = value.toLocal();
  String two(int number) => number.toString().padLeft(2, '0');
  final text =
      '${date.year}-${two(date.month)}-${two(date.day)} '
      '${two(date.hour)}:${two(date.minute)}';
  return seconds ? '$text:${two(date.second)}' : text;
}

String fileSize(int? n) => n == null
    ? '—'
    : n >= 1048576
    ? '${(n / 1048576).toStringAsFixed(1)} MB'
    : n >= 1024
    ? '${(n / 1024).toStringAsFixed(1)} KB'
    : '$n B';
