import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../models/structure.dart';
import '../services/remote_files.dart';
import '../services/structure_parser.dart';
import 'app_theme.dart';
import 'structure_view.dart';
import '../services/remote_commands.dart';
import 'remote_command_panel.dart';
import '../services/vasp_progress_service.dart';
import 'outcar_progress_page.dart';
import '../services/gaussian_parser.dart';
import '../services/optimization_check_service.dart';
import 'gaussian_progress_page.dart';
import 'file_date.dart';
import 'remote_file_row.dart';

class RemoteFileBrowser extends StatefulWidget {
  const RemoteFileBrowser({
    super.key,
    required this.files,
    required this.directory,
    required this.title,
    this.commands,
    this.onSubmitted,
  });
  final RemoteFiles files;
  final String directory, title;
  final RemoteCommands? commands;
  final VoidCallback? onSubmitted;
  @override
  State<RemoteFileBrowser> createState() => _RemoteFileBrowserState();
}

class _RemoteFileBrowserState extends State<RemoteFileBrowser> {
  late String _path = widget.directory;
  RemoteDirectory? _directory;
  String? _error;
  bool _busy = true,
      _terminalOpen = false,
      _commandBusy = false,
      _opening = false;
  final _search = TextEditingController();
  FileSort _sort = FileSort.newest;
  List<RemoteEntry> _entries = [];
  int _loadRevision = 0;
  bool get _compactBrowser =>
      _terminalOpen && MediaQuery.viewInsetsOf(context).bottom > 0;
  void _filter() {
    final query = _search.text.toLowerCase();
    _entries = (_directory?.entries ?? const <RemoteEntry>[])
        .where((e) => e.name.toLowerCase().contains(query))
        .toList();
    _entries.sort((a, b) {
      if (a.directory != b.directory) return a.directory ? -1 : 1;
      if (_sort != FileSort.name) {
        if (a.modified == null && b.modified != null) return 1;
        if (a.modified != null && b.modified == null) return -1;
        final time = (a.modified?.microsecondsSinceEpoch ?? 0).compareTo(
          b.modified?.microsecondsSinceEpoch ?? 0,
        );
        if (time != 0) return _sort == FileSort.newest ? -time : time;
      }
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
  }

  @override
  void initState() {
    super.initState();
    _load(_path);
  }

  @override
  void dispose() {
    _loadRevision++;
    widget.files.close();
    widget.commands?.close();
    _search.dispose();
    super.dispose();
  }

  Future<void> _load(String path) async {
    if (_commandBusy && path != _path) return;
    final revision = ++_loadRevision;
    setState(() {
      _busy = true;
      _error = null;
      _directory = null;
      _entries = [];
      _path = path;
      _search.clear();
    });
    try {
      final directory = await widget.files.list(path);
      if (mounted && revision == _loadRevision) {
        setState(() {
          _directory = directory;
          _filter();
        });
      }
    } catch (e) {
      if (mounted && revision == _loadRevision) {
        setState(() => _error = fileError(e));
      }
    } finally {
      if (mounted && revision == _loadRevision) setState(() => _busy = false);
    }
  }

  Future<void> _open(RemoteEntry entry) async {
    if (_opening) return;
    setState(() => _opening = true);
    final path = remoteJoin(_path, entry.name);
    try {
      if (entry.directory ||
          (entry.link && await widget.files.isDirectory(path))) {
        await _load(path);
      } else if (mounted) {
        var gaussian = false;
        if (isGaussianLog(entry.name)) {
          final sample = await widget.files.sample(path, tail: true);
          gaussian = looksLikeGaussian(sample.text);
          if (!gaussian && sample.truncated) {
            gaussian = looksLikeGaussian(
              (await widget.files.sample(path)).text,
            );
          }
        }
        if (!mounted) return;
        await Navigator.push(
          context,
          MaterialPageRoute<void>(
            builder: (_) => isOutcar(entry.name)
                ? OutcarProgressPage(
                    files: widget.files,
                    path: path,
                    onOpenText: () => Navigator.push(
                      context,
                      MaterialPageRoute<void>(
                        builder: (_) =>
                            RemoteFilePage(files: widget.files, path: path),
                      ),
                    ),
                  )
                : gaussian
                ? GaussianProgressPage(
                    files: widget.files,
                    path: path,
                    onOpenText: () => Navigator.push<void>(
                      context,
                      MaterialPageRoute(
                        builder: (_) =>
                            RemoteFilePage(files: widget.files, path: path),
                      ),
                    ),
                  )
                : RemoteFilePage(files: widget.files, path: path),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(fileError(e))));
      }
    } finally {
      if (mounted) setState(() => _opening = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final entries = _entries;
    return PopScope(
      canPop: !_commandBusy,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop && _commandBusy) {
          setState(() => _terminalOpen = true);
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('请先停止当前命令，再返回')));
        }
      },
      child: Scaffold(
        appBar: AppBar(
          bottom: PreferredSize(
            preferredSize: const Size.fromHeight(3),
            child: _busy || _opening
                ? const LinearProgressIndicator(minHeight: 3)
                : const SizedBox(height: 3),
          ),
          title: Text(
            widget.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          actions: [
            if (widget.commands != null)
              IconButton(
                tooltip: '当前目录命令',
                onPressed: _busy && !_terminalOpen
                    ? null
                    : () => setState(() => _terminalOpen = !_terminalOpen),
                isSelected: _terminalOpen,
                icon: Badge(
                  isLabelVisible: _commandBusy,
                  child: const Icon(Icons.terminal),
                ),
              ),
            IconButton(
              tooltip: '任务目录',
              onPressed: _busy || _commandBusy
                  ? null
                  : () => _load(widget.directory),
              icon: const Icon(Icons.home_outlined),
            ),
            IconButton(
              tooltip: '刷新文件列表',
              onPressed: _busy ? null : () => _load(_path),
              icon: const Icon(Icons.refresh),
            ),
          ],
        ),
        body: SafeArea(
          child: LayoutBuilder(
            builder: (context, constraints) => Column(
              children: [
                Expanded(
                  child: RefreshIndicator(
                    onRefresh: () => _load(_path),
                    child: CustomScrollView(
                      physics: const AlwaysScrollableScrollPhysics(),
                      slivers: [
                        SliverToBoxAdapter(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 16),
                            child: Row(
                              children: [
                                IconButton(
                                  tooltip: '上级目录',
                                  onPressed:
                                      _busy || _commandBusy || _path == '/'
                                      ? null
                                      : () => _load(remoteParent(_path)),
                                  icon: const Icon(
                                    Icons.drive_folder_upload_outlined,
                                  ),
                                ),
                                Expanded(
                                  child: SingleChildScrollView(
                                    scrollDirection: Axis.horizontal,
                                    child: Row(
                                      children: [
                                        for (final crumb in _breadcrumbs())
                                          TextButton(
                                            onPressed: _busy || _commandBusy
                                                ? null
                                                : () => _load(crumb.$2),
                                            style: TextButton.styleFrom(
                                              padding:
                                                  const EdgeInsets.symmetric(
                                                    horizontal: 6,
                                                  ),
                                              minimumSize: const Size(32, 48),
                                            ),
                                            child: Text(
                                              crumb.$1,
                                              style: const TextStyle(
                                                fontSize: 12,
                                              ),
                                            ),
                                          ),
                                      ],
                                    ),
                                  ),
                                ),
                                IconButton(
                                  tooltip: '复制目录',
                                  onPressed: () => Clipboard.setData(
                                    ClipboardData(text: _path),
                                  ),
                                  icon: const Icon(
                                    Icons.copy_outlined,
                                    size: 18,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                        if (!_compactBrowser)
                          SliverToBoxAdapter(
                            child: Padding(
                              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                              child: TextField(
                                controller: _search,
                                onChanged: (_) => setState(_filter),
                                decoration: const InputDecoration(
                                  hintText: '搜索文件',
                                  prefixIcon: Icon(Icons.search),
                                  isDense: true,
                                ),
                              ),
                            ),
                          ),
                        SliverToBoxAdapter(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 16),
                            child: RemoteFileColumns(
                              sort: _sort,
                              onSort: (value) => setState(() {
                                _sort = value;
                                _filter();
                              }),
                            ),
                          ),
                        ),
                        if (_directory?.truncated == true)
                          const SliverToBoxAdapter(
                            child: Padding(
                              padding: EdgeInsets.all(8),
                              child: Text('目录较大，仅列出前 3000 项，可进入子目录继续查看'),
                            ),
                          ),
                        if (_busy || _error != null || entries.isEmpty)
                          SliverFillRemaining(
                            hasScrollBody: false,
                            child: _busy
                                ? const Center(
                                    child: CircularProgressIndicator(),
                                  )
                                : _error != null
                                ? _FileFailure(
                                    _error!,
                                    retry: () => _load(_path),
                                  )
                                : const Center(child: Text('没有匹配的文件')),
                          )
                        else
                          SliverPadding(
                            padding: const EdgeInsets.symmetric(horizontal: 16),
                            sliver: SliverList.builder(
                              itemCount: entries.length,
                              itemBuilder: (context, index) {
                                final e = entries[index];
                                return RemoteFileRow(
                                  entry: e,
                                  onTap: _commandBusy && (e.directory || e.link)
                                      ? null
                                      : () => _open(e),
                                );
                              },
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                if (widget.commands != null)
                  Offstage(
                    offstage: !_terminalOpen,
                    child: ConstrainedBox(
                      constraints: BoxConstraints(
                        maxHeight:
                            (constraints.maxHeight *
                                    (_compactBrowser ? .55 : .65))
                                .clamp(0, 360),
                      ),
                      child: RemoteCommandPanel(
                        directory: _path,
                        commands: widget.commands!,
                        visible: _terminalOpen,
                        onClose: () => setState(() => _terminalOpen = false),
                        onBusyChanged: (value) =>
                            setState(() => _commandBusy = value),
                        onFinished: () {
                          if (!_busy) _load(_path);
                        },
                        onSubmitted: widget.onSubmitted,
                        scripts: [
                          for (final entry
                              in _directory?.entries ?? <RemoteEntry>[])
                            if (!entry.directory &&
                                RegExp(
                                  r'\.(sh|slurm|sbatch|job)$',
                                  caseSensitive: false,
                                ).hasMatch(entry.name))
                              entry.name,
                        ].take(12).toList(),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  List<(String, String)> _breadcrumbs() {
    var path = '';
    return [
      ('/', '/'),
      for (final name in _path.split('/').where((s) => s.isNotEmpty))
        (name, path = '$path/$name'),
    ];
  }
}

class RemoteFilePage extends StatefulWidget {
  const RemoteFilePage({super.key, required this.files, required this.path});
  final RemoteFiles files;
  final String path;
  @override
  State<RemoteFilePage> createState() => _RemoteFilePageState();
}

class _RemoteFilePageState extends State<RemoteFilePage> {
  RemoteText? _content;
  AtomicStructure? _structure;
  String? _error, _structureError;
  bool _busy = true, _parsing = false, _tail = false;
  late bool _preview = StructureFormat.detect(remoteName(widget.path)) != null;
  final _query = TextEditingController();
  final _scroll = ScrollController();
  final _horizontal = ScrollController();
  List<String> _lines = [];
  List<int> _matches = [];
  int _match = 0, _revision = 0;
  int _longest = 0;
  Timer? _searchTimer;
  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _revision++;
    _searchTimer?.cancel();
    _query.dispose();
    _scroll.dispose();
    _horizontal.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final revision = ++_revision;
    setState(() {
      _busy = true;
      _parsing = false;
      _error = null;
      _structure = null;
      _structureError = null;
    });
    try {
      final content = await widget.files.read(widget.path, tail: _tail);
      if (!mounted || revision != _revision) return;
      setState(() {
        _content = content;
        _lines = content.text.split('\n');
        _longest = _lines
            .fold(0, (n, s) => s.length > n ? s.length : n)
            .clamp(0, 2000);
        _busy = false;
      });
      _find(_query.text, jump: false);
      if (StructureFormat.detect(remoteName(widget.path)) != null) {
        if (content.truncated) {
          setState(() => _structureError = '文件较大，只读取了部分内容；结构预览需要完整文件');
        } else {
          setState(() => _parsing = true);
          try {
            final structure = await compute(parseStructure, (
              remoteName(widget.path),
              content.text,
            ));
            if (mounted && revision == _revision) {
              setState(() => _structure = structure);
            }
          } catch (e) {
            if (mounted && revision == _revision) {
              setState(
                () => _structureError = e is FormatException
                    ? e.message
                    : '结构解析失败，可切换到原文查看',
              );
            }
          } finally {
            if (mounted && revision == _revision) {
              setState(() => _parsing = false);
            }
          }
        }
      }
    } catch (e) {
      if (mounted && revision == _revision) {
        setState(() {
          _error = fileError(e);
          _busy = false;
        });
      }
    }
  }

  void _find(String text, {bool jump = true}) {
    final q = text.toLowerCase();
    setState(() {
      _matches = q.isEmpty
          ? []
          : [
              for (var i = 0; i < _lines.length; i++)
                if (_lines[i].toLowerCase().contains(q)) i,
            ];
      _match = 0;
    });
    if (jump) _jump();
  }

  double _lineHeight(BuildContext context) =>
      MediaQuery.textScalerOf(context).scale(13) * 1.6;
  void _jump() {
    if (_matches.isEmpty || !_scroll.hasClients) return;
    _scroll.jumpTo(
      (_matches[_match] * _lineHeight(context)).clamp(
        0,
        _scroll.position.maxScrollExtent,
      ),
    );
  }

  Widget _text() {
    final query = _query.text.toLowerCase();
    final longest = _longest;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 8, 6),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _query,
                  onChanged: (value) {
                    _searchTimer?.cancel();
                    _searchTimer = Timer(const Duration(milliseconds: 150), () {
                      if (mounted) _find(value);
                    });
                  },
                  decoration: const InputDecoration(
                    hintText: '查找文本',
                    isDense: true,
                    prefixIcon: Icon(Icons.search),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Text(_matches.isEmpty ? '0' : '${_match + 1}/${_matches.length}'),
              IconButton(
                tooltip: '上一个匹配',
                icon: const Icon(Icons.keyboard_arrow_up),
                onPressed: _matches.isEmpty
                    ? null
                    : () {
                        setState(
                          () => _match =
                              (_match - 1 + _matches.length) % _matches.length,
                        );
                        _jump();
                      },
              ),
              IconButton(
                tooltip: '下一个匹配',
                onPressed: _matches.isEmpty
                    ? null
                    : () {
                        setState(() => _match = (_match + 1) % _matches.length);
                        _jump();
                      },
                icon: const Icon(Icons.keyboard_arrow_down),
              ),
            ],
          ),
        ),
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) => Scrollbar(
              controller: _horizontal,
              thumbVisibility: true,
              child: SingleChildScrollView(
                controller: _horizontal,
                scrollDirection: Axis.horizontal,
                child: SizedBox(
                  width:
                      (longest * MediaQuery.textScalerOf(context).scale(8) + 74)
                          .clamp(constraints.maxWidth, 20000),
                  child: Scrollbar(
                    controller: _scroll,
                    thumbVisibility: true,
                    child: ListView.builder(
                      key: ValueKey('text-${widget.path}-$_tail'),
                      controller: _scroll,
                      itemCount: _lines.length,
                      itemExtent: _lineHeight(context),
                      itemBuilder: (context, index) {
                        final line = _lines[index];
                        final found =
                            query.isNotEmpty &&
                            line.toLowerCase().contains(query);
                        return ColoredBox(
                          color: found
                              ? Theme.of(
                                  context,
                                ).colorScheme.primary.withValues(alpha: .16)
                              : Colors.transparent,
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              SizedBox(
                                width: 62,
                                child: Text(
                                  '${index + 1}',
                                  textAlign: TextAlign.right,
                                  style: TextStyle(
                                    fontSize: 12,
                                    height: 1.6,
                                    fontFamily: 'monospace',
                                    color: context.muted,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Text(
                                  line,
                                  maxLines: 1,
                                  softWrap: false,
                                  overflow: TextOverflow.clip,
                                  style: const TextStyle(
                                    fontSize: 13,
                                    height: 1.6,
                                    fontFamily: 'monospace',
                                  ),
                                ),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final hasStructure =
        StructureFormat.detect(remoteName(widget.path)) != null;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          remoteName(widget.path),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          IconButton(
            tooltip: '复制已读取文本',
            onPressed: _content == null
                ? null
                : () => Clipboard.setData(ClipboardData(text: _content!.text)),
            icon: const Icon(Icons.copy_outlined, size: 20),
          ),
          IconButton(
            tooltip: '刷新文件',
            onPressed: _busy ? null : _load,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(
                children: [
                  if (hasStructure) ...[
                    ChoiceChip(
                      label: const Text('结构'),
                      selected: _preview,
                      onSelected: (_) => setState(() => _preview = true),
                    ),
                    const SizedBox(width: 8),
                    ChoiceChip(
                      label: const Text('原文'),
                      selected: !_preview,
                      onSelected: (_) => setState(() => _preview = false),
                    ),
                  ],
                  const Spacer(),
                  if (_content != null)
                    Text(
                      fileSize(_content!.size),
                      style: TextStyle(fontSize: 11, color: context.muted),
                    ),
                  if (!_preview)
                    PopupMenuButton<bool>(
                      tooltip: '读取位置',
                      initialValue: _tail,
                      onSelected: (tail) {
                        _tail = tail;
                        _load();
                      },
                      itemBuilder: (_) => [
                        CheckedPopupMenuItem(
                          value: false,
                          checked: !_tail,
                          child: const Text('文件开头'),
                        ),
                        CheckedPopupMenuItem(
                          value: true,
                          checked: _tail,
                          child: const Text('文件末尾'),
                        ),
                      ],
                    ),
                ],
              ),
            ),
            if (_content?.truncated == true)
              Padding(
                padding: const EdgeInsets.all(8),
                child: Text(
                  '仅显示${_tail ? '末尾' : '开头'} 2 MB',
                  style: TextStyle(fontSize: 11, color: context.muted),
                ),
              ),
            Expanded(
              child: _busy
                  ? const Center(child: CircularProgressIndicator())
                  : _error != null
                  ? _FileFailure(_error!, retry: _load)
                  : _preview
                  ? _parsing
                        ? const Center(child: CircularProgressIndicator())
                        : _structure != null
                        ? StructureView(
                            key: ValueKey(_structure),
                            structure: _structure!,
                          )
                        : _FileFailure(
                            _structureError ?? '没有可预览的结构',
                            retry: () => setState(() => _preview = false),
                            label: '查看原文',
                          )
                  : _text(),
            ),
          ],
        ),
      ),
    );
  }
}

class _FileFailure extends StatelessWidget {
  const _FileFailure(this.message, {required this.retry, this.label = '重试'});
  final String message, label;
  final VoidCallback retry;
  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(message, textAlign: TextAlign.center),
          const SizedBox(height: 12),
          TextButton(onPressed: retry, child: Text(label)),
        ],
      ),
    ),
  );
}
