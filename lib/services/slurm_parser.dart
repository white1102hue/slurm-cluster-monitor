import 'dart:convert';
import 'dart:math' as math;
import '../models/slurm_models.dart';

/// Slurm's duration fields have fractional seconds and optional day prefixes.
double? parseSlurmDurationToSeconds(String raw) {
  final match = RegExp(
    r'^(?:(\d+)-)?(\d+(?::\d+){0,2}(?:\.\d+)?)$',
  ).firstMatch(raw.trim());
  if (match == null) return null;
  final parts = match[2]!.split(':').map(double.parse).toList();
  var total = (double.tryParse(match[1] ?? '') ?? 0) * 86400;
  for (var i = 0; i < parts.length; i++) {
    total += parts[parts.length - 1 - i] * math.pow(60, i);
  }
  return total;
}

/// c = per allocated CPU; n = per allocated node. Unsuffixed values are MB.
/// Null is unknown/unlimited, never a fabricated zero quota.
double? parseSlurmMemoryToMb(String raw, int cpus, int nodes) {
  final m = RegExp(
    r'^(\d+(?:\.\d+)?)([KMGTPE]?)([cn]?)$',
    caseSensitive: false,
  ).firstMatch(raw.trim());
  if (m == null) return null;
  final value = double.parse(m[1]!);
  if (value == 0) return null;
  const factors = {
    '': 1.0,
    'K': 1 / 1024,
    'M': 1.0,
    'G': 1024.0,
    'T': 1048576.0,
    'P': 1073741824.0,
    'E': 1099511627776.0,
  };
  final suffix = m[3]!.toLowerCase();
  final count = suffix == 'c'
      ? cpus
      : suffix == 'n'
      ? nodes
      : 1;
  if (count <= 0) return null;
  return value * factors[m[2]!.toUpperCase()]! * count;
}

DateTime? _date(String raw) {
  final s = raw.trim();
  return s.contains('T') ? DateTime.tryParse('${s}Z') : null;
}

String _safeCommandDetail(ServerConfig server, List<String>? lines) {
  var text = (lines ?? []).join('\n');
  for (final secret in [
    server.password,
    server.passphrase,
    server.privateKey,
  ]) {
    if (secret.isNotEmpty) text = text.replaceAll(secret, '[已隐藏]');
  }
  text = text
      .replaceAll(RegExp(r'-----BEGIN [^-]*PRIVATE KEY-----[\s\S]*'), '[私钥已隐藏]')
      .replaceAllMapped(
        RegExp(
          r'(password|passphrase|token|secret|authorization)(\s*[:=]\s*)[^\s;]+',
          caseSensitive: false,
        ),
        (m) => '${m[1]}${m[2]}[已隐藏]',
      )
      .replaceAll(RegExp(r'\x1b\[[0-9;]*[A-Za-z]'), '')
      .replaceAll(RegExp(r'[\x00-\x08\x0b-\x1f\x7f]'), '')
      .trim();
  return text.length > 1000 ? '${text.substring(0, 1000)}…' : text;
}

class _Step {
  _Step(this.id, this.cpu, this.rss, this.tasks);
  final String id;
  final double? cpu, rss;
  final int? tasks;
}

class SlurmParser {
  const SlurmParser();

