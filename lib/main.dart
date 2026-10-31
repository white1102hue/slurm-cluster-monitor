import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:provider/provider.dart';
import 'models/slurm_models.dart';
import 'models/app_skin.dart';
import 'models/server_palette.dart';
import 'services/monitor_controller.dart';
import 'ui/app_theme.dart';
import 'ui/job_card.dart';
import 'ui/refresh_age.dart';
import 'ui/open_server_files.dart';
import 'ui/server_editor.dart';
import 'ui/widget_setup_page.dart';
import 'ui/optimization_check_page.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final controller = MonitorController(
    demo: kIsWeb || const bool.fromEnvironment('DEMO'),
  );
  await controller.initialize();
  runApp(
    ChangeNotifierProvider.value(
      value: controller,
      child: const SlurmMonitorApp(),
    ),
  );
}

class SlurmMonitorApp extends StatelessWidget {
  const SlurmMonitorApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Slurm 集群监控',
    debugShowCheckedModeBanner: false,
    locale: Locale('zh', 'CN'),
    supportedLocales: [Locale('zh', 'CN'), Locale('en')],
    localizationsDelegates: GlobalMaterialLocalizations.delegates,
    theme: buildAppTheme(
      context.select<MonitorController, AppSkin>((c) => c.skin),
    ),
    home: const DashboardPage(),
  );
}

class DashboardPage extends StatefulWidget {
  const DashboardPage({super.key});
  @override
  State<DashboardPage> createState() => _DashboardPageState();
}

