class ReminderTrigger {
  const ReminderTrigger({
    required this.deliveryId,
    required this.reminderId,
    required this.messageText,
    required this.durationSeconds,
  });

  final String deliveryId;
  final String reminderId;
  final String messageText;
  final int durationSeconds;

  factory ReminderTrigger.fromJson(Map<String, dynamic> json) {
    if (json['type'] != 'reminder.trigger') {
      throw const FormatException('Unsupported WebSocket event type');
    }

    final message = json['message_text'];
    final rawDuration = json['duration_seconds'];
    final duration = rawDuration is int
      ? rawDuration
      : rawDuration is String
        ? int.tryParse(rawDuration)
        : null;
    if (message is! String || message.trim().isEmpty) {
      throw const FormatException('Trigger message_text must not be empty');
    }
    if (duration == null || duration < 1) {
      throw const FormatException('Trigger duration_seconds must be positive');
    }

    return ReminderTrigger(
      deliveryId: json['delivery_id'] as String,
      reminderId: json['reminder_id'] as String,
      messageText: message,
      durationSeconds: duration,
    );
  }
}
