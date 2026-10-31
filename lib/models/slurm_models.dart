import 'dart:math' as math;
import 'node_resources.dart';
export 'node_resources.dart';

enum AuthType { password, privateKey }

/// Serialized only into Android Keystore-backed secure storage.
class ServerConfig {
  const ServerConfig({
    required this.id,
    required this.name,
    required this.host,
    required this.username,
    this.port = 22,
    this.authType = AuthType.password,
    this.password = '',
    this.privateKey = '',
    this.passphrase = '',
    this.fingerprint = '',
    this.enabled = true,
    this.revision = '',
  });
  final String id, name, host, username, password, privateKey, passphrase;
  final String fingerprint;
  final int port;
  final AuthType authType;
  final bool enabled;
  // Non-secret identity epoch, changed when the endpoint/auth or enablement changes.
  final String revision;

  bool hasSameConnection(ServerConfig other) =>
      host == other.host &&
      port == other.port &&
      username == other.username &&
      authType == other.authType &&
      password == other.password &&
      privateKey == other.privateKey &&
      passphrase == other.passphrase &&
      fingerprint == other.fingerprint;

  ServerConfig copyWith({
    bool? enabled,
    String? fingerprint,
    String? revision,
  }) => ServerConfig(
    id: id,
    name: name,
    host: host,
    port: port,
    username: username,
    authType: authType,
    password: password,
    privateKey: privateKey,
    passphrase: passphrase,
    enabled: enabled ?? this.enabled,
    revision: revision ?? this.revision,
    fingerprint: fingerprint ?? this.fingerprint,
  );

  Map<String, dynamic> toSecureJson() => {
    'id': id,
    'name': name,
    'host': host,
    'port': port,
    'username': username,
    'authType': authType.name,
    'password': password,
    'privateKey': privateKey,
    'passphrase': passphrase,
    'fingerprint': fingerprint,
    'enabled': enabled,
    'revision': revision,
  };

  factory ServerConfig.fromSecureJson(Map<String, dynamic> j) => ServerConfig(
    id: j['id'] as String,
    name: j['name'] as String,
    host: j['host'] as String,
    username: j['username'] as String,
    port: j['port'] as int? ?? 22,
    authType: j['authType'] == 'privateKey'
        ? AuthType.privateKey
        : AuthType.password,
    password: j['password'] as String? ?? '',
    privateKey: j['privateKey'] as String? ?? '',
    passphrase: j['passphrase'] as String? ?? '',
    fingerprint: j['fingerprint'] as String? ?? '',
    enabled: j['enabled'] as bool? ?? true,
    revision: j['revision'] as String? ?? '',
  );
}

String normalizeState(String raw) {
  final s = raw
      .trim()
      .toUpperCase()
      .split(RegExp(r'\s+'))
      .first
      .replaceAll('+', '');
  return const {
        'PD': 'PENDING',
        'R': 'RUNNING',
        'CG': 'COMPLETING',
        'CD': 'COMPLETED',
        'F': 'FAILED',
        'TO': 'TIMEOUT',
        'OOM': 'OUT_OF_MEMORY',
        'CA': 'CANCELLED',
        'S': 'SUSPENDED',
        'NF': 'NODE_FAIL',
        'PR': 'PREEMPTED',
      }[s] ??
      s;
}

bool isTerminalState(String state) => const {
  'COMPLETED',
  'FAILED',
  'TIMEOUT',
  'OUT_OF_MEMORY',
  'CANCELLED',
  'NODE_FAIL',
  'PREEMPTED',
  'BOOT_FAIL',
  'DEADLINE',
  'REVOKED',
}.contains(normalizeState(state));

String formatMemory(double? mb) {
  if (mb == null || !mb.isFinite || mb <= 0) return mb == 0 ? '0 MB' : '—';
  if (mb >= 1048576) return '${(mb / 1048576).toStringAsFixed(1)} TB';
  if (mb >= 1024) return '${(mb / 1024).toStringAsFixed(1)} GB';
  return '${mb.toStringAsFixed(0)} MB';
}

