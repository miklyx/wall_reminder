import 'dart:async';
import 'dart:collection';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../config/app_config.dart';
import '../models/reminder_trigger.dart';
import '../services/reminder_api.dart';
import '../services/reminder_connection.dart';
import '../services/fcm_push_service.dart';
import '../widgets/marquee_text.dart';

class ReminderDisplayScreen extends StatefulWidget {
  const ReminderDisplayScreen({super.key, required this.config});

  final AppConfig config;

  @override
  State<ReminderDisplayScreen> createState() => _ReminderDisplayScreenState();
}

class _ReminderDisplayScreenState extends State<ReminderDisplayScreen>
    with WidgetsBindingObserver {
  late final ReminderConnection _connection;
  late final ReminderApi _api;
  late final FcmPushService _fcmPushService;
  StreamSubscription<ReminderTrigger>? _triggerSubscription;
  StreamSubscription<ConnectionStatus>? _statusSubscription;

  final Queue<ReminderTrigger> _queue = Queue<ReminderTrigger>();
  final LinkedHashSet<String> _receivedDeliveryIds = LinkedHashSet<String>();

  ReminderTrigger? _current;
  ConnectionStatus _connectionStatus = ConnectionStatus.disconnected;
  String? _feedback;
  bool _isDismissing = false;
  bool _marqueeStopped = false;
  bool _appIsResumed = true;
  bool _wakeLockEnabled = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky));

    _connection = ReminderConnection(widget.config);
    _api = ReminderApi(widget.config);
    _fcmPushService = FcmPushService(api: _api, onTrigger: _onTrigger);
    unawaited(_initializeFcm());
    _connectionStatus = _connection.status;
    _triggerSubscription = _connection.triggers.listen(
      _onTrigger,
      onError: (Object _) {
        if (mounted) setState(() => _feedback = 'Invalid reminder event received');
      },
    );
    _statusSubscription = _connection.statuses.listen((status) {
      if (mounted) setState(() => _connectionStatus = status);
    });
    _connection.connect();
  }

  Future<void> _initializeFcm() async {
    try {
      await _fcmPushService.initialize();
    } catch (error) {
      debugPrint('FCM initialization failed: $error');
      if (mounted) {
        setState(() => _feedback = 'Push notifications are unavailable');
      }
    }
  }

  void _onTrigger(ReminderTrigger trigger) {
    if (!_receivedDeliveryIds.add(trigger.deliveryId)) {
      if (_current?.deliveryId == trigger.deliveryId) {
        _connection.acknowledgeDisplayed(trigger.deliveryId);
      }
      return;
    }
    while (_receivedDeliveryIds.length > 1000) {
      _receivedDeliveryIds.remove(_receivedDeliveryIds.first);
    }

    setState(() {
      _feedback = null;
      if (_current == null) {
        _current = trigger;
        _marqueeStopped = false;
      } else {
        _queue.addLast(trigger);
      }
    });

    if (_current?.deliveryId == trigger.deliveryId) {
      _connection.acknowledgeDisplayed(trigger.deliveryId);
      unawaited(_setWakeLock(_appIsResumed));
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _appIsResumed = state == AppLifecycleState.resumed;
    if (_appIsResumed) {
      _connection.connect();
      if (_current != null && !_isDismissing) {
        unawaited(_setWakeLock(true));
      }
    } else {
      unawaited(_setWakeLock(false));
    }
  }

  Future<void> _setWakeLock(bool enabled) async {
    if (_wakeLockEnabled == enabled) return;
    _wakeLockEnabled = enabled;
    try {
      if (enabled) {
        await WakelockPlus.enable();
      } else {
        await WakelockPlus.disable();
      }
    } catch (error) {
      debugPrint('Unable to update screen wake lock: $error');
      _wakeLockEnabled = false;
      if (mounted) {
        setState(() => _feedback = 'Could not change screen wake state');
      }
    }
  }

  Future<void> _dismissCurrent() async {
    final reminder = _current;
    if (reminder == null || _isDismissing) return;

    setState(() {
      _isDismissing = true;
      _marqueeStopped = true;
      _feedback = null;
    });
    await _setWakeLock(false);

    try {
      await _api.dismiss(reminder.reminderId);
      if (!mounted) return;
      setState(() {
        _current = _queue.isEmpty ? null : _queue.removeFirst();
        _isDismissing = false;
        _marqueeStopped = false;
      });
      if (_current != null && _appIsResumed) {
        _connection.acknowledgeDisplayed(_current!.deliveryId);
        unawaited(_setWakeLock(true));
      }
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _isDismissing = false;
        _feedback = 'Dismiss was not synced. Tap to retry.';
      });
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_triggerSubscription?.cancel());
    unawaited(_statusSubscription?.cancel());
    unawaited(_fcmPushService.dispose());
    unawaited(_connection.dispose());
    _api.close();
    unawaited(WakelockPlus.disable());
    unawaited(SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final reminder = _current;
    final screen = MediaQuery.sizeOf(context);
    final messageSize =
      (screen.shortestSide * 0.105).clamp(42.0, 112.0).toDouble();

    return Scaffold(
      backgroundColor: const Color(0xFF080D14),
      body: SafeArea(
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: (screen.width * 0.06).clamp(24.0, 88.0).toDouble(),
            vertical: 20,
          ),
          child: Column(
            children: [
              _ConnectionIndicator(status: _connectionStatus),
              const Spacer(flex: 2),
              if (reminder == null) ...[
                const Icon(Icons.notifications_none_rounded,
                    size: 72, color: Color(0xFF526174)),
                const SizedBox(height: 20),
                const Text(
                  'READY FOR REMINDERS',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Color(0xFF8998AA),
                    fontSize: 22,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 3,
                  ),
                ),
              ] else ...[
                const Text(
                  'REMINDER',
                  style: TextStyle(
                    color: Color(0xFF5FE1C0),
                    fontSize: 18,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 5,
                  ),
                ),
                const SizedBox(height: 30),
                SizedBox(
                  height: screen.height * 0.34,
                  width: double.infinity,
                  child: Center(
                    child: MarqueeText(
                      text: reminder.messageText,
                      isRunning: _appIsResumed && !_marqueeStopped && !_isDismissing,
                      style: TextStyle(
                        color: const Color(0xFFF5F8FC),
                        fontSize: messageSize,
                        height: 1.08,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 0.3,
                      ),
                    ),
                  ),
                ),
                if (_queue.isNotEmpty) ...[
                  const SizedBox(height: 14),
                  Text(
                    '${_queue.length} MORE REMINDER${_queue.length == 1 ? '' : 'S'}',
                    style: const TextStyle(
                      color: Color(0xFF8998AA),
                      fontSize: 14,
                      letterSpacing: 2,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ],
              if (_feedback != null) ...[
                const SizedBox(height: 16),
                Text(
                  _feedback!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Color(0xFFFFB4AB), fontSize: 15),
                ),
              ],
              const Spacer(flex: 2),
              if (reminder != null)
                SizedBox(
                  width: double.infinity,
                  height: 76,
                  child: FilledButton.icon(
                    onPressed: _isDismissing ? null : _dismissCurrent,
                    icon: Icon(
                      _feedback == null ? Icons.check_circle_outline : Icons.sync,
                      size: 28,
                    ),
                    label: Text(
                      _isDismissing
                          ? 'SAVING…'
                          : _feedback == null
                              ? 'DISMISS / DONE'
                              : 'RETRY DISMISS / DONE',
                      style: const TextStyle(
                        fontSize: 19,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 1.2,
                      ),
                    ),
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFF5FE1C0),
                      foregroundColor: const Color(0xFF071710),
                      disabledBackgroundColor: const Color(0xFF315C51),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(22),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ConnectionIndicator extends StatelessWidget {
  const _ConnectionIndicator({required this.status});

  final ConnectionStatus status;

  @override
  Widget build(BuildContext context) {
    final connected = status == ConnectionStatus.connected;
    final label = switch (status) {
      ConnectionStatus.connected => 'CONNECTED',
      ConnectionStatus.connecting => 'CONNECTING',
      ConnectionStatus.reconnecting => 'RECONNECTING',
      ConnectionStatus.disconnected => 'OFFLINE',
    };
    final color = connected ? const Color(0xFF5FE1C0) : const Color(0xFFFFC66D);

    return Align(
      alignment: Alignment.centerRight,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.09),
          borderRadius: BorderRadius.circular(30),
          border: Border.all(color: color.withValues(alpha: 0.25)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            ),
            const SizedBox(width: 9),
            Text(
              label,
              style: TextStyle(
                color: color,
                fontSize: 12,
                fontWeight: FontWeight.w800,
                letterSpacing: 1.4,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
