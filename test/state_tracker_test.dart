import 'package:flutter_test/flutter_test.dart';
import 'package:slurm_cluster_monitor/models/slurm_models.dart';
import 'package:slurm_cluster_monitor/services/state_tracker.dart';
import 'package:slurm_cluster_monitor/services/notification_service.dart';

final epoch = DateTime.utc(2026, 10, 24);
SlurmJob job(
  String state, {
  String server = 'a',
  String id = '1',
  int end = 0,
  int submit = 0,
}) => SlurmJob(
  serverId: server,
  serverName: server,
  jobId: id,
  jobName: 'simulation',
  state: normalizeState(state),
  submitTime: epoch.add(Duration(seconds: submit)),
  endTime: end == 0 ? null : epoch.add(Duration(seconds: end)),
  nodeList: 'cn01',
  elapsed: '00:03:00',
  exitCode: '1:0',
  reason: 'NonZeroExitCode',
);
ServerSnapshot snapshot(
  List<SlurmJob> jobs, {
  int at = 0,
  bool accounting = true,
}) => ServerSnapshot(
  serverId: jobs.isEmpty ? 'a' : jobs.first.serverId,
  serverName: 'A',
  timestamp: epoch.add(Duration(seconds: at)),
  jobs: jobs,
  accountingOk: accounting,
);

void main() {
  test('first snapshot is a silent baseline', () {
    final t = JobStateTracker();
    expect(
      t.observe(
        snapshot([
          job('COMPLETED', end: -10),
          job('FAILED', id: '2', end: -20),
        ]),
      ),
      isEmpty,
    );
  });
  test(
    'all five requested transitions work; every prior state can complete',
    () {
      for (final pair in [
        ('PENDING', 'RUNNING'),
        ('PENDING', 'COMPLETED'),
        ('RUNNING', 'FAILED'),
        ('RUNNING', 'TIMEOUT'),
        ('RUNNING', 'OOM'),
      ]) {
        final t = JobStateTracker();
        t.observe(snapshot([job(pair.$1)]));
        final event = t
            .observe(snapshot([job(pair.$2, end: 5)], at: 10))
            .single;
        expect(event.previous, pair.$1);
        expect(event.title, contains('作业'));
        expect(event.body, contains('simulation'));
      }
    },
  );
  test(
    'jobs start and finish between polls; no notification for missing records',
    () {
      final t = JobStateTracker();
      t.observe(snapshot([]));
      expect(
        t.observe(snapshot([job('COMPLETED', end: 5)], at: 10)),
        hasLength(1),
      );
      expect(t.observe(snapshot([], at: 20)), isEmpty);
      expect(t.observe(snapshot([job('COMPLETED', end: 5)], at: 30)), isEmpty);
    },
  );
  test('persists outbox, deduplication and baselines over process restart', () {
    final t = JobStateTracker();
    t.observe(snapshot([job('PENDING')]));
    t.observe(snapshot([job('RUNNING')], at: 5));
    final copy = JobStateTracker()..restore(t.toJson());
    expect(copy.pending, hasLength(1));
    copy.acknowledge(copy.pending.single, epoch);
    final restored = JobStateTracker()..restore(copy.toJson());
    expect(restored.pending, isEmpty);
    expect(restored.observe(snapshot([job('RUNNING')], at: 10)), isEmpty);
  });
  test(
    'server identities are independent and reused job IDs use submission time',
    () {
      final t = JobStateTracker();
      t.observe(snapshot([job('PENDING')]));
      expect(
        t.observe(snapshot([job('RUNNING', server: 'b')], at: 5)),
        isEmpty,
      );
      expect(t.observe(snapshot([job('RUNNING', submit: 3)], at: 5)), isEmpty);
    },
  );
  test('accounting outage does not reset successful baseline', () {
    final t = JobStateTracker();
    t.observe(snapshot([]));
    t.observe(snapshot([], at: 10, accounting: false));
    expect(t.observe(snapshot([job('FAILED', end: 6)], at: 20)), hasLength(1));
  });
  test('removed servers lose queued notifications', () {
    final t = JobStateTracker();
    t.observe(snapshot([job('PENDING')]));
    t.observe(snapshot([job('RUNNING')], at: 5));
    t.retainServers({});
    expect(t.pending, isEmpty);
  });
  test(
    'notification ID is deterministic, positive and distinguishes server/state',
    () {
      expect(
        stableNotificationId('a/1/RUNNING'),
        stableNotificationId('a/1/RUNNING'),
      );
      expect(
        stableNotificationId('a/1/RUNNING'),
        isNot(stableNotificationId('b/1/RUNNING')),
      );
      expect(stableNotificationId('a/1/RUNNING'), greaterThanOrEqualTo(0));
    },
  );
}
