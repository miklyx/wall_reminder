class AppConfig {
  const AppConfig({required this.apiBaseUrl, required this.apiKey});

  /// Set for a physical Android device with:
  /// --dart-define=API_BASE_URL=http://<backend-host>:8000
  /// --dart-define=API_KEY=<shared-api-key>
  static const fromBuild = AppConfig(
    apiBaseUrl: String.fromEnvironment(
      'API_BASE_URL',
      defaultValue: 'http://10.0.2.2:8000',
    ),
    apiKey: String.fromEnvironment('API_KEY'),
  );

  final String apiBaseUrl;
  final String apiKey;

  Uri get webSocketUri {
    final base = Uri.parse(apiBaseUrl);
    final scheme = switch (base.scheme) {
      'https' => 'wss',
      'http' => 'ws',
      _ => throw const FormatException('API_BASE_URL must use http or https'),
    };
    return base.replace(scheme: scheme, path: '/ws', query: '', fragment: '');
  }

  Uri dismissUri(String reminderId) =>
      Uri.parse(apiBaseUrl).resolve('/api/dismiss/$reminderId');
}
