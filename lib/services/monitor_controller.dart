import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import '../demo_data.dart';
import '../models/slurm_models.dart';
import '../models/app_skin.dart';
import '../models/server_palette.dart';
import 'foreground_service.dart';
import 'notification_service.dart';
import 'storage_service.dart';
import 'widget_service.dart';
import 'widget_refresh.dart';
import 'slurm_ssh_service.dart';
import 'state_tracker.dart';

class MonitorController extends ChangeNotifier with WidgetsBindingObserver {
  MonitorController({
    this._demo = false,
    StorageService? storage,
    SnapshotSource Function()? sourceFactory,
  }) : _storage = storage ?? StorageService(),
       _sourceFactory = sourceFactory ?? SlurmSshService.new;
  final StorageService _storage;
  final SnapshotSource Function() _sourceFactory;
  final _notifications = SlurmNotificationService();
  List<ServerConfig> _servers = [];
  final _snapshots = <String, ServerSnapshot>{};
  bool _demo, monitoring = false, busy = false, refreshing = false;
  int refreshIntervalSeconds = 10;
  String? message;
  String? selectedServer;
  Timer? _statusTimer;
  bool _nativeInitialized = false;
  bool _disposed = false;
  Future<void>? _refreshFuture;
  Completer<void>? _refreshReply;
  String? _refreshId;
  SnapshotSource? _oneShotSource;
  bool _checkingStatus = false;
  Future<void> _configWrites = Future.value();
  int dataVersion = 0;
  Map<String, int>? _colorsCache;
  List<ServerSnapshot>? _visibleCache;
  List<SlurmJob>? _activeCache, _finishedCache;
  AppSkin skin = AppSkin.ocean;
  Map<String, int> get serverColors => _colorsCache ??= buildServerColors(
    servers.where((s) => s.enabled).map((s) => s.id),
  );
  bool get demo => _demo;
  bool get nativeSupported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
  List<ServerConfig> get servers =>
      List.unmodifiable(_demo ? demoServers : _servers);
  Map<String, ServerSnapshot> get snapshots => Map.unmodifiable(_snapshots);
  List<ServerSnapshot> get visibleSnapshots {
    if (_visibleCache != null) return _visibleCache!;
    final enabled = servers.where((s) => s.enabled).map((s) => s.id).toSet();
    return _visibleCache = _snapshots.values
        .where(
          (s) =>
              enabled.contains(s.serverId) &&
              (selectedServer == null || selectedServer == s.serverId),
        )
        .toList();
  }

  List<SlurmJob> get activeJobs {
    if (_activeCache != null) return _activeCache!;
    final jobs = visibleSnapshots.expand((s) => s.activeJobs).toList()
      ..sort((a, b) {
        final state = (a.isRunning ? 0 : 1).compareTo(b.isRunning ? 0 : 1);
        if (state != 0) return state;
        final time = (a.submitTime ?? DateTime(1970)).compareTo(
          b.submitTime ?? DateTime(1970),
        );
        return time != 0 ? time : a.key.compareTo(b.key);
      });
    return _activeCache = List.unmodifiable(jobs);
  }

  List<SlurmJob> get finishedJobs {
    if (_finishedCache != null) return _finishedCache!;
    final jobs = visibleSnapshots.expand((s) => s.finishedJobs).toList()
      ..sort((a, b) {
        final time = (b.endTime ?? DateTime(1970)).compareTo(
          a.endTime ?? DateTime(1970),
        );
        return time != 0 ? time : a.key.compareTo(b.key);
      });
    return _finishedCache = List.unmodifiable(jobs);
  }

