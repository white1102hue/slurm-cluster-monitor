import 'package:flutter/material.dart';
import '../services/optimization_analysis.dart';

class OptimizationStatus extends StatelessWidget {
  const OptimizationStatus({super.key, required this.assessment});
  final OptimizationAssessment assessment;
  @override
  Widget build(BuildContext context) {
    final warning = assessment.state == OptimizationState.oscillating;
    final color = warning
        ? Theme.of(context).colorScheme.tertiary
        : Theme.of(context).colorScheme.primary;
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 8),
      decoration: BoxDecoration(
        color: color.withValues(alpha: .09),
        borderRadius: BorderRadius.circular(10),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => showDialog<void>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text(assessment.title),
            content: Text(assessment.detail),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('关闭'),
              ),
            ],
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Row(
            children: [
              Icon(
                warning ? Icons.waves : Icons.insights_outlined,
                size: 18,
                color: color,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  assessment.title,
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    color: color,
                    fontSize: 13,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Tooltip(
                message: '查看判断依据',
                child: Icon(Icons.info_outline, size: 16, color: color),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
