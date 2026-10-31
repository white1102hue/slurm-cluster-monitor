import 'package:flutter/material.dart';
import '../models/slurm_models.dart';
import '../services/remote_commands.dart';
import '../services/remote_files.dart';
import 'remote_file_browser.dart';

/// Each browser owns its services; it never borrows a running scanner's channel.
Future<void> openServerFiles(
  BuildContext context,
  ServerConfig server, {
  required bool demo,
  String? directory,
  String? title,
  VoidCallback? onSubmitted,
}) async {
  final files = demo ? DemoRemoteFiles() : SshRemoteFiles(server);
  final commands = demo ? DemoRemoteCommands() : SshRemoteCommands(server);
  try {
    if (directory == null) {
      try {
        directory = await files.homeDirectory();
      } catch (_) {
        if (!context.mounted) return;
        final input = TextEditingController();
        String? error;
        directory = await showDialog<String>(
          context: context,
          builder: (c) => StatefulBuilder(
            builder: (c, update) => AlertDialog(
              title: const Text('输入服务器目录'),
              content: TextField(
                controller: input,
                autofocus: true,
                decoration: InputDecoration(
                  labelText: '绝对路径',
                  helperText: '主目录暂不可读，可输入已知的可访问路径',
                  errorText: error,
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(c),
                  child: const Text('取消'),
                ),
                FilledButton(
                  onPressed: () {
                    final path = input.text.trim();
                    if (!path.startsWith('/') || path.contains('\x00')) {
                      update(() => error = '请输入以 / 开始的路径');
                      return;
                    }
                    Navigator.pop(c, path);
                  },
                  child: const Text('打开'),
                ),
              ],
            ),
          ),
        );
        input.dispose();
      }
    }
    if (!context.mounted || directory == null) return;
    await Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => RemoteFileBrowser(
          title: title ?? server.name,
          directory: directory!,
          files: files,
          commands: commands,
          onSubmitted: onSubmitted,
        ),
      ),
    );
  } finally {
    files.close();
    commands.close();
  }
}
