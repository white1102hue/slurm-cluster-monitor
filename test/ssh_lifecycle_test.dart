import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:slurm_cluster_monitor/models/slurm_models.dart';
import 'package:slurm_cluster_monitor/services/slurm_ssh_service.dart';
import 'package:slurm_cluster_monitor/services/remote_commands.dart';

void main() {
  final root = Platform.environment['SLURM_SSH_FIXTURE'];
  group(
    'loopback delayed channel lifecycle',
    skip: root == null ? 'Local SSH fixture not configured' : false,
    () {
      late ServerConfig server;
      File state() => File('$root/state.json');
      Future<int> count(String name) async {
        for (var i = 0; i < 30; i++) {
          try {
            return (jsonDecode(await File('$root/counters.json').readAsString())
                    as Map)[name]
                as int;
          } on FileSystemException {
            await Future<void>.delayed(const Duration(milliseconds: 20));
          }
        }
        throw StateError('fixture counter remained locked');
      }

      Future<void> waitRequest(String name, int previous) async {
        final end = DateTime.now().add(const Duration(seconds: 10));
        while (await count(name) <= previous) {
          if (DateTime.now().isAfter(end)) {
            throw TimeoutException('fixture request not received');
          }
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
      }

      setUpAll(() {
        final connection =
            jsonDecode(File('$root/connection.json').readAsStringSync()) as Map;
        server = ServerConfig(
          id: 'lifecycle',
          name: 'Lifecycle',
          host: '127.0.0.1',
          username: 'tester',
          password: 'fixture-password',
          port: connection['port'] as int,
          fingerprint: connection['fingerprint'] as String,
        );
      });
      tearDown(() {
        if (state().existsSync()) state().deleteSync();
      });

      test(
        'cancel while exec reply is delayed stops waiting and next command works',
        () async {
          final commands = SshRemoteCommands(server);
          addTearDown(commands.close);
          state().writeAsStringSync(jsonEncode({'execAckDelay': 2}));
          final before = await count('exec_requests');
          final pending = commands.run('/home/tester/project-42', 'pwd');
          await waitRequest('exec_requests', before);
          final watch = Stopwatch()..start();
          commands.cancel();
          final result = await pending;
          expect(watch.elapsedMilliseconds, lessThan(1500));
          expect(result.cancelled, isTrue);
          expect(result.stdout, isEmpty);
          expect(result.started, isTrue);
          state().writeAsStringSync('{}');
          final next = await commands.run('/home/tester/project-42', 'pwd');
          expect(next.exitCode, 0);
          expect(next.error, isNull);
          expect(next.stdout, contains('fixture command completed'));
        },
      );

      test(
        'exec creation timeout closes transport and cannot reuse a late channel',
        () async {
          final commands = SshRemoteCommands(server);
          addTearDown(commands.close);
          state().writeAsStringSync(jsonEncode({'execAckDelay': 16}));
          final result = await commands.run('/home/tester/project-42', 'pwd');
          expect(result.timedOut, isTrue);
          expect(result.started, isTrue);
          expect(result.stdout, isEmpty);
          state().writeAsStringSync('{}');
          final next = await commands.run('/home/tester/project-42', 'pwd');
          expect(next.exitCode, 0);
          expect(next.stdout, contains('fixture command completed'));
        },
      );

      test(
        'SFTP open timeout discards transport; subsequent file channel reconnects',
        () async {
          final ssh = SlurmSshService();
          addTearDown(ssh.close);
          final client = await ssh.connect(server);
          state().writeAsStringSync(jsonEncode({'channelOpenDelay': 16}));
          await expectLater(
            ssh.openFiles(server),
            throwsA(isA<TimeoutException>()),
          );
          expect(client.isClosed, isTrue);
          state().writeAsStringSync('{}');
          final sftp = await ssh.openFiles(server);
          expect(await sftp.absolute('.'), startsWith('/'));
          await sftp.close();
        },
      );
    },
  );
}
