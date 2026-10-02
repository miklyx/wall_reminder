import 'package:flutter/material.dart';

import '../models/reminder_trigger.dart';

class ReminderQueuePreview extends StatelessWidget {
  const ReminderQueuePreview({required this.reminders, super.key});

  final List<ReminderTrigger> reminders;

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Padding(
            padding: EdgeInsets.only(bottom: 4),
            child: Text(
              'NEXT',
              style: TextStyle(
                color: Color(0xFF5FE1C0),
                fontSize: 11,
                fontWeight: FontWeight.w800,
                letterSpacing: 2,
              ),
            ),
          ),
          Expanded(
            child: ListView.separated(
              padding: EdgeInsets.zero,
              itemCount: reminders.length,
              separatorBuilder: (context, index) => const SizedBox(height: 2),
              itemBuilder: (context, index) => Text(
                reminders[index].messageText,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Color(0xFFB8C4D3),
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
        ],
      );
}
