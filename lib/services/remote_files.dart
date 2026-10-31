import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';
import 'package:dartssh2/dartssh2.dart';
import '../models/slurm_models.dart';
import 'slurm_ssh_service.dart';
import '../models/remote_search.dart';
import 'remote_output_search.dart';
export '../models/remote_search.dart';

String remoteJoin(String directory, String name) =>
    '${directory == '/' ? '' : directory}/$name';
String remoteParent(String path) {
  final end = path.lastIndexOf('/');
  return end <= 0 ? '/' : path.substring(0, end);
}

String remoteName(String path) => path.split('/').last;

class RemoteEntry {
  const RemoteEntry(
    this.name, {
    this.directory = false,
    this.link = false,
    this.size,
    this.modified,
  });
  final String name;
  final bool directory, link;
  final int? size;
  final DateTime? modified;
}

class RemoteDirectory {
  const RemoteDirectory(this.entries, {this.truncated = false});
  final List<RemoteEntry> entries;
  final bool truncated;
}

class RemoteText {
  const RemoteText(
    this.text, {
    required this.size,
    this.truncated = false,
    this.tail = false,
  });
  final String text;
  final int size;
  final bool truncated, tail;
}

abstract class RemoteFiles {
  Future<String> homeDirectory() async => '/';
  Future<RemoteDirectory> list(String path);
  Future<bool> isDirectory(String path);
  Future<RemoteText> read(String path, {bool tail = false});
  Future<RemoteText> sample(String path, {bool tail = false}) =>
      read(path, tail: tail);
  Future<RemoteEntry?> stat(String path) async {
    final listing = await list(remoteParent(path));
    return listing.entries.where((e) => e.name == remoteName(path)).firstOrNull;
  }

  Stream<RemoteEntry> children(String path) async* {
    final listing = await list(path);
    for (final entry in listing.entries) {
      yield entry;
    }
    if (listing.truncated) throw const FormatException('目录未完全列出');
  }

  /// Portable fallback without fixed depth/directory caps.
  Future<RemoteOutputSearch> findOutputs(
    String directory, {
    bool Function()? cancelled,
    void Function(int matched)? onProgress,
  }) async {
    final queue = Queue<String>()..add(directory);
    final visited = <String>{};
    final results = OutputSearchAccumulator();
    var unreadable = 0, links = 0;
    while (queue.isNotEmpty) {
      if (cancelled?.call() == true) throw const FileReadCancelled();
      final path = queue.removeFirst();
      if (!visited.add(path)) continue;
      try {
        await for (final entry in children(path)) {
          if (cancelled?.call() == true) throw const FileReadCancelled();
          if (entry.name == '.' ||
              entry.name == '..' ||
              entry.name.contains('/') ||
              entry.name.contains('\x00')) {
            continue;
          }
          if (entry.link) {
            links++;
            continue;
          }
          final child = remoteJoin(path, entry.name);
          if (entry.directory) {
            queue.add(child);
          } else if (entry.name.toLowerCase() == 'outcar' ||
              RegExp(
                r'\.(log|out)$',
                caseSensitive: false,
              ).hasMatch(entry.name)) {
            results.add(
              RemoteFileMatch(
                child,
                size: entry.size,
                modified: entry.modified,
              ),
            );
            onProgress?.call(results.matched);
          }
        }
      } on FileReadCancelled {
        rethrow;
      } catch (_) {
        unreadable++;
      }
    }
    return results.finish(
      complete: unreadable == 0 && links == 0,
      warnings: [
        if (unreadable > 0) '$unreadable 个目录未完全读取；显示已找到的最新输出。',
        if (links > 0) 'SFTP 回退扫描跳过了 $links 个符号链接。',
      ],
    );
  }

  Stream<List<int>> readChunks(
    String path, {
    void Function(int read, int total)? onProgress,
    bool Function()? cancelled,
  }) async* {
    if (cancelled?.call() == true) throw const FileReadCancelled();
    final content = await read(path);
    if (content.truncated) throw const FormatException('此文件源不支持完整读取');
    final bytes = utf8.encode(content.text);
    onProgress?.call(bytes.length, bytes.length);
    yield bytes;
  }