  List<PartitionNodeStatus> get partitions =>
      visibleSnapshots.expand((s) => s.partitions).toList();
  int get runningCount => visibleSnapshots.fold(
    0,
    (n, s) => n + s.jobs.where((j) => j.isRunning).length,
  );
  int get pendingCount => visibleSnapshots.fold(
    0,
    (n, s) => n + s.jobs.where((j) => j.isPending).length,
  );
  int get idleNodes => visibleSnapshots
      .where((s) => s.isOnline && s.nodesOk)
      .fold(0, (n, s) => n + (s.uniqueIdleNodes ?? 0));
  int get visibleServerCount => servers
      .where(
        (s) => s.enabled && (selectedServer == null || s.id == selectedServer),
      )
      .length;
  int get healthyServers =>
      visibleSnapshots.where((s) => s.isOnline && s.queueOk).length;
  int get validNodeServers => visibleSnapshots
      .where((s) => s.isOnline && s.nodesOk && s.uniqueTotalNodes != null)
      .length;
  bool get hasCachedJobs =>
      !demo &&
      (!monitoring || visibleSnapshots.any((s) => !s.isOnline || !s.queueOk));
  DateTime? get lastUpdate {
    final dates = visibleSnapshots.map((s) => s.oldestTimestamp).toList()
      ..sort();
    return dates.isEmpty ? null : dates.first;
  }

  Future<void> initialize() async {
    WidgetsBinding.instance.addObserver(this);
    if (_demo || !nativeSupported) {
      _demo = true;
      _loadDemo();
      return;
    }
    try {
      skin = await _storage.readSkin();
      FlutterForegroundTask.initCommunicationPort();
      initializeForegroundService();
      FlutterForegroundTask.addTaskDataCallback(_onTaskData);
      await _notifications.initialize();
      await initializeWidgetInteraction();
      _nativeInitialized = true;
      await _loadConfiguration();
      _applyCache(await _storage.readMap('monitor_cache'));
      await _checkStatus();
      await WidgetService().syncConfiguration(_servers);
      _startStatusTimer();
    } catch (_) {
      message = '配置读取失败，请检查设备安全存储后重新打开应用';
    }
    _notify(dataChanged: true, configuration: true);
  }

  Future<void> _loadConfiguration() async {
    _servers = await _storage.readServers();
    refreshIntervalSeconds = await _storage.readInterval();
  }

  void _loadDemo() {
    _snapshots
      ..clear()
      ..addEntries(demoSnapshots().map((s) => MapEntry(s.serverId, s)));
    message = null;
    selectedServer = null;
    _notify(dataChanged: true, configuration: true);
  }

  void _applyCache(Map data) {
    _snapshots
      ..clear()
      ..addEntries(
        readSnapshots(data, _servers).map((s) => MapEntry(s.serverId, s)),
      );
  }

  void _onTaskData(Object data) {
    if (_demo || data is! Map) return;
    if (data.containsKey('snapshots')) {
      _applyCache(data);
      busy = false;
    }
    if (data['monitoring'] is bool) monitoring = data['monitoring'] as bool;
    if (data['polling'] is bool) refreshing = data['polling'] as bool;
    if (data.containsKey('error')) message = data['error'] as String?;
    if (data['requestId'] == _refreshId &&
        _refreshReply?.isCompleted == false) {
      _refreshReply!.complete();
    }
    _notify(dataChanged: data.containsKey('snapshots'));
  }

  Future<void> _checkStatus() async {
    if (_disposed || _demo || !nativeSupported || _checkingStatus) return;
    _checkingStatus = true;
    try {
      final running = await FlutterForegroundTask.isRunningService;
      if (_disposed) return;
      if (monitoring != running) {
        monitoring = running;
        if (!running) {
          refreshing = false;
          busy = false;
          message = await _storage.prefs.getString('service_error');
        }
        _notify();
      }
    } finally {
      _checkingStatus = false;
    }
  }

  void _startStatusTimer() {
    _statusTimer?.cancel();
    if (_disposed || _demo || !nativeSupported) return;
    _statusTimer = Timer.periodic(
      const Duration(seconds: 3),
      (_) => unawaited(_checkStatus().catchError((Object _) {})),
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && nativeSupported && !_demo) {
      _startStatusTimer();
      unawaited(_resumeSnapshot().catchError((Object _) {}));
    } else {
      _statusTimer?.cancel();
    }
  }

  Future<void> _resumeSnapshot() async {
    await _checkStatus();
    if (monitoring) {
      FlutterForegroundTask.sendDataToTask({'command': 'recover'});
    } else {
      final cache = await _storage.readMap('monitor_cache');
      if (!_disposed && !monitoring) {
        _applyCache(cache);
        _notify(dataChanged: true);
      }
    }
  }

