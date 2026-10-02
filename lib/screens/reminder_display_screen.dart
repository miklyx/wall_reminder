import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../config/app_config.dart';
import '../models/reminder_trigger.dart';
import '../services/reminder_api.dart';
import '../services/reminder_connection.dart';
import '../services/fcm_push_service.dart';
import '../services/reminder_queue_store.dart';
import '../widgets/marquee_text.dart';
import '../widgets/reminder_queue_preview.dart';

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
  ReminderQueueStore? _queueStore;
  StreamSubscription<ReminderTrigger>? _triggerSubscription;
  StreamSubscription<ConnectionStatus>? _statusSubscription;
  ReminderQueueState? _queueState;
  Timer? _dismissRetryTimer;
  Duration _dismissRetryDelay = const Duration(seconds: 5);
  ConnectionStatus _connectionStatus = ConnectionStatus.disconnected;
  String? _feedback;
  bool _isDismissing = false;
  bool _marqueeStopped = false;
  bool _appIsResumed = true;
  bool _wakeLockEnabled = false;
  bool _isReady = false;
  bool _isFlushingDismissals = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(
        SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky));

    _connection = ReminderConnection(widget.config);
    _api = ReminderApi(widget.config);
    _fcmPushService = FcmPushService(api: _api, onTrigger: _onTrigger);
    _connectionStatus = _connection.status;
    _triggerSubscription = _connection.triggers.listen(
      (trigger) => unawaited(_onTrigger(trigger)),
      onError: (Object _) {
        if (mounted) {
          setState(() => _feedback = 'Invalid reminder event received');
        }
      },
    );
    _statusSubscription = _connection.statuses.listen((status) {
      if (mounted) setState(() => _connectionStatus = status);
      if (status == ConnectionStatus.connected) {
        _dismissRetryTimer?.cancel();
        _dismissRetryTimer = null;
        _dismissRetryDelay = const Duration(seconds: 5);
        unawaited(_flushPendingDismissals());
      }
    });
    unawaited(_initialize());
  }

  Future<void> _initialize() async {
    try {
      final preferences = await SharedPreferences.getInstance();
      final store = await ReminderQueueStore.load(preferences);
      if (!mounted) return;
      setState(() {
        _queueStore = store;
        _queueState = store.state;
        _isReady = true;
      });
      _connection.connect();
      unawaited(_initializeFcm());
      unawaited(_flushPendingDismissals());
      if (_queueState?.current != null && _appIsResumed) {
        unawaited(_setWakeLock(true));
      }
    } catch (error) {
      debugPrint('Could not restore the local reminder queue: $error');
      if (mounted) {
        setState(() => _feedback = 'Could not restore saved reminders');
      }
    }
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

  Future<void> _onTrigger(ReminderTrigger trigger) async {
    final store = _queueStore;
    if (!_isReady || store == null) return;
    try {
      final added = await store.add(trigger);
      if (!mounted) return;
      if (added) {
        setState(() {
          _queueState = store.state;
          _feedback = null;
          _marqueeStopped = false;
        });
      }
      _connection.acknowledgeStored(trigger.deliveryId);
      if (added &&
          store.state.current?.deliveryId == trigger.deliveryId &&
          _appIsResumed) {
        unawaited(_setWakeLock(true));
      }
    } catch (error) {
      debugPrint('Could not save incoming reminder: $error');
      if (mounted) {
        setState(() => _feedback = 'Could not save incoming reminder');
      }
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _appIsResumed = state == AppLifecycleState.resumed;
    if (_appIsResumed) {
      _connection.connect();
      _dismissRetryTimer?.cancel();
      _dismissRetryTimer = null;
      unawaited(_flushPendingDismissals());
      if (_queueState?.current != null && !_isDismissing) {
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
    final reminder = _queueState?.current;
    final store = _queueStore;
    if (reminder == null || store == null || _isDismissing) return;

    setState(() {
      _isDismissing = true;
      _marqueeStopped = true;
      _feedback = null;
    });
    await _setWakeLock(false);

    try {
      await store.complete(reminder.deliveryId);
      if (!mounted) return;
      setState(() {
        _queueState = store.state;
        _isDismissing = false;
        _marqueeStopped = false;
      });
      if (_queueState?.current != null && _appIsResumed) {
        unawaited(_setWakeLock(true));
      }
      unawaited(_flushPendingDismissals());
    } catch (error) {
      debugPrint('Could not save reminder completion locally: $error');
      if (!mounted) return;
      setState(() {
        _isDismissing = false;
        _marqueeStopped = false;
        _feedback = 'Could not save completion. Please retry.';
      });
      if (_appIsResumed) unawaited(_setWakeLock(true));
    }
  }

  Future<void> _flushPendingDismissals() async {
    final store = _queueStore;
    if (!_isReady || store == null || _isFlushingDismissals) return;
    _isFlushingDismissals = true;
    var failed = false;
    try {
      for (final deliveryId
          in store.state.pendingDismissalDeliveryIds.toList()) {
        try {
          await _api.dismissDelivery(deliveryId);
          await store.markDismissalSynced(deliveryId);
          if (mounted) setState(() => _queueState = store.state);
        } catch (error) {
          debugPrint('Could not sync reminder completion: $error');
          failed = true;
        }
      }
    } finally {
      _isFlushingDismissals = false;
    }

    if (store.state.pendingDismissalDeliveryIds.isEmpty) {
      _dismissRetryTimer?.cancel();
      _dismissRetryTimer = null;
      _dismissRetryDelay = const Duration(seconds: 5);
    } else if (failed || _dismissRetryTimer == null) {
      _scheduleDismissRetry();
    }
  }

  void _scheduleDismissRetry() {
    if (_dismissRetryTimer?.isActive == true) return;
    final delay = _dismissRetryDelay;
    _dismissRetryDelay = Duration(
      seconds: (_dismissRetryDelay.inSeconds * 2).clamp(5, 300),
    );
    _dismissRetryTimer = Timer(delay, () {
      _dismissRetryTimer = null;
      unawaited(_flushPendingDismissals());
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _dismissRetryTimer?.cancel();
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
    final reminder = _queueState?.current;
    final screen = MediaQuery.sizeOf(context);
    final messageSize = (screen.height * 0.19).clamp(48.0, 94.0).toDouble();
    final queuedReminders =
        _queueState?.reminders.skip(1).toList() ?? const <ReminderTrigger>[];

    return Scaffold(
      backgroundColor: const Color(0xFF080D14),
      body: SafeArea(
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: (screen.width * 0.045).clamp(24.0, 72.0).toDouble(),
            vertical: 10,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _ConnectionIndicator(status: _connectionStatus),
              if (reminder == null) ...[
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(Icons.notifications_none_rounded,
                          size: 64, color: Color(0xFF526174)),
                      const SizedBox(height: 16),
                      Text(
                        _isReady
                            ? 'READY FOR REMINDERS'
                            : 'LOADING SAVED REMINDERS',
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: Color(0xFF8998AA),
                          fontSize: 20,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 3,
                        ),
                      ),
                    ],
                  ),
                ),
              ] else ...[
                const Text(
                  'REMINDER',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Color(0xFF5FE1C0),
                    fontSize: 15,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 4,
                  ),
                ),
                Expanded(
                  child: Center(
                    child: SizedBox(
                      height: screen.height * 0.30,
                      width: double.infinity,
                      child: Center(
                        child: MarqueeText(
                          text: reminder.messageText,
                          isRunning: _appIsResumed &&
                              !_marqueeStopped &&
                              !_isDismissing,
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
                  ),
                ),
                if (queuedReminders.isNotEmpty)
                  SizedBox(
                    height: (screen.height * 0.24).clamp(60.0, 104.0),
                    child: ReminderQueuePreview(reminders: queuedReminders),
                  ),
              ],
              if (_feedback != null) ...[
                const SizedBox(height: 6),
                Text(
                  _feedback!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Color(0xFFFFB4AB),
                    fontSize: 13,
                  ),
                ),
              ],
              if (reminder != null) ...[
                const SizedBox(height: 8),
                SizedBox(
                  width: double.infinity,
                  height: 62,
                  child: FilledButton.icon(
                    onPressed: _isDismissing ? null : _dismissCurrent,
                    icon: Icon(
                      _feedback == null
                          ? Icons.check_circle_outline
                          : Icons.sync,
                      size: 25,
                    ),
                    label: Text(
                      _isDismissing
                          ? 'SAVING…'
                          : _feedback == null
                              ? 'DISMISS / DONE'
                              : 'RETRY DISMISS / DONE',
                      style: const TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 1,
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