  void close();
}

class FileReadCancelled implements Exception {
  const FileReadCancelled();
}

class SshRemoteFiles extends RemoteFiles {
  SshRemoteFiles(this.server);
  final ServerConfig server;
  final _ssh = SlurmSshService();
  bool _closed = false;
  static const previewBytes = 2 * 1024 * 1024;
  static const maxEntries = 3000;

  @override
  Future<String> homeDirectory() =>
      _withSftp('/', (sftp) => sftp.absolute('.'));

  void _check(String path) {
    if (_closed) throw const FormatException('文件连接已关闭');
    if (!path.startsWith('/') || path.contains('\x00')) {
      throw const FormatException('无效的远程路径');
    }
  }

  Future<T> _withSftp<T>(
    String path,
    Future<T> Function(SftpClient) run,
  ) async {
    _check(path);
    final sftp = await _ssh.openFiles(server);
    try {
      if (_closed) {
        _ssh.close();
        throw const FormatException('文件连接已关闭');
      }
      return await run(sftp).timeout(const Duration(seconds: 25));
    } on SftpStatusError catch (e) {
      throw FormatException(switch (e.code) {
        2 => '目录或文件不存在；请确认该路径在登录服务器上可见',
        3 => '当前账号没有读取权限',
        _ => '文件读取失败，请刷新重试',
      });
    } finally {
      // Also releases an unfinished directory handle on early stream exit.
      try {
        await sftp.close().timeout(const Duration(seconds: 3));
      } catch (_) {
        _ssh.close();
      }
    }
  }

  RemoteEntry _entry(String name, SftpFileAttrs attrs) => RemoteEntry(
    name,
    directory: attrs.isDirectory,
    link: attrs.isSymbolicLink,
    size: attrs.size,
    modified: attrs.modifyTime == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(
            attrs.modifyTime! * 1000,
            isUtc: true,
          ),
  );

  @override
  Future<RemoteEntry?> stat(String path) => _withSftp(path, (sftp) async {
    try {
      return _entry(remoteName(path), await sftp.stat(path));
    } on SftpStatusError catch (e) {
      if (e.code == 2) return null;
      rethrow;
    }
  });

  @override
  Stream<RemoteEntry> children(String path) async* {
    _check(path);
    final sftp = await _ssh.openFiles(server);
    try {
      await for (final batch
          in sftp.readdir(path).timeout(const Duration(seconds: 25))) {
        if (_closed) throw const FileReadCancelled();
        for (final item in batch) {
          final name = item.filename;
          if (name != '.' &&
              name != '..' &&
              !name.contains('/') &&
              !name.contains('\x00')) {
            yield _entry(name, item.attr);
          }
        }
      }
    } finally {
      try {
        await sftp.close().timeout(const Duration(seconds: 3));
      } catch (_) {
        _ssh.close();
      }
    }
  }

  @override
  Future<RemoteOutputSearch> findOutputs(
    String directory, {
    bool Function()? cancelled,
    void Function(int matched)? onProgress,
  }) async {
    _check(directory);
    RemoteOutputSearch? result;
    final client = await _ssh.connect(server);
    try {
      result = await searchRemoteOutputs(
        client,
        directory,
        cancelled: () => _closed || cancelled?.call() == true,
        onProgress: onProgress,
      );
    } on FileReadCancelled {
      rethrow;
    } catch (_) {
      if (_closed || cancelled?.call() == true) throw const FileReadCancelled();
    }
    return result ??
        await super.findOutputs(
          directory,
          cancelled: () => _closed || cancelled?.call() == true,
          onProgress: onProgress,
        );
  }

