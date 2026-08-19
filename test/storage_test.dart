import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:onebase/src/auth/token_provider.dart';
import 'package:onebase/src/errors.dart';
import 'package:onebase/src/schema/schema_parser.dart';
import 'package:onebase/src/schema/storage_schema.dart';
import 'package:onebase/src/storage/storage.dart';
import 'package:onebase/src/sync/sync_api.dart';

void main() {
  final schema = parseSchemaYaml('''
collections:
  todos:
    shared: true
    fields:
      title: text

storage:
  avatars:
    access: private
    max_size: 1KB
    content_types: [image/png, image/jpeg]
  brochures:
    access: shared
''');

  late List<String> calls;
  late List<Map<String, Object?>> bodies;
  late List<Map<String, String>> uploadHeaders;
  late List<int> uploadedBytes;

  setUp(() {
    calls = [];
    bodies = [];
    uploadHeaders = [];
    uploadedBytes = [];
  });

  OnebaseStorage storageWith({
    Map<String, Object?> Function(String route)? respond,
    int uploadStatus = 200,
  }) {
    final api = SyncApi(
      baseUrl: 'https://api.test',
      tokenProvider: TokenProvider.static('token'),
      httpClient: MockClient((request) async {
        calls.add(request.url.toString());
        if (request.url.host != 'api.test') {
          // The presigned PUT goes straight to the object store.
          uploadHeaders.add(Map.of(request.headers));
          uploadedBytes.addAll(request.bodyBytes);
          return http.Response('', uploadStatus);
        }
        bodies.add((jsonDecode(request.body) as Map).cast<String, Object?>());
        final route = request.url.path.split('/').last;
        final body = respond?.call(route) ??
            switch (route) {
              'upload-url' => {
                  'url': 'https://s3.test/avatars/u/me.png?X-Amz-Signature=abc',
                  'headers': {
                    'content-type': 'image/png',
                    'content-length': '3',
                  },
                  'key': 'avatars/u/me.png',
                },
              'complete' => {'key': 'avatars/u/me.png'},
              'download-url' => {'url': 'https://s3.test/signed-get'},
              'delete' => {'key': 'avatars/u/me.png'},
              'list' => {
                  'files': [
                    {
                      'path': 'me.png',
                      'size': 3,
                      'content_type': 'image/png',
                      'updated_at': '2026-01-01T00:00:00.000Z',
                      'owner': 'u',
                    },
                  ],
                },
              _ => <String, Object?>{},
            };
        return http.Response(jsonEncode(body), 200,
            headers: {'content-type': 'application/json'});
      }),
    );
    return OnebaseStorage(api, schema);
  }

  group('references', () {
    test('splits "bucket/path" and validates the bucket', () {
      final ref = storageWith().ref('avatars/me.png');
      expect(ref.bucket, 'avatars');
      expect(ref.path, 'me.png');
      expect(ref.reference, 'avatars/me.png');
    });

    test('keeps nested paths intact', () {
      expect(
          storageWith().ref('avatars/2026/01/me.png').path, '2026/01/me.png');
    });

    test('rejects a reference with no path', () {
      expect(
          () => storageWith().ref('avatars'), throwsA(isA<StorageException>()));
      expect(() => storageWith().ref('avatars/'),
          throwsA(isA<StorageException>()));
    });

    test('rejects an undeclared bucket, listing the real ones', () {
      expect(
        () => storageWith().ref('ghosts/x.png'),
        throwsA(isA<SchemaParseException>()
            .having((e) => e.hint, 'hint', contains('avatars'))),
      );
    });
  });

  group('path safety', () {
    test('refuses paths that could escape the user prefix', () {
      for (final path in [
        '../secrets.txt',
        'a/../../b.png',
        '/etc/passwd',
        'a\\b.png',
        'a//b.png',
        './x.png',
        '',
      ]) {
        expect(
          () => storageWith().bucket('avatars').file(path),
          throwsA(isA<StorageException>()),
          reason: 'must reject "$path"',
        );
      }
    });

    test('refuses control characters and absurd lengths', () {
      expect(() => storageWith().bucket('avatars').file('a\u0000b'),
          throwsA(isA<StorageException>()));
      expect(() => storageWith().bucket('avatars').file('a' * 1025),
          throwsA(isA<StorageException>()));
    });

    test('allows ordinary names, including dots and unicode', () {
      for (final path in [
        'me.png',
        'a.b.c.png',
        'photos/été.png',
        'x-1_2.png'
      ]) {
        expect(storageWith().bucket('avatars').file(path).path, path);
      }
    });
  });

  group('upload', () {
    test('signs, uploads to the object store, then records the file', () async {
      final file = await storageWith()
          .ref('avatars/me.png')
          .putData(Uint8List.fromList([1, 2, 3]));

      expect(calls, hasLength(3));
      expect(calls[0], endsWith('/storage/upload-url'));
      expect(calls[1], startsWith('https://s3.test/'));
      expect(calls[2], endsWith('/storage/complete'));

      // The bytes never touch the backend.
      expect(uploadedBytes, [1, 2, 3]);
      expect(uploadHeaders.single['content-type'], 'image/png');
      expect(uploadHeaders.single['content-length'], '3');

      expect(file.size, 3);
      expect(file.contentType, 'image/png');
    });

    test('completion is only recorded after the bytes land', () async {
      await expectLater(
        storageWith(uploadStatus: 403)
            .ref('avatars/me.png')
            .putData(Uint8List.fromList([1, 2, 3])),
        throwsA(isA<StorageException>()),
      );
      expect(calls.where((c) => c.endsWith('/storage/complete')), isEmpty);
    });

    test('guesses the content type from the extension', () async {
      await storageWith().ref('avatars/me.jpeg').putData(Uint8List(1));
      expect(bodies.first['contentType'], 'image/jpeg');
    });

    test('rejects a type the bucket does not allow, before uploading',
        () async {
      await expectLater(
        storageWith().ref('avatars/notes.pdf').putData(Uint8List(1)),
        throwsA(isA<StorageException>()),
      );
      expect(calls, isEmpty, reason: 'must not reach the network');
    });

    test('rejects a file over the bucket limit, before uploading', () async {
      await expectLater(
        storageWith().ref('avatars/big.png').putData(Uint8List(2048)),
        throwsA(isA<StorageException>()
            .having((e) => e.message, 'message', contains('1024'))),
      );
      expect(calls, isEmpty);
    });

    test('a bucket with no rules accepts anything', () async {
      await storageWith().ref('brochures/plan.pdf').putData(Uint8List(5000));
      expect(bodies.first['contentType'], 'application/pdf');
    });
  });

  group('read, list and delete', () {
    test('getDownloadUrl returns the signed URL', () async {
      expect(await storageWith().ref('avatars/me.png').getDownloadUrl(),
          'https://s3.test/signed-get');
    });

    test('delete posts the bucket and path', () async {
      await storageWith().ref('avatars/me.png').delete();
      expect(bodies.single, {'bucket': 'avatars', 'path': 'me.png'});
    });

    test('list decodes file metadata', () async {
      final files = await storageWith().bucket('avatars').list(prefix: 'me');
      expect(bodies.single['prefix'], 'me');
      expect(files.single.path, 'me.png');
      expect(files.single.size, 3);
      expect(files.single.updatedAt, DateTime.utc(2026));
    });
  });

  group('schema', () {
    test('parses access, sizes and content types', () {
      final avatars = schema.storage.bucket('avatars');
      expect(avatars.access, StorageAccess.private);
      expect(avatars.isPrivate, isTrue);
      expect(avatars.maxSizeBytes, 1024);
      expect(avatars.contentTypes, ['image/png', 'image/jpeg']);

      final brochures = schema.storage.bucket('brochures');
      expect(brochures.access, StorageAccess.shared);
      expect(brochures.maxSizeBytes, isNull);
    });

    test('understands size suffixes', () {
      final parsed = parseSchemaYaml('''
collections:
  t:
    shared: true
    fields:
      a: text
storage:
  b1: {max_size: 500}
  b2: {max_size: 2KB}
  b3: {max_size: 5MB}
  b4: {max_size: 1GB}
''');
      expect(parsed.storage.bucket('b1').maxSizeBytes, 500);
      expect(parsed.storage.bucket('b2').maxSizeBytes, 2048);
      expect(parsed.storage.bucket('b3').maxSizeBytes, 5 * 1024 * 1024);
      expect(parsed.storage.bucket('b4').maxSizeBytes, 1024 * 1024 * 1024);
    });

    test('content type wildcards match a family', () {
      final bucket = StorageBucketSchema('b', contentTypes: ['image/*']);
      expect(bucket.allowsContentType('image/png'), isTrue);
      expect(bucket.allowsContentType('IMAGE/PNG'), isTrue);
      expect(bucket.allowsContentType('video/mp4'), isFalse);
    });

    test('an app with no storage section is valid', () {
      final parsed = parseSchemaYaml('''
collections:
  t:
    shared: true
    fields:
      a: text
''');
      expect(parsed.storage.isEmpty, isTrue);
    });

    test('rejects a bad bucket name, access or size', () {
      for (final yaml in [
        'storage:\n  "Bad Name": {}',
        'storage:\n  b: {access: everyone}',
        'storage:\n  b: {max_size: huge}',
        'storage:\n  b: {nope: 1}',
      ]) {
        expect(
          () => parseSchemaYaml(
              'collections:\n  t:\n    shared: true\n    fields:\n      a: text\n$yaml'),
          throwsA(isA<SchemaParseException>()),
          reason: yaml,
        );
      }
    });
  });

  test('content type guesses cover what apps actually upload', () {
    expect(guessContentType('a.png'), 'image/png');
    expect(guessContentType('a.JPG'), 'image/jpeg');
    expect(guessContentType('a.mp4'), 'video/mp4');
    expect(guessContentType('a.pdf'), 'application/pdf');
    expect(guessContentType('noextension'), 'application/octet-stream');
    expect(guessContentType('a.unknown'), 'application/octet-stream');
  });
}
