import 'package:flutter/material.dart';
import '../models/server_palette.dart';
import '../models/slurm_models.dart';
import '../services/optimization_check_service.dart';
import '../services/remote_files.dart';
import 'app_theme.dart';
import 'gaussian_progress_page.dart';
import 'optimization_status.dart';
import 'outcar_progress_page.dart';
import 'file_date.dart';
import 'remote_file_browser.dart';
import 'open_server_files.dart';

class OptimizationCheckPage extends StatefulWidget {
  const OptimizationCheckPage({
    super.key,
    required this.jobs,
    required this.servers,
    this.demo = false,
    this.stateNotes = const {},
    this.isStillRunning,
    this.onSubmitted,
    this.filesFactory,
  });
  final List<SlurmJob> jobs;
  final List<ServerConfig> servers;
  final bool demo;
  final Map<String, String> stateNotes;
  final bool Function(String key)? isStillRunning;
  final VoidCallback? onSubmitted;
  final RemoteFiles Function(ServerConfig)? filesFactory;
  @override
  State<OptimizationCheckPage> createState() => _OptimizationCheckPageState();
}

class _OptimizationCheckPageState extends State<OptimizationCheckPage> {
  final _services = <String, OptimizationCheckService>{};
  final _results = <String, CurrentCalculation>{};
  final _errors = <String, String>{};
  final _counts = <String, int>{};
  bool _busy = true;
  int _revision = 0;
  late final _colors = buildServerColors(
    widget.servers.where((s) => s.enabled).map((s) => s.id),
  );
  @override
  void initState() {
    super.initState();
    _check();
  }

  @override
  void dispose() {
    _revision++;
    for (final service in _services.values) {
      service.files.close();
    }
    super.dispose();
  }

  RemoteFiles _files(SlurmJob job) => widget.demo
      ? DemoRemoteFiles()
      : (widget.filesFactory ?? SshRemoteFiles.new)(
          widget.servers.firstWhere((s) => s.id == job.serverId),
        );
  String _scanKey(SlurmJob job) => '${job.serverId}\x00${job.workDir}';
  Future<void> _check() async {
    final revision = ++_revision;
    setState(() {
      _busy = true;
      _results.clear();
      _errors.clear();
      _counts.clear();
    });
    final groups = <String, List<SlurmJob>>{};
    for (final job in widget.jobs) {
      (groups[job.serverId] ??= []).add(job);
    }
    final servers = groups.values.toList();
    var next = 0;
    Future<void> worker() async {
      while (mounted && revision == _revision && next < servers.length) {
        final jobs = servers[next++];
        final scans = <String, CurrentCalculation>{};
        for (final job in jobs) {
          if (!mounted || revision != _revision) return;
          if (widget.isStillRunning?.call(job.key) == false) {
            setState(() => _errors[job.key] = '该作业已不在最新运行列表中');
            continue;
          }
          if (!job.workDir.startsWith('/')) {
            setState(() => _errors[job.key] = '未提供可读取的工作目录');
            continue;
          }
          try {
            final service = _services.putIfAbsent(
              job.serverId,
              () => OptimizationCheckService(_files(job)),
            );
            final scanKey = _scanKey(job);
            final progressWatch = Stopwatch()..start();
            final result =
                scans[scanKey] ??
                await service.check(
                  job.workDir,
                  cancelled: () => !mounted || revision != _revision,
                  onProgress: (count) {
                    if (mounted &&
                        revision == _revision &&
                        progressWatch.elapsedMilliseconds >= 120) {
                      setState(() => _counts[scanKey] = count);
                      progressWatch.reset();
                    }
                  },
                );
            scans[scanKey] = result;
            if (!mounted || revision != _revision) return;
            setState(() {
              if (widget.isStillRunning?.call(job.key) == false) {
                _errors[job.key] = '该作业已不在最新运行列表中';
              } else {
                _results[job.key] = result;
              }
            });
          } on FileReadCancelled {
            return;
          } catch (e) {
            if (!mounted || revision != _revision) return;
            setState(() => _errors[job.key] = fileError(e));
          }
        }
      }
    }

    await Future.wait(
      List.generate(servers.length.clamp(0, 4), (_) => worker()),
    );
    if (mounted && revision == _revision) setState(() => _busy = false);
  }

