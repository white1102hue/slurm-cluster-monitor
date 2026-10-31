import '../models/structure.dart';
import '../models/vasp_progress.dart';
import 'remote_files.dart';
import 'structure_parser.dart';
import 'vasp_progress_parser.dart';
import 'remote_lines.dart';

bool isOutcar(String name) => name.toUpperCase() == 'OUTCAR';

class VaspProgressService {
  const VaspProgressService(this.files);
  final RemoteFiles files;
  Future<VaspProgress> load(
    String path, {
    void Function(int read, int total)? onProgress,
    bool Function()? cancelled,
  }) async {
    final directory = remoteParent(path);
    AtomicStructure? structure;
    final warnings = <String>[];
    for (final name in ['POSCAR', 'CONTCAR']) {
      if (cancelled?.call() == true) throw const FileReadCancelled();
      try {
        final text = await files.read(remoteJoin(directory, name));
        if (text.truncated) continue;
        structure = parseVaspForceConstraints(text.text);
        if (name == 'CONTCAR') warnings.add('POSCAR 不可用，约束改从 CONTCAR 读取。');
        break;
      } catch (_) {
        // A growing CONTCAR or a missing POSCAR must not prevent raw forces.
      }
    }
    final outcar = OutcarProgressParser(structure: structure);
    await readRemoteLines(
      files,
      path,
      outcar.addLine,
      onProgress: onProgress,
      cancelled: cancelled,
    );
    final oszicar = OszicarProgressParser();
    try {
      await readRemoteLines(
        files,
        remoteJoin(directory, 'OSZICAR'),
        oszicar.addLine,
        cancelled: cancelled,
      );
    } on FileReadCancelled {
      rethrow;
    } on FormatException catch (e) {
      if (e.message.contains('200000')) rethrow;
      oszicar.energies.clear();
      warnings.add('OSZICAR 不可用，能量使用 OUTCAR 的 energy(sigma->0)。');
    } catch (_) {
      oszicar.energies.clear();
      warnings.add('OSZICAR 不可用，能量使用 OUTCAR 的 energy(sigma->0)。');
    }
    if (cancelled?.call() == true) throw const FileReadCancelled();
    return VaspProgress(
      energies: oszicar.energies.isEmpty ? outcar.energies : oszicar.energies,
      energySource: oszicar.energies.isEmpty ? 'OUTCAR · E0' : 'OSZICAR · E0',
      segmentStart: oszicar.energies.isEmpty
          ? outcar.segmentStart
          : oszicar.segmentStart,
      forces: outcar.forces,
      finished: outcar.finished,
      converged: outcar.converged,
      ibrion: outcar.ibrion,
      warnings: [...warnings, ...outcar.warnings],
    );
  }
}
