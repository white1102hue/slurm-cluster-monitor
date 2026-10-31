import 'dart:convert';
import 'remote_files.dart';

/// Stream without holding a full log in memory; yield to the UI between batches.
Future<void> readRemoteLines(
  RemoteFiles files,
  String path,
  void Function(String) consume, {
  void Function(int read, int total)? onProgress,
  bool Function()? cancelled,
}) async {
  var batch = 0;
  final stream = files.readChunks(
    path,
    onProgress: onProgress,
    cancelled: cancelled,
  );
  await for (final line in const Utf8Decoder(
    allowMalformed: true,
  ).bind(stream).transform(const LineSplitter())) {
    if (cancelled?.call() == true) throw const FileReadCancelled();
    if (line.length > 1024 * 1024) {
      throw const FormatException('文件含超过 1 MB 的单行，无法解析优化进度');
    }
    consume(line);
    if (++batch == 2048) {
      batch = 0;
      await Future<void>.delayed(Duration.zero);
    }
  }
}
