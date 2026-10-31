import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:slurm_cluster_monitor/models/slurm_models.dart';
import 'package:slurm_cluster_monitor/services/slurm_ssh_service.dart';

/// Opt-in, read-only live test. Supply credentials through this process's
/// environment only; never put them in source, fixture files, or test output.
void main() {
  final env = Platform.environment;
  final ready = [
    'HOST',
    'USER',
    'PASSWORD',
    'FINGERPRINT',
  ].every((key) => (env['SLURM_TEST_$key'] ?? '').isNotEmpty);
  test(
    'authorized real cluster returns valid queue, accounting and node snapshots',
    () async {
      final service = SlurmSshService();
      addTearDown(service.close);
      final server = ServerConfig(
        id: 'live-smoke',
        name: 'Live cluster',
        host: env['SLURM_TEST_HOST']!,
        port: int.parse(env['SLURM_TEST_PORT'] ?? '22'),
        username: env['SLURM_TEST_USER']!,
        password: env['SLURM_TEST_PASSWORD']!,
        fingerprint: env['SLURM_TEST_FINGERPRINT']!,
      );
      final first = await service.fetch(server);
      expect(first.isOnline, isTrue);
      expect(first.accountingOk, isTrue);
      expect(first.nodesOk, isTrue);
      expect(first.warnings, isEmpty);
      expect(first.uniqueTotalNodes, greaterThan(0));
      final second = await service.fetch(server, since: first.timestamp);
      expect(second.isOnline, isTrue);
      expect(second.accountingOk, isTrue);
      expect(second.nodesOk, isTrue);
      expect(second.warnings, isEmpty);
      expect(second.timestamp.isBefore(first.timestamp), isFalse);
      // Report aggregate counts only; job names, IDs and credentials stay private.
      // ignore: avoid_print
      print(
        'Live collection OK: ${second.activeJobs.length} active jobs, '
        '${second.partitions.length} partitions, '
        '${second.uniqueTotalNodes} unique nodes.',
      );
    },
    skip: ready ? false : 'Set SLURM_TEST_* for an authorized live cluster.',
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
