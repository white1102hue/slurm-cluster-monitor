import '../models/gaussian_progress.dart';
import 'gaussian_parser.dart';
import 'remote_files.dart';
import 'remote_lines.dart';

class GaussianService {
  const GaussianService(this.files);
  final RemoteFiles files;
  Future<GaussianProgress> load(
    String path, {
    void Function(int read, int total)? onProgress,
    bool Function()? cancelled,
  }) async {
    final parser = GaussianParser();
    await readRemoteLines(
      files,
      path,
      parser.addLine,
      onProgress: onProgress,
      cancelled: cancelled,
    );
    return parser.result;
  }
}
