/// Fill this in after running `dart run mongo_easy:setup` and deploying the
/// generated backend (see backend/README.md) — or override at run time with
/// --dart-define=API_URL=... (used by the local E2E harness in
/// tool/local_e2e).
abstract final class AppConfig {
  /// Root URL of your deployed mongo_easy backend, without a trailing slash.
  static const apiUrl = String.fromEnvironment(
    'API_URL',
    defaultValue: 'https://YOUR-PROJECT.example.com',
  );

  /// The dev-only token endpoint (email login without an auth provider).
  static String get tokenUrl => '$apiUrl/token';

  /// Run the app as a thin online client:
  /// `flutter run --dart-define=ONLINE=true`
  static const online = bool.fromEnvironment('ONLINE');

  static bool get isConfigured => !apiUrl.contains('YOUR-PROJECT');
}
