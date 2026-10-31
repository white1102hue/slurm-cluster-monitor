import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:slurm_cluster_monitor/models/slurm_models.dart';
import 'package:slurm_cluster_monitor/services/remote_commands.dart';
import 'package:slurm_cluster_monitor/services/shell_utils.dart';

void main() {
  test(
    'submission arguments are literal argv, with quotes and empty values preserved',
    () {
      expect(splitArguments('one "two words" \'\' "\$(literal)"'), [
        'one',
        'two words',
        '',
        '\$(literal)',
      ]);
      expect(() => splitArguments("'unfinished"), throwsFormatException);
      expect(
        sbatchCommand(
          'job name.sh',
          options: '-p compute',
          arguments: "'x y' ';echo bad'",
        ),
        "sbatch --parsable '-p' 'compute' -- './job name.sh' 'x y' ';echo bad'",
      );
      expect(submittedJobId('9001;cluster\n'), '9001');
      expect(submittedJobId('warning'), isNull);
    },
  );
  test(
    'real bash runs only in the quoted directory and submits the selected literal script',
    () async {
      final bash = Platform.isWindows
          ? '${Platform.environment['ProgramFiles']}/Git/bin/bash.exe'
          : '/bin/bash';
      if (!File(bash).existsSync()) {
        markTestSkipped('bash unavailable');
        return;
      }
      final temp = Directory.systemTemp.createTempSync('slurm-command-');
      addTearDown(() => temp.deleteSync(recursive: true));
      final target = Directory("${temp.path}/a 'quote' \$(literal)")
        ..createSync();
      String unix(String path) {
        path = path.replaceAll('\\', '/');
        return Platform.isWindows
            ? path.replaceFirstMapped(
                RegExp(r'^([A-Za-z]):'),
                (m) => '/${m[1]!.toLowerCase()}',
              )
            : path;
      }

      final cwd = await Process.run(bash, [
        '-c',
        directoryCommand(unix(target.path), 'pwd'),
      ]);
      expect(cwd.exitCode, 0);
      expect((cwd.stdout as String).trim(), unix(target.path));
      final log = unix('${temp.path}/argv.txt'),
          envFile = File('${temp.path}/env.sh');
      envFile.writeAsStringSync(
        'sbatch() { printf \'%s\\n\' "\$@" > ${shellQuote(log)}; echo 9001; }\n',
      );
      final result = await Process.run(
        bash,
        [
          '-c',
          directoryCommand(
            unix(target.path),
            sbatchCommand(
              'job name.sh',
              options: '-p compute',
              arguments: "'x y' ';echo bad'",
            ),
          ),
        ],
        environment: {'BASH_ENV': unix(envFile.path)},
      );
      expect(result.exitCode, 0);
      expect(File('${temp.path}/argv.txt').readAsLinesSync(), [
        '--parsable',
        '-p',
        'compute',
        '--',
        './job name.sh',
        'x y',
        ';echo bad',
      ]);
    },
  );
  final dir = Platform.environment['SLURM_SSH_FIXTURE'];
  group(
    'real loopback command execution',
    skip: dir == null ? 'Local fixture not configured' : false,
    () {
      late ServerConfig server;
      setUpAll(() {
        final c =
            jsonDecode(File('$dir/connection.json').readAsStringSync()) as Map;
        server = ServerConfig(
          id: 'cmd',
          name: 'Fixture',
          host: '127.0.0.1',
          port: c['port'] as int,
          username: 'tester',
          password: 'fixture-password',
          fingerprint: c['fingerprint'] as String,
        );
      });
      test(
        'streams stdout/stderr, preserves working directory, reports exit and submits once',
        () async {
          final runner = SshRemoteCommands(server);
          addTearDown(runner.close);
          final output = <String>[];
          final pwd = await runner.run(
            "/home/tester/a 'quoted' \$(literal)",
            'pwd',
            onOutput: (text, _) => output.add(text),
          );
          expect(pwd.exitCode, 0);
          expect(pwd.stdout, contains("a 'quoted' \$(literal)"));
          expect(output, isNotEmpty);
          final last =
              jsonDecode(File('$dir/last-command.json').readAsStringSync())
                  as Map;
          expect(last['directory'], "/home/tester/a 'quoted' \$(literal)");
          final failed = await runner.run(
            '/home/tester/project-42',
            'SLURM_TEST_ERROR',
          );
          expect(failed.exitCode, 7);
          expect(failed.stderr, contains('fixture stderr'));
          final before =
              (jsonDecode(File('$dir/counters.json').readAsStringSync())
                      as Map)['submissions']
                  as int;
          final submit = await runner.run(
            '/home/tester/project-42',
            sbatchCommand('job.sh'),
          );
          expect(submittedJobId(submit.stdout), '9001');
          expect(
            (jsonDecode(File('$dir/counters.json').readAsStringSync())
                as Map)['submissions'],
            before + 1,
          );
        },
      );
      test(
        'output bounds, timeout and wrong-host failures never trigger automatic retries',
        () async {
          final runner = SshRemoteCommands(server);
          addTearDown(runner.close);
          final big = await runner.run(
            '/home/tester/project-42',
            'SLURM_TEST_BIG',
          );
          expect(big.truncated, isTrue);
          expect(
            big.stdout.length,
            lessThanOrEqualTo(SshRemoteCommands.outputLimit),
          );
          final timed = await runner.run(
            '/home/tester/project-42',
            'SLURM_TEST_WAIT',
            timeout: const Duration(milliseconds: 60),
          );
          expect(timed.timedOut, isTrue);
          expect(timed.started, isTrue);
          final untrusted = SshRemoteCommands(
            server.copyWith(fingerprint: 'SHA256:wrong'),
          );
          addTearDown(untrusted.close);
          final result = await untrusted.run('/home/tester/project-42', 'pwd');
          expect(result.started, isFalse);
          expect(result.error, isNotNull);
        },
      );
    },
  );
}
