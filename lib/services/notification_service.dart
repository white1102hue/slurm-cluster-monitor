import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'state_tracker.dart';

class SlurmNotificationService {
  final _plugin = FlutterLocalNotificationsPlugin();
  Future<bool> get enabled async =>
      await _plugin
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >()
          ?.areNotificationsEnabled() ??
      false;
  Future<void> initialize() async {
    await _plugin.initialize(
      settings: const InitializationSettings(
        android: AndroidInitializationSettings('ic_stat_slurm'),
      ),
    );
  }

  Future<void> showTest() => _plugin.show(
    id: 41003,
    title: 'Slurm 通知已就绪',
    body: '作业状态变化将显示在这里。',
    notificationDetails: const NotificationDetails(
      android: AndroidNotificationDetails(
        'slurm_job_alerts',
        'Slurm 作业状态',
        importance: Importance.high,
        priority: Priority.high,
        icon: 'ic_stat_slurm',
      ),
    ),
  );
  Future<bool> requestPermission() async =>
      await _plugin
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >()
          ?.requestNotificationsPermission() ??
      false;
  Future<void> show(JobTransition event) => _plugin.show(
    id: stableNotificationId(event.identity),
    title: event.title,
    body: event.body,
    notificationDetails: NotificationDetails(
      android: AndroidNotificationDetails(
        'slurm_job_alerts',
        'Slurm 作业状态',
        channelDescription: '作业开始、完成、失败、超时和内存不足通知',
        importance: Importance.high,
        priority: Priority.high,
        icon: 'ic_stat_slurm',
        onlyAlertOnce: true,
        styleInformation: BigTextStyleInformation(event.body),
      ),
    ),
    payload: event.job.key,
  );
}

int stableNotificationId(String text) {
  var hash = 0x811c9dc5;
  for (final unit in text.codeUnits) {
    hash = ((hash ^ unit) * 0x01000193) & 0x7fffffff;
  }
  // Foreground service reserves ID 41001.
  return hash == 41001 ? 41002 : hash;
}