String clockText(DateTime? value) {
  if (value == null) return '尚未刷新';
  final d = value.toLocal();
  return '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}:${d.second.toString().padLeft(2, '0')}';
}

class SlurmJob {
  const SlurmJob({
    required this.serverId,
    required this.serverName,
    required this.jobId,
    required this.jobName,
    required this.state,
    this.partition = '',
    this.elapsed = '00:00',
    this.timeLimit = '—',
    this.allocatedCpus = 0,
    this.allocatedNodes = 0,
    this.allocatedMemMb,
    this.usedCpus,
    this.usedMemMb,
    this.nodeList = '',
    this.reason = '',
    this.exitCode = '',
    this.endTime,
    this.submitTime,
    this.metricNote = '',
    this.workDir = '',
    this.nodes = const [],
  });
  final String serverId, serverName, jobId, jobName, state, partition;
  final String elapsed, timeLimit, nodeList, reason, exitCode, metricNote;
  final int allocatedCpus, allocatedNodes;
  final double? allocatedMemMb, usedCpus, usedMemMb;
  final DateTime? endTime, submitTime;
  final String workDir;
  final List<NodeResources> nodes;
  String get key => '$serverId/$jobId';
  String get identity => '$key/${submitTime?.toIso8601String() ?? ''}';
  bool get isAbnormalEnd =>
      isTerminal &&
      !const {'COMPLETED', 'CANCELLED'}.contains(normalizeState(state));
  bool get isRunning => normalizeState(state) == 'RUNNING';
  bool get isPending => normalizeState(state) == 'PENDING';
  bool get isTerminal => isTerminalState(state);
  // Preserve >100% in text; clamp only when drawing progress bars.
  double? get cpuUsagePercent => usedCpus != null && allocatedCpus > 0
      ? usedCpus! / allocatedCpus * 100
      : null;
  double? get memQuotaUsagePercent =>
      usedMemMb != null && (allocatedMemMb ?? 0) > 0
      ? usedMemMb! / allocatedMemMb! * 100
      : null;
  double? get nodeMemoryMb {
    if (nodes.isEmpty ||
        nodes.length != allocatedNodes ||
        nodes.any((n) => (n.totalMemoryMb ?? 0) <= 0)) {
      return null;
    }
    return nodes.fold<double>(0, (sum, node) => sum + node.totalMemoryMb!);
  }

  double? get memUsagePercent => usedMemMb != null && nodeMemoryMb != null
      ? usedMemMb! / nodeMemoryMb! * 100
      : null;
  String get cpuText =>
      '${usedCpus?.toStringAsFixed(1) ?? '—'} / $allocatedCpus 核';
  String get memText =>
      '${formatMemory(usedMemMb)} / ${formatMemory(nodeMemoryMb)}';