  ServerSnapshot parse(
    ServerConfig server,
    String output, {
    List<NodeResources> nodeCapacity = const [],
  }) {
    final sections = <String, List<String>>{};
    final statuses = <String, int>{};
    final diagnostics = <String, List<String>>{};
    const sectionNames = {'META', 'SQUEUE', 'SSTAT', 'SACCT', 'SINFO', 'NODES'};
    var duplicateSection = false;
    String? current;
    DateTime? remoteTime;
    for (final line in const LineSplitter().convert(output)) {
      final text = line.trim();
      final status = RegExp(r'^===STATUS:(\w+):(\d+)===$').firstMatch(text);
      final detail = RegExp(r'^===DETAIL:(\w+)===(.*)$').firstMatch(text);
      if (detail != null) {
        (diagnostics[detail[1]!] ??= []).add(detail[2]!);
      } else if (status != null) {
        statuses[status[1]!] = int.parse(status[2]!);
        current = null;
      } else if (sectionNames.any((name) => text == '===$name===')) {
        current = text.replaceAll('=', '');
        duplicateSection |= sections.containsKey(current);
        sections[current] = [];
      } else if (current == 'META') {
        final epoch = int.tryParse(text);
        if (epoch != null) {
          remoteTime = DateTime.fromMillisecondsSinceEpoch(
            epoch * 1000,
            isUtc: true,
          );
        }
      } else if (current != null && text.isNotEmpty) {
        sections[current]!.add(text);
      }
    }
    if (duplicateSection ||
        !statuses.containsKey('SQUEUE') ||
        !sections.containsKey('SQUEUE') ||
        remoteTime == null) {
      throw const FormatException(
        'SSH 已登录，但采集输出不完整。请检查服务器的登录初始化脚本是否提前退出，以及 bash、date 是否可用。',
      );
    }
    if (statuses['SQUEUE'] != 0) {
      final detail = _safeCommandDetail(server, diagnostics['SQUEUE']);
      final hint = statuses['SQUEUE'] == 127
          ? '请检查 SSH 非交互登录环境的 PATH，或使用安装了 Slurm 客户端的登录节点。'
          : '请检查 Slurm 命令版本、集群连接与账号权限。';
      throw FormatException(
        'SSH 已登录，但 squeue 执行失败（退出码 ${statuses['SQUEUE']}）。'
        '${detail.isEmpty ? '' : '\n$detail'}\n$hint',
      );
    }
    final warnings = <String>[];
    for (final name in ['SSTAT', 'SACCT', 'SINFO']) {
      if (statuses[name] != 0) {
        final detail = _safeCommandDetail(server, diagnostics[name]);
        warnings.add(
          '$name 不可用：${name == 'SSTAT'
              ? '资源统计暂缺'
              : name == 'SACCT'
              ? '结束状态暂无法确认'
              : '节点信息暂缺'}${detail.isEmpty ? '' : '（$detail）'}',
        );
      }
    }

    final steps = <String, List<_Step>>{};
    final nodeResources = <String, NodeResources>{
      if (!statuses.containsKey('NODES'))
        for (final node in nodeCapacity) node.name: node,
    };
    if (statuses['NODES'] == 0) {
      for (final row in sections['NODES'] ?? <String>[]) {
        final fields = {
          for (final m in RegExp(r'(?:^|\s)(\w+)=(\S+)').allMatches(row))
            m[1]!: m[2]!,
        };
        final name = fields['NodeName'];
        if (name == null || expandNodeList(name).length != 1) continue;
        double? memory(String key) {
          final value = double.tryParse(fields[key] ?? '');
          return value != null && value >= 0 && value.isFinite ? value : null;
        }

        nodeResources[name] = NodeResources(
          name: name,
          totalMemoryMb: memory('RealMemory'),
        );
      }
    }
    if (statuses.containsKey('NODES') && statuses['NODES'] != 0) {
      warnings.add('节点总内存暂不可用，请检查 scontrol 权限');
    }
    List<NodeResources> resourcesFor(String names) => expandNodeList(
      names,
    ).map((name) => nodeResources[name] ?? NodeResources(name: name)).toList();
    if (statuses['SSTAT'] == 0) {
      for (final line in sections['SSTAT'] ?? <String>[]) {
        final p = line.split('|').map((e) => e.trim()).toList();
        if (p.length < 5 || !p[0].contains('.')) continue;
        final base = p[0].split('.').first;
        final tasks = int.tryParse(p[4]);
        final average = parseSlurmDurationToSeconds(p[1]);
        // AveCPU is per task, so multiply NTasks before comparing with allocation.
        final cpu = average == null || tasks == null || tasks <= 0
            ? null
            : average * tasks;
        final aveRss = parseSlurmMemoryToMb(p[2], 1, 1);
        final maxRss = parseSlurmMemoryToMb(p[3], 1, 1);
        final rss = aveRss != null && tasks != null && tasks > 0
            ? aveRss * tasks
            : maxRss;
        (steps[base] ??= []).add(_Step(p[0].split('.').last, cpu, rss, tasks));
      }
    }

