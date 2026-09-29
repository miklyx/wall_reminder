enum ReminderStatus {
  pending,
  displayed,
  dismissed;

  static ReminderStatus fromJson(String value) =>
      ReminderStatus.values.firstWhere(
        (status) => status.name == value,
        orElse: () => throw FormatException('Unknown reminder status: $value'),
      );
}

sealed class ScheduledTimeDto {
  const ScheduledTimeDto();

  factory ScheduledTimeDto.fromJson(Map<String, dynamic> json) {
    switch (json['kind']) {
      case 'timestamp':
        final value = json['at'] as String;
        if (!RegExp(r'(Z|[+-]\d{2}:\d{2})$', caseSensitive: false)
            .hasMatch(value)) {
          throw const FormatException('Timestamp must include a UTC offset');
        }
        return TimestampScheduleDto(DateTime.parse(value).toUtc());
      case 'cron':
        return CronScheduleDto(
          expression: json['expression'] as String,
          timeZone: json['time_zone'] as String,
        );
      default:
        throw FormatException(
          'Unknown scheduled_time kind: ${json['kind']}',
        );
    }
  }

  Map<String, dynamic> toJson();
}

final class TimestampScheduleDto extends ScheduledTimeDto {
  const TimestampScheduleDto(this.at);

  final DateTime at;

  @override
  Map<String, dynamic> toJson() => {
        'kind': 'timestamp',
        'at': at.toUtc().toIso8601String(),
      };
}

final class CronScheduleDto extends ScheduledTimeDto {
  const CronScheduleDto({
    required this.expression,
    required this.timeZone,
  });

  final String expression;
  final String timeZone;

  @override
  Map<String, dynamic> toJson() => {
        'kind': 'cron',
        'expression': expression,
        'time_zone': timeZone,
      };
}

class ReminderDto {
  const ReminderDto({
    required this.id,
    required this.messageText,
    required this.scheduledTime,
    required this.isActive,
    required this.durationSeconds,
    required this.status,
  });

  final String id;
  final String messageText;
  final ScheduledTimeDto scheduledTime;
  final bool isActive;
  final int durationSeconds;
  final ReminderStatus status;

  factory ReminderDto.fromJson(Map<String, dynamic> json) {
    final duration = json['duration_seconds'] as int;
    if (duration <= 0) {
      throw const FormatException('duration_seconds must be positive');
    }

    return ReminderDto(
      id: json['id'] as String,
      messageText: json['message_text'] as String,
      scheduledTime: ScheduledTimeDto.fromJson(
        json['scheduled_time'] as Map<String, dynamic>,
      ),
      isActive: json['is_active'] as bool,
      durationSeconds: duration,
      status: ReminderStatus.fromJson(json['status'] as String),
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'message_text': messageText,
        'scheduled_time': scheduledTime.toJson(),
        'is_active': isActive,
        'duration_seconds': durationSeconds,
        'status': status.name,
      };
}