  Map<String, dynamic> toJson() => {
    'serverId': serverId,
    'serverName': serverName,
    'jobId': jobId,
    'jobName': jobName,
    'state': state,
    'partition': partition,
    'elapsed': elapsed,
    'timeLimit': timeLimit,
    'allocatedCpus': allocatedCpus,
    'allocatedNodes': allocatedNodes,
    'allocatedMemMb': allocatedMemMb,
    'usedCpus': usedCpus,
    'usedMemMb': usedMemMb,
    'nodeList': nodeList,
    'reason': reason,
    'exitCode': exitCode,
    'endTime': endTime?.toIso8601String(),
    'submitTime': submitTime?.toIso8601String(),
    'metricNote': metricNote,
    'workDir': workDir,
    'nodes': nodes.map((n) => n.toJson()).toList(),
  };
  Map<String, dynamic> toWidgetJson({required bool stale}) => {
    'key': key,
    'serverName': serverName,
    'jobId': jobId,
    'jobName': jobName,
    'nodeList': nodeList,
    'elapsed': elapsed,
    'workDir': workDir,
    'cpuText': cpuText,
    'memText': memText,
    'cpuPercentText': percentText(cpuUsagePercent),
    'memPercentText': percentText(memUsagePercent),
    'cpuPct': cpuUsagePercent?.clamp(0, 100).round() ?? 0,
    'memPct': memUsagePercent?.clamp(0, 100).round() ?? 0,
    'stale': stale,
  };
  factory SlurmJob.fromJson(Map<String, dynamic> j) => SlurmJob(
    serverId: j['serverId'] as String,
    serverName: j['serverName'] as String,
    jobId: j['jobId'] as String,
    jobName: j['jobName'] as String,
    state: j['state'] as String,
    partition: j['partition'] as String? ?? '',
    elapsed: j['elapsed'] as String? ?? '',
    timeLimit: j['timeLimit'] as String? ?? '—',
    allocatedCpus: j['allocatedCpus'] as int? ?? 0,
    allocatedNodes: j['allocatedNodes'] as int? ?? 0,
    allocatedMemMb: (j['allocatedMemMb'] as num?)?.toDouble(),
    usedCpus: (j['usedCpus'] as num?)?.toDouble(),
    usedMemMb: (j['usedMemMb'] as num?)?.toDouble(),
    nodeList: j['nodeList'] as String? ?? '',
    reason: j['reason'] as String? ?? '',
    exitCode: j['exitCode'] as String? ?? '',
    endTime: DateTime.tryParse(j['endTime'] as String? ?? ''),
    submitTime: DateTime.tryParse(j['submitTime'] as String? ?? ''),
    metricNote: j['metricNote'] as String? ?? '',
    workDir: j['workDir'] as String? ?? '',
    nodes: (j['nodes'] as List? ?? [])
        .map((n) => NodeResources.fromJson(Map<String, dynamic>.from(n as Map)))
        .toList(),
  );
}

String percentText(double? value) =>
    value == null ? '暂无统计' : '${value.toStringAsFixed(1)}%';

class PartitionNodeStatus {
  const PartitionNodeStatus({
    required this.serverId,
    required this.serverName,
    required this.name,
    this.availability = 'up',
    this.allocatedNodes = 0,
    this.idleNodes = 0,
    this.otherNodes = 0,
    this.totalNodes = 0,
    this.allocatedCpus = 0,
    this.idleCpus = 0,
    this.totalCpus = 0,
  });
  final String serverId, serverName, name, availability;
  final int allocatedNodes, idleNodes, otherNodes, totalNodes;
  final int allocatedCpus, idleCpus, totalCpus;
  double get idleNodeRatio => totalNodes > 0 ? idleNodes / totalNodes : 0;
  Map<String, dynamic> toJson() => {
    'serverId': serverId,
    'serverName': serverName,
    'name': name,
    'availability': availability,
    'allocatedNodes': allocatedNodes,
    'idleNodes': idleNodes,
    'otherNodes': otherNodes,
    'totalNodes': totalNodes,
    'allocatedCpus': allocatedCpus,
    'idleCpus': idleCpus,
    'totalCpus': totalCpus,
  };
  factory PartitionNodeStatus.fromJson(Map<String, dynamic> j) =>
      PartitionNodeStatus(
        serverId: j['serverId'] as String,
        serverName: j['serverName'] as String,
        name: j['name'] as String,
        availability: j['availability'] as String? ?? 'up',
        allocatedNodes: j['allocatedNodes'] as int? ?? 0,
        idleNodes: j['idleNodes'] as int? ?? 0,
        otherNodes: j['otherNodes'] as int? ?? 0,
        totalNodes: j['totalNodes'] as int? ?? 0,
        allocatedCpus: j['allocatedCpus'] as int? ?? 0,
        idleCpus: j['idleCpus'] as int? ?? 0,
        totalCpus: j['totalCpus'] as int? ?? 0,
      );
}

