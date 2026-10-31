import 'dart:async';
import 'package:flutter/widgets.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'monitor_engine.dart';
import 'notification_service.dart';
import 'slurm_ssh_service.dart';
import 'state_tracker.dart';
import 'storage_service.dart';
import 'widget_service.dart';
import '../models/slurm_models.dart';

@pragma('vm:entry-point')
void startMonitorCallback() {
  WidgetsFlutterBinding.ensureInitialized();
  FlutterForegroundTask.setTaskHandler(SlurmTaskHandler());
}

class SlurmTaskHandler extends TaskHandler {
  final _storage = StorageService();
  final _tracker = JobStateTracker();
  final _notifications = SlurmNotificationService();
  final _widget = WidgetService();
  late final MonitorEngine _engine;
  Future<void> _publishQueue = Future.value();
  Timer? _publishTimer;
  Future<void>? _publishing;
  bool _publishDirty = false;
  final _pendingCommands = <Map>[];
  bool _ready = false, _stopping = false;
  String? _deliveryError;

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    try {
      await _notifications.initialize();
      _tracker.restore(await _storage.readMap('job_states'));
      _engine = MonitorEngine(
        source: SlurmSshService(),
        onChanged: _changed,
        onPollingChanged: (value) =>
            FlutterForegroundTask.sendDataToMain({'polling': value}),
      );
      await _loadConfig();
      _engine.restore(await _storage.readMap('monitor_cache'));
      _ready = true;
      FlutterForegroundTask.sendDataToMain({'ready': true});
      for (final command in _pendingCommands) {
        onReceiveData(command);
      }
      _pendingCommands.clear();
      await _engine.tick(force: true);
    } catch (_) {
      await _storage.prefs.setString('service_error', '后台服务初始化失败，请重新打开应用并启动监控');
      FlutterForegroundTask.sendDataToMain({'error': '后台服务初始化失败，请重新启动监控'});
      await FlutterForegroundTask.stopService();
    }
  }

  Future<void> _loadConfig() async {
    final servers = await _storage.readServers();
    final interval = await _storage.readInterval();
    _engine.configure(servers, interval);
    _tracker.configure(servers);
  }

  @override
  void onRepeatEvent(DateTime timestamp) {
    if (_ready && !_stopping) {
      unawaited(_engine.tick().catchError((Object _) {}));
    }
  }

  @override
  void onReceiveData(Object data) {
    if (_stopping || data is! Map) return;
    if (!_ready) {
      _pendingCommands.add(Map.of(data));
      return;
    }
    unawaited(
      _command(data).catchError((Object _) {
        FlutterForegroundTask.sendDataToMain({'error': '设置同步失败，请重启监控服务'});
      }),
    );
  }

  Future<void> _command(Map data) async {
    if (data['command'] == 'reload') {
      await _loadConfig();
      await _changed(null);
      await _engine.tick();
      return;
    }
    if (data['command'] == 'snapshot') {
      FlutterForegroundTask.sendDataToMain({
        ..._engine.toJson(),
        'monitoring': true,
        'polling': _engine.isPolling,
      });
    } else {
      await _loadConfig();
      await _engine.refresh(
        serverIds: data['serverId'] is String
            ? [data['serverId'] as String]
            : null,
        recovery: data['command'] == 'recover',
      );
      await _publishQueue;
      await _publishNow();
      FlutterForegroundTask.sendDataToMain({
        ..._engine.toJson(),
        'requestId': data['requestId'],
        'monitoring': true,
        'polling': _engine.isPolling,
        'error': _deliveryError,
      });
    }
  }

  Future<void> _changed(ServerSnapshot? snapshot) {
    _publishQueue = _publishQueue.catchError((Object _) {}).then((_) async {
      await _loadConfig();
      if (snapshot != null && _engine.accepts(snapshot)) {
        _tracker.observe(snapshot);
      }
      // Persist outbox before delivery, so a process restart can retry notifications.
      await _storage.saveMap('job_states', _tracker.toJson());
      final notificationsEnabled = await _notifications.enabled;
      _deliveryError = notificationsEnabled ? null : '通知未授权，请在系统设置中允许作业状态通知';
      for (final event
          in notificationsEnabled
              ? List<JobTransition>.of(_tracker.pending)
              : <JobTransition>[]) {
        try {
          final current = await _storage.readServers();
          if (!current.any(
            (s) =>
                s.enabled &&
                s.id == event.job.serverId &&
                s.revision == event.configRevision,
          )) {
            continue;
          }
          await _notifications.show(event);
          _tracker.acknowledge(event, DateTime.now().toUtc());
        } catch (_) {
          _deliveryError = '通知发送失败，请检查系统通知设置';
        }
      }
      await _storage.saveMap('job_states', _tracker.toJson());
      await _storage.prefs.remove('service_error');
      _publishDirty = true;
      if (!_stopping && _publishTimer == null) {
        _publishTimer = Timer(const Duration(milliseconds: 300), () {
          _publishTimer = null;
          unawaited(_publishNow().catchError((Object _) {}));
        });
      }
    });
    return _publishQueue;
  }

  Future<void> _publishNow() {
    _publishTimer?.cancel();
    _publishTimer = null;
    return _publishing ??= _publish().whenComplete(() {
      _publishing = null;
    });
  }

  Future<void> _publish() async {
    do {
      _publishDirty = false;
      if (_stopping) return;
      final servers = await _storage.readServers();
      final payload = await _storage.saveMonitorCache(_engine.toJson());
      payload['snapshots'] = readSnapshots(
        payload,
        servers,
      ).map((s) => s.toJson()).toList();
      try {
        await _widget.sync(
          _engine.snapshots.values,
          status: '监控中',
          interval: _engine.intervalSeconds,
          serverIds: _engine.serverIds,
        );
      } catch (_) {
        _deliveryError ??= '桌面小部件同步失败，请重新添加小部件';
      }
      FlutterForegroundTask.sendDataToMain({
        ...payload,
        'monitoring': true,
        'polling': _engine.isPolling,
        'error': _deliveryError,
      });
      final visible = readSnapshots(payload, servers);
      final running = visible.fold<int>(
        0,
        (n, s) => n + s.activeJobs.where((j) => j.isRunning).length,
      );
      final offline = visible.where((s) => !s.isOnline).length;
      await FlutterForegroundTask.updateService(
        notificationTitle: 'Slurm · $running 个作业运行中',
        notificationText:
            '每 ${_engine.intervalSeconds} 秒刷新${offline > 0 ? ' · $offline 台离线重试' : ''} · 点按打开',
      );
    } while (_publishDirty && !_stopping);
  }

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {
    _stopping = true;
    _publishTimer?.cancel();
    if (!_ready) return;
    _engine.close();
    await _publishQueue.catchError((Object _) {});
    await _publishing?.catchError((Object _) {});
    await _storage.saveMonitorCache(_engine.toJson());
    final status = isTimeout ? '系统时限已到，请打开应用恢复' : '监控已暂停';
    await _storage.prefs.setString('service_error', status);
    await _widget.sync(
      _engine.snapshots.values,
      status: status,
      interval: _engine.intervalSeconds,
      serverIds: _engine.serverIds,
    );
    FlutterForegroundTask.sendDataToMain({
      'monitoring': false,
      'error': status,
    });
  }

  @override
  void onNotificationPressed() {
    FlutterForegroundTask.launchApp();
  }
}

void initializeForegroundService() {
  FlutterForegroundTask.init(
    androidNotificationOptions: AndroidNotificationOptions(
      channelId: 'slurm_monitor_service',
      channelName: 'Slurm 后台监控',
      channelDescription: '后台 SSH 采集与桌面小部件同步',
      channelImportance: NotificationChannelImportance.LOW,
      priority: NotificationPriority.LOW,
    ),
    iosNotificationOptions: const IOSNotificationOptions(
      showNotification: false,
    ),
    foregroundTaskOptions: ForegroundTaskOptions(
      eventAction: ForegroundTaskEventAction.repeat(1000),
      autoRunOnBoot: false,
      autoRunOnMyPackageReplaced: false,
      allowWakeLock: true,
      allowWifiLock: true,
    ),
  );
}
