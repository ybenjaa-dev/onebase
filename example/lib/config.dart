/// Fill these in after running `dart run mongo_easy:setup` and deploying the
/// generated backend (see backend/vercel/README.md) — or override at run
/// time with --dart-define=POWERSYNC_URL=... etc. (used by the local E2E
/// harness in tool/local_e2e).
abstract final class AppConfig {
  /// Your PowerSync instance URL (PowerSync Dashboard → instance).
  static const powersyncUrl = String.fromEnvironment(
    'POWERSYNC_URL',
    defaultValue: 'https://YOUR-INSTANCE.powersync.journeyapps.com',
  );

  /// The deployed write-upload endpoint.
  static const uploadUrl = String.fromEnvironment(
    'UPLOAD_URL',
    defaultValue: 'https://YOUR-PROJECT.vercel.app/api/upload',
  );

  /// The dev-only token endpoint (email login without an auth provider).
  static const tokenUrl = String.fromEnvironment(
    'TOKEN_URL',
    defaultValue: 'https://YOUR-PROJECT.vercel.app/api/token',
  );

  static bool get isConfigured => !powersyncUrl.contains('YOUR-INSTANCE');
}
