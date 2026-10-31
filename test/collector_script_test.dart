import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:slurm_cluster_monitor/models/slurm_models.dart';
import 'package:slurm_cluster_monitor/services/slurm_parser.dart';
import 'package:slurm_cluster_monitor/services/slurm_ssh_service.dart';

void main() {
  final bash = Platform.isWindows
      ? '${Platform.environment['ProgramFiles']}/Git/bin/bash.exe'
      : '/bin/bash';

  Future<(ProcessResult, ServerSnapshot?)> runCollector({
    required String queue,
    String accounting =
        "printf '%s\\n' '42|fixture|compute|RUNNING|00:10:00|8|4Gc||0:0|1|cn01|Unknown|2026-10-24T01:00:00|None|01:00:00'",
    bool parse = true,
    bool collectNodeCapacity = true,
  }) async {
    final temp = Directory.systemTemp.createTempSync('slurm-compat-');
    addTearDown(() => temp.deleteSync(recursive: true));
    for (final entry in {
      'squeue': queue,
      'sstat': "printf '%s\\n' '42.batch|00:05:00|1G|1G|4'",
      'sacct': accounting,
      'sinfo': "printf '%s\\n' 'compute*|up|cn01|idle|0/64/0/64'",
      'scontrol':
          "printf '%s\\n' 'NodeName=cn01 RealMemory=131072 FreeMem=81920 State=IDLE'",
    }.entries) {
      File(
        '${temp.path}/${entry.key}',
      ).writeAsStringSync('#!/bin/bash\n${entry.value}\n');
    }
    if (!Platform.isWindows) {
      await Process.run('chmod', [
        '+x',
        ...[
          'squeue',
          'sstat',
          'sacct',
          'sinfo',
          'scontrol',
        ].map((s) => '${temp.path}/$s'),
      ]);
    }
    var path = temp.path.replaceAll('\\', '/');
    if (Platform.isWindows) {
      path = path.replaceFirstMapped(
        RegExp(r'^([A-Za-z]):'),
        (m) => '/${m[1]!.toLowerCase()}',
      );
    }
    final result = await Process.run(bash, [
      '-c',
      'export PATH=${shellQuote(path)}:/usr/bin:/bin:\$PATH\n${collectionScript(collectNodeCapacity: collectNodeCapacity)}',
    ]);
    expect(result.exitCode, 0, reason: '${result.stderr}');
    return (
      result,
      parse
          ? const SlurmParser().parse(
              const ServerConfig(
                id: 'test',
                name: 'Test',
                host: 'localhost',
                username: 'tester',
              ),
              '${result.stdout}',
            )
          : null,
    );
  }

  const legacyQueue = '''
for arg in "\$@"; do
  if [ "\$arg" = '--me' ]; then
    echo "squeue: unrecognized option '--me'" >&2
    exit 1
  fi
done
case " \$* " in
  *' -u '*) ;;
  *) echo 'Current-user filter is required' >&2; exit 1;;
esac
printf '%s\\n' '42|fixture|compute|RUNNING|00:10:00|01:00:00|8|4G|cn01|None|1|2026-10-24T01:00:00|42'
''';

  test(
    'cached node capacity omits the remote capacity query while keeping live queue data',
    () async {
      final (result, _) = await runCollector(
        queue: legacyQueue,
        collectNodeCapacity: false,
        parse: false,
      );
      expect('${result.stdout}', isNot(contains('===NODES===')));
      final snapshot = const SlurmParser().parse(
        const ServerConfig(
          id: 'test',
          name: 'Test',
          host: 'localhost',
          username: 'tester',
        ),
        '${result.stdout}',
        nodeCapacity: const [
          NodeResources(name: 'cn01', totalMemoryMb: 131072),
        ],
      );
      expect(snapshot.activeJobs.single.nodeMemoryMb, 131072);
      expect(snapshot.activeJobs.single.cpuUsagePercent, 25);
    },
    skip: !File(bash).existsSync(),
  );
  test(
    'Slurm 19 accepts scoped queue and falls back when sacct lacks --array',
    () async {
      final (_, snapshot) = await runCollector(
        queue: legacyQueue,
        accounting: '''
for arg in "\$@"; do
  if [ "\$arg" = '--array' ]; then
    echo "sacct: unrecognized option '--array'" >&2
    exit 1
  fi
done
printf '%s\\n' '42|fixture|compute|RUNNING|00:10:00|8|4Gc||0:0|1|cn01|Unknown|2026-10-24T01:00:00|None|01:00:00'
''',
      );
      expect(snapshot!.activeJobs.single.cpuUsagePercent, 25);
      expect(snapshot.accountingOk, isTrue);
      expect(snapshot.warnings, isEmpty);
    },
    skip: !File(bash).existsSync(),
  );

  test(
    'queue stderr survives framing and a real failure cannot look empty',
    () async {
      final (result, _) = await runCollector(
        queue: "echo 'squeue: Unable to contact slurm controller' >&2\nexit 1",
        parse: false,
      );
      expect(
        '${result.stdout}',
        contains(
          '===DETAIL:SQUEUE===squeue: Unable to contact slurm controller',
        ),
      );
      expect('${result.stdout}', isNot(contains('===SACCT===')));
      expect(
        () => const SlurmParser().parse(
          const ServerConfig(
            id: 'test',
            name: 'Test',
            host: 'localhost',
            username: 'tester',
          ),
          '${result.stdout}',
        ),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'detail',
            contains('Unable to contact slurm controller'),
          ),
        ),
      );
    },
    skip: !File(bash).existsSync(),
  );

  test(
    'accounting permission failure is reported without an unrelated retry',
    () async {
      final (result, snapshot) = await runCollector(
        queue: legacyQueue,
        accounting:
            "echo ACCOUNTING_CALL\necho 'sacct: Access denied' >&2\nexit 1",
      );
      expect(
        RegExp('ACCOUNTING_CALL').allMatches('${result.stdout}'),
        hasLength(1),
      );
      expect(snapshot!.accountingOk, isFalse);
      expect(snapshot.activeJobs, hasLength(1));
      expect(snapshot.warnings.single, contains('Access denied'));
    },
    skip: !File(bash).existsSync(),
  );

  test(
    'collector executes as bash, calls squeue once and reads own job steps',
    () async {
      final bash = Platform.isWindows
          ? '${Platform.environment['ProgramFiles']}/Git/bin/bash.exe'
          : '/bin/bash';
      if (!File(bash).existsSync()) {
        markTestSkipped('bash is not installed');
        return;
      }
      final temp = Directory.systemTemp.createTempSync('slurm-collector-');
      addTearDown(() => temp.deleteSync(recursive: true));
      void mock(String name, String content) {
        File('${temp.path}/$name').writeAsStringSync('#!/bin/bash\n$content\n');
      }

      mock(
        'squeue',
        '''echo called >> "\$SLURM_FIXTURE_LOG"
printf '%s\\n' '42|fixture|compute|RUNNING|00:10:00|01:00:00|8|4G|cn01|None|1|2026-10-24T01:00:00' ''',
      );
      mock('sstat', "printf '%s\\n' '42.batch|00:05:00|1G|1G|4'");
      mock(
        'sacct',
        "if [ \"\$1\" != '--array' ]; then echo 'Array expansion required' >&2; exit 1; fi\n"
            "printf '%s\\n' '42|fixture|compute|RUNNING|00:10:00|8|4Gc||0:0|1|cn01|Unknown|2026-10-24T01:00:00|None|01:00:00'",
      );
      mock('sinfo', "printf '%s\\n' 'compute*|up|cn01|idle|0/64/0/64'");
      mock(
        'scontrol',
        "printf '%s\\n' 'NodeName=cn01 RealMemory=131072 FreeMem=81920 State=IDLE'",
      );
      if (!Platform.isWindows) {
        await Process.run('chmod', [
          '+x',
          ...[
            'squeue',
            'sstat',
            'sacct',
            'sinfo',
            'scontrol',
          ].map((s) => '${temp.path}/$s'),
        ]);
      }
      var path = temp.path.replaceAll('\\', '/');
      if (Platform.isWindows) {
        path = path.replaceFirstMapped(
          RegExp(r'^([A-Za-z]):'),
          (m) => '/${m[1]!.toLowerCase()}',
        );
      }
      final result = await Process.run(
        bash,
        [
          '-c',
          'export PATH=${shellQuote(path)}:/usr/bin:/bin:\$PATH\n${collectionScript()}',
        ],
        environment: {'SLURM_FIXTURE_LOG': '$path/calls.log'},
      );
      expect(result.exitCode, 0, reason: '${result.stderr}');
      final snapshot = const SlurmParser().parse(
        const ServerConfig(
          id: 'test',
          name: 'Test',
          host: 'localhost',
          username: 'tester',
        ),
        '${result.stdout}',
      );
      expect(snapshot.activeJobs.single.cpuUsagePercent, 25);
      expect(snapshot.uniqueIdleNodes, 1);
      expect(File('${temp.path}/calls.log').readAsLinesSync(), hasLength(1));
    },
  );
}
