import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:onebase/src/auth/jwt_utils.dart';
import 'package:onebase/src/errors.dart';

String _fakeJwt(Map<String, Object?> payload) {
  String segment(Map<String, Object?> json) =>
      base64Url.encode(utf8.encode(jsonEncode(json))).replaceAll('=', '');
  return '${segment({'alg': 'HS256', 'typ': 'JWT'})}.'
      '${segment(payload)}.signature';
}

void main() {
  test('decodes sub, exp and aud', () {
    final exp = DateTime.utc(2030).millisecondsSinceEpoch ~/ 1000;
    final claims = decodeJwt(
      _fakeJwt({
        'sub': 'user-42',
        'exp': exp,
        'aud': 'https://api.example.com',
      }),
    );
    expect(claims.subject, 'user-42');
    expect(claims.expiresAt, DateTime.utc(2030));
    expect(claims.audience, 'https://api.example.com');
    expect(claims.isExpired, isFalse);
  });

  test('aud as list takes the first entry', () {
    final claims = decodeJwt(
      _fakeJwt({
        'sub': 's',
        'aud': ['a', 'b'],
      }),
    );
    expect(claims.audience, 'a');
  });

  test('expired token reports isExpired', () {
    final claims = decodeJwt(_fakeJwt({'sub': 's', 'exp': 1000}));
    expect(claims.isExpired, isTrue);
  });

  test('missing exp means no expiry', () {
    final claims = decodeJwt(_fakeJwt({'sub': 's'}));
    expect(claims.expiresAt, isNull);
    expect(claims.isExpired, isFalse);
  });

  test('non-JWT strings throw with a helpful hint', () {
    expect(
      () => decodeJwt('not-a-jwt'),
      throwsA(
        isA<InvalidTokenException>().having(
          (e) => e.hint,
          'hint',
          contains('TokenProvider'),
        ),
      ),
    );
  });

  test('corrupted payload throws', () {
    expect(
      () => decodeJwt('aaa.%%%%.ccc'),
      throwsA(isA<InvalidTokenException>()),
    );
  });

  test('missing sub claim throws', () {
    expect(
      () => decodeJwt(_fakeJwt({'aud': 'x'})),
      throwsA(
        isA<InvalidTokenException>().having(
          (e) => e.message,
          'message',
          contains('sub'),
        ),
      ),
    );
  });
}
