import 'package:flutter/material.dart';
import '../services/widget_setup_service.dart';
import 'app_theme.dart';

class WidgetSetupPage extends StatefulWidget {
  const WidgetSetupPage({super.key, this.service = const WidgetSetupService()});
  final WidgetSetupService service;
  @override
  State<WidgetSetupPage> createState() => _WidgetSetupPageState();
}

class _WidgetSetupPageState extends State<WidgetSetupPage>
    with WidgetsBindingObserver {
  WidgetCapabilities? _capabilities;
  bool _loading = true, _adding = false;
  String? _error;
  int _revision = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _reload();
  }

  Future<void> _reload() async {
    final revision = ++_revision;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final capabilities = await widget.service.capabilities();
      if (mounted && revision == _revision) {
        setState(() => _capabilities = capabilities);
      }
    } catch (_) {
      if (mounted && revision == _revision) {
        setState(() {
          _capabilities = null;
          _error = '暂时无法检测系统卡片入口，请重试';
        });
      }
    } finally {
      if (mounted && revision == _revision) setState(() => _loading = false);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _reload();
  }

  Future<void> _add({required bool xiaomi}) async {
    if (_adding) return;
    setState(() => _adding = true);
    var message = '';
    try {
      final accepted = xiaomi
          ? await widget.service.openXiaomi()
          : await widget.service.addDesktop();
      message = accepted
          ? xiaomi
                ? '已请求打开小米卡片添加页，请在系统页面确认'
                : '请在系统对话框中确认添加桌面小部件'
          : xiaomi
          ? '系统未打开卡片添加页，可从负一屏“+”查找已收录卡片'
          : '当前桌面不支持快捷添加，请长按桌面，在小部件列表中选择 Slurm';
    } catch (_) {
      message = '未能打开系统添加入口，请从系统小部件列表添加';
    } finally {
      if (mounted) {
        setState(() => _adding = false);
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(message)));
      }
    }
  }

  @override
  void dispose() {
    _revision++;
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final capabilities = _capabilities;
    return Scaffold(
      appBar: AppBar(
        title: const Text('小米负一屏'),
        actions: [
          IconButton(
            tooltip: '重新检测',
            onPressed: _loading ? null : _reload,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Text('集群概览 · 4×2', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 16),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (_loading)
                    const LinearProgressIndicator()
                  else
                    Text(
                      _error ??
                          (capabilities?.widgetSupported == true
                              ? '支持小米卡片'
                              : '当前系统不支持小米卡片'),
                    ),
                  if ((capabilities?.installedCount ?? 0) > 0) ...[
                    const SizedBox(height: 8),
                    Text('已添加概览卡片 ${capabilities!.installedCount} 张'),
                  ],
                  const SizedBox(height: 16),
                  FilledButton.icon(
                    onPressed:
                        !_loading &&
                            !_adding &&
                            capabilities?.canOpenXiaomi == true
                        ? () => _add(xiaomi: true)
                        : null,
                    icon: const Icon(Icons.widgets_outlined),
                    label: const Text('小米卡片'),
                  ),
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    onPressed: _adding ? null : () => _add(xiaomi: false),
                    icon: const Icon(Icons.add_to_home_screen),
                    label: const Text('桌面小部件'),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 20),
          Text(
            '尚未完成平台上架审核；负一屏搜索不到时，请使用桌面小部件。',
            style: TextStyle(color: context.muted, height: 1.5),
          ),
          const SizedBox(height: 8),
          const ExpansionTile(
            tilePadding: EdgeInsets.zero,
            title: Text('添加到负一屏'),
            children: [
              Padding(
                padding: EdgeInsets.only(bottom: 16),
                child: Text('负一屏 → 右上角“+” → “Slurm 集群监控 · 集群概览” → 添加。'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
