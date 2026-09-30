import 'dart:async';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';

import '../models/reminder_trigger.dart';
import 'reminder_api.dart';

/// Registers this installation for server-originated FCM notifications and
/// forwards foreground/tapped reminder payloads into the display UI.
class FcmPushService {
  FcmPushService({
    required ReminderApi api,
    required ValueChanged<ReminderTrigger> onTrigger,
    FirebaseMessaging? messaging,
  })  : _api = api,
        _onTrigger = onTrigger,
        _messaging = messaging ?? FirebaseMessaging.instance;

  final ReminderApi _api;
  final ValueChanged<ReminderTrigger> _onTrigger;
  final FirebaseMessaging _messaging;
  final List<StreamSubscription<dynamic>> _subscriptions = [];
  bool _disposed = false;

  Future<void> initialize() async {
    _subscriptions.add(
      FirebaseMessaging.onMessage.listen(_handleMessage),
    );
    _subscriptions.add(
      FirebaseMessaging.onMessageOpenedApp.listen(_handleMessage),
    );

    final settings = await _messaging.requestPermission(
      alert: true,
      badge: true,
      sound: true,
    );
    if (settings.authorizationStatus == AuthorizationStatus.denied) {
      debugPrint('FCM notification permission was denied');
      return;
    }

    await _registerCurrentToken();
    _subscriptions.add(
      _messaging.onTokenRefresh.listen(
        (token) => unawaited(_registerToken(token)),
      ),
    );

    final initialMessage = await _messaging.getInitialMessage();
    if (initialMessage != null) _handleMessage(initialMessage);
  }

  Future<void> _registerCurrentToken() async {
    try {
      final token = await _messaging.getToken();
      if (token != null && token.isNotEmpty) await _registerToken(token);
    } catch (error) {
      debugPrint('Could not obtain/register FCM token: $error');
    }
  }

  Future<void> _registerToken(String token) async {
    if (_disposed) return;
    try {
      await _api.registerFcmToken(token);
      debugPrint('FCM token registered with reminder backend');
    } catch (error) {
      // Token refresh and initial setup may race the backend startup. It will be
      // retried on the next token refresh or app launch; never log the token.
      debugPrint('Could not register FCM token with backend: $error');
    }
  }

  void _handleMessage(RemoteMessage message) {
    if (_disposed || message.data['type'] != 'reminder.trigger') return;
    try {
      _onTrigger(ReminderTrigger.fromJson(message.data));
    } on FormatException catch (error) {
      debugPrint('Ignoring invalid FCM reminder payload: $error');
    } on TypeError catch (error) {
      debugPrint('Ignoring invalid FCM reminder payload: $error');
    }
  }

  Future<void> dispose() async {
    _disposed = true;
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    _subscriptions.clear();
  }
}
