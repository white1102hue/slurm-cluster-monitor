import 'package:flutter/material.dart';
import '../models/slurm_models.dart';
import 'app_theme.dart';

class ResourceRing extends StatelessWidget {
  const ResourceRing({
    super.key,
    required this.label,
    required this.detail,
    required this.percent,
    required this.color,
  });

  final String label, detail;
  final double? percent;
  final Color color;

  @override
  Widget build(BuildContext context) => Semantics(
    label: '$label，${percentText(percent)}，$detail',
    excludeSemantics: true,
    child: Row(
      children: [
        SizedBox.square(
          dimension: 24,
          child: CircularProgressIndicator(
            value: (percent ?? 0).clamp(0, 100) / 100,
            strokeWidth: 3,
            strokeCap: StrokeCap.round,
            color: color,
            backgroundColor: context.track,
          ),
        ),
        SizedBox(width: 9),
        Expanded(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Wrap(
                spacing: 5,
                children: [
                  Text(
                    label,
                    style: TextStyle(fontSize: 11, color: context.muted),
                  ),
                  Text(
                    percentText(percent),
                    style: TextStyle(
                      fontSize: 11,
                      color: percent == null ? context.muted : color,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
              SizedBox(height: 4),
              Text(
                detail,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 11, color: context.ink),
              ),
            ],
          ),
        ),
      ],
    ),
  );
}
