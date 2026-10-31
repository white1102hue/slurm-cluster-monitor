import 'models/slurm_models.dart';

const demoServers = [
  ServerConfig(
    id: 'demo-a',
    name: 'Atlas · 计算集群',
    host: 'atlas.example.org',
    username: 'researcher',
  ),
  ServerConfig(
    id: 'demo-b',
    name: 'Orion · GPU 集群',
    host: 'orion.example.org',
    username: 'researcher',
    authType: AuthType.privateKey,
  ),
];

List<ServerSnapshot> demoSnapshots() {
  final now = DateTime.now().toUtc();
  return [
    ServerSnapshot(
      serverId: 'demo-a',
      serverName: demoServers[0].name,
      timestamp: now,
      uniqueIdleNodes: 18,
      uniqueTotalNodes: 64,
      jobs: [
        SlurmJob(
          serverId: 'demo-a',
          serverName: demoServers[0].name,
          jobId: '48219',
          jobName: 'mof_adsorption_298K',
          state: 'RUNNING',
          partition: 'compute',
          elapsed: '02:34:18',
          timeLimit: '1-00:00:00',
          allocatedCpus: 32,
          usedCpus: 27.6,
          allocatedMemMb: 65536,
          usedMemMb: 38912,
          allocatedNodes: 2,
          nodeList: 'cn[021-022]',
          metricNote: 'CPU 为累计平均等效核数；RSS 为作业步统计估算',
        ),
        SlurmJob(
          serverId: 'demo-a',
          serverName: demoServers[0].name,
          jobId: '48235_3',
          jobName: 'ligand_screening',
          state: 'PENDING',
          partition: 'compute',
          elapsed: '00:00',
          timeLimit: '12:00:00',
          allocatedCpus: 16,
          allocatedNodes: 1,
          allocatedMemMb: 32768,
          reason: 'Priority',
        ),
        SlurmJob(
          serverId: 'demo-a',
          serverName: demoServers[0].name,
          jobId: '48192',
          jobName: 'structure_relaxation',
          state: 'COMPLETED',
          partition: 'compute',
          elapsed: '01:12:09',
          endTime: now.subtract(const Duration(minutes: 8)),
          exitCode: '0:0',
        ),
      ],
      partitions: [
        PartitionNodeStatus(
          serverId: 'demo-a',
          serverName: demoServers[0].name,
          name: 'compute',
          idleNodes: 18,
          allocatedNodes: 42,
          otherNodes: 4,
          totalNodes: 64,
          idleCpus: 1152,
          allocatedCpus: 2688,
          totalCpus: 4096,
        ),
      ],
    ),
    ServerSnapshot(
      serverId: 'demo-b',
      serverName: demoServers[1].name,
      timestamp: now,
      uniqueIdleNodes: 6,
      uniqueTotalNodes: 24,
      jobs: [
        SlurmJob(
          serverId: 'demo-b',
          serverName: demoServers[1].name,
          jobId: '9107',
          jobName: 'graph_model_training',
          state: 'RUNNING',
          partition: 'gpu-a100',
          elapsed: '00:48:52',
          timeLimit: '08:00:00',
          allocatedCpus: 8,
          usedCpus: 5.9,
          allocatedNodes: 1,
          allocatedMemMb: 32768,
          usedMemMb: 29081,
          nodeList: 'gpu-004',
          metricNote: 'CPU 为累计平均等效核数；RSS 为作业步统计估算',
        ),
      ],
      partitions: [
        PartitionNodeStatus(
          serverId: 'demo-b',
          serverName: demoServers[1].name,
          name: 'gpu-a100',
          idleNodes: 6,
          allocatedNodes: 16,
          otherNodes: 2,
          totalNodes: 24,
          idleCpus: 384,
          allocatedCpus: 1024,
          totalCpus: 1536,
        ),
      ],
    ),
  ].map((snapshot) {
    final nodes = <String, NodeResources>{};
    final jobs = snapshot.jobs.map((job) {
      final resources = expandNodeList(job.nodeList)
          .map(
            (name) => nodes.putIfAbsent(
              name,
              () => NodeResources(
                name: name,
                totalMemoryMb: name.startsWith('gpu') ? 262144 : 131072,
              ),
            ),
          )
          .toList();
      return {
        ...job.toJson(),
        'workDir': '/home/researcher/projects/${job.jobName}',
        'nodes': resources.map((n) => n.toJson()).toList(),
      };
    }).toList();
    return ServerSnapshot.fromJson({
      ...snapshot.toJson(),
      'jobs': jobs,
      'nodes': nodes.values.map((n) => n.toJson()).toList(),
    });
  }).toList();
}
