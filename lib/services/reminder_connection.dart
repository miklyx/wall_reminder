import 'dart:async';
import 'dart:convert';

import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../config/app_config.dart';
import '../models/reminder_trigger.dart';

enum ConnectionStatus { connecting, connected, reconnecting, disconnected }

class ReminderConnection {
  ReminderConnection(this._config);

  final AppConfig _config;
  final _triggerController = StreamController<ReminderTrigger>.broadcast();
  final _statusController =
      StreamController<ConnectionStatus>.broadcast(sync: true);

  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _socketSubscription;
  Timer? _reconnectTimer;
  bool _disposed = false;
  int _retryAttempt = 0;
  ConnectionStatus _status = ConnectionStatus.disconnected;

  Stream<ReminderTrigger> get triggers => _triggerController.stream;
  Stream<ConnectionStatus> get statuses => _statusController.stream;
  ConnectionStatus get status => _status;

  void connect() {
    if (_disposed || _channel != null || _status == ConnectionStatus.connecting) {
      return;
    }
    _reconnectTimer?.cancel();
    _setStatus(_retryAttempt == 0
        ? ConnectionStatus.connecting
        : ConnectionStatus.reconnecting);

    try {
      final channel = IOWebSocketChannel.connect(
        _config.webSocketUri,
        headers: {'X-API-Key': _config.apiKey},
        pingInterval: const Duration(seconds: 25),
      );
      _channel = channel;
      _socketSubscription = channel.stream.listen(
        _handleSocketData,
        onError: (_) => _handleDisconnect(channel),
        onDone: () => _handleDisconnect(channel),
        cancelOnError: true,
      );
      channel.ready.then((_) {
        if (_disposed || !identical(_channel, channel)) return;
        _retryAttempt = 0;
        _setStatus(ConnectionStatus.connected);
      }).catchError((Object _) => _handleDisconnect(channel));
    } catch (_) {
      _scheduleReconnect();
    }
  }

  void _handleSocketData(dynamic event) {
    if (event is! String) return;
    try {
      final decoded = jsonDecode(event);
      if (decoded is! Map<String, dynamic>) return;
      if (decoded['type'] == 'reminder.trigger') {
        _triggerController.add(ReminderTrigger.fromJson(decoded));
      }
    } on FormatException catch (error, stackTrace) {
      _triggerController.addError(error, stackTrace);
    } on TypeError catch (error, stackTrace) {
      _triggerController.addError(error, stackTrace);
    }
  }

  void acknowledgeDisplayed(String deliveryId) {
    final channel = _channel;
    if (channel == null || _status != ConnectionStatus.connected) return;
    channel.sink.add(jsonEncode({'type': 'ack', 'delivery_id': deliveryId}));
  }

  void _handleDisconnect(WebSocketChannel channel) {
    if (_disposed || !identical(_channel, channel)) return;
    _channel = null;
    unawaited(_socketSubscription?.cancel());
    _socketSubscription = null;
    unawaited(channel.sink.close());
    _scheduleReconnect();
  }

  void _scheduleReconnect() {
    if (_disposed || _reconnectTimer?.isActive == true) return;
    _retryAttempt++;
    _setStatus(ConnectionStatus.reconnecting);
    final exponent = (_retryAttempt - 1).clamp(0, 5).toInt();
    final seconds = (1 << exponent).clamp(1, 30).toInt();
    _reconnectTimer = Timer(Duration(seconds: seconds), connect);
  }

  void _setStatus(ConnectionStatus next) {
    _status = next;
    if (!_statusController.isClosed) _statusController.add(next);
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _reconnectTimer?.cancel();
    await _socketSubscription?.cancel();
    _socketSubscription = null;
    await _channel?.sink.close();
    _channel = null;
    _setStatus(ConnectionStatus.disconnected);
    await _triggerController.close();
    await _statusController.close();
  }
}
