import '../models/slurm_models.dart';

class JobTransition {
  const JobTransition(this.job, this.previous, {this.configRevision = ''});
  final SlurmJob job;
  final String? previous;
  final String configRevision;
  String get identity =>
      '${job.key}/${job.submitTime?.toIso8601String() ?? ''}/${job.state}';
  String get title =>
      '${const {'RUNNING': '作业开始运行', 'COMPLETED': '作业已完成', 'FAILED': '作业失败', 'TIMEOUT': '作业超时', 'OUT_OF_MEMORY': '作业内存不足'}[job.state]} · ${job.serverName}';
  String get body {
    final prefix = '${job.jobName} #${job.jobId}';
    return switch (job.state) {
      'RUNNING' => '$prefix 已分配至 ${job.nodeList}',
      'COMPLETED' => '$prefix 总耗时 ${job.elapsed}',
      'FAILED' =>
        '$prefix 退出码 ${job.exitCode}；${job.reason.isEmpty ? '请查看作业日志' : job.reason}',
      'TIMEOUT' => '$prefix 达到时间上限 ${job.timeLimit}，已运行 ${job.elapsed}',
      'OUT_OF_MEMORY' => '$prefix 超出内存配额 ${formatMemory(job.allocatedMemMb)}',
      _ => prefix,
    };
  }

  Map<String, dynamic> toJson() => {
    'job': job.toJson(),
    'previous': previous,
    'configRevision': configRevision,
  };
  factory JobTransition.fromJson(Map<String, dynamic> j) => JobTransition(
    SlurmJob.fromJson(Map<String, dynamic>.from(j['job'] as Map)),
    j['previous'] as String?,
    configRevision: j['configRevision'] as String? ?? '',
  );
}

/// Persistent baselines suppress old history while catching jobs completed between polls.
class JobStateTracker {
  final _states = <String, Map<String, dynamic>>{};
  final _baselines = <String, DateTime>{};
  final _delivered = <String, DateTime>{};
  final pending = <JobTransition>[];
  final _revisions = <String, String>{};

  void configure(List<ServerConfig> servers) {
    final enabled = {
      for (final s in servers.where((s) => s.enabled)) s.id: s.revision,
    };
    final keep = enabled.keys
        .where((id) => (_revisions[id] ?? '') == enabled[id])
        .toSet();
    retainServers(keep);
    _revisions
      ..clear()
      ..addAll(enabled);
    pending.removeWhere((e) => enabled[e.job.serverId] != e.configRevision);
  }

  List<JobTransition> observe(ServerSnapshot snapshot) {
    if (!snapshot.isOnline) return [];
    final baseline = _baselines[snapshot.serverId];
    final events = <JobTransition>[];
    for (final job in snapshot.jobs) {
      if (!snapshot.queueOk && !job.isTerminal) continue;
      final old = _states[job.key];
      final sameSubmission =
          old != null &&
          (old['submit'] == job.submitTime?.toIso8601String() ||
              job.submitTime == null);
      final previous = sameSubmission ? old['state'] as String? : null;
      final endAfterBaseline =
          baseline != null &&
          job.endTime != null &&
          job.endTime!.isAfter(baseline);
      final shouldNotify =
          (previous == 'PENDING' && job.state == 'RUNNING') ||
          (const {
                'COMPLETED',
                'FAILED',
                'TIMEOUT',
                'OUT_OF_MEMORY',
              }.contains(job.state) &&
              previous != job.state &&
              (previous != null || endAfterBaseline));
      if (shouldNotify) {
        final event = JobTransition(
          job,
          previous,
          configRevision: snapshot.configRevision,
        );
        if (!_delivered.containsKey(event.identity) &&
            !pending.any((e) => e.identity == event.identity)) {
          events.add(event);
          pending.add(event);
        }
      }
      _states[job.key] = {
        'state': job.state,
        'submit': job.submitTime?.toIso8601String(),
        'seen': snapshot.timestamp.toIso8601String(),
      };
    }
    // An accounting outage must not establish a baseline and hide missed completions.
    if (snapshot.accountingOk) {
      _baselines.putIfAbsent(snapshot.serverId, () => snapshot.timestamp);
    }
    final cutoff = snapshot.timestamp.subtract(const Duration(days: 7));
    _states.removeWhere(
      (_, v) => DateTime.parse(v['seen'] as String).isBefore(cutoff),
    );
    _delivered.removeWhere((_, time) => time.isBefore(cutoff));
    pending.removeWhere(
      (e) => (e.job.endTime ?? e.job.submitTime ?? snapshot.timestamp).isBefore(
        cutoff,
      ),
    );
    return events;
  }

  void acknowledge(JobTransition event, DateTime time) {
    _delivered[event.identity] = time;
    pending.removeWhere((e) => e.identity == event.identity);
  }

  void retainServers(Set<String> ids) {
    _states.removeWhere((key, _) => !ids.contains(key.split('/').first));
    _baselines.removeWhere((id, _) => !ids.contains(id));
    _delivered.removeWhere((key, _) => !ids.contains(key.split('/').first));
    pending.removeWhere((e) => !ids.contains(e.job.serverId));
  }

  Map<String, dynamic> toJson() => {
    'revisions': _revisions,
    'states': _states,
    'baselines': _baselines.map((k, v) => MapEntry(k, v.toIso8601String())),
    'delivered': _delivered.map((k, v) => MapEntry(k, v.toIso8601String())),
    'pending': pending.map((e) => e.toJson()).toList(),
  };
  void restore(Map<String, dynamic> j) {
    _states.clear();
    _baselines.clear();
    _delivered.clear();
    pending.clear();
    _revisions.clear();
    final revisions = j['revisions'];
    if (revisions is Map) {
      revisions.forEach((k, v) {
        if (k is String && v is String) _revisions[k] = v;
      });
    }
    final states = j['states'];
    if (states is Map) {
      states.forEach((k, v) {
        if (k is String &&
            v is Map &&
            v['state'] is String &&
            v['seen'] is String &&
            DateTime.tryParse(v['seen'] as String) != null) {
          _states[k] = Map<String, dynamic>.from(v);
        }
      });
    }
    void dates(String name, Map<String, DateTime> target) {
      final values = j[name];
      if (values is Map) {
        values.forEach((k, v) {
          if (k is String && v is String) {
            final date = DateTime.tryParse(v);
            if (date != null) target[k] = date;
          }
        });
      }
    }

    dates('baselines', _baselines);
    dates('delivered', _delivered);
    final values = j['pending'];
    for (final e in values is List ? values : const []) {
      try {
        if (e is Map) {
          pending.add(JobTransition.fromJson(Map<String, dynamic>.from(e)));
        }
      } on FormatException {
        continue;
      } on TypeError {
        continue;
      }
    }
  }
}