  Future<void> startMonitoring() async {
    if (_demo) return;
    if (!_servers.any((s) => s.enabled)) {
      message = '请先添加并启用一台服务器';
      _notify();
      return;
    }
    busy = true;
    message = null;
    _notify();
    try {
      final permission = await _notifications.requestPermission();
      if (!permission) message = '通知未授权；请在系统设置中允许作业状态通知';
      final result = await FlutterForegroundTask.startService(
        serviceId: 41001,
        serviceTypes: [ForegroundServiceTypes.dataSync],
        notificationTitle: 'Slurm 后台监控',
        notificationText: '正在连接集群…',
        notificationIcon: const NotificationIcon(
          metaDataName: 'slurm_service_icon',
        ),
        callback: startMonitorCallback,
      );
      if (result is ServiceRequestFailure) {
        message = '后台服务启动失败，请保持应用可见后重试；系统后台时限可能已用尽';
      }
      monitoring = await FlutterForegroundTask.isRunningService;
    } catch (_) {
      message = '无法启动后台监控，请检查系统权限后重试';
    }
    busy = false;
    _notify();
  }

  Future<void> stopMonitoring() async {
    if (_demo) return;
    final result = await FlutterForegroundTask.stopService();
    if (result is ServiceRequestFailure) {
      message = '暂停失败，请重试';
    }
    monitoring = await FlutterForegroundTask.isRunningService;
    refreshing = false;
    if (!monitoring) {
      await WidgetService().sync(
        _snapshots.values,
        status: '监控已暂停',
        interval: refreshIntervalSeconds,
        serverIds: _servers.where((s) => s.enabled).map((s) => s.id),
      );
    }
    busy = false;
    _notify();
  }

  Future<void> refresh({String? serverId}) =>
      _refreshFuture ??= _refresh(serverId).whenComplete(() {
        _refreshFuture = null;
      });

  Future<void> _refresh(String? serverId) async {
    if (_demo) {
      _loadDemo();
      return;
    }
    refreshing = true;
    message = null;
    _notify();
    try {
      if (monitoring) {
        _refreshReply = Completer<void>();
        _refreshId = DateTime.now().microsecondsSinceEpoch.toString();
        FlutterForegroundTask.sendDataToTask({
          'command': 'refresh',
          'requestId': _refreshId,
          'serverId': ?serverId,
        });
        await _refreshReply!.future.timeout(
          Duration(seconds: 90 * ((_servers.length + 3) ~/ 4).clamp(1, 100)),
        );
      } else {
        final cache = await _storage.readMap('monitor_cache');
        final source = _oneShotSource = _sourceFactory();
        final targets = _servers
            .where((s) => s.enabled && (serverId == null || s.id == serverId))
            .toList();
        final fresh = await collectWidgetOnce(targets, cache, source);
        if (_disposed) return;
        if (nativeSupported && await FlutterForegroundTask.isRunningService) {
          FlutterForegroundTask.sendDataToTask({'command': 'refresh'});
          return;
        }
        final current = await _storage.readServers();
        final merged = {
          for (final s in readSnapshots(cache, current)) s.serverId: s,
          for (final s in fresh) s.serverId: s,
        };
        cache['snapshots'] = merged.values.map((s) => s.toJson()).toList();
        final saved = await _storage.saveMonitorCache(cache);
        _applyCache(saved);
        if (_nativeInitialized) {
          await WidgetService().sync(
            _snapshots.values,
            status: '已刷新 · 监控暂停',
            interval: refreshIntervalSeconds,
          );
        }
        _notify(dataChanged: true);
      }
    } catch (e) {
      message = friendlyError(e);
    } finally {
      refreshing = false;
      _refreshReply = null;
      _refreshId = null;
      _oneShotSource = null;
      _notify();
    }
  }

  Future<void> saveServer(ServerConfig server) => _writeConfiguration(() async {
    final next = [..._servers];
    final index = next.indexWhere((s) => s.id == server.id);
    final previous = index < 0 ? null : next[index];
    final changed =
        previous == null ||
        !previous.hasSameConnection(server) ||
        previous.enabled != server.enabled;
    server = server.copyWith(
      revision: changed
          ? DateTime.now().microsecondsSinceEpoch.toString()
          : previous.revision,
    );
    if (index < 0) {
      next.add(server);
    } else {
      next[index] = server;
    }
    await _storage.saveServers(next);
    _servers = next;
    if (changed) {
      _snapshots.remove(server.id);
    } else if (_snapshots[server.id] != null) {
      _snapshots[server.id] = _snapshots[server.id]!.forServer(server);
    }
    await _configurationSaved();
  });

