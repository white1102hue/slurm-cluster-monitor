import 'package:flutter_test/flutter_test.dart';
import 'package:slurm_cluster_monitor/models/slurm_models.dart';
import 'package:slurm_cluster_monitor/services/slurm_parser.dart';

void main() {
  test(
    'retired node probe settings and state are discarded from legacy caches',
    () {
      const server = ServerConfig(
        id: 'a',
        name: 'A',
        host: 'localhost',
        username: 'u',
      );
      final config = ServerConfig.fromSecureJson({
        ...server.toSecureJson(),
        'nodeFingerprints': {'cn01': 'retired'},
      });
      expect(config.toSecureJson(), isNot(contains('nodeFingerprints')));
      final node = NodeResources.fromJson({
        'name': 'cn01',
        'state': 'MIXED',
        'totalMemoryMb': 131072,
        'freeMemoryMb': 81920,
        'disks': [],
      });
      expect(node.toJson().keys, unorderedEquals(['name', 'totalMemoryMb']));
      expect(node.totalMemoryMb, 131072);
    },
  );
  test(
    'hostlists expand padded, multiple and compound ranges without shell syntax',
    () {
      expect(expandNodeList('cn[001-002,005],gpu-04'), [
        'cn001',
        'cn002',
        'cn005',
        'gpu-04',
      ]);
      expect(expandNodeList('r[1-2]n[01-02]'), [
        'r1n01',
        'r1n02',
        'r2n01',
        'r2n02',
      ]);
      expect(expandNodeList('cn[1-999999]', limit: 3), ['cn1', 'cn2', 'cn3']);
      expect(expandNodeList(r'$(id),-oProxyCommand=bad'), isEmpty);
    },
  );
  test(
    'memory denominator is total memory of all allocated nodes; missing capacity stays unknown',
    () {
      SlurmJob job(List<NodeResources> nodes) => SlurmJob(
        serverId: 'a',
        serverName: 'A',
        jobId: '42',
        jobName: 'test',
        state: 'RUNNING',
        allocatedNodes: 2,
        allocatedMemMb: 8192,
        usedMemMb: 4096,
        nodes: nodes,
      );
      final complete = job(const [
        NodeResources(name: 'cn01', totalMemoryMb: 32768),
        NodeResources(name: 'cn02', totalMemoryMb: 98304),
      ]);
      expect(complete.memUsagePercent, 3.125);
      expect(complete.memQuotaUsagePercent, 50);
      expect(complete.memText, '4.0 GB / 128.0 GB');
      expect(
        job(const [
          NodeResources(name: 'cn01', totalMemoryMb: 32768),
        ]).memUsagePercent,
        isNull,
      );
      final copy = SlurmJob.fromJson(complete.toJson());
      expect(copy.memUsagePercent, 3.125);
      expect(copy.toWidgetJson(stale: false)['memPercentText'], '3.1%');
    },
  );
  test('parses work directory with spaces and pipes and Slurm node memory', () {
    const server = ServerConfig(
      id: 'a',
      name: 'A',
      host: 'localhost',
      username: 'u',
    );
    final snapshot = const SlurmParser().parse(server, '''===META===
1792807200
===SQUEUE===
42|job|compute|RUNNING|00:10:00|01:00:00|8|4G|cn01|None|1|2026-10-24T01:00:00|42|/home/u/a b|c
===STATUS:SQUEUE:0===
===SSTAT===
42.batch|00:05:00|1G|1G|4
===STATUS:SSTAT:0===
===SACCT===
===STATUS:SACCT:0===
===SINFO===
compute|up|cn01|mixed|8/56/0/64
===STATUS:SINFO:0===
===NODES===
NodeName=cn01 NodeAddr=192.0.2.10 RealMemory=131072 FreeMem=81920 State=MIXED
===STATUS:NODES:0===
''');
    expect(snapshot.activeJobs.single.workDir, '/home/u/a b|c');
    expect(snapshot.activeJobs.single.memUsagePercent, 3.125);
    expect(snapshot.nodes.single.totalMemoryMb, 131072);
    expect(snapshot.nodes.single.toJson().containsKey('freeMemoryMb'), isFalse);
    expect(snapshot.nodes.single.toJson().containsKey('disks'), isFalse);
  });
}
