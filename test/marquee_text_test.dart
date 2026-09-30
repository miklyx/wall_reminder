import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wall_reminder_display/widgets/marquee_text.dart';

Widget _host({required String text, required bool isRunning}) => MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 160,
            height: 80,
            child: MarqueeText(
              key: const ValueKey('marquee'),
              text: text,
              isRunning: isRunning,
              style: const TextStyle(fontSize: 20),
            ),
          ),
        ),
      ),
    );

void main() {
  testWidgets('can switch from a short stopped message to a long running one',
      (tester) async {
    await tester.pumpWidget(_host(text: 'OK', isRunning: true));
    await tester.pumpWidget(_host(text: 'OK', isRunning: false));

    await tester.pumpWidget(
      _host(
        text: 'A long reminder message that must scroll across the display',
        isRunning: true,
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));

    expect(tester.takeException(), isNull);
    expect(find.textContaining('A long reminder'), findsNWidgets(2));
  });
}
