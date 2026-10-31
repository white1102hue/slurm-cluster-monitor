import 'package:flutter/services.dart';

class ImportedKey {
  const ImportedKey(this.name, this.content);
  final String name, content;
}

class KeyFileService {
  static const _channel = MethodChannel('slurm_monitor/files');
  static Future<ImportedKey?> pick() async {
    final result = await _channel.invokeMapMethod<String, dynamic>(
      'pickPrivateKey',
    );
    if (result == null) return null;
    final content = validatePrivateKey(result['content'] as String? ?? '');
    return ImportedKey(result['name'] as String? ?? '私钥文件', content);
  }
}

String validatePrivateKey(String content) {
  final value = content.replaceFirst('\uFEFF', '').trim();
  if (value.startsWith('PuTTY-User-Key-File-')) {
    throw const FormatException(
      'PPK 文件请先用 PuTTYgen 或 Xshell 导出为 OpenSSH 私钥，再导入。',
    );
  }
  if (value.length > 512 * 1024) throw const FormatException('私钥文件超过 512 KB');
  final begin = RegExp(
    r'-----BEGIN (OPENSSH |RSA |EC |ENCRYPTED )?PRIVATE KEY-----',
  ).firstMatch(value);
  if (begin == null ||
      !value.contains(begin[0]!.replaceFirst('BEGIN', 'END'))) {
    throw const FormatException('请选择完整的 OpenSSH 或 PEM 私钥文件，公钥文件不可用于登录。');
  }
  return value;
}
