import 'package:flutter/material.dart';

import 'config/app_config.dart';
import 'screens/reminder_display_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const WallReminderApp());
}

class WallReminderApp extends StatelessWidget {
  const WallReminderApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Wall Reminder',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          brightness: Brightness.dark,
          colorScheme: ColorScheme.fromSeed(
            seedColor: const Color(0xFF5FE1C0),
            brightness: Brightness.dark,
          ),
          scaffoldBackgroundColor: const Color(0xFF080D14),
          useMaterial3: true,
        ),
        home: const ReminderDisplayScreen(config: AppConfig.fromBuild),
      );
}