    ({double? cpu, double? rss, String note}) metrics(
      String jobId,
      String elapsed,
    ) {
      final all = steps[jobId] ?? [];
      // batch/extern can encompass regular steps: do not count their cgroups twice.
      final regular = all
          .where((s) => RegExp(r'^\d+$').hasMatch(s.id))
          .toList();
      final selected = regular.isNotEmpty
          ? regular
          : all.where((s) => s.id == 'batch').toList();
      if (selected.isEmpty) return (cpu: null, rss: null, note: '集群尚未提供作业步统计');
      final seconds = parseSlurmDurationToSeconds(elapsed) ?? 0;
      final cpuKnown = selected.every((s) => s.cpu != null);
      final rssKnown = selected.every((s) => s.rss != null);
      return (
        cpu: cpuKnown && seconds > 0
            ? selected.fold<double>(0, (n, s) => n + s.cpu!) / seconds
            : null,
        rss: rssKnown ? selected.fold<double>(0, (n, s) => n + s.rss!) : null,
        note: 'CPU 为累计平均等效核数；RSS 为作业步任务统计估算，非瞬时整作业峰值',
      );
    }

    // Read accounting first; queue always wins over delayed accounting records.
    final jobs = <String, SlurmJob>{};
    final allocations = <String, List<String>>{};
    var accountingOk = statuses['SACCT'] == 0;
    if (statuses['SACCT'] == 0) {
      for (final line in sections['SACCT'] ?? <String>[]) {
        final p = line.split('|').map((e) => e.trim()).toList();
        if (p.length < 15) {
          accountingOk = false;
          continue;
        }
        if (p[0].contains('.')) continue;
        allocations[p[0]] = p;
        final state = normalizeState(p[3]);
        // Active records come exclusively from squeue; missing never means finished.
        if (!isTerminalState(state)) continue;
        final cpus = int.tryParse(p[5]) ?? 0;
        final nodes = int.tryParse(p[9]) ?? 0;
        jobs[p[0]] = SlurmJob(
          serverId: server.id,
          serverName: server.name,
          jobId: p[0],
          jobName: p[1],
          partition: p[2],
          state: state,
          elapsed: p[4],
          allocatedCpus: cpus,
          allocatedNodes: nodes,
          allocatedMemMb: parseSlurmMemoryToMb(p[6], cpus, nodes),
          usedMemMb: parseSlurmMemoryToMb(p[7], 1, 1),
          exitCode: p[8],
          nodeList: p[10],
          endTime: _date(p[11]),
          submitTime: _date(p[12]),
          reason: p[13],
          timeLimit: p[14],
          metricNote: '完成作业的分配记录通常不含 RSS',
          workDir: p.length >= 16 ? p.sublist(15).join('|') : '',
          nodes: resourcesFor(p[10]),
        );
      }
    }
    var malformed = 0;
    if (!accountingOk && statuses['SACCT'] == 0) {
      warnings.add('SACCT 含无法解析的记录，结束状态可能不完整');
    }
    for (final line in sections['SQUEUE']!) {
      final p = line.split('|').map((e) => e.trim()).toList();
      if (p.length < 12 ||
          int.tryParse(p[6]) == null ||
          int.tryParse(p[10]) == null ||
          parseSlurmDurationToSeconds(p[4]) == null) {
        malformed++;
        continue;
      }
      final cpus = int.tryParse(p[6]) ?? 0;
      final nodes = int.tryParse(p[10]) ?? 0;
      final alloc = allocations[p[0]];
      // squeue %m is per-node minimum without c/n; sacct ReqMem is authoritative.
      final reqMem = alloc != null && alloc[6].isNotEmpty
          ? alloc[6]
          : '${p[7]}n';
      // sstat requires the numeric element ID (%A), not the displayed array ID (%i).
      final m = metrics(p.length >= 13 ? p[12] : p[0], p[4]);
      jobs[p[0]] = SlurmJob(
        serverId: server.id,
        serverName: server.name,
        jobId: p[0],
        jobName: p[1],
        partition: p[2],
        state: normalizeState(p[3]),
        elapsed: p[4],
        timeLimit: p[5],
        allocatedCpus: cpus,
        allocatedNodes: nodes,
        allocatedMemMb: parseSlurmMemoryToMb(reqMem, cpus, nodes),
        usedCpus: m.cpu,
        usedMemMb: m.rss,
        nodeList: p[8],
        reason: p[9],
        submitTime: _date(p[11]),
        metricNote: m.note,
        workDir: p.length >= 14
            ? p.sublist(13).join('|')
            : (alloc != null && alloc.length >= 16
                  ? alloc.sublist(15).join('|')
                  : ''),
        nodes: resourcesFor(p[8]),
      );
    }
    if (malformed > 0) {
      jobs.removeWhere((_, job) => !job.isTerminal);
      warnings.add('队列不完整：$malformed 条记录无法解析，显示上次完整队列；作业名称中请避免使用 |');
    }

