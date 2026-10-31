import 'package:flutter_test/flutter_test.dart';
import 'package:slurm_cluster_monitor/models/slurm_models.dart';
import 'package:slurm_cluster_monitor/services/slurm_parser.dart';
import 'package:slurm_cluster_monitor/services/slurm_ssh_service.dart';

const server = ServerConfig(
  id: 'atlas',
  name: 'Atlas',
  host: 'example.org',
  username: 'alice',
);
String fixture({
  String queue = '',
  String stats = '',
  String accounting = '',
  String nodes = '',
  int queueStatus = 0,
  int statStatus = 0,
  int acctStatus = 0,
  int nodeStatus = 0,
}) =>
    '''
Welcome (login banner)
===META===
1792807200
===SQUEUE===
$queue
===STATUS:SQUEUE:$queueStatus===
===SSTAT===
$stats
===STATUS:SSTAT:$statStatus===
===SACCT===
$accounting
===STATUS:SACCT:$acctStatus===
===SINFO===
$nodes
===STATUS:SINFO:$nodeStatus===
''';
const running =
    '42_1|simulation|compute|RUNNING|00:10:00|1-00:00:00|8|4G|cn[01-02]|None|2|2026-10-24T01:00:00';
const allocation =
    '42_1|simulation|compute|RUNNING|00:10:00|8|4Gc||0:0|2|cn[01-02]|Unknown|2026-10-24T01:00:00|None|1-00:00:00';

