import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:slurm_cluster_monitor/models/slurm_models.dart';
import 'package:slurm_cluster_monitor/services/slurm_ssh_service.dart';

void main() {
  final dir = Platform.environment['SLURM_SSH_FIXTURE'];
  group(
    'real loopback SSH protocol',
    skip: dir == null
        ? 'Set SLURM_SSH_FIXTURE to run the optional local SSH fixture.'
        : false,
    () {
      late Map<String, dynamic> connection;
      setUpAll(() {
        connection =
            jsonDecode(File('$dir/connection.json').readAsStringSync())
                as Map<String, dynamic>;
      });
      ServerConfig config({
        String id = 'fixture',
        AuthType auth = AuthType.password,
        String key = '',
        String passphrase = '',
        String? fingerprint,
        String password = 'fixture-password',
      }) => ServerConfig(
        id: id,
        name: 'Fixture',
        host: '127.0.0.1',
        port: connection['port'] as int,
        username: 'tester',
        authType: auth,
        password: password,
        privateKey: key,
        passphrase: passphrase,
        fingerprint: fingerprint ?? connection['fingerprint'] as String,
      );
      Map counts() =>
          jsonDecode(File('$dir/counters.json').readAsStringSync()) as Map;
      test(
        'fingerprint probe sends no password; password connection is reused',
        () async {
          final beforeAuth = counts()['password_auth'] as int;
          final observed = await SlurmSshService.probeHost(config());
          expect(observed.fingerprint, connection['fingerprint']);
          expect(counts()['password_auth'], beforeAuth);
          final source = SlurmSshService();
          addTearDown(source.close);
          final first = await source.fetch(config());
          final afterFirst = counts()['connections'] as int;
          final second = await source.fetch(config());
          expect(first.activeJobs.single.jobName, 'fixture-job');
          expect(second.activeJobs.single.cpuUsagePercent, 25);
          expect(counts()['connections'], afterFirst);
          expect(counts()['password_auth'], beforeAuth + 1);
        },
      );
      test(
        'simultaneous callers share one authenticated SSH connection',
        () async {
          final source = SlurmSshService();
          addTearDown(source.close);
          final before = counts()['connections'] as int;
          final clients = await Future.wait(
            List.generate(6, (_) => source.connect(config())),
          );
          expect(clients.every((c) => identical(c, clients.first)), isTrue);
          expect(counts()['connections'], before + 1);
        },
      );
      test(
        'changed credentials cannot reuse a previously authenticated connection',
        () async {
          final source = SlurmSshService();
          addTearDown(source.close);
          final old = await source.connect(config());
          await expectLater(
            source.connect(config(password: 'wrong')),
            throwsA(anything),
          );
          expect(old.isClosed, isTrue);
          expect((await source.fetch(config())).isOnline, isTrue);
        },
      );
      test(
        'closing a pending connection cannot leave an orphan authenticated client',
        () async {
          final source = SlurmSshService();
          addTearDown(source.close);
          final pending = source.connect(config());
          source.close();
          await expectLater(pending, throwsA(anything));
          expect((await source.fetch(config())).isOnline, isTrue);
        },
      );
      test(
        'node capacity is queried once per minute on the reused connection',
        () async {
          var now = DateTime.utc(2026, 10, 26);
          final source = SlurmSshService(now: () => now);
          addTearDown(source.close);
          final before = counts()['capacity_queries'] as int;
          await source.fetch(config());
          now = now.add(const Duration(seconds: 10));
          final cached = await source.fetch(config());
          expect(cached.activeJobs.single.nodeMemoryMb, 262144);
          expect(counts()['capacity_queries'], before + 1);
          now = now.add(const Duration(seconds: 50));
          await source.fetch(config());
          expect(counts()['capacity_queries'], before + 2);
        },
      );
      test(
        'Slurm command errors preserve the authenticated transport for the next poll',
        () async {
          final source = SlurmSshService();
          addTearDown(source.close);
          await source.fetch(config());
          final before = counts()['connections'] as int;
          final stateFile = File('$dir/state.json');
          final previous = stateFile.existsSync()
              ? stateFile.readAsStringSync()
              : null;
          try {
            stateFile.writeAsStringSync(jsonEncode({'queueError': true}));
            await expectLater(source.fetch(config()), throwsFormatException);
          } finally {
            if (previous == null) {
              stateFile.deleteSync();
            } else {
              stateFile.writeAsStringSync(previous);
            }
          }
          expect((await source.fetch(config())).isOnline, isTrue);
          expect(counts()['connections'], before);
        },
      );
      test(
        'changed host fingerprint is blocked before credential authentication',
        () async {
          final before = counts()['password_auth'];
          final source = SlurmSshService();
          addTearDown(source.close);
          await expectLater(
            source.fetch(config(fingerprint: 'SHA256:untrusted')),
            throwsFormatException,
          );
          expect(counts()['password_auth'], before);
        },
      );
      for (final name in [
        'rsa.pem',
        'rsa-encrypted.pem',
        'ed25519',
        'ed25519-encrypted',
      ]) {
        test('$name private key authenticates', () async {
          final source = SlurmSshService();
          addTearDown(source.close);
          final result = await source.fetch(
            config(
              auth: AuthType.privateKey,
              key: File('$dir/$name').readAsStringSync(),
              passphrase: name.contains('encrypted')
                  ? 'fixture-passphrase'
                  : '',
            ),
          );
          expect(result.activeJobs.single.jobId, '42');
        });
      }
      test('authentication failure recovers on next attempt', () async {
        final source = SlurmSshService();
        addTearDown(source.close);
        await expectLater(
          source.fetch(config(password: 'wrong')),
          throwsA(anything),
        );
        expect((await source.fetch(config())).isOnline, isTrue);
      });
      test(
        'collection uses only the login host and Slurm memory capacity',
        () async {
          final source = SlurmSshService();
          addTearDown(source.close);
          final before = counts()['commands'] as int;
          final snapshot = await source.fetch(config());
          expect(snapshot.activeJobs.single.nodeMemoryMb, 262144);
          expect(snapshot.activeJobs.single.memUsagePercent, 1.5625);
          expect(
            snapshot.activeJobs.single.nodes.single.toJson().keys,
            containsAll(['name', 'totalMemoryMb']),
          );
          expect(counts()['commands'], before + 1);
          expect(counts()['node_attempts'], 0);
        },
      );
    },
  );
}
