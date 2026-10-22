import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:wall_reminder_display/config/app_config.dart';
import 'package:wall_reminder_display/services/reminder_api.dart';

void main() {
  test('API and WebSocket URLs preserve a configured path prefix', () {
    const config = AppConfig(
      apiBaseUrl: 'http://192.168.178.29/android-reminder',
      apiKey: 'test-key',
    );

    expect(
      config.resolveApiUri('api/devices/fcm-token').toString(),
      'http://192.168.178.29/android-reminder/api/devices/fcm-token',
    );
    expect(
      config.webSocketUri.toString(),
      'ws://192.168.178.29/android-reminder/ws',
    );
  });

  test('API and WebSocket URLs work with a trailing slash in the base URL',
      () {
    const config = AppConfig(
      apiBaseUrl: 'https://reminders.example.test/android-reminder/',
      apiKey: 'test-key',
    );

    expect(
      config.resolveApiUri('api/push').toString(),
      'https://reminders.example.test/android-reminder/api/push',
    );
    expect(
      config.webSocketUri.toString(),
      'wss://reminders.example.test/android-reminder/ws',
    );
  });

  test('dismiss sync targets one delivery and treats missing delivery as done',
      () async {
    http.Request? capturedRequest;
    final api = ReminderApi(
      const AppConfig(
        apiBaseUrl: 'https://reminders.example.test',
        apiKey: 'test-key',
      ),
      client: MockClient((request) async {
        capturedRequest = request;
        return http.Response(
          jsonEncode({'detail': 'Delivery not found'}),
          404,
          headers: {'content-type': 'application/json'},
        );
      }),
    );
    addTearDown(api.close);

    await api.dismissDelivery('delivery-1');

    expect(capturedRequest?.method, 'POST');
    expect(
      capturedRequest?.url.path,
      '/api/deliveries/delivery-1/dismiss',
    );
    expect(capturedRequest?.headers['X-API-Key'], 'test-key');
  });

  test('dismiss sync keeps retryable server failures visible as errors',
      () async {
    final api = ReminderApi(
      const AppConfig(
        apiBaseUrl: 'https://reminders.example.test',
        apiKey: 'test-key',
      ),
      client: MockClient((_) async => http.Response('Unavailable', 503)),
    );
    addTearDown(api.close);

    await expectLater(
      api.dismissDelivery('delivery-1'),
      throwsA(isA<ReminderApiException>()),
    );
  });

  test('dismiss sync does not swallow an unsupported endpoint 404', () async {
    final api = ReminderApi(
      const AppConfig(
        apiBaseUrl: 'https://reminders.example.test',
        apiKey: 'test-key',
      ),
      client: MockClient(
        (_) async => http.Response(
          '{"detail":"Not Found"}',
          404,
          headers: {'content-type': 'application/json'},
        ),
      ),
    );
    addTearDown(api.close);

    await expectLater(
      api.dismissDelivery('delivery-1'),
      throwsA(isA<ReminderApiException>()),
    );
  });

  test('FCM token registration retains the configured path prefix', () async {
    http.Request? capturedRequest;
    final api = ReminderApi(
      const AppConfig(
        apiBaseUrl: 'http://192.168.178.29/android-reminder',
        apiKey: 'test-key',
      ),
      client: MockClient((request) async {
        capturedRequest = request;
        return http.Response('', 204);
      }),
    );
    addTearDown(api.close);

    await api.registerFcmToken('token');

    expect(
      capturedRequest?.url.path,
      '/android-reminder/api/devices/fcm-token',
    );
  });
}