  void _stop() => setState(() {
    _revision++;
    _busy = false;
    for (final job in widget.jobs) {
      if (!_results.containsKey(job.key) && !_errors.containsKey(job.key)) {
        _errors[job.key] = '已停止检测';
      }
    }
  });

  void _open(SlurmJob job, CurrentCalculation result) {
    final path = result.path!;
    final files = _services[job.serverId]!.files;
    void text() => Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => RemoteFilePage(files: files, path: path),
      ),
    );
    Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => result.kind == CalculationKind.gaussian
            ? GaussianProgressPage(files: files, path: path, onOpenText: text)
            : remoteName(path).toUpperCase() == 'OUTCAR'
            ? OutcarProgressPage(files: files, path: path, onOpenText: text)
            : RemoteFilePage(files: files, path: path),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('优化检测'),
      actions: [
        IconButton(
          tooltip: _busy ? '停止检测' : '重新检测',
          onPressed: _busy ? _stop : _check,
          icon: Icon(_busy ? Icons.stop_circle_outlined : Icons.refresh),
        ),
      ],
    ),
    body: SafeArea(
      child: Column(
        children: [
          if (_busy) const LinearProgressIndicator(minHeight: 3),
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.all(12),
              itemCount: widget.jobs.isEmpty ? 1 : widget.jobs.length,
              itemBuilder: (context, index) {
                if (widget.jobs.isEmpty) {
                  return const Center(child: Text('暂无运行作业'));
                }
                final job = widget.jobs[index], result = _results[job.key];
                final error = _errors[job.key],
                    color = Color(
                      _colors[job.serverId] ?? serverColorValue(job.serverId),
                    );
                return Card(
                  margin: const EdgeInsets.only(bottom: 10),
                  color: Color.alphaBlend(
                    color.withValues(alpha: .12),
                    Theme.of(context).colorScheme.surface,
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${job.serverName} · #${job.jobId}',
                          style: TextStyle(fontSize: 11, color: context.muted),
                        ),
                        Text(
                          job.jobName,
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                        if (widget.stateNotes[job.key] != null)
                          Text(
                            widget.stateNotes[job.key]!,
                            style: TextStyle(
                              fontSize: 11,
                              color: context.muted,
                            ),
                          ),
                        const SizedBox(height: 6),
                        if (error != null || result?.assessment == null)
                          Text(
                            error ??
                                result?.message ??
                                '扫描子目录中 · 已找到 ${_counts[_scanKey(job)] ?? 0} 个输出',
                            style: TextStyle(
                              fontSize: 12,
                              color: context.muted,
                            ),
                          ),
                        if (result?.assessment != null)
                          OptimizationStatus(assessment: result!.assessment!),
                        if (result?.path != null) ...[
                          Text(
                            result!.path!,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 11),
                          ),
                          Tooltip(
                            message: '最近修改',
                            child: Text(
                              fileDate(result.modified),
                              style: TextStyle(
                                fontSize: 11,
                                color: context.muted,
                              ),
                            ),
                          ),
                        ],
                        Wrap(
                          spacing: 8,
                          children: [
                            if (result?.path != null)
                              TextButton.icon(
                                onPressed: () => _open(job, result!),
                                icon: const Icon(Icons.show_chart, size: 17),
                                label: const Text('曲线与结构'),
                              ),
                            if (job.workDir.startsWith('/'))
                              TextButton.icon(
                                onPressed: () => openServerFiles(
                                  context,
                                  widget.servers.firstWhere(
                                    (s) => s.id == job.serverId,
                                  ),
                                  demo: widget.demo,
                                  directory: job.workDir,
                                  title: '#${job.jobId} · ${job.serverName}',
                                  onSubmitted: widget.onSubmitted,
                                ),
                                icon: const Icon(
                                  Icons.folder_open_outlined,
                                  size: 17,
                                ),
                                label: const Text('文件'),
                              ),
                          ],
                        ),
                        if (result?.warnings.isNotEmpty == true)
                          Text(
                            result!.warnings.join('\n'),
                            style: TextStyle(
                              fontSize: 11,
                              color: context.muted,
                            ),
                          ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    ),
  );
}
