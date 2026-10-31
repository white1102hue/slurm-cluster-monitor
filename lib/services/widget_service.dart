import 'dart:convert';
import 'package:home_widget/home_widget.dart';
import '../models/slurm_models.dart';
import '../models/app_skin.dart';
import '../models/server_palette.dart';
import 'storage_service.dart';

Map<String, dynamic> buildWidgetSnapshot(
  Iterable<ServerSnapshot> snapshots, {
  required String status,
  required int interval,
  Iterable<String>? serverIds,
  Map<String, String>? serverRevisions,
}) {
  final list = snapshots.toList();
  final colors = buildServerColors({
    ...?serverIds,
    ...list.map((s) => s.serverId),
  });
  final online = list.where((s) => s.isOnline && s.nodesOk).toList();
  final idle = online.fold<int>(0, (n, s) => n + (s.uniqueIdleNodes ?? 0));
  final total = online.fold<int>(0, (n, s) => n + (s.uniqueTotalNodes ?? 0));
  final times = list.map((s) => s.oldestTimestamp).toList()..sort();
  final expected = serverIds?.length ?? list.length;
  final partial = online.length < expected;
  final cache = list.any((s) => !s.isOnline || !s.queueOk) || status != '监控中';
  final running = [
    for (final s in list)
      for (final j in s.activeJobs.where((j) => j.isRunning))
        {
          ...j.toWidgetJson(
            stale: !s.isOnline || !s.queueOk || status != '监控中',
          ),
          'serverId': j.serverId,
          'serverColor': colors[j.serverId] ?? serverColorValue(j.serverId),
        },
  ];
  return {
    'running_jobs_json': running,
    'runningCount': running.length,
    'pendingCount': list.fold<int>(
      0,
      (n, s) => n + s.activeJobs.where((j) => j.isPending).length,
    ),
    'nodeSummary': online.isEmpty
        ? '空闲节点 —'
        : '空闲节点 $idle / $total${partial ? ' · 部分数据' : ''}',
    'status':
        '$status${cache && list.isNotEmpty ? ' · 含缓存' : ''}${list.any((s) => !s.queueOk) ? ' · 队列异常' : ''}',
    if (serverRevisions != null)
      'configuration': widgetConfiguration(serverRevisions),
    'timestamp': times.isEmpty ? '尚未刷新' : clockText(times.first),
    'timestampEpochMs': times.isEmpty
        ? null
        : times.first.millisecondsSinceEpoch,
    'interval': interval,
    'offline': list.where((s) => !s.isOnline).length,
  };
}

class WidgetService {
  /// Only configuration writers advance this fence. Older producers may publish
  /// late snapshots, but native renderers refuse a mismatching configuration.
  Future<void> syncConfiguration(Iterable<ServerConfig> servers) async {
    await HomeWidget.saveWidgetData<String>(
      'slurm_widget_configuration',
      widgetConfiguration({
        for (final s in servers.where((s) => s.enabled)) s.id: s.revision,
      }),
    );
  }

  Future<void> setRefreshing(bool refreshing) async {
    await HomeWidget.saveWidgetData<bool>(
      'slurm_widget_refreshing',
      refreshing,
    );
    await HomeWidget.updateWidget(androidName: 'SlurmMonitorWidgetProvider');
  }

  Future<void> setSkin(AppSkin skin) async {
    await HomeWidget.saveWidgetData<String>('slurm_widget_skin', skin.name);
    await HomeWidget.updateWidget(androidName: 'SlurmMonitorWidgetProvider');
  }

  Future<void> sync(
    Iterable<ServerSnapshot> snapshots, {
    required String status,
    required int interval,
    Iterable<String>? serverIds,
  }) async {
    final configs = await StorageService().readServers();
    final filtered = readSnapshots({
      'snapshots': snapshots.map((s) => s.toJson()).toList(),
    }, configs);
    await HomeWidget.saveWidgetData<String>(
      'slurm_widget_skin',
      (await StorageService().readSkin()).name,
    );
    await HomeWidget.saveWidgetData<bool>('slurm_widget_refreshing', false);
    // One atomic preference prevents the header and ListView reading different polls.
    await HomeWidget.saveWidgetData<String>(
      'slurm_widget_snapshot',
      jsonEncode(
        buildWidgetSnapshot(
          filtered,
          status: status,
          interval: interval,
          serverIds: configs.where((s) => s.enabled).map((s) => s.id),
          serverRevisions: {
            for (final s in configs.where((s) => s.enabled)) s.id: s.revision,
          },
        ),
      ),
    );
    await HomeWidget.updateWidget(androidName: 'SlurmMonitorWidgetProvider');
  }
}

String widgetConfiguration(Map<String, String> revisions) {
  final ids = revisions.keys.toList()..sort();
  return jsonEncode({for (final id in ids) id: revisions[id]});
}