    // Per-node output prevents double-counting nodes shared by partitions.
    final partitionNodes = <String, Map<String, List<String>>>{};
    final uniqueNodes = <String, List<String>>{};
    var nodesOk = statuses['SINFO'] == 0;
    if (statuses['SINFO'] == 0) {
      for (final line in sections['SINFO'] ?? <String>[]) {
        final p = line.split('|').map((e) => e.trim()).toList();
        if (p.length != 5 || p[4].split('/').length != 4) {
          nodesOk = false;
          continue;
        }
        final partition = p[0].replaceAll('*', '');
        (partitionNodes[partition] ??= {})[p[2]] = p;
        uniqueNodes[p[2]] = p;
      }
    }
    if (!nodesOk && statuses['SINFO'] == 0) {
      warnings.add('SINFO 含无法解析的记录，节点统计暂不可用');
    }
    bool idle(List<String> p) => p[3].toLowerCase() == 'idle';
    final partitions = <PartitionNodeStatus>[];
    for (final entry in partitionNodes.entries) {
      final rows = entry.value.values;
      final idleCount = rows.where(idle).length;
      final allocated = rows
          .where((p) => ['allocated', 'mixed'].contains(p[3].toLowerCase()))
          .length;
      int sumCpu(int index) => rows.fold(
        0,
        (n, p) => n + (int.tryParse(p[4].split('/')[index]) ?? 0),
      );
      partitions.add(
        PartitionNodeStatus(
          serverId: server.id,
          serverName: server.name,
          name: entry.key,
          availability: rows.first[1],
          idleNodes: idleCount,
          allocatedNodes: allocated,
          otherNodes: rows.length - idleCount - allocated,
          totalNodes: rows.length,
          allocatedCpus: sumCpu(0),
          idleCpus: sumCpu(1),
          totalCpus: sumCpu(3),
        ),
      );
    }
    return ServerSnapshot(
      serverId: server.id,
      serverName: server.name,
      timestamp: remoteTime,
      jobs: jobs.values.toList(),
      partitions: partitions,
      warnings: warnings,
      accountingOk: accountingOk,
      nodesOk: nodesOk,
      uniqueIdleNodes: nodesOk ? uniqueNodes.values.where(idle).length : null,
      uniqueTotalNodes: nodesOk ? uniqueNodes.length : null,
      nodes: nodeResources.values.toList(),
      queueOk: malformed == 0,
      queueTimestamp: malformed == 0 ? remoteTime : null,
      configRevision: server.revision,
    );
  }
}
