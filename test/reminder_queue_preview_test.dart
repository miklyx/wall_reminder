import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wall_reminder_display/models/reminder_trigger.dart';
import 'package:wall_reminder_display/widgets/reminder_queue_preview.dart';

void main() {
  testWidgets('shows queued reminder messages below the NEXT label',
      (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SizedBox(
            height: 120,
            child: ReminderQueuePreview(
              reminders: [
                ReminderTrigger(
                  deliveryId: 'delivery-2',
                  reminderId: 'reminder-2',
                  messageText: 'Water the plants',
                  durationSeconds: 30,
                ),
                ReminderTrigger(
                  deliveryId: 'delivery-3',
                  reminderId: 'reminder-3',
                  messageText: 'Take evening medicine',
                  durationSeconds: 30,
                ),
              ],
            ),
          ),
        ),
      ),
    );

    expect(find.text('NEXT'), findsOneWidget);
    expect(find.text('Water the plants'), findsOneWidget);
    expect(find.text('Take evening medicine'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
