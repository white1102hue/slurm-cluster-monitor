import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
// The application already locks this platform implementation through shared_preferences.
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/types.dart';
import 'package:slurm_cluster_monitor/models/slurm_models.dart';
import 'package:slurm_cluster_monitor/services/monitor_controller.dart';
import 'package:slurm_cluster_monitor/services/monitor_engine.dart';
import 'package:slurm_cluster_monitor/services/slurm_ssh_service.dart';
import 'package:slurm_cluster_monitor/services/storage_service.dart';
import 'package:slurm_cluster_monitor/services/state_tracker.dart';
import 'slurm_parser_test.dart' show fixture, running, server;
import 'package:slurm_cluster_monitor/services/slurm_parser.dart';

final class MemoryPreferences extends SharedPreferencesAsyncPlatform {
  final values = <String, Object>{};
  @override
  Future<String?> getString(
    String key,
    SharedPreferencesOptions options,
  ) async => values[key] as String?;
  @override
  Future<void> setString(
    String key,
    String value,
    SharedPreferencesOptions options,
  ) async {
    values[key] = value;
  }

  @override
  Future<int?> getInt(String key, SharedPreferencesOptions options) async =>
      values[key] as int?;
  @override
  Future<void> setInt(
    String key,
    int value,
    SharedPreferencesOptions options,
  ) async {
    values[key] = value;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class ControlledSource implements SnapshotSource {
  final calls = <String>[];
  int active = 0, peak = 0;
  Future<ServerSnapshot> Function(ServerConfig)? handler;
  @override
  Future<ServerSnapshot> fetch(ServerConfig s, {DateTime? since}) async {
    calls.add(s.id);
    active++;
    if (active > peak) peak = active;
    try {
      return await (handler?.call(s) ??
          Future.value(
            ServerSnapshot(
              serverId: s.id,
              serverName: s.name,
              timestamp: DateTime.now(),
            ),
          ));
    } finally {
      active--;
    }
  }

  @override
  void close([String? serverId]) {}
}

const a = ServerConfig(
  id: 'a',
  name: 'A',
  host: 'old.example.invalid',
  username: 'u',
);
ServerSnapshot snap(ServerConfig s, {List<SlurmJob> jobs = const []}) =>
    ServerSnapshot(
      serverId: s.id,
      serverName: s.name,
      timestamp: DateTime.utc(2026, 10, 30, 12),
      configRevision: s.revision,
      jobs: jobs,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late MemoryPreferences prefs;
  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    prefs = MemoryPreferences();
    SharedPreferencesAsyncPlatform.instance = prefs;
    FlutterSecureStorage.setMockInitialValues({});
  });
  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
  });

  test('valid snapshots survive identity-filtered persistence', () async {
    final storage = StorageService();
    await storage.saveServers([a.copyWith(revision: 'epoch')]);
    final current = (await storage.readServers()).single;
    final saved = await storage.saveMonitorCache({
      'snapshots': [snap(current).toJson()],
    });
    expect(saved['snapshots'], hasLength(1));
  });

  test(
    'paused refresh coalesces callers, waits for data and never starts monitoring',
    () async {
      final source = ControlledSource();
      final pending = Completer<ServerSnapshot>();
      source.handler = (_) => pending.future;
      final ctrl = MonitorController(sourceFactory: () => source);
      addTearDown(ctrl.dispose);
      await ctrl.saveServer(a);
      final one = ctrl.refresh(), two = ctrl.refresh();
      expect(identical(one, two), isTrue);
      await Future<void>.delayed(Duration.zero);
      expect(source.calls, ['a']);
      expect(ctrl.refreshing, isTrue);
      pending.complete(snap(ctrl.servers.single));
      await one;
      expect(ctrl.snapshots, contains('a'), reason: ctrl.message);
      expect(ctrl.monitoring, isFalse);
      expect(ctrl.refreshing, isFalse);
      expect(ctrl.snapshots['a']!.configRevision, ctrl.servers.single.revision);
    },
  );

  test(
    'changing endpoint rejects a paused late result on disk and in the UI',
    () async {
      final source = ControlledSource();
      final pending = Completer<ServerSnapshot>();
      source.handler = (_) => pending.future;
      final ctrl = MonitorController(sourceFactory: () => source);
      addTearDown(ctrl.dispose);
      await ctrl.saveServer(a);
      final original = ctrl.servers.single;
      final refresh = ctrl.refresh();
      await Future<void>.delayed(Duration.zero);
      await ctrl.saveServer(
        const ServerConfig(
          id: 'a',
          name: 'New',
          host: 'new.example.invalid',
          username: 'other',
        ),
      );
      expect(ctrl.servers.single.revision, isNot(original.revision));
      pending.complete(snap(original));
      await refresh;
      expect(ctrl.snapshots, isEmpty);
      expect(
        (await StorageService().readMap('monitor_cache'))['snapshots'],
        isEmpty,
      );
    },
  );

  test(
    'renaming preserves identity, disabling clears selection and persistent snapshot',
    () async {
      final source = ControlledSource()..handler = (s) async => snap(s);
      final ctrl = MonitorController(sourceFactory: () => source);
      addTearDown(ctrl.dispose);
      await ctrl.saveServer(a);
      await ctrl.refresh();
      expect(ctrl.snapshots, contains('a'), reason: ctrl.message);
      final original = ctrl.servers.single;
      await ctrl.saveServer(
        ServerConfig.fromSecureJson({
          ...original.toSecureJson(),
          'name': 'Renamed',
        }),
      );
      expect(ctrl.servers.single.revision, original.revision);
      expect(ctrl.snapshots['a']!.serverName, 'Renamed');
      ctrl.selectServer('a');
      await ctrl.setEnabled(ctrl.servers.single, false);
      expect(ctrl.selectedServer, isNull);
      expect(ctrl.snapshots, isEmpty);
    },
  );

  test(
    'wrong JSON type and individual damaged cache records preserve valid data',
    () async {
      prefs.values['monitor_cache'] = '[]';
      expect(await StorageService().readMap('monitor_cache'), isEmpty);
      final data = {
        'snapshots': [
          snap(a).toJson(),
          null,
          {'timestamp': 'broken'},
          {...snap(a).toJson(), 'serverId': 'b', 'timestamp': 'bad'},
        ],
      };
      expect(readSnapshots(data, [a]), hasLength(1));
      expect(readSnapshots({'snapshots': {}}, [a]), isEmpty);
      expect(readSnapshots(data, [a.copyWith(revision: 'changed')]), isEmpty);
    },
  );

  test(
    'unchanged reload preserves deadline and backoff, long intervals never retry faster',
    () async {
      final source = ControlledSource();
      var now = DateTime.utc(2026, 10, 30);
      final engine = MonitorEngine(
        source: source,
        onChanged: (_) async {},
        now: () => now,
        random: () => 0,
      );
      addTearDown(engine.close);
      engine.configure([a], 60);
      await engine.tick();
      now = now.add(const Duration(seconds: 1));
      engine.configure([a], 60);
      await engine.tick();
      expect(source.calls, ['a']);
      expect(retryDelay(1, 3600), 3600);
      expect(retryDelay(10, 600), 600);
      source.handler = (_) => throw TimeoutException('offline');
      engine.configure([a], 3600);
      await engine.refresh();
      expect(engine.snapshots['a']!.nextRetry!.difference(now).inSeconds, 3600);
      engine.configure([a], 3600);
      await engine.tick();
      expect(source.calls.length, 2);
    },
  );

  test(
    'manual refresh joins scheduled request, then covers hosts beyond four slots',
    () async {
      final source = ControlledSource();
      final first = Completer<ServerSnapshot>();
      source.handler = (s) async {
        if (s.id == 'a') return first.future;
        await Future<void>.delayed(const Duration(milliseconds: 2));
        return snap(s);
      };
      final hosts = [
        a,
        for (var i = 0; i < 6; i++)
          ServerConfig(id: '$i', name: '$i', host: '$i', username: 'u'),
      ];
      final engine = MonitorEngine(source: source, onChanged: (_) async {});
      addTearDown(engine.close);
      engine.configure(hosts, 10);
      final tick = engine.tick();
      var finished = false;
      final manual = engine.refresh().then((_) => finished = true);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(finished, isFalse);
      expect(source.calls.where((id) => id == 'a'), hasLength(1));
      first.complete(snap(a));
      await tick;
      await manual;
      expect(engine.snapshots, hasLength(7));
      expect(source.peak, lessThanOrEqualTo(4));
    },
  );

  test(
    'partial queue retains last complete age and jobs while confirmed accounting advances',
    () {
      final old = const SlurmParser().parse(server, fixture(queue: running));
      final partial = const SlurmParser().parse(
        server,
        fixture(
          queue: '$running\nbroken|job|line',
          accounting:
              '43|done|compute|COMPLETED|00:10:00|8|4Gn||0:0|1|cn01|2026-10-24T02:00:00|2026-10-24T01:00:00|None|01:00:00',
        ),
      );
      final merged = partial.withHistory(old);
      expect(merged.isOnline, isTrue);
      expect(merged.queueOk, isFalse);
      expect(merged.activeJobs.single.jobId, '42_1');
      expect(merged.finishedJobs.single.jobId, '43');
      expect(merged.queueUpdatedAt, old.queueUpdatedAt);
      final first = partial.withHistory(null);
      expect(first.activeJobs, isEmpty);
      expect(first.queueUpdatedAt, isNull);
    },
  );

  test(
    'untrusted cached active rows cannot cause running notifications; revision resets outbox',
    () {
      final tracker = JobStateTracker()..configure([a]);
      SlurmJob job(String state) => SlurmJob(
        serverId: 'a',
        serverName: 'A',
        jobId: '42',
        jobName: 'x',
        state: state,
      );
      tracker.observe(snap(a, jobs: [job('PENDING')]));
      tracker.observe(
        ServerSnapshot(
          serverId: 'a',
          serverName: 'A',
          timestamp: DateTime.now(),
          queueOk: false,
          jobs: [job('RUNNING')],
        ),
      );
      expect(tracker.pending, isEmpty);
      tracker.observe(snap(a, jobs: [job('RUNNING')]));
      expect(tracker.pending, hasLength(1));
      tracker.configure([a.copyWith(revision: 'new')]);
      expect(tracker.pending, isEmpty);
    },
  );

  test('only data changes invalidate ordering and palette caches', () async {
    final ctrl = MonitorController(demo: true);
    await ctrl.initialize();
    addTearDown(ctrl.dispose);
    final jobs = ctrl.activeJobs, colors = ctrl.serverColors;
    await ctrl.setSkin(ctrl.skin);
    expect(identical(jobs, ctrl.activeJobs), isTrue);
    expect(identical(colors, ctrl.serverColors), isTrue);
    ctrl.selectServer(ctrl.servers.first.id);
    expect(identical(jobs, ctrl.activeJobs), isFalse);
    expect(identical(colors, ctrl.serverColors), isTrue);
  });
}
