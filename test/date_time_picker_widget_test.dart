import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_ledger/features/date_time_picker.dart';

void main() {
  testWidgets(
    'time picker shows the complete time on a small large-text screen',
    (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(1.6)),
            child: child!,
          ),
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => showSecondDateTimePicker(
                  context,
                  initial: DateTime(2026, 10, 19, 15, 8, 39),
                ),
                child: const Text('打开'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开'));
      await tester.pumpAndSettle();

      expect(find.text('2026-10-19 15:08:39'), findsOneWidget);
      expect(find.text('15'), findsOneWidget);
      expect(find.text('08'), findsOneWidget);
      expect(find.text('39'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
