import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slurm_cluster_monitor/models/slurm_models.dart';
import 'package:slurm_cluster_monitor/services/widget_service.dart';
import 'package:slurm_cluster_monitor/services/widget_setup_service.dart';
import 'package:slurm_cluster_monitor/ui/widget_setup_page.dart';
import 'package:slurm_cluster_monitor/models/server_palette.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('slurm_monitor/widgets');
  const home = MethodChannel('home_widget');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
    messenger.setMockMethodCallHandler(home, null);
  });

  test(
    'widget summary counts pending jobs and preserves stale time while excluding offline node capacity',
    () {
      final older = DateTime.utc(2026, 10, 26, 10);
      SlurmJob job(String host, String id, String state) => SlurmJob(
        serverId: host,
        serverName: host,
        jobId: id,
        jobName: id,
        state: state,
      );
      final summary = buildWidgetSnapshot(
        [
          ServerSnapshot(
            serverId: 'a',
            serverName: 'a',
            timestamp: older.add(const Duration(minutes: 1)),
            jobs: [
              job('a', 'run', 'RUNNING'),
              job('a', 'pending', 'PENDING'),
              job('a', 'done', 'COMPLETED'),
            ],
            uniqueIdleNodes: 2,
            uniqueTotalNodes: 8,
          ),
          ServerSnapshot(
            serverId: 'b',
            serverName: 'b',
            timestamp: older,
            error: 'offline',
            jobs: [job('b', 'cached', 'RUNNING')],
            uniqueIdleNodes: 99,
            uniqueTotalNodes: 100,
          ),
        ],
        status: '监控中',
        interval: 10,
      );
      expect(summary['runningCount'], 2);
      expect(summary['pendingCount'], 1);
      expect(summary['nodeSummary'], '空闲节点 2 / 8 · 部分数据');
      expect(summary['timestampEpochMs'], older.millisecondsSinceEpoch);
      expect(summary['offline'], 1);
      final rows = summary['running_jobs_json'] as List;
      expect(rows.first['stale'], isFalse);
      expect(rows.last['stale'], isTrue);
      expect(rows.first['serverColor'], serverColorValue('a'));
      expect(rows.last['serverColor'], serverColorValue('b'));
      expect(rows.first['serverColor'], isNot(rows.last['serverColor']));
    },
  );
  test('an empty widget snapshot retains unknown node capacity and time', () {
    final summary = buildWidgetSnapshot([], status: '监控暂停', interval: 10);
    expect(summary['nodeSummary'], '空闲节点 —');
    expect(summary['timestampEpochMs'], isNull);
    expect(summary['timestamp'], '尚未刷新');
  });
  test(
    'widget colors use the full server set when only one colliding server has data',
    () {
      final colors = buildServerColors(['a', 'i']);
      final snapshot = buildWidgetSnapshot(
        [
          ServerSnapshot(
            serverId: 'i',
            serverName: 'I',
            timestamp: DateTime.now(),
            jobs: const [
              SlurmJob(
                serverId: 'i',
                serverName: 'I',
                jobId: '1',
                jobName: 'one',
                state: 'RUNNING',
              ),
            ],
          ),
        ],
        status: '监控中',
        interval: 10,
        serverIds: ['a', 'i'],
      );
      final job = (snapshot['running_jobs_json'] as List).single as Map;
      expect(job['serverId'], 'i');
      expect(job['serverColor'], colors['i']);
      expect(job['serverColor'], isNot(colors['a']));
    },
  );
  test(
    'a system request rejection is not reported as a card addition',
    () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'requestXiaomiWidget');
        return false;
      });
      expect(await const WidgetSetupService().openXiaomi(), isFalse);
    },
  );
  test(
    'ordinary widget fallback checks launcher support before requesting a pin',
    () async {
      final requests = <MethodCall>[];
      messenger.setMockMethodCallHandler(home, (call) async {
        requests.add(call);
        if (call.method == 'isRequestPinWidgetSupported') return false;
        fail('Unsupported launchers must not receive a pin request');
      });
      expect(await const WidgetSetupService().addDesktop(), isFalse);
      expect(requests, hasLength(1));
      messenger.setMockMethodCallHandler(home, (call) async {
        if (call.method == 'isRequestPinWidgetSupported') return true;
        expect(call.method, 'requestPinWidget');
        expect(call.arguments['android'], 'SlurmMonitorWidgetProvider');
        return null;
      });
      expect(await const WidgetSetupService().addDesktop(), isTrue);
    },
  );
  testWidgets(
    'Xiaomi entry requires all capabilities and never claims automatic installation',
    (tester) async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'getCapabilities') {
          return {
            'widgetSupported': true,
            'detailSupported': true,
            'pinSupported': true,
            'installedCount': 1,
          };
        }
        return true;
      });
      await tester.pumpWidget(const MaterialApp(home: WidgetSetupPage()));
      await tester.pumpAndSettle();
      expect(find.text('已添加概览卡片 1 张'), findsOneWidget);
      await tester.tap(find.text('小米卡片'));
      await tester.pumpAndSettle();
      expect(find.text('已请求打开小米卡片添加页，请在系统页面确认'), findsOneWidget);
      expect(find.textContaining('尚未完成平台上架审核'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('unavailable Xiaomi APIs leave the desktop fallback accessible', (
    tester,
  ) async {
    messenger.setMockMethodCallHandler(
      channel,
      (_) async => {
        'widgetSupported': false,
        'detailSupported': false,
        'pinSupported': true,
      },
    );
    await tester.pumpWidget(const MaterialApp(home: WidgetSetupPage()));
    await tester.pumpAndSettle();
    final add = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, '小米卡片'),
    );
    expect(add.onPressed, isNull);
    final fallback = tester.widget<OutlinedButton>(
      find.widgetWithText(OutlinedButton, '桌面小部件'),
    );
    expect(fallback.onPressed, isNotNull);
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'capability failure can be retried on a small screen with enlarged text',
    (tester) async {
      tester.view.physicalSize = const Size(360, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      var failQuery = true;
      messenger.setMockMethodCallHandler(channel, (_) async {
        if (failQuery) throw PlatformException(code: 'UNAVAILABLE');
        return {
          'widgetSupported': true,
          'detailSupported': false,
          'pinSupported': true,
        };
      });
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(1.3)),
            child: child!,
          ),
          home: const WidgetSetupPage(),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('暂时无法检测系统卡片入口，请重试'), findsOneWidget);
      failQuery = false;
      await tester.tap(find.byTooltip('重新检测'));
      await tester.pumpAndSettle();
      expect(find.text('支持小米卡片'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
