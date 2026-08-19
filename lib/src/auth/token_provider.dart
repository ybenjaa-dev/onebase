/// Supplies the JWT the sync engine sends on every backend request.
///
/// mongobase is auth-provider-agnostic: wrap whatever issues your JWTs.
///
/// ```dart
/// // Supabase Auth
/// TokenProvider(() async =>
///     Supabase.instance.client.auth.currentSession?.accessToken);
///
/// // Firebase Auth
/// TokenProvider(() => FirebaseAuth.instance.currentUser?.getIdToken());
///
/// // Custom backend / dev tokens
/// TokenProvider(() async => myAuthService.jwt);
/// ```
///
/// Return `null` while the user is signed out — mongobase keeps working
/// against local data and starts syncing once a token appears.
class TokenProvider {
  const TokenProvider(this._fetch);

  /// A provider that always returns the same token. Useful for tests and
  /// quick prototypes; real apps should fetch fresh tokens so expiry and
  /// refresh work.
  factory TokenProvider.static(String token) =>
      TokenProvider(() async => token);

  final Future<String?> Function() _fetch;

  /// Fetches the current JWT, or `null` when no user is signed in.
  Future<String?> getToken() => _fetch();
}
