import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slurm_cluster_monitor/ui/resource_ring.dart';

void main() {
  testWidgets('rings show quota and distinguish unknown usage from zero', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MediaQuery(
            data: const MediaQueryData(textScaler: TextScaler.linear(1.3)),
            child: const Center(
              child: SizedBox(
                width: 260,
                child: Row(
                  children: [
                    Expanded(
                      child: ResourceRing(
                        label: 'CPU',
                        detail: '0.0 / 8 核',
                        percent: 0,
                        color: Colors.blue,
                      ),
                    ),
                    SizedBox(width: 16),
                    Expanded(
                      child: ResourceRing(
                        label: '内存',
                        detail: '— / 32 GB',
                        percent: null,
                        color: Colors.teal,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
    expect(find.text('0.0%'), findsOneWidget);
    expect(find.text('暂无统计'), findsOneWidget);
    expect(find.text('0.0 / 8 核'), findsOneWidget);
    expect(find.bySemanticsLabel('内存，暂无统计，— / 32 GB'), findsOneWidget);
    semantics.dispose();
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'usage over quota retains its actual percentage beside the ring',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: ResourceRing(
              label: 'CPU',
              detail: '3.0 / 2 核',
              percent: 150,
              color: Colors.blue,
            ),
          ),
        ),
      );
      expect(find.text('150.0%'), findsOneWidget);
      expect(find.text('3.0 / 2 核'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
