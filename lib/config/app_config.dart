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

  Uri resolveApiUri(String relativePath) {
    final base = Uri.parse(apiBaseUrl);
    final basePath = base.path.endsWith('/') ? base.path : '${base.path}/';
    return base.replace(path: basePath).resolve(relativePath);
  }

  Uri get webSocketUri {
    final base = Uri.parse(apiBaseUrl);
    final scheme = switch (base.scheme) {
      'https' => 'wss',
      'http' => 'ws',
      _ => throw const FormatException('API_BASE_URL must use http or https'),
    };
    final basePath = base.path.endsWith('/') ? base.path : '${base.path}/';
    return Uri(
      scheme: scheme,
      userInfo: base.userInfo.isEmpty ? null : base.userInfo,
      host: base.host,
      port: base.hasPort ? base.port : null,
      path: '${basePath}ws',
    );
  }
}