  @override
  Future<RemoteDirectory> list(String path) async {
    final entries = <RemoteEntry>[];
    var truncated = false;
    await for (final entry in children(path)) {
      if (entries.length == maxEntries) {
        truncated = true;
        break;
      }
      entries.add(entry);
    }
    entries.sort((a, b) {
      if (a.directory != b.directory) return a.directory ? -1 : 1;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return RemoteDirectory(entries, truncated: truncated);
  }

  @override
  Future<bool> isDirectory(String path) =>
      _withSftp(path, (sftp) async => (await sftp.stat(path)).isDirectory);

  @override
  Future<RemoteText> read(String path, {bool tail = false}) =>
      _read(path, tail: tail, limit: previewBytes);
  @override
  Future<RemoteText> sample(String path, {bool tail = false}) =>
      _read(path, tail: tail, limit: 64 * 1024);

  Future<RemoteText> _read(
    String path, {
    required bool tail,
    required int limit,
  }) => _withSftp(path, (sftp) async {
    final file = await sftp.open(path, mode: SftpFileOpenMode.read);
    try {
      final attrs = await file.stat();
      if (attrs.isDirectory) throw const FormatException('请选择一个文件');
      if (attrs.mode != null && !attrs.isFile) {
        throw const FormatException('仅支持普通文件的文本预览');
      }
      final size = attrs.size ?? 0;
      final offset = tail && size > limit ? size - limit : 0;
      final builder = BytesBuilder(copy: false);
      await for (final chunk in file.read(offset: offset, length: limit + 1)) {
        builder.add(chunk);
      }
      var bytes = builder.takeBytes();
      final truncated = offset > 0 || bytes.length > limit || size > limit;
      if (bytes.length > limit) {
        bytes = Uint8List.sublistView(bytes, 0, limit);
      }
      if (bytes.contains(0)) throw const FormatException('这是二进制文件，暂不支持文本预览');
      var text = utf8.decode(bytes, allowMalformed: true);
      if (offset > 0 && text.contains('\n')) {
        text = text.substring(text.indexOf('\n') + 1);
      }
      return RemoteText(text, size: size, truncated: truncated, tail: tail);
    } finally {
      await file.close();
    }
  });

  @override
  Stream<List<int>> readChunks(
    String path, {
    void Function(int read, int total)? onProgress,
    bool Function()? cancelled,
  }) async* {
    _check(path);
    if (cancelled?.call() == true) throw const FileReadCancelled();
    final sftp = await _ssh.openFiles(server);
    SftpFile? file;
    try {
      if (_closed) throw const FileReadCancelled();
      file = await sftp
          .open(path, mode: SftpFileOpenMode.read)
          .timeout(const Duration(seconds: 25));
      final attrs = await file.stat().timeout(const Duration(seconds: 25));
      if (attrs.isDirectory || (attrs.mode != null && !attrs.isFile)) {
        throw const FormatException('请选择普通日志文本文件');
      }
      final size = attrs.size;
      if (size == null || size < 0) {
        throw const FormatException('无法取得文件大小，请刷新重试');
      }
      var read = 0;
      onProgress?.call(0, size);
      await for (final chunk
          in file
              .read(length: size, chunkSize: 65536, maxPendingRequests: 8)
              .timeout(const Duration(seconds: 25))) {
        if (_closed || cancelled?.call() == true) {
          throw const FileReadCancelled();
        }
        read += chunk.length;
        onProgress?.call(read, size);
        yield chunk;
      }
      if (read < size) throw const FormatException('读取期间文件被截短，请刷新重试');
      if (cancelled?.call() == true) throw const FileReadCancelled();
    } on SftpStatusError catch (e) {
      throw FormatException(switch (e.code) {
        2 => '目录或文件不存在；请确认该路径在登录服务器上可见',
        3 => '当前账号没有读取权限',
        _ => '文件读取失败，请刷新重试',
      });
    } finally {
      try {
        await file?.close().timeout(const Duration(seconds: 3));
      } catch (_) {}
      try {
        await sftp.close().timeout(const Duration(seconds: 3));
      } catch (_) {
        _ssh.close();
      }
    }
  }

  @override
  void close() {
    _closed = true;
    _ssh.close();
  }
}

String fileError(Object error) => error is FormatException
    ? error.message
    : error is SftpError
    ? '服务器 SFTP 不可用，请检查该账号的 SFTP 权限'
    : friendlyError(error);

String _demoOutcar() {
  final text = StringBuffer(
    'NIONS = 8\n IBRION = 2\n direct lattice vectors\n5.43 0 0\n0 5.43 0\n0 0 5.43\n',
  );
  for (var step = 1; step <= 12; step++) {
    text.writeln('POSITION TOTAL-FORCE (eV/Angst)\n------------------');
    for (var atom = 0; atom < 8; atom++) {
      text.writeln('0 0 0 ${0.4 / step} ${0.12 / step} 0');
    }
    text.writeln(
      '------------------\nenergy without entropy = -100 energy(sigma->0) = ${-108.5 + 1 / step}',
    );
  }
  return text.toString();
}

String _demoGaussian() {
  final output = StringBuffer('Entering Gaussian System\n');
  for (var step = 1; step <= 12; step++) {
    final force = .01 / step;
    output.writeln('''
 Standard orientation:
 ---------------------------------------------------------------------
 Center Atomic Atomic Coordinates (Angstroms)
 Number Number Type X Y Z
 ---------------------------------------------------------------------
 1 8 0 0 0 0
 2 1 0 .758 0 .504
 3 1 0 -.758 0 .504
 ---------------------------------------------------------------------
 SCF Done: E(RB3LYP) = ${-76.4 + .1 / step} A.U.
 Item Value Threshold Converged?
 Maximum Force $force .000450 NO
 RMS Force ${force / 2} .000300 NO
 Maximum Displacement ${force * 2} .001800 NO
 RMS Displacement $force .001200 NO
''');
  }
  return output.toString();
}

final demoFiles = <String, String>{
  'water.log': _demoGaussian(),
  'OUTCAR': _demoOutcar(),
  'OSZICAR': [
    for (var step = 1; step <= 12; step++)
      ' $step F= -108.5 E0= ${-108.5 + 1 / step} d E = -0.01',
  ].join('\n'),
  'job.sh':
      '#!/bin/bash\n#SBATCH -J example\n#SBATCH --time=00:05:00\necho completed\n',
  'POSCAR': '''Silicon
1.0
5.43 0 0
0 5.43 0
0 0 5.43
Si
8
Direct
0 0 0
0.25 0.25 0.25
0 0.5 0.5
0.25 0.75 0.75
0.5 0 0.5
0.75 0.25 0.75
0.5 0.5 0
0.75 0.75 0.25
''',
  'water.gjf': '''%nprocshared=8
# B3LYP/6-31G(d) opt

Water

0 1
O 0.000 0.000 0.000
H 0.758 0.000 0.504
H -0.758 0.000 0.504

''',
  'silicon.cif': '''data_silicon
_cell_length_a 5.43
_cell_length_b 5.43
_cell_length_c 5.43
_cell_angle_alpha 90
_cell_angle_beta 90
_cell_angle_gamma 90
loop_
_space_group_symop_operation_xyz
'x,y,z'
'-x,-y,-z'
loop_
_atom_site_type_symbol
_atom_site_fract_x
_atom_site_fract_y
_atom_site_fract_z
Si 0.125 0.125 0.125
''',
  'slurm-48219.out':
      'Starting calculation...\nElectronic convergence reached\nIonic step 12 completed\nJob running\n',
  'INCAR':
      'SYSTEM = Silicon\nENCUT = 520\nEDIFF = 1E-6\nISMEAR = 0\nSIGMA = 0.05\n',
};

class DemoRemoteFiles extends RemoteFiles {
  @override
  Future<RemoteDirectory> list(String path) async => RemoteDirectory([
    for (final item in demoFiles.entries)
      RemoteEntry(
        item.key,
        size: utf8.encode(item.value).length,
        modified: DateTime.now().subtract(
          Duration(
            minutes: item.key == 'OUTCAR' || item.key == 'OSZICAR' ? 0 : 10,
          ),
        ),
      ),
  ]);
  @override
  Future<bool> isDirectory(String path) async => false;
  @override
  Future<RemoteText> read(String path, {bool tail = false}) async {
    final text = demoFiles[remoteName(path)];
    if (text == null) throw const FormatException('文件不存在');
    return RemoteText(text, size: utf8.encode(text).length, tail: tail);
  }

  @override
  void close() {}
}