class _DashboardPageState extends State<DashboardPage> {
  Color get mint => Theme.of(context).colorScheme.primary;
  Color get blue => Theme.of(context).colorScheme.secondary;
  Color get amber => Theme.of(context).colorScheme.tertiary;
  int _page = 0;
  String _jobFilter = '活跃作业';
  final _query = TextEditingController();
  final _expandedJobs = <String>{};
  bool _searchOpen = false, _abnormalOnly = false, _openingFiles = false;
  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    context.select<MonitorController, (int, bool)>(
      (c) => (c.dataVersion, c.monitoring),
    );
    final ctrl = context.read<MonitorController>();
    final identities = ctrl.snapshots.values
        .expand((s) => s.jobs)
        .map((j) => j.identity)
        .toSet();
    _expandedJobs.removeWhere((key) => !identities.contains(key));
    return Scaffold(
      appBar: AppBar(
        title: Text(
          ['作业总览', '集群资源', '连接管理'][_page],
          style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
        ),
        actions: [
          Consumer<MonitorController>(
            builder: (_, state, _) => IconButton(
              tooltip: '立即刷新',
              onPressed: state.busy || state.refreshing ? null : state.refresh,
              icon: Icon(Icons.refresh_rounded),
            ),
          ),
          PopupMenuButton<String>(
            tooltip: '更多操作',
            onSelected: (value) {
              if (value == 'optimization') {
                _checkOptimization(ctrl);
              } else {
                showModalBottomSheet<void>(
                  context: context,
                  isScrollControlled: true,
                  useSafeArea: true,
                  builder: (_) => ChangeNotifierProvider.value(
                    value: ctrl,
                    child: const SettingsSheet(),
                  ),
                );
              }
            },
            itemBuilder: (_) => [
              if (_page == 0 && ctrl.activeJobs.any((j) => j.isRunning))
                const PopupMenuItem(value: 'optimization', child: Text('优化检测')),
              const PopupMenuItem(value: 'settings', child: Text('监控设置')),
            ],
          ),
          SizedBox(width: 6),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(3),
          child: Consumer<MonitorController>(
            builder: (_, state, _) => state.busy || state.refreshing
                ? const LinearProgressIndicator(minHeight: 3)
                : const SizedBox(height: 3),
          ),
        ),
      ),
      body: SafeArea(
        top: false,
        child: Center(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: 1080),
            child: RefreshIndicator(
              onRefresh: ctrl.refresh,
              child: CustomScrollView(
                key: PageStorageKey<int>(_page),
                physics: AlwaysScrollableScrollPhysics(),
                slivers: [
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                    sliver: SliverToBoxAdapter(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Consumer<MonitorController>(
                            builder: (_, state, _) => _statusHeader(state),
                          ),
                          SizedBox(height: 8),
                          Selector<MonitorController, String?>(
                            selector: (_, state) => state.message,
                            builder: (_, message, _) => message == null
                                ? const SizedBox.shrink()
                                : Padding(
                                    padding: const EdgeInsets.only(bottom: 10),
                                    child: notice(
                                      context,
                                      message,
                                      Icons.info_outline,
                                      amber,
                                    ),
                                  ),
                          ),
                          if (_page != 2) _connectionNotice(ctrl),
                          if (_page != 2) ...[
                            if (_page == 1) ...[
                              _summary(ctrl),
                              const SizedBox(height: 10),
                            ],
                            _serverFilter(ctrl),
                            SizedBox(height: 8),
                          ],
                        ],
                      ),
                    ),
                  ),
                  if (_page == 0) ..._jobs(ctrl),
                  if (_page != 0)
                    SliverPadding(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      sliver: _adaptiveCards(
                        _page == 1 ? _nodes(ctrl) : _servers(ctrl),
                      ),
                    ),
                  const SliverToBoxAdapter(child: SizedBox(height: 24)),
                ],
              ),
            ),
          ),
        ),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _page,
        onDestinationSelected: (v) => setState(() => _page = v),
        destinations: [
          NavigationDestination(
            icon: Icon(Icons.stacked_line_chart),
            label: '我的作业',
          ),
          NavigationDestination(icon: Icon(Icons.dns_outlined), label: '节点空闲'),
          NavigationDestination(
            icon: Icon(Icons.storage_outlined),
            label: '服务器',
          ),
        ],
      ),
      floatingActionButton: _page == 2 && !ctrl.demo
          ? FloatingActionButton.extended(
              onPressed: () => _editServer(ctrl),
              icon: Icon(Icons.add),
              label: Text('添加服务器'),
            )
          : null,
    );
  }

  Widget _statusHeader(MonitorController ctrl) => Row(
    children: [
      Expanded(
        child: Wrap(
          spacing: 7,
          runSpacing: 4,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            if (ctrl.demo)
              Tooltip(
                message: '退出演示',
                child: TextButton.icon(
                  onPressed: ctrl.nativeSupported ? ctrl.toggleDemo : null,
                  icon: const Icon(Icons.science_outlined, size: 16),
                  label: const Text('演示'),
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    visualDensity: VisualDensity.compact,
                  ),
                ),
              )
            else ...[
              Icon(
                Icons.circle,
                size: 7,
                color: ctrl.monitoring ? mint : amber,
              ),
              Text(
                ctrl.monitoring ? '监控中' : '已暂停',
                style: TextStyle(color: context.muted, fontSize: 11),
              ),
            ],
            RefreshAge(
              timestamp: ctrl.lastUpdate,
              style: TextStyle(color: context.muted, fontSize: 12),
            ),
            if (ctrl.visibleServerCount > 0)
              Text(
                '${ctrl.healthyServers}/${ctrl.visibleServerCount} 集群正常',
                style: TextStyle(fontSize: 12, color: context.muted),
              ),
            if (ctrl.hasCachedJobs && ctrl.visibleSnapshots.isNotEmpty)
              Text('含缓存', style: TextStyle(fontSize: 12, color: amber)),
          ],
        ),
      ),
      if (!ctrl.demo && ctrl.servers.isNotEmpty)
        IconButton(
          tooltip: ctrl.monitoring ? '暂停监控' : '启动监控',
          onPressed: ctrl.busy
              ? null
              : ctrl.monitoring
              ? ctrl.stopMonitoring
              : ctrl.startMonitoring,
          icon: Icon(
            ctrl.monitoring ? Icons.pause_rounded : Icons.play_arrow_rounded,
            size: 18,
          ),
        ),
    ],
  );

  Widget _summary(MonitorController ctrl) => Card(
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          Expanded(
            child: _metric(
              '空闲节点',
              ctrl.validNodeServers == 0 ? '—' : '${ctrl.idleNodes}',
              blue,
            ),
          ),
          Expanded(
            child: _metric(
              '总节点',
              ctrl.validNodeServers == 0
                  ? '—'
                  : '${ctrl.visibleSnapshots.where((s) => s.isOnline && s.nodesOk).fold<int>(0, (n, s) => n + (s.uniqueTotalNodes ?? 0))}',
              mint,
            ),
          ),
          if (ctrl.validNodeServers < ctrl.visibleServerCount)
            Text('部分数据', style: TextStyle(fontSize: 12, color: amber)),
        ],
      ),
    ),
  );
  Widget _connectionNotice(MonitorController ctrl) {
    final bad = ctrl.visibleSnapshots
        .where((s) => !s.isOnline || !s.queueOk || s.warnings.isNotEmpty)
        .toList();
    if (bad.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: InkWell(
        onTap: () => setState(() => _page = 2),
        child: notice(
          context,
          '${bad.map((s) => s.serverName).join('、')} 采集异常，保留可用记录 · 查看',
          Icons.info_outline,
          amber,
        ),
      ),
    );
  }

  Widget _adaptiveCards(List<Widget> cards) => SliverLayoutBuilder(
    builder: (context, constraints) {
      final scale = MediaQuery.textScalerOf(context).scale(1).clamp(1.0, 2.0);
      final columns = (constraints.crossAxisExtent / (400 * scale))
          .floor()
          .clamp(1, 2);
      return SliverList.builder(
        itemCount: (cards.length / columns).ceil(),
        itemBuilder: (_, row) => Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (var c = 0; c < columns; c++) ...[
              if (c > 0) const SizedBox(width: 10),
              Expanded(
                child: row * columns + c < cards.length
                    ? cards[row * columns + c]
                    : const SizedBox.shrink(),
              ),
            ],
          ],
        ),
      );
    },
  );
  Widget _metric(String label, String value, Color color) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        value,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 23,
          height: 1.1,
          fontWeight: FontWeight.w600,
          color: color,
        ),
      ),
      const SizedBox(height: 4),
      Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(fontSize: 11, color: context.muted),
      ),
    ],
  );
  Widget _serverFilter(MonitorController ctrl) => SingleChildScrollView(
    scrollDirection: Axis.horizontal,
    child: Row(
      children: [
        ChoiceChip(
          label: Text('所有集群'),
          selected: ctrl.selectedServer == null,
          onSelected: (_) => ctrl.selectServer(null),
        ),
        for (final server in ctrl.servers.where((s) => s.enabled))
          Padding(
            padding: const EdgeInsets.only(left: 8),
            child: ChoiceChip(
              label: Text(server.name),
              avatar: Icon(
                Icons.circle,
                size: 8,
                color: Color(
                  ctrl.serverColors[server.id] ?? serverColorValue(server.id),
                ),
              ),
              selected: ctrl.selectedServer == server.id,
              onSelected: (_) => ctrl.selectServer(server.id),
            ),
          ),
      ],
    ),
  );

  List<Widget> _jobs(MonitorController ctrl) {
    final base = _jobFilter == '最近结束'
        ? ctrl.finishedJobs
        : ctrl.activeJobs
              .where(
                (j) => _jobFilter == '运行中'
                    ? j.isRunning
                    : _jobFilter == '排队中'
                    ? j.isPending
                    : true,
              )
              .toList();
    final query = _query.text.trim().toLowerCase();
    final jobs = base
        .where(
          (j) =>
              (!_abnormalOnly || _jobFilter != '最近结束' || j.isAbnormalEnd) &&
              (query.isEmpty ||
                  '${j.jobName} ${j.jobId} ${j.partition} ${j.nodeList}'
                      .toLowerCase()
                      .contains(query)),
        )
        .toList();
    String filterLabel(String filter) => switch (filter) {
      '活跃作业' => '活跃 ${ctrl.activeJobs.length}',
      '运行中' => '运行 ${ctrl.runningCount}',
      '排队中' => '排队 ${ctrl.pendingCount}',
      _ => filter,
    };
    return [
      SliverPadding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        sliver: SliverToBoxAdapter(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: [
                          for (final filter in ['活跃作业', '运行中', '排队中', '最近结束'])
                            Padding(
                              padding: const EdgeInsets.only(right: 6),
                              child: FilterChip(
                                label: Text(filterLabel(filter)),
                                key: ValueKey('job-filter-$filter'),
                                tooltip: filter == '最近结束' ? '最近 7 天' : null,
                                selected: _jobFilter == filter,
                                showCheckmark: false,
                                onSelected: (_) =>
                                    setState(() => _jobFilter = filter),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: '搜索作业',
                    isSelected: _searchOpen,
                    onPressed: () => setState(() {
                      _searchOpen = !_searchOpen;
                      if (!_searchOpen) _query.clear();
                    }),
                    icon: const Icon(Icons.search),
                  ),
                ],
              ),
              if (_searchOpen) ...[
                TextField(
                  controller: _query,
                  autofocus: true,
                  onChanged: (_) => setState(() {}),
                  decoration: InputDecoration(
                    hintText: '名称、作业号、分区或节点',
                    isDense: true,
                    suffixIcon: IconButton(
                      tooltip: '清空搜索',
                      icon: const Icon(Icons.clear),
                      onPressed: () => setState(_query.clear),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 5),
                  child: Text(
                    '匹配 ${jobs.length} 项',
                    style: TextStyle(fontSize: 12, color: context.muted),
                  ),
                ),
              ],
              if (_jobFilter == '最近结束')
                Wrap(
                  spacing: 8,
                  children: [
                    for (final abnormal in [false, true])
                      ChoiceChip(
                        label: Text(abnormal ? '异常结束' : '全部'),
                        selected: _abnormalOnly == abnormal,
                        onSelected: (_) =>
                            setState(() => _abnormalOnly = abnormal),
                      ),
                  ],
                ),
              const SizedBox(height: 4),
              if (ctrl.servers.isEmpty)
                emptyState(
                  context,
                  '尚未连接集群',
                  Icons.hub_outlined,
                  action: Column(
                    children: [
                      FilledButton.icon(
                        onPressed: () => _editServer(ctrl),
                        icon: Icon(Icons.add),
                        label: Text('添加服务器'),
                      ),
                      TextButton(
                        onPressed: ctrl.toggleDemo,
                        child: Text('查看演示'),
                      ),
                    ],
                  ),
                )
              else if (jobs.isEmpty)
                emptyState(
                  context,
                  ctrl.visibleSnapshots.any(
                        (s) => !s.queueOk && s.queueUpdatedAt == null,
                      )
                      ? '队列暂不可用，请查看连接状态'
                      : _jobFilter == '最近结束'
                      ? '暂无匹配的结束作业'
                      : '当前没有匹配的作业',
                  Icons.task_alt,
                ),
            ],
          ),
        ),
      ),
      if (jobs.isNotEmpty)
        SliverPadding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          sliver: SliverLayoutBuilder(
            builder: (context, constraints) {
              final scale = MediaQuery.textScalerOf(
                context,
              ).scale(1).clamp(1.0, 2.0);
              final columns = (constraints.crossAxisExtent / (340 * scale))
                  .floor()
                  .clamp(1, 3);
              return SliverList.builder(
                itemCount: (jobs.length / columns).ceil(),
                itemBuilder: (context, row) => Padding(
                  key: ValueKey('row-${jobs[row * columns].key}'),
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (var column = 0; column < columns; column++) ...[
                        if (column > 0) const SizedBox(width: 10),
                        Expanded(
                          child: row * columns + column < jobs.length
                              ? RepaintBoundary(
                                  child: _jobCard(
                                    jobs[row * columns + column],
                                    ctrl,
                                  ),
                                )
                              : const SizedBox.shrink(),
                        ),
                      ],
                    ],
                  ),
                ),
              );
            },
          ),
        ),
    ];
  }

  Widget _jobCard(SlurmJob job, MonitorController ctrl) {
    final snap = ctrl.snapshots[job.serverId];
    final stale =
        !ctrl.demo &&
        (!ctrl.monitoring ||
            snap?.isOnline != true ||
            snap?.queueOk != true ||
            DateTime.now()
                    .difference(snap!.queueUpdatedAt ?? snap.timestamp)
                    .inSeconds >
                ctrl.refreshIntervalSeconds * 3 + 30);
    return JobCard(
      key: ValueKey('${job.serverId}/${job.jobId}'),
      job: job,
      stale: stale,
      refreshedAt: snap?.queueUpdatedAt,
      expanded: _expandedJobs.contains(job.identity),
      onExpansionChanged: (value) => setState(() {
        if (value) {
          _expandedJobs.add(job.identity);
        } else {
          _expandedJobs.remove(job.identity);
        }
      }),
      serverColor: Color(
        ctrl.serverColors[job.serverId] ?? serverColorValue(job.serverId),
      ),
      onCheckOptimization: job.isRunning
          ? () => _checkOptimization(ctrl, job: job)
          : null,
      onOpenFiles: job.workDir.startsWith('/')
          ? () {
              final server = ctrl.servers.firstWhere(
                (s) => s.id == job.serverId,
              );
              _openFiles(
                ctrl,
                server,
                directory: job.workDir,
                title: '#${job.jobId} · ${server.name}',
              );
            }
          : null,
    );
  }

  void _checkOptimization(MonitorController ctrl, {SlurmJob? job}) {
    final running = job == null
        ? ctrl.activeJobs.where((j) => j.isRunning).toList()
        : [job];
    final notes = <String, String>{};
    for (final current in running) {
      if (!ctrl.demo &&
          (!ctrl.monitoring ||
              ctrl.snapshots[current.serverId]?.isOnline != true)) {
        notes[current.key] = 'Slurm 状态来自缓存；文件仍按最新修改时间检测';
      }
    }
    Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => OptimizationCheckPage(
          jobs: running,
          servers: ctrl.servers,
          demo: ctrl.demo,
          stateNotes: notes,
          isStillRunning: (key) =>
              ctrl.activeJobs.any((j) => j.key == key && j.isRunning),
          onSubmitted: () {
            ctrl.refresh();
          },
        ),
      ),
    );
  }

  List<Widget> _nodes(MonitorController ctrl) => [
    if (ctrl.partitions.isEmpty)
      emptyState(context, '暂无节点信息', Icons.dns_outlined),
    for (final p in ctrl.partitions)
      Padding(
        padding: const EdgeInsets.only(bottom: 14),
        child: Card(
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        p.name,
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    badge(
                      ctrl.snapshots[p.serverId]?.nodesOk == true &&
                              (ctrl.monitoring || ctrl.demo)
                          ? (p.availability == 'up'
                                ? '可用'
                                : p.availability == 'down'
                                ? '停用'
                                : p.availability)
                          : '缓存',
                      mint,
                    ),
                  ],
                ),
                SizedBox(height: 6),
                Text(p.serverName, style: TextStyle(color: blue, fontSize: 12)),
                SizedBox(height: 12),
                usageBar(
                  context,
                  '空闲节点',
                  '${p.idleNodes} / ${p.totalNodes}',
                  p.idleNodeRatio * 100,
                  mint,
                ),
                SizedBox(height: 16),
                usageBar(
                  context,
                  '空闲 CPU',
                  '${p.idleCpus} / ${p.totalCpus} 核',
                  p.totalCpus > 0 ? p.idleCpus / p.totalCpus * 100 : null,
                  blue,
                ),
                SizedBox(height: 15),
                Text(
                  '已分配 ${p.allocatedNodes} 节点 · 其他状态 ${p.otherNodes} 节点',
                  style: TextStyle(color: context.muted, fontSize: 12),
                ),
              ],
            ),
          ),
        ),
      ),
  ];

  List<Widget> _servers(MonitorController ctrl) => [
    if (ctrl.servers.isEmpty)
      emptyState(
        context,
        '尚未连接集群',
        Icons.add_to_queue,
        action: FilledButton.icon(
          onPressed: () => _editServer(ctrl),
          icon: Icon(Icons.add),
          label: Text('添加服务器'),
        ),
      ),
    for (final server in ctrl.servers)
      Padding(
        padding: const EdgeInsets.only(bottom: 14),
        child: _serverCard(server, ctrl),
      ),
  ];

  Widget _serverCard(ServerConfig server, MonitorController ctrl) {
    final snap = ctrl.snapshots[server.id];
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  snap?.isOnline == true
                      ? Icons.cloud_done_outlined
                      : Icons.cloud_off_outlined,
                  color: snap?.isOnline == true ? mint : amber,
                ),
                SizedBox(width: 12),
                Expanded(
                  child: Text(
                    server.name,
                    style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
                  ),
                ),
                if (!ctrl.demo)
                  PopupMenuButton<String>(
                    tooltip: '管理服务器',
                    onSelected: (action) async {
                      if (action == 'edit') {
                        _editServer(ctrl, server);
                        return;
                      }
                      final confirmed = await showDialog<bool>(
                        context: context,
                        builder: (c) => AlertDialog(
                          title: Text('移除服务器？'),
                          content: Text('移除 ${server.name} 及保存在本机的凭据。'),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.pop(c, false),
                              child: Text('取消'),
                            ),
                            FilledButton(
                              onPressed: () => Navigator.pop(c, true),
                              child: Text('移除'),
                            ),
                          ],
                        ),
                      );
                      if (confirmed == true) await ctrl.removeServer(server.id);
                    },
                    itemBuilder: (_) => [
                      PopupMenuItem(value: 'edit', child: Text('编辑连接')),
                      PopupMenuItem(value: 'delete', child: Text('移除服务器')),
                    ],
                  ),
              ],
            ),
            SizedBox(height: 12),
            SelectableText(
              '${server.username}@${server.host}:${server.port}',
              style: TextStyle(color: context.muted, fontSize: 12),
            ),
            SizedBox(height: 12),
            Row(
              children: [
                badge(
                  !server.enabled
                      ? '已停用'
                      : ctrl.demo
                      ? '已连接'
                      : !ctrl.monitoring
                      ? '监控暂停'
                      : snap == null
                      ? '等待连接'
                      : snap.isOnline
                      ? '已连接'
                      : '连接异常',
                  snap?.isOnline == true ? mint : amber,
                ),
                const Spacer(),
                if (!ctrl.demo)
                  Tooltip(
                    message: '启用监控',
                    child: Switch(
                      value: server.enabled,
                      onChanged: (v) => ctrl.setEnabled(server, v),
                    ),
                  ),
              ],
            ),
            if (snap?.error != null) ...[
              SizedBox(height: 14),
              Text(snap!.error!, style: TextStyle(fontSize: 12, color: amber)),
              if (snap.nextRetry != null)
                Text(
                  '重试时间 ${clockText(snap.nextRetry)}',
                  style: TextStyle(fontSize: 11, color: context.muted),
                ),
            ],
            Wrap(
              spacing: 8,
              children: [
                if (server.enabled &&
                    (ctrl.demo || server.fingerprint.isNotEmpty))
                  TextButton.icon(
                    onPressed: _openingFiles
                        ? null
                        : () => _openFiles(ctrl, server),
                    icon: const Icon(Icons.folder_open_outlined, size: 18),
                    label: const Text('文件与提交'),
                  ),
                if (server.enabled && !ctrl.demo)
                  TextButton.icon(
                    onPressed: ctrl.refreshing
                        ? null
                        : () {
                            ctrl.refresh(serverId: server.id);
                          },
                    icon: const Icon(Icons.refresh, size: 18),
                    label: const Text('重试此连接'),
                  ),
              ],
            ),
            if (snap != null)
              RefreshAge(
                timestamp: snap.queueUpdatedAt,
                style: TextStyle(fontSize: 12, color: context.muted),
              ),
            for (final w in snap?.warnings ?? <String>[])
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(w, style: TextStyle(color: amber, fontSize: 12)),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _openFiles(
    MonitorController ctrl,
    ServerConfig server, {
    String? directory,
    String? title,
  }) async {
    if (_openingFiles) return;
    setState(() => _openingFiles = true);
    try {
      await openServerFiles(
        context,
        server,
        demo: ctrl.demo,
        directory: directory,
        title: title,
        onSubmitted: () {
          ctrl.refresh();
        },
      );
    } finally {
      if (mounted) setState(() => _openingFiles = false);
    }
  }

  void _editServer(MonitorController ctrl, [ServerConfig? server]) =>
      Navigator.push<void>(
        context,
        MaterialPageRoute(
          builder: (_) => ServerEditor(controller: ctrl, server: server),
        ),
      );
}