  Future<void> removeServer(String id) => _writeConfiguration(() async {
    final next = _servers.where((s) => s.id != id).toList();
    await _storage.saveServers(next);
    _servers = next;
    _snapshots.remove(id);
    await _configurationSaved();
  });

  Future<void> _writeConfiguration(Future<void> Function() operation) {
    final task = _configWrites
        .catchError((Object _) {})
        .then((_) => operation());
    _configWrites = task;
    return task;
  }

  Future<void> _configurationSaved() async {
    if (!_servers.any((s) => s.enabled && s.id == selectedServer)) {
      selectedServer = null;
    }
    final cache = await _storage.saveMonitorCache(
      await _storage.readMap('monitor_cache'),
    );
    _applyCache(cache);
    if (!monitoring) {
      final tracker = JobStateTracker()
        ..restore(await _storage.readMap('job_states'))
        ..configure(_servers);
      await _storage.saveMap('job_states', tracker.toJson());
    }
    if (_nativeInitialized) {
      await WidgetService().syncConfiguration(_servers);
      await WidgetService().sync(
        _snapshots.values,
        status: monitoring ? '监控中' : '监控已暂停',
        interval: refreshIntervalSeconds,
      );
    }
    _notify(dataChanged: true, configuration: true);
    if (monitoring) {
      FlutterForegroundTask.sendDataToTask({'command': 'reload'});
      if (!_servers.any((s) => s.enabled)) await stopMonitoring();
    }
  }

  Future<void> setEnabled(ServerConfig server, bool value) async {
    await saveServer(server.copyWith(enabled: value));
    if (!value && !_servers.any((s) => s.enabled) && monitoring) {
      await stopMonitoring();
    }
  }

  Future<void> setInterval(int value) async {
    refreshIntervalSeconds = value.clamp(2, 3600);
    if (!_demo) {
      await _storage.saveInterval(refreshIntervalSeconds);
      if (monitoring) {
        FlutterForegroundTask.sendDataToTask({'command': 'reload'});
      }
    }
    _notify(dataChanged: true);
  }

  Future<void> setSkin(AppSkin value) async {
    skin = value;
    _notify();
    if (_nativeInitialized) {
      await _storage.saveSkin(value);
      await WidgetService().setSkin(value);
    }
  }

  void selectServer(String? id) {
    selectedServer = id;
    _notify(dataChanged: true);
  }

  Future<void> toggleDemo() async {
    if (_demo) {
      if (!nativeSupported) return;
      _demo = false;
      if (!_nativeInitialized) {
        await initialize();
        return;
      }
      await _loadConfiguration();
      _applyCache(await _storage.readMap('monitor_cache'));
      message = null;
      selectedServer = null;
    } else {
      if (monitoring) await stopMonitoring();
      _demo = true;
      _loadDemo();
    }
    _notify(dataChanged: true, configuration: true);
  }

  Future<void> openBatterySettings() async {
    if (nativeSupported && !_demo) {
      await FlutterForegroundTask.openIgnoreBatteryOptimizationSettings();
    }
  }

  Future<void> testNotification() async {
    if (_demo) return;
    await _notifications.requestPermission();
    await _notifications.showTest();
  }

  void _notify({bool dataChanged = false, bool configuration = false}) {
    if (configuration) _colorsCache = null;
    if (dataChanged || configuration) {
      _visibleCache = null;
      _activeCache = _finishedCache = null;
      dataVersion++;
    }
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _statusTimer?.cancel();
    _oneShotSource?.close();
    if (_refreshReply?.isCompleted == false) _refreshReply!.complete();
    WidgetsBinding.instance.removeObserver(this);
    if (nativeSupported) {
      FlutterForegroundTask.removeTaskDataCallback(_onTaskData);
    }
    super.dispose();
  }
}
