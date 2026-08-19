import 'package:flutter_test/flutter_test.dart';
import 'package:onebase/src/errors.dart';
import 'package:onebase/src/schema/schema.dart';
import 'package:onebase/src/schema/value_codec.dart';

void main() {
  Object? encode(Object? value, MongoFieldType type) =>
      ValueCodec.encode(value, type, field: 'f', collection: 'c');

  group('encode', () {
    test('null passes through for every type', () {
      for (final type in MongoFieldType.values) {
        expect(encode(null, type), isNull);
      }
    });

    test('text/int pass through', () {
      expect(encode('hi', MongoFieldType.text), 'hi');
      expect(encode(7, MongoFieldType.int), 7);
    });

    test('double accepts ints and normalizes', () {
      expect(encode(3, MongoFieldType.double), 3.0);
      expect(encode(3.5, MongoFieldType.double), 3.5);
    });

    test('bool becomes 0/1', () {
      expect(encode(true, MongoFieldType.bool), 1);
      expect(encode(false, MongoFieldType.bool), 0);
    });

    test('datetime becomes UTC ISO-8601', () {
      final local = DateTime(2026, 7, 2, 13);
      expect(
        encode(local, MongoFieldType.datetime),
        local.toUtc().toIso8601String(),
      );
    });

    test('json maps and lists become JSON strings', () {
      expect(encode({'a': 1}, MongoFieldType.json), '{"a":1}');
      expect(encode([1, 'two'], MongoFieldType.json), '[1,"two"]');
    });

    test('type mismatches throw QueryException with the field name', () {
      expect(
        () => encode('yes', MongoFieldType.bool),
        throwsA(
          isA<QueryException>().having(
            (e) => e.message,
            'message',
            contains('"f"'),
          ),
        ),
      );
      expect(
        () => encode(1, MongoFieldType.text),
        throwsA(isA<QueryException>()),
      );
      expect(
        () => encode('2026-01-01', MongoFieldType.datetime),
        throwsA(isA<QueryException>()),
      );
      expect(
        () => encode('not json', MongoFieldType.json),
        throwsA(isA<QueryException>()),
      );
    });
  });

  group('decode', () {
    test('bool from 0/1', () {
      expect(ValueCodec.decode(1, MongoFieldType.bool), true);
      expect(ValueCodec.decode(0, MongoFieldType.bool), false);
    });

    test('datetime from ISO string', () {
      expect(
        ValueCodec.decode('2026-07-02T12:00:00.000Z', MongoFieldType.datetime),
        DateTime.utc(2026, 7, 2, 12),
      );
    });

    test('unparseable datetime falls back to the raw string', () {
      expect(ValueCodec.decode('garbage', MongoFieldType.datetime), 'garbage');
    });

    test('json from string', () {
      expect(ValueCodec.decode('{"a":[1,2]}', MongoFieldType.json), {
        'a': [1, 2],
      });
    });

    test('invalid json falls back to the raw string', () {
      expect(ValueCodec.decode('{oops', MongoFieldType.json), '{oops');
    });

    test('double from int column', () {
      expect(ValueCodec.decode(2, MongoFieldType.double), 2.0);
    });
  });

  group('round-trip', () {
    test('encode then decode preserves values', () {
      final now = DateTime.now();
      expect(
        ValueCodec.decode(
          encode(now, MongoFieldType.datetime),
          MongoFieldType.datetime,
        ),
        now.toUtc(),
      );
      expect(
        ValueCodec.decode(
          encode({
            'nested': [true, null],
          }, MongoFieldType.json),
          MongoFieldType.json,
        ),
        {
          'nested': [true, null],
        },
      );
      expect(
        ValueCodec.decode(
          encode(true, MongoFieldType.bool),
          MongoFieldType.bool,
        ),
        true,
      );
    });
  });

  group('decodeRow', () {
    test('converts declared fields, passes through id and unknowns', () {
      final schema = MongoCollectionSchema(
        'c',
        fields: {'done': MongoFieldType.bool},
        shared: true,
      );
      final decoded = ValueCodec.decodeRow({
        'id': 'x',
        'done': 1,
        'extra': 'raw',
      }, schema);
      expect(decoded, {'id': 'x', 'done': true, 'extra': 'raw'});
    });
  });
}
