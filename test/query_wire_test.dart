import 'package:flutter_test/flutter_test.dart';
import 'package:mongobase/src/query/local_query_runner.dart';
import 'package:mongobase/src/query/query_builder.dart';
import 'package:mongobase/src/query/query_wire.dart';
import 'package:mongobase/src/schema/schema.dart';

import 'fake_executor.dart';

void main() {
  final schema = MongoCollectionSchema(
    'todos',
    fields: {
      'title': MongoFieldType.text,
      'done': MongoFieldType.bool,
      'priority': MongoFieldType.int,
      'due_at': MongoFieldType.datetime,
      'meta': MongoFieldType.json,
      'owner_id': MongoFieldType.text,
    },
    ownerField: 'owner_id',
  );

  MongoQuery query() => MongoQuery(LocalQueryRunner(FakeExecutor()), schema);

  Map<String, Object?> encode(MongoQuery q) => encodeQuery(schema, q.spec);

  test('names the collection', () {
    expect(encode(query())['collection'], 'todos');
  });

  test('maps every operator onto its wire name', () {
    final cases = <MongoQuery, String>{
      query().where('title', isEqualTo: 'a'): 'eq',
      query().where('title', isNotEqualTo: 'a'): 'ne',
      query().where('priority', isGreaterThan: 1): 'gt',
      query().where('priority', isGreaterThanOrEqualTo: 1): 'gte',
      query().where('priority', isLessThan: 1): 'lt',
      query().where('priority', isLessThanOrEqualTo: 1): 'lte',
      query().where('title', whereIn: ['a']): 'in',
      query().where('title', isNull: true): 'isNull',
      query().where('title', isNull: false): 'isNotNull',
    };
    for (final MapEntry(key: q, value: expected) in cases.entries) {
      final filters = encode(q)['filters']! as List;
      expect((filters.single as Map)['op'], expected);
    }
  });

  test('encodes values exactly as SQLite would store them', () {
    final filters = encode(query()
        .where('done', isEqualTo: true)
        .where('due_at', isLessThan: DateTime.utc(2026)))['filters']! as List;

    // Both modes must agree on the representation, or the same query would
    // return different results depending on where it ran.
    expect((filters[0] as Map)['value'], 1);
    expect((filters[1] as Map)['value'], '2026-01-01T00:00:00.000Z');
  });

  test('encodes whereIn as a list of encoded values', () {
    final filters =
        encode(query().where('priority', whereIn: [1, 2]))['filters']! as List;
    expect((filters.single as Map)['value'], [1, 2]);
  });

  test('null checks carry no value', () {
    final filters =
        encode(query().where('title', isNull: true))['filters']! as List;
    expect((filters.single as Map).containsKey('value'), isFalse);
  });

  test('dot-paths keep the raw value so the backend matches nested json', () {
    final filters =
        encode(query().where('meta.city', isEqualTo: 'Rabat'))['filters']!
            as List;
    expect((filters.single as Map)['field'], 'meta.city');
    expect((filters.single as Map)['value'], 'Rabat');
  });

  test('carries order, limit and offset', () {
    final wire =
        encode(query().orderBy('title', descending: true).limit(10).offset(5));
    expect(wire['order'], [
      {'field': 'title', 'descending': true},
    ]);
    expect(wire['limit'], 10);
    expect(wire['offset'], 5);
  });

  test('omits limit and offset when unset', () {
    final wire = encode(query());
    expect(wire.containsKey('limit'), isFalse);
    expect(wire.containsKey('offset'), isFalse);
  });
}