const jobHistoryRetention = Duration(days: 7);

class ServerSnapshot {
  const ServerSnapshot({
    required this.serverId,
    required this.serverName,
    required this.timestamp,
    this.jobs = const [],
    this.partitions = const [],
    this.error,
    this.warnings = const [],
    this.accountingOk = true,
    this.nodesOk = true,
    this.uniqueIdleNodes,
    this.uniqueTotalNodes,
    this.nextRetry,
    this.nodes = const [],
    this.configRevision = '',
    this.queueOk = true,
    this.queueTimestamp,
  });
  final String serverId, serverName;
  final DateTime timestamp;
  final List<SlurmJob> jobs;
  final List<PartitionNodeStatus> partitions;
  final String? error;
  final List<String> warnings;
  final bool accountingOk, nodesOk, queueOk;
  final String configRevision;
  final DateTime? queueTimestamp;
  DateTime? get queueUpdatedAt =>
      queueTimestamp ?? (queueOk ? timestamp : null);
  DateTime get oldestTimestamp =>
      queueUpdatedAt != null && queueUpdatedAt!.isBefore(timestamp)
      ? queueUpdatedAt!
      : timestamp;
  final int? uniqueIdleNodes, uniqueTotalNodes;
  final DateTime? nextRetry;
  final List<NodeResources> nodes;
  bool get isOnline => error == null;
  List<SlurmJob> get activeJobs => jobs.where((j) => !j.isTerminal).toList();
  List<SlurmJob> get finishedJobs => jobs.where((j) => j.isTerminal).toList();

  /// Accounting is queried incrementally. Keep confirmed terminal records while
  /// replacing active jobs entirely from the current queue. A missing queue row
  /// never proves completion, and a reused job ID always takes the newest row.
  ServerSnapshot withHistory(ServerSnapshot? previous) {
    if (previous?.configRevision != configRevision) previous = null;
    final cutoff = timestamp.subtract(jobHistoryRetention);
    bool retain(SlurmJob job) =>
        !job.isTerminal ||
        job.endTime == null ||
        !job.endTime!.isBefore(cutoff);
    final merged = <String, SlurmJob>{
      if (previous?.serverId == serverId)
        for (final job in previous!.finishedJobs.where(retain)) job.jobId: job,
      if (!queueOk && previous?.serverId == serverId)
        for (final job in previous!.activeJobs) job.jobId: job,
      for (final job in jobs.where(
        (j) => retain(j) && (queueOk || j.isTerminal),
      ))
        job.jobId: job,
    };
    return ServerSnapshot(
      serverId: serverId,
      serverName: serverName,
      timestamp: timestamp,
      jobs: merged.values.toList(),
      partitions: partitions,
      error: error,
      warnings: warnings,
      accountingOk: accountingOk,
      nodesOk: nodesOk,
      uniqueIdleNodes: uniqueIdleNodes,
      uniqueTotalNodes: uniqueTotalNodes,
      nextRetry: nextRetry,
      nodes: nodes,
      configRevision: configRevision,
      queueOk: queueOk,
      queueTimestamp: queueOk ? timestamp : previous?.queueUpdatedAt,
    );
  }

  ServerSnapshot forServer(ServerConfig server) {
    if (serverName == server.name && configRevision == server.revision) {
      return this;
    }
    return ServerSnapshot.fromJson({
      ...toJson(),
      'serverName': server.name,
      'configRevision': server.revision,
      'jobs': [
        for (final j in jobs) {...j.toJson(), 'serverName': server.name},
      ],
      'partitions': [
        for (final p in partitions) {...p.toJson(), 'serverName': server.name},
      ],
    });
  }

