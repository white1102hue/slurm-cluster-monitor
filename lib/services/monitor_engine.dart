import 'dart:async';
import 'dart:math' as math;
import '../models/slurm_models.dart';
import 'slurm_ssh_service.dart';

/// Each host has its own deadline and in-flight guard; a slow cluster cannot
/// block polling of healthy clusters. A maximum of four hosts run concurrently.
class MonitorEngine {
  MonitorEngine({
    required this.source,
    required this.onChanged,
    this.onPollingChanged,
    DateTime Function()? now,
    double Function()? random,
  }) : now = now ?? DateTime.now,
       random = random ?? math.Random().nextDouble;
  final SnapshotSource source;
  final Future<void> Function(ServerSnapshot? snapshot) onChanged;
  final void Function(bool)? onPollingChanged;
  final DateTime Function() now;
  final double Function() random;
  final snapshots = <String, ServerSnapshot>{};
  final accountingCursor = <String, DateTime>{};
  final _servers = <String, ServerConfig>{};
  final _revision = <String, Object>{};
  final _historyBackfill = <String, DateTime>{};
  final _due = <String, DateTime>{};
  final _failures = <String, int>{};
  final _inFlight = <String>{};
  final _requests = <String, Future<void>>{};
  final _attempted = <String, DateTime>{};
  final _blocked = <String>{};
  int intervalSeconds = 10;
  bool _closed = false;
  bool get isPolling => _inFlight.isNotEmpty;
  Iterable<String> get serverIds => _servers.keys;

  void configure(List<ServerConfig> configs, int interval) {
    final intervalChanged = intervalSeconds != interval.clamp(2, 3600);
    intervalSeconds = interval.clamp(2, 3600);
    final enabled = {for (final s in configs.where((s) => s.enabled)) s.id: s};
    final ids = {..._servers.keys, ...enabled.keys};
    for (final id in ids) {
      final next = enabled[id];
      final previous = _servers[id];
      final changed =
          next == null ||
          previous == null ||
          previous.revision != next.revision ||
          !previous.hasSameConnection(next);
      if (changed) {
        source.close(id);
        snapshots.remove(id);
        accountingCursor.remove(id);
        _historyBackfill.remove(id);
        _failures.remove(id);
        _due.remove(id);
        _blocked.remove(id);
        _attempted.remove(id);
      } else if (previous.name != next.name && snapshots[id] != null) {
        snapshots[id] = snapshots[id]!.forServer(next);
      }
      if (next == null) {
        _revision.remove(id);
      } else if (changed) {
        _revision[id] = Object();
      }
    }
    _servers
      ..clear()
      ..addAll(enabled);
    snapshots.removeWhere((id, _) => !enabled.containsKey(id));
    accountingCursor.removeWhere((id, _) => !enabled.containsKey(id));
    for (final id in enabled.keys) {
      _due.putIfAbsent(id, now);
      if (intervalChanged &&
          _attempted.containsKey(id) &&
          !_failures.containsKey(id)) {
        _due[id] = now().add(Duration(seconds: intervalSeconds));
      }
    }
  }

  Future<void> tick({bool force = false}) async {
    if (_closed) return;
    final tasks = <Future<void>>[];
    final candidates = _servers.values.toList()
      ..sort(
        (a, b) => (_due[a.id] ?? DateTime(1970)).compareTo(
          _due[b.id] ?? DateTime(1970),
        ),
      );
    for (final server in candidates) {
      if (_inFlight.length >= 4) break;
      if (_requests.containsKey(server.id) ||
          (!force && _blocked.contains(server.id))) {
        continue;
      }
      if (!force && (_due[server.id]?.isAfter(now()) ?? false)) continue;
      tasks.add(_start(server));
    }
    await Future.wait(tasks);
  }

  Future<void> _start(ServerConfig server) {
    final wasPolling = isPolling;
    _inFlight.add(server.id);
    if (!wasPolling) onPollingChanged?.call(true);
    late final Future<void> task;
    task = _poll(server).whenComplete(() {
      if (identical(_requests[server.id], task)) _requests.remove(server.id);
    });
    _requests[server.id] = task;
    return task;
  }

