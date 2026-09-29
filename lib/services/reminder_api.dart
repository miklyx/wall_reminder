import 'dart:convert';

import 'package:http/http.dart' as http;

import '../config/app_config.dart';

class ReminderApi {
  ReminderApi(this._config, {http.Client? client}) : _client = client ?? http.Client();

  final AppConfig _config;
  final http.Client _client;

  Future<void> dismiss(String reminderId) async {
    final response = await _client
        .post(
          _config.dismissUri(reminderId),
          headers: {
            'X-API-Key': _config.apiKey,
            'Accept': 'application/json',
          },
        )
        .timeout(const Duration(seconds: 10));

    if (response.statusCode < 200 || response.statusCode >= 300) {
      var detail = 'HTTP ${response.statusCode}';
      try {
        final body = jsonDecode(response.body);
        if (body is Map<String, dynamic> && body['detail'] is String) {
          detail = body['detail'] as String;
        }
      } on FormatException {
        // Use the HTTP status when the backend response is not JSON.
      }
      throw ReminderApiException(detail);
    }
  }

  void close() => _client.close();
}

class ReminderApiException implements Exception {
  const ReminderApiException(this.message);

  final String message;

  @override
  String toString() => message;
}
