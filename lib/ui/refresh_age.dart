import 'dart:async';
import 'package:flutter/material.dart';

String refreshAge(DateTime? timestamp, DateTime now) {
  if (timestamp == null) return '尚未刷新';
  final seconds = now.difference(timestamp).inSeconds.clamp(0, 1 << 30);
  if (seconds < 5) return '刚刚刷新';
  if (seconds < 60) return '$seconds 秒前刷新';
  if (seconds < 3600) return '${seconds ~/ 60} 分钟前刷新';
  if (seconds < 86400) return '${seconds ~/ 3600} 小时前刷新';
  return '${seconds ~/ 86400} 天前刷新';
}

class RefreshAge extends StatefulWidget {
  const RefreshAge({super.key, required this.timestamp, this.style});
  final DateTime? timestamp;
  final TextStyle? style;
  @override
  State<RefreshAge> createState() => _RefreshAgeState();
}

class _RefreshAgeState extends State<RefreshAge> {
  Timer? _timer;
  bool _enabled = true;
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _enabled = TickerMode.valuesOf(context).enabled;
    _schedule();
  }

  @override
  void didUpdateWidget(RefreshAge oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.timestamp != widget.timestamp) _schedule();
  }

  void _schedule() {
    _timer?.cancel();
    if (!_enabled || widget.timestamp == null) return;
    final age = DateTime.now()
        .difference(widget.timestamp!)
        .inSeconds
        .clamp(0, 1 << 30);
    final seconds = age < 5
        ? 5 - age
        : age < 60
        ? 1
        : age < 3600
        ? 60 - age % 60
        : age < 86400
        ? 3600 - age % 3600
        : 86400 - age % 86400;
    _timer = Timer(Duration(seconds: seconds), () {
      if (!mounted) return;
      setState(() {});
      _schedule();
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Text(
    refreshAge(widget.timestamp, DateTime.now()),
    style: widget.style,
    maxLines: 1,
    overflow: TextOverflow.ellipsis,
  );
}
