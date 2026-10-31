import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:slurm_cluster_monitor/models/slurm_models.dart';
import 'package:slurm_cluster_monitor/services/monitor_engine.dart';
import 'package:slurm_cluster_monitor/services/slurm_ssh_service.dart';

const a = ServerConfig(id: 'a', name: 'A', host: 'a', username: 'u');
const b = ServerConfig(id: 'b', name: 'B', host: 'b', username: 'u');

class FakeSource implements SnapshotSource {
  final calls = <String, int>{};
  final closed = <String?>[];
  Future<ServerSnapshot> Function(ServerConfig)? handler;
  DateTime? since;
  @override
  Future<ServerSnapshot> fetch(ServerConfig server, {DateTime? since}) async {
    calls[server.id] = (calls[server.id] ?? 0) + 1;
    this.since = since;
    return handler == null
        ? ServerSnapshot(
            serverId: server.id,
            serverName: server.name,
            timestamp: DateTime.utc(2026, 10, 24),
          )
        : handler!(server);
  }

  @override
  void close([String? id]) {
    closed.add(id);
  }
}

void main() {
  test('publishes polling state for the actual request duration', () async {
    final source = FakeSource(), states = <bool>[];
    final pending = Completer<ServerSnapshot>();
    source.handler = (_) => pending.future;
    final engine = MonitorEngine(
      source: source,
      onChanged: (_) async {},
      onPollingChanged: states.add,
    )..configure([a], 10);
    final tick = engine.tick();
    expect(states, [true]);
    expect(engine.isPolling, isTrue);
    pending.complete(
      ServerSnapshot(serverId: 'a', serverName: 'A', timestamp: DateTime.now()),
    );
    await tick;
    expect(states, [true, false]);
    engine.close();
  });
  test('four connection slots schedule a waiting fifth host fairly', () async {
    final source = FakeSource();
    var now = DateTime.utc(2026, 10, 24);
    final blockers = <String, Completer<ServerSnapshot>>{};
    source.handler = (s) =>
        (blockers[s.id] = Completer<ServerSnapshot>()).future;
    final hosts = List.generate(
      5,
      (i) => ServerConfig(id: '$i', name: '$i', host: '$i', username: 'u'),
    );
    final engine = MonitorEngine(
      source: source,
      onChanged: (_) async {},
      now: () => now,
    )..configure(hosts, 3);
    final first = engine.tick();
    expect(source.calls.length, 4);
    now = now.add(const Duration(seconds: 5));
    for (final entry in blockers.entries) {
      entry.value.complete(
        ServerSnapshot(
          serverId: entry.key,
          serverName: entry.key,
          timestamp: now,
        ),
      );
    }
    await first;
    source.handler = null;
    await engine.tick();
    expect(source.calls['4'], 1);
    engine.close();
  });
  test(
    'honors interval and does not overlap requests for a single host',
    () async {
      final source = FakeSource();
      var now = DateTime.utc(2026, 10, 24);
      final wait = Completer<ServerSnapshot>();
      source.handler = (_) => wait.future;
      final engine = MonitorEngine(
        source: source,
        onChanged: (_) async {},
        now: () => now,
      )..configure([a], 5);
      final first = engine.tick();
      await engine.tick(force: true);
      expect(source.calls['a'], 1);
      wait.complete(
        ServerSnapshot(serverId: 'a', serverName: 'A', timestamp: now),
      );
      await first;
      await engine.tick();
      expect(source.calls['a'], 1);
      source.handler = null;
      now = now.add(const Duration(seconds: 5));
      await engine.tick();
      expect(source.calls['a'], 2);
      engine.close();
    },
  );
  test(
    'a slow server does not block another server or its next refresh',
    () async {
      final source = FakeSource();
      var now = DateTime.utc(2026, 10, 24);
      final slow = Completer<ServerSnapshot>();
      source.handler = (s) async => s.id == 'a'
          ? slow.future
          : ServerSnapshot(serverId: 'b', serverName: 'B', timestamp: now);
      final engine = MonitorEngine(
        source: source,
        onChanged: (_) async {},
        now: () => now,
      )..configure([a, b], 3);
      final pending = engine.tick();
      await Future<void>.delayed(Duration.zero);
      expect(engine.snapshots.containsKey('b'), isTrue);
      now = now.add(const Duration(seconds: 3));
      await engine.tick();
      expect(source.calls['b'], 2);
      expect(source.calls['a'], 1);
      slow.complete(
        ServerSnapshot(serverId: 'a', serverName: 'A', timestamp: now),
      );
      await pending;
      engine.close();
    },
  );
  test(
    'offline preserves data and backs off; force refresh can retry early',
    () async {
      final source = FakeSource();
      var now = DateTime.utc(2026, 10, 24);
      final engine = MonitorEngine(
        source: source,
        onChanged: (_) async {},
        now: () => now,
      )..configure([a], 3);
      await engine.tick();
      final lastTime = engine.snapshots['a']!.timestamp;
      source.handler = (_) => throw TimeoutException('private debug details');
      now = now.add(const Duration(seconds: 3));
      await engine.tick();
      final offline = engine.snapshots['a']!;
      expect(offline.isOnline, isFalse);
      expect(offline.timestamp, lastTime);
      expect(offline.error, isNot(contains('private')));
      await engine.tick();
      expect(source.calls['a'], 2);
      await engine.tick(force: true);
      expect(source.calls['a'], 3);
      expect(retryDelay(10, 3), 192);
      expect(retryDelay(10, 60), 300);
      engine.close();
    },
  );
  test('late results cannot resurrect removed or changed servers', () async {
    final source = FakeSource();
    final slow = Completer<ServerSnapshot>();
    source.handler = (_) => slow.future;
    final engine = MonitorEngine(source: source, onChanged: (_) async {})
      ..configure([a], 3);
    final pending = engine.tick();
    engine.configure([], 3);
    slow.complete(
      ServerSnapshot(serverId: 'a', serverName: 'A', timestamp: DateTime.now()),
    );
    await pending;
    expect(engine.snapshots, isEmpty);
    engine.close();
  });
  test('accounting cursor overlaps successful polls by 30 minutes', () async {
    final source = FakeSource();
    final now = DateTime.utc(2026, 10, 24);
    final engine = MonitorEngine(
      source: source,
      onChanged: (_) async {},
      now: () => now,
    )..configure([a], 3);
    await engine.tick();
    expect(source.since, now.subtract(jobHistoryRetention));
    await engine.tick(force: true);
    expect(source.since, now.subtract(const Duration(minutes: 30)));
    expect(engine.toJson().toString(), isNot(contains('password')));
    engine.close();
  });
  test(
    'slow requests wait a full interval after completion before polling again',
    () async {
      final source = FakeSource();
      var now = DateTime.utc(2026, 10, 26);
      source.handler = (s) async {
        now = now.add(const Duration(seconds: 12));
        return ServerSnapshot(
          serverId: s.id,
          serverName: s.name,
          timestamp: now,
        );
      };
      final engine = MonitorEngine(
        source: source,
        onChanged: (_) async {},
        now: () => now,
      )..configure([a], 3);
      await engine.tick();
      await engine.tick();
      expect(source.calls['a'], 1);
      now = now.add(const Duration(seconds: 3));
      await engine.tick();
      expect(source.calls['a'], 2);
      engine.close();
    },
  );
  test(
    'periodic backfill recovers accounting records delayed beyond the overlap',
    () async {
      final source = FakeSource();
      var now = DateTime.utc(2026, 10, 26, 12);
      source.handler = (s) async => ServerSnapshot(
        serverId: s.id,
        serverName: s.name,
        timestamp: now,
        jobs:
            source.calls[s.id]! >= 3 &&
                source.since == now.subtract(jobHistoryRetention)
            ? [
                SlurmJob(
                  serverId: s.id,
                  serverName: s.name,
                  jobId: 'delayed',
                  jobName: 'delayed',
                  state: 'COMPLETED',
                  endTime: now.subtract(const Duration(hours: 2)),
                ),
              ]
            : [],
      );
      final engine = MonitorEngine(
        source: source,
        onChanged: (_) async {},
        now: () => now,
      )..configure([a], 3);
      await engine.tick();
      now = now.add(const Duration(minutes: 1));
      await engine.tick();
      expect(source.since, DateTime.utc(2026, 10, 26, 11, 30));
      expect(engine.snapshots['a']!.finishedJobs, isEmpty);
      now = now.add(const Duration(minutes: 9));
      await engine.tick();
      expect(source.since, now.subtract(jobHistoryRetention));
      expect(engine.snapshots['a']!.finishedJobs, hasLength(1));
      engine.close();
    },
  );
  test(
    'older installed caches backfill history on their first successful poll',
    () async {
      final source = FakeSource();
      final now = DateTime.utc(2026, 10, 26);
      source.handler = (s) async =>
          ServerSnapshot(serverId: s.id, serverName: s.name, timestamp: now);
      final engine = MonitorEngine(
        source: source,
        onChanged: (_) async {},
        now: () => now,
      )..configure([a], 3);
      engine.restore({
        'accountingCursor': {'a': now.toIso8601String()},
      });
      await engine.tick();
      expect(source.since, now.subtract(jobHistoryRetention));
      final cache = engine.toJson();
      engine.close();
      final restored = MonitorEngine(
        source: source,
        onChanged: (_) async {},
        now: () => now,
      )..configure([a], 3);
      restored.restore(cache);
      await restored.tick();
      expect(source.since, now.subtract(const Duration(minutes: 30)));
      restored.close();
    },
  );
  test(
    'failed accounting cannot advance either the cursor or history backfill',
    () async {
      final source = FakeSource();
      final now = DateTime.utc(2026, 10, 26);
      source.handler = (s) async => ServerSnapshot(
        serverId: s.id,
        serverName: s.name,
        timestamp: now,
        accountingOk: false,
      );
      final engine = MonitorEngine(
        source: source,
        onChanged: (_) async {},
        now: () => now,
      )..configure([a], 3);
      await engine.tick();
      await engine.tick(force: true);
      expect(source.since, now.subtract(jobHistoryRetention));
      expect(engine.accountingCursor, isEmpty);
      expect(engine.toJson()['historyBackfill'], isEmpty);
      engine.close();
    },
  );
  test(
    'removing and readding an identical server rejects the original late result',
    () async {
      final source = FakeSource();
      final slow = Completer<ServerSnapshot>();
      source.handler = (_) => slow.future;
      final engine = MonitorEngine(source: source, onChanged: (_) async {})
        ..configure([a], 3);
      final pending = engine.tick();
      engine.configure([], 3);
      engine.configure([a], 3);
      slow.complete(
        ServerSnapshot(
          serverId: 'a',
          serverName: 'A',
          timestamp: DateTime.now(),
        ),
      );
      await pending;
      expect(engine.snapshots, isEmpty);
      engine.close();
    },
  );
}