  ServerSnapshot offline(String message, DateTime? retry) => ServerSnapshot(
    serverId: serverId,
    serverName: serverName,
    timestamp: timestamp,
    jobs: jobs,
    partitions: partitions,
    error: message,
    warnings: warnings,
    accountingOk: false,
    nodesOk: false,
    uniqueIdleNodes: uniqueIdleNodes,
    uniqueTotalNodes: uniqueTotalNodes,
    nextRetry: retry,
    nodes: nodes,
    configRevision: configRevision,
    queueOk: false,
    queueTimestamp: queueUpdatedAt,
  );
  Map<String, dynamic> toJson() => {
    'serverId': serverId,
    'serverName': serverName,
    'timestamp': timestamp.toIso8601String(),
    'jobs': jobs.map((j) => j.toJson()).toList(),
    'partitions': partitions.map((p) => p.toJson()).toList(),
    'error': error,
    'warnings': warnings,
    'accountingOk': accountingOk,
    'nodesOk': nodesOk,
    'uniqueIdleNodes': uniqueIdleNodes,
    'uniqueTotalNodes': uniqueTotalNodes,
    'nextRetry': nextRetry?.toIso8601String(),
    'nodes': nodes.map((n) => n.toJson()).toList(),
    'configRevision': configRevision,
    'queueOk': queueOk,
    'queueTimestamp': queueTimestamp?.toIso8601String(),
  };
  factory ServerSnapshot.fromJson(Map<String, dynamic> j) => ServerSnapshot(
    serverId: j['serverId'] as String,
    serverName: j['serverName'] as String,
    timestamp: DateTime.parse(j['timestamp'] as String),
    jobs: (j['jobs'] as List? ?? [])
        .map((e) => SlurmJob.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList(),
    partitions: (j['partitions'] as List? ?? [])
        .map(
          (e) =>
              PartitionNodeStatus.fromJson(Map<String, dynamic>.from(e as Map)),
        )
        .toList(),
    error: j['error'] as String?,
    warnings: List<String>.from(j['warnings'] as List? ?? []),
    accountingOk: j['accountingOk'] as bool? ?? true,
    nodesOk: j['nodesOk'] as bool? ?? true,
    uniqueIdleNodes: j['uniqueIdleNodes'] as int?,
    uniqueTotalNodes: j['uniqueTotalNodes'] as int?,
    nextRetry: DateTime.tryParse(j['nextRetry'] as String? ?? ''),
    nodes: (j['nodes'] as List? ?? [])
        .map((n) => NodeResources.fromJson(Map<String, dynamic>.from(n as Map)))
        .toList(),
    configRevision: j['configRevision'] as String? ?? '',
    queueOk: j['queueOk'] as bool? ?? true,
    queueTimestamp: DateTime.tryParse(j['queueTimestamp'] as String? ?? ''),
  );
}

int retryDelay(int failures, int interval) => math.min(
  math.max(300, interval),
  math.max(interval, 3) * (1 << (failures - 1).clamp(0, 6)),
);

/// Tolerant cache boundary: a damaged record must not prevent other hosts loading.
List<ServerSnapshot> readSnapshots(Map data, Iterable<ServerConfig> servers) {
  final configs = {for (final s in servers.where((s) => s.enabled)) s.id: s};
  final raw = data['snapshots'];
  if (raw is! List) return [];
  final result = <ServerSnapshot>[];
  for (final value in raw) {
    try {
      if (value is! Map) continue;
      final snapshot = ServerSnapshot.fromJson(
        Map<String, dynamic>.from(value),
      );
      final server = configs[snapshot.serverId];
      if (server != null && snapshot.configRevision == server.revision) {
        result.add(snapshot.forServer(server));
      }
    } on FormatException {
      continue;
    } on TypeError {
      continue;
    }
  }
  return result;
}

String stateLabel(String s) =>
    const {
      'RUNNING': '运行中',
      'PENDING': '排队中',
      'COMPLETING': '结束中',
      'COMPLETED': '已完成',
      'FAILED': '失败',
      'TIMEOUT': '超时',
      'OUT_OF_MEMORY': '内存不足',
      'CANCELLED': '已取消',
    }[s] ??
    s;
