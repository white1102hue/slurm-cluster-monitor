import 'package:flutter_test/flutter_test.dart';
import 'package:slurm_cluster_monitor/models/slurm_models.dart';

void main() {
  final now = DateTime.utc(2026, 10, 26, 12);
  SlurmJob job(String id, String state, {DateTime? end}) => SlurmJob(
    serverId: 'a',
    serverName: 'A',
    jobId: id,
    jobName: id,
    state: state,
    endTime: end,
  );
  ServerSnapshot snapshot(List<SlurmJob> jobs, {bool accounting = true}) =>
      ServerSnapshot(
        serverId: 'a',
        serverName: 'A',
        timestamp: now,
        jobs: jobs,
        accountingOk: accounting,
      );

  test(
    'incremental refresh retains confirmed history and drops stale active rows',
    () {
      final previous = snapshot([
        job('1', 'COMPLETED', end: now.subtract(const Duration(hours: 2))),
        job('2', 'RUNNING'),
      ]);
      final merged = snapshot([
        job('3', 'FAILED', end: now),
      ]).withHistory(previous);
      expect(merged.jobs.map((j) => j.jobId), ['1', '3']);
      expect(merged.activeJobs, isEmpty);
    },
  );
  test(
    'accounting outages keep confirmed completions without inferring new ones',
    () {
      final previous = snapshot([
        job('1', 'COMPLETED', end: now.subtract(const Duration(hours: 1))),
        job('2', 'RUNNING'),
      ]);
      final merged = snapshot([], accounting: false).withHistory(previous);
      expect(merged.finishedJobs.single.jobId, '1');
      expect(merged.accountingOk, isFalse);
      expect(merged.activeJobs, isEmpty);
    },
  );
  test(
    'history expires by completion time and is preserved across serialization',
    () {
      final previous = snapshot([
        job('old', 'COMPLETED', end: now.subtract(const Duration(days: 8))),
        job('edge', 'COMPLETED', end: now.subtract(jobHistoryRetention)),
      ]);
      final restored = ServerSnapshot.fromJson(previous.toJson());
      final merged = snapshot([
        job('also-old', 'FAILED', end: now.subtract(const Duration(days: 9))),
      ]).withHistory(restored);
      expect(merged.jobs.single.jobId, 'edge');
    },
  );
  test(
    'new queue rows replace history when a job ID is reused or requeued',
    () {
      final previous = snapshot([
        job('1', 'COMPLETED', end: now.subtract(const Duration(hours: 1))),
      ]);
      final merged = snapshot([job('1', 'RUNNING')]).withHistory(previous);
      expect(merged.jobs.single.state, 'RUNNING');
      expect(merged.finishedJobs, isEmpty);
    },
  );
}