  /// User refreshes join an existing operation and wait for all selected hosts.
  Future<void> refresh({
    Iterable<String>? serverIds,
    bool recovery = false,
  }) async {
    final targets = (serverIds ?? _servers.keys).toSet().toList();
    var index = 0;
    Future<void> worker() async {
      while (!_closed && index < targets.length) {
        final id = targets[index++];
        final server = _servers[id];
        if (server == null) continue;
        if (recovery &&
            (_blocked.contains(id) ||
                (snapshots[id]?.isOnline == true &&
                    now().difference(snapshots[id]!.timestamp).inSeconds <
                        intervalSeconds * 3 + 30) ||
                (_attempted[id] != null &&
                    now().difference(_attempted[id]!).inSeconds <
                        math.max(5, intervalSeconds)))) {
          continue;
        }
        final existing = _requests[id];
        if (existing != null) {
          await existing;
          if (_servers[id]?.revision == server.revision &&
              snapshots[id]?.configRevision == server.revision) {
            continue;
          }
        }
        while (!_closed && _inFlight.length >= 4) {
          await Future.any(_requests.values.toList());
        }
        if (_closed ||
            _servers[id]?.revision != server.revision ||
            !_servers[id]!.hasSameConnection(server)) {
          continue;
        }
        await (_requests[id] ?? _start(server));
      }
    }

    await Future.wait(
      List.generate(math.min(4, targets.length), (_) => worker()),
    );
  }

  bool accepts(ServerSnapshot snapshot) =>
      _servers[snapshot.serverId]?.revision == snapshot.configRevision;

  Future<void> _poll(ServerConfig server) async {
    final revision = _revision[server.id];
    final started = now();
    _attempted[server.id] = started;
    ServerSnapshot? result;
    try {
      final cursor = accountingCursor[server.id];
      final earliest = started.toUtc().subtract(jobHistoryRetention);
      final backfill = _historyBackfill[server.id];
      final fullHistory =
          cursor == null ||
          backfill == null ||
          started.difference(backfill) >= const Duration(minutes: 10);
      final since = fullHistory
          ? earliest
          : cursor.subtract(const Duration(minutes: 30));
      result = await source.fetch(
        server,
        since: since.isBefore(earliest) ? earliest : since,
      );
      if (_closed || _revision[server.id] != revision) return;
      result = result.forServer(_servers[server.id]!);
      _failures.remove(server.id);
      _blocked.remove(server.id);
      _due[server.id] = now().add(Duration(seconds: intervalSeconds));
      if (result.accountingOk) {
        accountingCursor[server.id] = result.timestamp;
        if (fullHistory) _historyBackfill[server.id] = started;
      }
      result = result.withHistory(snapshots[server.id]);
      snapshots[server.id] = result;
    } catch (e) {
      if (_closed || _revision[server.id] != revision) return;
      final failures = (_failures[server.id] ?? 0) + 1;
      _failures[server.id] = failures;
      final type = e.runtimeType.toString().toLowerCase();
      final permanent =
          type.contains('auth') ||
          type.contains('keydecode') ||
          type.contains('keydecrypt') ||
          type.contains('hostkey') ||
          (e is FormatException &&
              (e.message.contains('指纹') || e.message.contains('PATH')));
      final delay =
          (retryDelay(failures, intervalSeconds) * (.9 + .2 * random()))
              .round()
              .clamp(intervalSeconds, math.max(300, intervalSeconds));
      final retry = permanent
          ? null
          : now().add(Duration(seconds: delay.toInt()));
      if (permanent) _blocked.add(server.id);
      _due[server.id] = retry ?? now().add(const Duration(days: 365));
      final old =
          snapshots[server.id] ??
          ServerSnapshot(
            serverId: server.id,
            serverName: server.name,
            timestamp: now().toUtc(),
            configRevision: server.revision,
            queueOk: false,
          );
      result = old.offline(friendlyError(e), retry);
      snapshots[server.id] = result;
    } finally {
      _inFlight.remove(server.id);
      if (!isPolling) onPollingChanged?.call(false);
    }
    if (!_closed && _revision[server.id] == revision) await onChanged(result);
  }

  Map<String, dynamic> toJson() => {
    'snapshots': snapshots.values.map((s) => s.toJson()).toList(),
    'accountingCursor': accountingCursor.map(
      (k, v) => MapEntry(k, v.toIso8601String()),
    ),
    'historyBackfill': _historyBackfill.map(
      (k, v) => MapEntry(k, v.toIso8601String()),
    ),
  };
  void restore(Map<String, dynamic> j) {
    for (final s in readSnapshots(j, _servers.values)) {
      snapshots[s.serverId] = s;
    }
    void dates(String name, Map<String, DateTime> target) {
      final data = j[name];
      if (data is! Map) return;
      data.forEach((k, v) {
        if (k is! String || v is! String || !_servers.containsKey(k)) return;
        // Legacy cursor-only caches are accepted only before identity epochs exist.
        if (!snapshots.containsKey(k) && _servers[k]!.revision.isNotEmpty) {
          return;
        }
        final value = DateTime.tryParse(v);
        if (value != null) target[k] = value;
      });
    }

    dates('accountingCursor', accountingCursor);
    dates('historyBackfill', _historyBackfill);
  }

  void close() {
    _closed = true;
    source.close();
  }
}