void main() {
  group('duration and memory units', () {
    test('days, fractional CPU seconds, and missing values', () {
      expect(parseSlurmDurationToSeconds('2-03:04:05.5'), 183845.5);
      expect(parseSlurmDurationToSeconds('04:05'), 245);
      expect(parseSlurmDurationToSeconds('0.75'), .75);
      expect(parseSlurmDurationToSeconds('UNLIMITED'), isNull);
      expect(parseSlurmDurationToSeconds('bad'), isNull);
    });
    test('per-core, per-node, K/M/G/T and unlimited quotas', () {
      expect(parseSlurmMemoryToMb('4Gc', 8, 2), 32768);
      expect(parseSlurmMemoryToMb('64Gn', 8, 3), 196608);
      expect(parseSlurmMemoryToMb('4096Mc', 16, 1), 65536);
      expect(parseSlurmMemoryToMb('1048576K', 1, 1), 1024);
      expect(parseSlurmMemoryToMb('1.5T', 1, 1), 1572864);
      expect(parseSlurmMemoryToMb('0', 1, 1), isNull);
      expect(parseSlurmMemoryToMb('N/A', 1, 1), isNull);
      expect(parseSlurmMemoryToMb('2Gn', 2, 0), isNull);
    });
  });
  group('aggregate parser', () {
    test(
      'malformed partial sections are marked unavailable, never a valid zero',
      () {
        final s = const SlurmParser().parse(
          server,
          fixture(accounting: 'bad|record', nodes: 'bad|node'),
        );
        expect(s.accountingOk, isFalse);
        expect(s.nodesOk, isFalse);
        expect(s.uniqueIdleNodes, isNull);
        expect(s.warnings, hasLength(2));
      },
    );
    test('maps numeric array element IDs back to displayed array IDs', () {
      final s = const SlurmParser().parse(
        server,
        fixture(
          queue: '$running|72',
          accounting: allocation,
          stats: '72.batch|00:05:00|1G|1G|4',
        ),
      );
      expect(s.activeJobs.single.jobId, '42_1');
      expect(s.activeJobs.single.cpuUsagePercent, 25);
    });
    test('each job uses its own steps and allocation, never the server total', () {
      final s = const SlurmParser().parse(
        server,
        fixture(
          queue:
              '42|first|compute|RUNNING|00:10:00|01:00:00|8|4G|cn01|None|1|2026-10-24T01:00:00|42\n'
              '43|second|compute|RUNNING|00:10:00|01:00:00|4|8G|cn02|None|1|2026-10-24T01:00:00|43',
          stats: '42.batch|00:05:00|1G|1G|4\n43.batch|00:10:00|2G|2G|2',
          accounting:
              '42|first|compute|RUNNING|00:10:00|8|4Gc||0:0|1|cn01|Unknown|2026-10-24T01:00:00|None|01:00:00\n'
              '43|second|compute|RUNNING|00:10:00|4|8Gn||0:0|1|cn02|Unknown|2026-10-24T01:00:00|None|01:00:00',
        ),
      );
      final first = s.activeJobs.singleWhere((j) => j.jobId == '42');
      final second = s.activeJobs.singleWhere((j) => j.jobId == '43');
      expect(first.cpuUsagePercent, 25);
      expect(second.cpuUsagePercent, 50);
      expect(first.memQuotaUsagePercent, 12.5);
      expect(second.memQuotaUsagePercent, 50);
      expect(first.toWidgetJson(stale: false)['cpuPercentText'], '25.0%');
      expect(second.toWidgetJson(stale: false)['cpuPercentText'], '50.0%');
      expect(first.allocatedMemMb, 32768);
      expect(second.allocatedMemMb, 8192);
    });
    test(
      'multiplies AveCPU by task count and avoids batch/extern double counting',
      () {
        final s = const SlurmParser().parse(
          server,
          fixture(
            queue: running,
            accounting: allocation,
            stats:
                '42_1.batch|00:10:00|10G|10G|1\n42_1.extern|00:01:00|1G|1G|1\n42_1.0|00:05:00|1G|2G|4',
          ),
        );
        final j = s.activeJobs.single;
        expect(j.allocatedMemMb, 32768);
        expect(j.usedCpus, 2);
        expect(j.cpuUsagePercent, 25);
        expect(j.usedMemMb, 4096);
        expect(j.memQuotaUsagePercent, 12.5);
      },
    );
    test('reads batch-only jobs; sums disjoint regular steps', () {
      final batch = const SlurmParser().parse(
        server,
        fixture(queue: running, stats: '42_1.batch|00:10:00|2G|2G|1'),
      );
      expect(batch.activeJobs.single.usedCpus, 1);
      expect(batch.activeJobs.single.allocatedMemMb, 8192); // %m is per-node.
      final steps = const SlurmParser().parse(
        server,
        fixture(
          queue: running,
          stats: '42_1.0|00:05:00|1G|1G|2\n42_1.1|00:05:00|2G|2G|2',
        ),
      );
      expect(steps.activeJobs.single.usedCpus, 2);
      expect(steps.activeJobs.single.usedMemMb, 6144);
    });
    test('missing metrics remain unknown; text is allowed to exceed quota', () {
      final noStats = const SlurmParser().parse(
        server,
        fixture(queue: running, statStatus: 1),
      );
      expect(noStats.activeJobs.single.cpuUsagePercent, isNull);
      expect(noStats.warnings, isNotEmpty);
      const j = SlurmJob(
        serverId: 'a',
        serverName: 'A',
        jobId: '1',
        jobName: 'oom',
        state: 'RUNNING',
        allocatedCpus: 2,
        usedCpus: 3,
        allocatedMemMb: 1024,
        usedMemMb: 2048,
        allocatedNodes: 1,
        nodes: [NodeResources(name: 'cn01', totalMemoryMb: 1024)],
      );
      expect(j.cpuUsagePercent, 150);
      expect(j.memUsagePercent, 200);
      expect(j.toWidgetJson(stale: false)['memPct'], 100);
      expect(j.toWidgetJson(stale: false)['cpuPercentText'], '150.0%');
      expect(j.toWidgetJson(stale: false)['memPercentText'], '200.0%');
      expect(
        noStats.activeJobs.single.toWidgetJson(stale: false)['cpuPercentText'],
        '暂无统计',
      );
    });
    test(
      'queue wins over stale accounting; normalizes suffixed terminal states',
      () {
        final s = const SlurmParser().parse(
          server,
          fixture(
            queue: running,
            accounting:
                '${allocation.replaceFirst('RUNNING', 'COMPLETED')}\n43|failed|compute|OUT_OF_MEMORY+|00:02:00|4|16Gn||0:9|2|cn03|2026-10-24T01:02:00|2026-10-24T01:00:00|OutOfMemory|00:30:00',
          ),
        );
        expect(s.activeJobs.single.state, 'RUNNING');
        expect(s.finishedJobs.single.state, 'OUT_OF_MEMORY');
        expect(s.finishedJobs.single.allocatedMemMb, 32768);
        expect(s.finishedJobs.single.endTime!.isUtc, isTrue);
      },
    );
    test('deduplicates shared nodes while keeping each partition accurate', () {
      final s = const SlurmParser().parse(
        server,
        fixture(
          nodes:
              'compute*|up|cn01|idle|0/64/0/64\ncompute*|up|cn02|mixed|32/32/0/64\nshort|up|cn01|idle|0/64/0/64\nshort|up|cn03|down|0/0/64/64',
        ),
      );
      expect(s.partitions.length, 2);
      expect(s.partitions.first.name, 'compute');
      expect(s.partitions.first.idleCpus, 96);
      expect(s.uniqueIdleNodes, 1);
      expect(s.uniqueTotalNodes, 3);
    });
    test('does not treat a failed or truncated command as an empty queue', () {
      expect(
        () => const SlurmParser().parse(server, fixture(queueStatus: 127)),
        throwsFormatException,
      );
      expect(
        () => const SlurmParser().parse(server, '===SQUEUE===\n'),
        throwsFormatException,
      );
      final incomplete = const SlurmParser().parse(
        server,
        fixture(queue: 'malformed'),
      );
      expect(incomplete.queueOk, isFalse);
      expect(incomplete.queueUpdatedAt, isNull);
      expect(incomplete.warnings.single, contains('队列不完整'));
      final s = const SlurmParser().parse(server, fixture(acctStatus: 1));
      expect(s.accountingOk, isFalse);
    });
    test('separates authenticated SSH from command and protocol failures', () {
      expect(
        () => const SlurmParser().parse(
          server,
          '${fixture(queueStatus: 1)}===DETAIL:SQUEUE===squeue: unrecognized option --me\n',
        ),
        throwsA(
          isA<FormatException>()
              .having((e) => e.message, 'phase', contains('SSH 已登录'))
              .having((e) => e.message, 'command', contains('squeue 执行失败'))
              .having(
                (e) => e.message,
                'detail',
                contains('unrecognized option'),
              ),
        ),
      );
      expect(
        () => const SlurmParser().parse(server, fixture(queueStatus: 127)),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'hint',
            contains('PATH'),
          ),
        ),
      );
      expect(
        () => const SlurmParser().parse(server, '===SQUEUE===\n'),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'phase',
            contains('采集输出不完整'),
          ),
        ),
      );
    });
    test('command diagnostics are bounded and redact configured credentials', () {
      const secretServer = ServerConfig(
        id: 'test',
        name: 'Test',
        host: 'localhost',
        username: 'user',
        password: 'fixture-password',
        passphrase: 'fixture-passphrase',
      );
      try {
        const SlurmParser().parse(
          secretServer,
          '${fixture(queueStatus: 1)}'
          '===DETAIL:SQUEUE===fixture-password fixture-passphrase token=hidden-value\n'
          '===DETAIL:SQUEUE===${'x' * 3000}\n',
        );
        fail('expected command failure');
      } on FormatException catch (error) {
        expect(error.message, isNot(contains('fixture-password')));
        expect(error.message, isNot(contains('fixture-passphrase')));
        expect(error.message, isNot(contains('hidden-value')));
        expect(error.message.length, lessThan(1300));
      }
    });
    test('unavailable accounting retains actionable command diagnostics', () {
      final s = const SlurmParser().parse(
        server,
        '${fixture(acctStatus: 1)}===DETAIL:SACCT===slurmdbd: Connection refused\n',
      );
      expect(s.accountingOk, isFalse);
      expect(s.warnings.single, contains('Connection refused'));
    });
    test('round trips snapshots without credentials', () {
      final s = const SlurmParser().parse(
        server,
        fixture(queue: running, accounting: allocation),
      );
      final copy = ServerSnapshot.fromJson(s.toJson());
      expect(copy.activeJobs.single.jobId, '42_1');
      expect(s.toJson().toString(), isNot(contains('password')));
    });
  });
  test(
    'script scopes both queue and accounting to SSH user, captures status and all steps',
    () {
      final script = collectionScript(since: DateTime.utc(2026, 10, 24));
      expect(script, contains('squeue --array -u "\$(id -un)"'));
      expect(script, isNot(contains('--me')));
      expect(script, contains('sacct "\$@" -u "\$(id -un)"'));
      expect(script, contains('slurm_monitor_sacct --array'));
      expect(script, contains('sstat --allsteps'));
      expect(script, contains('2026-10-24T00:00:00'));
      expect(script, contains('STATUS:SQUEUE'));
      expect(shellQuote("a'b"), "'a'\\''b'");
    },
  );
}
