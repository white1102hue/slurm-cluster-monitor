import 'dart:async';
import 'package:flutter/widgets.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:home_widget/home_widget.dart';
import '../models/slurm_models.dart';
import 'slurm_ssh_service.dart';
import 'storage_service.dart';
import 'widget_service.dart';

bool _refreshInFlight = false;

/// The widget's background engine delegates to an active monitor. When paused,
/// it does one read-only collection without launching the activity or starting
/// a continuous monitoring service.
@pragma('vm:entry-point')
Future<void> refreshFromWidget(Uri? uri) async {
  if (uri?.host != 'refresh' || _refreshInFlight) return;
  _refreshInFlight = true;
  WidgetsFlutterBinding.ensureInitialized();
  final widget = WidgetService();
  final storage = StorageService();
  var delegated = false;
  try {
    await widget.setRefreshing(true);
    if (await FlutterForegroundTask.isRunningService) {
      FlutterForegroundTask.sendDataToTask({'command': 'refresh'});
      delegated = true;
      return;
    }
    final servers = (await storage.readServers())
        .where((s) => s.enabled)
        .toList();
    final cache = await storage.readMap('monitor_cache');
    final snapshots = await collectWidgetOnce(
      servers,
      cache,
      SlurmSshService(),
    );
    // A user may start monitoring during this read. The foreground engine then
    // owns persistence and notification state; discard this competing result.
    if (await FlutterForegroundTask.isRunningService) {
      FlutterForegroundTask.sendDataToTask({'command': 'refresh'});
      delegated = true;
      return;
    }
    cache['snapshots'] = snapshots.map((s) => s.toJson()).toList();
    await storage.saveMonitorCache(cache);
    await widget.sync(
      snapshots,
      status: servers.isEmpty ? '请先添加服务器' : '已刷新 · 监控暂停',
      interval: await storage.readInterval(),
      serverIds: servers.map((s) => s.id),
    );
  } catch (_) {
    // Preserve the last complete snapshot when secure storage or scheduling is
    // unavailable. Connection failures are represented per server below.
  } finally {
    try {
      if (!delegated) await widget.setRefreshing(false);
    } finally {
      _refreshInFlight = false;
    }
  }
}

Future<void> initializeWidgetInteraction() =>
    HomeWidget.registerInteractivityCallback(refreshFromWidget).then((_) {});

Future<List<ServerSnapshot>> collectWidgetOnce(
  List<ServerConfig> servers,
  Map<String, dynamic> cache,
  SnapshotSource source, {
  DateTime Function()? now,
}) async {
  final clock = now ?? DateTime.now;
  final snapshots = <String, ServerSnapshot>{};
  for (final s in readSnapshots(cache, servers)) {
    snapshots[s.serverId] = s;
  }
  try {
    for (var i = 0; i < servers.length; i += 4) {
      await Future.wait(
        servers.skip(i).take(4).map((server) async {
          try {
            final fresh = await source.fetch(
              server,
              since: clock().toUtc().subtract(jobHistoryRetention),
            );
            snapshots[server.id] = fresh
                .forServer(server)
                .withHistory(snapshots[server.id]);
          } catch (e) {
            final old =
                snapshots[server.id] ??
                ServerSnapshot(
                  serverId: server.id,
                  serverName: server.name,
                  timestamp: clock().toUtc(),
                  configRevision: server.revision,
                  queueOk: false,
                );
            snapshots[server.id] = old.offline(
              friendlyError(e),
              clock().toUtc(),
            );
          }
        }),
      );
    }
    return [for (final server in servers) snapshots[server.id]!];
  } finally {
    source.close();
  }
}
