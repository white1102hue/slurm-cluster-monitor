import 'package:flutter/material.dart';
import '../models/structure.dart';
import '../services/remote_files.dart';
import '../services/vasp_progress_service.dart';
import 'app_theme.dart';
import 'file_date.dart';

enum FileSort { name, newest, oldest }

double fileDateColumnWidth(BuildContext context, double width) =>
    (width >= 650 ? 196 : 112) *
    MediaQuery.textScalerOf(context).scale(1).clamp(1.0, 1.6);

class RemoteFileRow extends StatelessWidget {
  const RemoteFileRow({super.key, required this.entry, this.onTap});
  final RemoteEntry entry;
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) {
    final structure = StructureFormat.detect(entry.name) != null;
    final log = isOutcar(entry.name);
    final color = Theme.of(context).colorScheme.primary;
    final caption = entry.directory
        ? '文件夹'
        : '${fileSize(entry.size)}${structure
              ? ' · 结构'
              : log
              ? ' · 优化日志'
              : ''}';
    return LayoutBuilder(
      builder: (context, constraints) {
        final date = fileDate(entry.modified);
        return Semantics(
          button: true,
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(10),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 10),
              child: Row(
                children: [
                  Container(
                    width: 32,
                    height: 36,
                    decoration: BoxDecoration(
                      color: color.withValues(alpha: .07),
                      borderRadius: BorderRadius.circular(9),
                    ),
                    child: Icon(
                      entry.directory
                          ? Icons.folder_outlined
                          : structure
                          ? Icons.view_in_ar_outlined
                          : log
                          ? Icons.show_chart
                          : Icons.insert_drive_file_outlined,
                      size: 19,
                      color: entry.directory || structure || log
                          ? color
                          : context.muted,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          entry.name,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          caption,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 10, color: context.muted),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 10),
                  SizedBox(
                    width: fileDateColumnWidth(context, constraints.maxWidth),
                    child: Tooltip(
                      message: entry.modified == null
                          ? '服务器未提供最近修改时间'
                          : fileDate(entry.modified, seconds: true),
                      child: Text(
                        constraints.maxWidth >= 650
                            ? date
                            : date.replaceFirst(' ', '\n'),
                        textAlign: TextAlign.right,
                        style: TextStyle(
                          fontSize: 10,
                          height: 1.5,
                          color: context.muted,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class RemoteFileColumns extends StatelessWidget {
  const RemoteFileColumns({
    super.key,
    required this.sort,
    required this.onSort,
  });
  final FileSort sort;
  final ValueChanged<FileSort> onSort;
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      Widget button(String title, VoidCallback tap, {IconData? icon}) =>
          InkWell(
            onTap: tap,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 10),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: context.muted,
                    ),
                  ),
                  if (icon != null) ...[
                    const SizedBox(width: 3),
                    Icon(icon, size: 14),
                  ],
                ],
              ),
            ),
          );
      return Row(
        children: [
          Expanded(
            child: button(
              '名称',
              () => onSort(FileSort.name),
              icon: sort == FileSort.name ? Icons.arrow_upward : null,
            ),
          ),
          SizedBox(
            width: fileDateColumnWidth(context, constraints.maxWidth),
            child: Align(
              alignment: Alignment.centerRight,
              child: button(
                '最近修改',
                () => onSort(
                  sort == FileSort.newest ? FileSort.oldest : FileSort.newest,
                ),
                icon: sort == FileSort.newest
                    ? Icons.arrow_downward
                    : sort == FileSort.oldest
                    ? Icons.arrow_upward
                    : Icons.unfold_more,
              ),
            ),
          ),
        ],
      );
    },
  );
}