Widget badge(String text, Color color) => Container(
  padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
  decoration: BoxDecoration(
    color: color.withValues(alpha: .10),
    borderRadius: BorderRadius.circular(7),
  ),
  child: Text(
    text,
    style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.w500),
  ),
);
Widget notice(BuildContext context, String text, IconData icon, Color color) =>
    Container(
      padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(
        color: color.withValues(alpha: .08),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(icon, color: color, size: 19),
          SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: TextStyle(color: color, fontSize: 12, height: 1.5),
            ),
          ),
        ],
      ),
    );
Widget emptyState(
  BuildContext context,
  String title,
  IconData icon, {
  Widget? action,
}) => Padding(
  padding: const EdgeInsets.symmetric(vertical: 36),
  child: Column(
    children: [
      Icon(
        icon,
        size: 48,
        color: Theme.of(context).colorScheme.primary.withValues(alpha: .7),
      ),
      SizedBox(height: 20),
      Text(
        title,
        textAlign: TextAlign.center,
        style: TextStyle(fontSize: 19, fontWeight: FontWeight.w600),
      ),
      if (action != null) ...[SizedBox(height: 24), action],
    ],
  ),
);
Widget usageBar(
  BuildContext context,
  String label,
  String text,
  double? percent,
  Color color,
) => Column(
  children: [
    Row(
      children: [
        Text(label, style: TextStyle(fontSize: 12, color: context.muted)),
        SizedBox(width: 10),
        Expanded(
          child: Text(
            text,
            textAlign: TextAlign.right,
            style: TextStyle(fontSize: 12),
          ),
        ),
        SizedBox(width: 8),
        Text(
          percentText(percent),
          style: TextStyle(
            color: color,
            fontSize: 12,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    ),
    SizedBox(height: 7),
    LinearProgressIndicator(
      value: percent == null ? 0 : percent.clamp(0, 100) / 100,
      minHeight: 5,
      borderRadius: BorderRadius.circular(4),
      color: color,
      backgroundColor: context.track,
    ),
  ],
);

class SettingsSheet extends StatefulWidget {
  const SettingsSheet({super.key});
  @override
  State<SettingsSheet> createState() => _SettingsSheetState();
}

class _SettingsSheetState extends State<SettingsSheet> {
  final _seconds = TextEditingController();
  String? _error;
  bool _loaded = false;
  @override
  void dispose() {
    _seconds.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ctrl = context.watch<MonitorController>();
    if (!_loaded) {
      _seconds.text = '${ctrl.refreshIntervalSeconds}';
      _loaded = true;
    }
    return Padding(
      padding: EdgeInsets.fromLTRB(
        24,
        24,
        24,
        MediaQuery.viewInsetsOf(context).bottom + 24,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '监控设置',
              style: TextStyle(fontSize: 23, fontWeight: FontWeight.w600),
            ),
            SizedBox(height: 22),
            Wrap(
              spacing: 8,
              children: [
                for (final skin in AppSkin.values)
                  ChoiceChip(
                    label: Text(skin.label),
                    selected: ctrl.skin == skin,
                    onSelected: (_) => ctrl.setSkin(skin),
                  ),
              ],
            ),
            SizedBox(height: 22),
            TextField(
              controller: _seconds,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(
                labelText: '刷新间隔',
                suffixText: '秒',
                hintText: '2–3600',
                errorText: _error,
              ),
              onChanged: (_) => setState(() => _error = null),
            ),
            SizedBox(height: 10),
            Wrap(
              spacing: 8,
              children: [
                for (final s in [3, 5, 10, 15, 30, 60])
                  ChoiceChip(
                    label: Text('${s}s'),
                    selected: _seconds.text.trim() == '$s',
                    onSelected: (_) => setState(() {
                      _seconds.text = '$s';
                      _error = null;
                    }),
                  ),
              ],
            ),
            SizedBox(height: 18),
            FilledButton(
              onPressed: () async {
                final n = int.tryParse(_seconds.text.trim());
                if (n == null || n < 2 || n > 3600) {
                  setState(() => _error = '请输入 2–3600 之间的整数');
                  return;
                }
                await ctrl.setInterval(n);
                if (context.mounted) Navigator.pop(context);
              },
              child: Text('保存刷新间隔'),
            ),
            SizedBox(height: 22),
            Divider(),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.widgets_outlined),
              title: Text('小米负一屏与桌面卡片'),
              trailing: Icon(Icons.chevron_right),
              onTap: () => Navigator.push<void>(
                context,
                MaterialPageRoute(builder: (_) => const WidgetSetupPage()),
              ),
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.notifications_outlined),
              title: Text('发送测试通知'),
              onTap: ctrl.demo ? null : ctrl.testNotification,
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.battery_saver_outlined),
              title: Text('后台电池设置'),
              onTap: ctrl.demo ? null : ctrl.openBatterySettings,
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text('示例数据'),
              value: ctrl.demo,
              onChanged: ctrl.nativeSupported ? (_) => ctrl.toggleDemo() : null,
            ),
            SizedBox(height: 12),
            ExpansionTile(
              tilePadding: EdgeInsets.zero,
              title: const Text('后台运行说明', style: TextStyle(fontSize: 13)),
              children: [
                Text(
                  'Android 15 及以上限制 dataSync 前台服务后台时长。系统或省电策略停止服务后，请打开应用重新启动。桌面小部件显示最后一次成功采集时间。',
                  style: TextStyle(
                    color: context.muted,
                    fontSize: 12,
                    height: 1.5,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
