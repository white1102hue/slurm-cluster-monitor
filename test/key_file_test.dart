import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slurm_cluster_monitor/services/key_file_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('slurm_monitor/files');
  const key =
      '-----BEGIN OPENSSH PRIVATE KEY-----\nfixture\n-----END OPENSSH PRIVATE KEY-----';
  test(
    'imports a selected key without requiring access to arbitrary file paths',
    () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            channel,
            (call) async => {'name': 'id_ed25519', 'content': key},
          );
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );
      final result = await KeyFileService.pick();
      expect(result!.name, 'id_ed25519');
      expect(result.content, key);
    },
  );
  test('cancelled file picker preserves the existing key', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async => null);
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );
    expect(await KeyFileService.pick(), isNull);
  });
  test(
    'rejects public keys, PPK and incomplete private keys with useful messages',
    () {
      expect(
        () => validatePrivateKey('ssh-ed25519 AAAA public'),
        throwsFormatException,
      );
      expect(
        () => validatePrivateKey('PuTTY-User-Key-File-3: ssh-rsa'),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'conversion',
            contains('OpenSSH'),
          ),
        ),
      );
      expect(
        () => validatePrivateKey('-----BEGIN RSA PRIVATE KEY-----'),
        throwsFormatException,
      );
      expect(validatePrivateKey('\uFEFF$key\n'), key);
    },
  );
}
