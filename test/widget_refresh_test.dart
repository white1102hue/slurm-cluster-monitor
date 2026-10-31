import 'package:flutter_test/flutter_test.dart';
import 'package:slurm_cluster_monitor/models/slurm_models.dart';
import 'package:slurm_cluster_monitor/services/slurm_ssh_service.dart';
import 'package:slurm_cluster_monitor/services/widget_refresh.dart';

class OneShotSource implements SnapshotSource {
  var active = 0, peak = 0;
  bool closed = false;
  final calls = <String>[];
  @override
  Future<ServerSnapshot> fetch(ServerConfig server, {DateTime? since}) async {
    calls.add(server.id);
    active++;
    if (active > peak) peak = active;
    await Future<void>.delayed(const Duration(milliseconds: 2));
    active--;
    if (server.id == 'bad') throw const FormatException('offline');
    return ServerSnapshot(
      serverId: server.id,
      serverName: server.name,
      timestamp: DateTime.utc(2026, 10, 25),
    );
  }

  @override
  void close([String? id]) {
    closed = true;
  }
}

void main() {
  test(
    'a successful paused widget refresh preserves cached completed jobs',
    () async {
      const server = ServerConfig(id: 'a', name: 'A', host: 'a', username: 'u');
      final old = ServerSnapshot(
        serverId: 'a',
        serverName: 'A',
        timestamp: DateTime.utc(2026, 10, 25),
        jobs: [
          SlurmJob(
            serverId: 'a',
            serverName: 'A',
            jobId: 'finished',
            jobName: 'finished',
            state: 'COMPLETED',
            endTime: DateTime.utc(2026, 10, 24),
          ),
        ],
      );
      final result = await collectWidgetOnce(
        [server],
        {
          'snapshots': [old.toJson()],
        },
        OneShotSource(),
      );
      expect(result.single.finishedJobs.single.jobId, 'finished');
    },
  );
  test(
    'one widget refresh polls all enabled hosts once with four concurrent slots',
    () async {
      final source = OneShotSource();
      final servers = [
        for (var i = 0; i < 6; i++)
          ServerConfig(
            id: '$i',
            name: '$i',
            host: 'localhost',
            username: 'test',
          ),
      ];
      final result = await collectWidgetOnce(servers, {}, source);
      expect(result, hasLength(6));
      expect(source.calls, hasLength(6));
      expect(source.peak, 4);
      expect(source.closed, isTrue);
    },
  );
  test(
    'offline refresh preserves cached jobs and removes unrelated hosts',
    () async {
      const server = ServerConfig(
        id: 'bad',
        name: 'A',
        host: 'localhost',
        username: 'test',
      );
      final old = ServerSnapshot(
        serverId: 'bad',
        serverName: 'A',
        timestamp: DateTime.utc(2026, 10, 24),
        jobs: const [
          SlurmJob(
            serverId: 'bad',
            serverName: 'A',
            jobId: '42',
            jobName: 'test',
            state: 'RUNNING',
          ),
        ],
      );
      final result = await collectWidgetOnce(
        [server],
        {
          'snapshots': [
            old.toJson(),
            ServerSnapshot(
              serverId: 'removed',
              serverName: 'old',
              timestamp: DateTime.utc(2026),
            ).toJson(),
          ],
        },
        OneShotSource(),
      );
      expect(result, hasLength(1));
      expect(result.single.isOnline, isFalse);
      expect(result.single.jobs.single.jobId, '42');
      expect(result.single.error, 'offline');
    },
  );
}
