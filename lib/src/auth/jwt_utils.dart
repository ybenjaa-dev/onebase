import 'dart:convert';

import '../errors.dart';

/// Decoded (unverified) JWT payload claims.
///
/// mongobase never verifies signatures client-side — the backend does that
/// on every request. This only reads `sub` and `exp` for owner-field
/// auto-fill and refresh timing.
class JwtClaims {
  const JwtClaims({required this.subject, this.expiresAt, this.audience});

  /// The `sub` claim — the user id.
  final String subject;

  /// The `exp` claim, if present.
  final DateTime? expiresAt;

  /// The `aud` claim, if present (first value when a list).
  final String? audience;

  bool get isExpired {
    final exp = expiresAt;
    return exp != null && exp.isBefore(DateTime.now());
  }
}

/// Decodes the payload of [token] without verifying its signature.
///
/// Throws [InvalidTokenException] with an actionable message when the token
/// is not a structurally valid JWT or lacks a `sub` claim.
JwtClaims decodeJwt(String token) {
  final parts = token.split('.');
  if (parts.length != 3) {
    throw InvalidTokenException(
      'Token is not a JWT (expected 3 dot-separated segments, '
      'got ${parts.length}).',
      hint: 'Your TokenProvider must return the raw JWT string from your auth '
          'provider (e.g. the Supabase access token), not a session object '
          'or an API key.',
    );
  }

  final Map<String, Object?> payload;
  try {
    final normalized = base64Url.normalize(parts[1]);
    payload = jsonDecode(utf8.decode(base64Url.decode(normalized)))
        as Map<String, Object?>;
  } on Object {
    throw const InvalidTokenException(
      'Could not decode the JWT payload.',
      hint: 'The token appears corrupted. Check that your TokenProvider '
          'returns it unmodified.',
    );
  }

  final subject = payload['sub'];
  if (subject is! String || subject.isEmpty) {
    throw const InvalidTokenException(
      'JWT has no "sub" claim.',
      hint: 'mongobase identifies users by the `sub` claim. Configure your '
          'auth provider (or token endpoint) to include it.',
    );
  }

  DateTime? expiresAt;
  final exp = payload['exp'];
  if (exp is num) {
    expiresAt =
        DateTime.fromMillisecondsSinceEpoch(exp.toInt() * 1000, isUtc: true);
  }

  final aud = payload['aud'];
  final audience = switch (aud) {
    final String value => value,
    final List<Object?> value when value.isNotEmpty => value.first.toString(),
    _ => null,
  };

  return JwtClaims(subject: subject, expiresAt: expiresAt, audience: audience);
}
