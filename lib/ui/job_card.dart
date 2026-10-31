import 'package:flutter/material.dart';
import '../models/slurm_models.dart';
import 'app_theme.dart';
import 'resource_ring.dart';
import 'refresh_age.dart';

class JobCard extends StatefulWidget {
  const JobCard({
    super.key,
    required this.job,
    this.stale = false,
    this.onOpenFiles,
    this.serverColor,
    this.refreshedAt,
    this.onCheckOptimization,
    this.expanded,
    this.onExpansionChanged,
  });
  final SlurmJob job;
  final bool stale;
  final VoidCallback? onOpenFiles;
  final Color? serverColor;
  final DateTime? refreshedAt;
  final VoidCallback? onCheckOptimization;
  final bool? expanded;
  final ValueChanged<bool>? onExpansionChanged;
  @override
  State<JobCard> createState() => _JobCardState();
}

class _JobCardState extends State<JobCard> {
  bool _localExpanded = false;
  bool get _expanded => widget.expanded ?? _localExpanded;
  void _toggle() {
    final next = !_expanded;
    if (widget.onExpansionChanged != null) {
      widget.onExpansionChanged!(next);
    } else {
      setState(() => _localExpanded = next);
    }
  }

  void _info() => showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('统计说明'),
      content: Text(
        [
          'CPU：累计平均等效核数 / 任务分配核数。',
          '内存：任务 RSS / 所在节点总内存。',
          if (widget.job.allocatedMemMb != null)
            '任务申请内存：${formatMemory(widget.job.allocatedMemMb)}。',
          if (widget.job.metricNote.isNotEmpty) widget.job.metricNote,
        ].join('\n\n'),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('关闭'),
        ),
      ],
    ),
  );
  @override
  Widget build(BuildContext context) {
    final job = widget.job, colors = Theme.of(context).colorScheme;
    final color = job.isRunning || job.state == 'COMPLETED'
        ? colors.primary
        : job.isPending
        ? colors.tertiary
        : colors.error;
    final showUsage = !job.isPending && !job.isTerminal;
    final serverInk = Theme.of(context).brightness == Brightness.light
        ? Color.lerp(widget.serverColor ?? colors.secondary, Colors.black, .2)!
        : widget.serverColor ?? colors.secondary;
    return Card(
      color: Color.alphaBlend(
        (widget.serverColor ?? colors.primary).withValues(
          alpha: Theme.of(context).brightness == Brightness.light ? .12 : .18,
        ),
        colors.surface,
      ),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(
          color: (widget.serverColor ?? colors.primary).withValues(alpha: .35),
          width: .8,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Semantics(
            button: true,
            label: '${_expanded ? '收起' : '展开'}任务 ${job.jobId}',
            child: InkWell(
              onTap: _toggle,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  children: [
                    Row(
                      children: [
                        Icon(
                          Icons.circle,
                          size: 7,
                          color: widget.serverColor ?? colors.primary,
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            job.serverName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 12, color: serverInk),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 4,
                          ),
                          decoration: BoxDecoration(
                            color: color.withValues(alpha: .12),
                            borderRadius: BorderRadius.circular(7),
                          ),
                          child: Text(
                            '${widget.stale ? '缓存 · ' : ''}${stateLabel(job.state)}',
                            style: TextStyle(color: color, fontSize: 11),
                          ),
                        ),
                        const SizedBox(width: 8),
                        if (!_expanded && widget.onOpenFiles != null)
                          IconButton(
                            tooltip: '打开文件夹',
                            onPressed: widget.onOpenFiles,
                            icon: Icon(
                              Icons.folder_open_outlined,
                              size: 18,
                              color: serverInk,
                            ),
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(
                              minWidth: 48,
                              minHeight: 48,
                            ),
                            visualDensity: VisualDensity.standard,
                          ),
                        Tooltip(
                          message: _expanded ? '收起任务详情' : '展开任务详情',
                          child: Icon(
                            _expanded ? Icons.expand_less : Icons.expand_more,
                            size: 20,
                            color: context.muted,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        job.jobName,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 15,
                        ),
                      ),
                    ),
                    const SizedBox(height: 4),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        [
                          '#${job.jobId}',
                          job.isRunning ? job.elapsed : job.partition,
                          job.nodeList,
                        ].where((value) => value.isNotEmpty).join(' · '),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 11, color: context.muted),
                      ),
                    ),
                    if (showUsage) ...[
                      const SizedBox(height: 10),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: ResourceRing(
                              label: '平均 CPU',
                              detail: job.cpuText,
                              percent: job.cpuUsagePercent,
                              color: colors.secondary,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: ResourceRing(
                              label: '内存',
                              detail: job.memText,
                              percent: job.memUsagePercent,
                              color: (job.memUsagePercent ?? 0) >= 85
                                  ? colors.tertiary
                                  : colors.primary,
                            ),
                          ),
                        ],
                      ),
                    ],
                    if (job.isPending) ...[
                      const SizedBox(height: 5),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          '排队：${job.reason.isEmpty ? '等待调度' : job.reason}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 12, color: color),
                        ),
                      ),
                    ],
                    if (job.isTerminal && job.endTime != null)
                      Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          '结束 ${job.endTime!.toLocal().toString().substring(0, 16)}',
                          style: TextStyle(fontSize: 12, color: context.muted),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
          if (_expanded)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Divider(height: 1),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      const Icon(Icons.schedule, size: 14),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          '${job.elapsed} / ${job.timeLimit}',
                          style: TextStyle(fontSize: 12, color: context.muted),
                        ),
                      ),
                      IconButton(
                        tooltip: '统计说明',
                        onPressed: _info,
                        icon: const Icon(Icons.info_outline, size: 18),
                      ),
                    ],
                  ),
                  if (job.isPending)
                    Text(
                      '排队：${job.reason.isEmpty ? '等待调度' : job.reason}',
                      style: TextStyle(fontSize: 12, color: color),
                    ),
                  if (job.isTerminal)
                    Text(
                      '退出码 ${job.exitCode.isEmpty ? '—' : job.exitCode}',
                      style: TextStyle(fontSize: 12, color: context.muted),
                    ),
                  if (widget.refreshedAt != null)
                    RefreshAge(
                      timestamp: widget.refreshedAt,
                      style: TextStyle(fontSize: 10, color: context.muted),
                    ),
                  Wrap(
                    spacing: 8,
                    children: [
                      if (job.isRunning && widget.onCheckOptimization != null)
                        TextButton.icon(
                          onPressed: widget.onCheckOptimization,
                          icon: const Icon(Icons.insights_outlined, size: 17),
                          label: const Text('优化检测'),
                        ),
                      if (widget.onOpenFiles != null)
                        TextButton.icon(
                          onPressed: widget.onOpenFiles,
                          icon: const Icon(
                            Icons.folder_open_outlined,
                            size: 17,
                          ),
                          label: const Text('文件'),
                        ),
                    ],
                  ),
                  SelectableText(
                    job.workDir.isEmpty ? '未提供工作目录' : job.workDir,
                    style: const TextStyle(fontSize: 11),
                    minLines: 1,
                    maxLines: 3,
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
