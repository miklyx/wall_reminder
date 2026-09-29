import 'package:flutter_test/flutter_test.dart';
import 'package:wall_reminder_display/models/reminder_trigger.dart';

void main() {
  test('parses backend reminder.trigger payload', () {
    final trigger = ReminderTrigger.fromJson({
      'type': 'reminder.trigger',
      'delivery_id': 'delivery-1',
      'reminder_id': 'reminder-1',
      'message_text': 'Take pills at 14:00',
      'duration_seconds': 30,
    });

    expect(trigger.deliveryId, 'delivery-1');
    expect(trigger.reminderId, 'reminder-1');
    expect(trigger.messageText, 'Take pills at 14:00');
    expect(trigger.durationSeconds, 30);
  });

  test('rejects empty messages and invalid duration', () {
    expect(
      () => ReminderTrigger.fromJson({
        'type': 'reminder.trigger',
        'delivery_id': 'delivery-1',
        'reminder_id': 'reminder-1',
        'message_text': ' ',
        'duration_seconds': 30,
      }),
      throwsFormatException,
    );
    expect(
      () => ReminderTrigger.fromJson({
        'type': 'reminder.trigger',
        'delivery_id': 'delivery-1',
        'reminder_id': 'reminder-1',
        'message_text': 'Hello',
        'duration_seconds': 0,
      }),
      throwsFormatException,
    );
  });
}
