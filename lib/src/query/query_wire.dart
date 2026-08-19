import '../errors.dart';
import '../schema/schema.dart';
import '../schema/value_codec.dart';
import 'filter.dart';
import 'query_spec.dart';

/// Wire operators accepted by the backend's `/query` route.
///
/// A closed set on purpose: the backend turns these into a MongoDB filter,
/// and anything it does not recognise is rejected rather than passed through.
abstract final class WireOperator {
  static const eq = 'eq';
  static const ne = 'ne';
  static const gt = 'gt';
  static const gte = 'gte';
  static const lt = 'lt';
  static const lte = 'lte';
  static const inList = 'in';
  static const isNull = 'isNull';
  static const isNotNull = 'isNotNull';

  static const all = {eq, ne, gt, gte, lt, lte, inList, isNull, isNotNull};

  /// Maps the SQL operator a [Filter] carries onto its wire name.
  static String of(String sqlOperator) => switch (sqlOperator) {
    '=' => eq,
    '!=' => ne,
    '>' => gt,
    '>=' => gte,
    '<' => lt,
    '<=' => lte,
    'IN' => inList,
    'IS NULL' => isNull,
    'IS NOT NULL' => isNotNull,
    _ => throw QueryException('Unsupported operator "$sqlOperator".'),
  };
}

/// Serializes a [QuerySpec] for the backend.
///
/// Values are encoded through [ValueCodec] exactly as they would be for
/// SQLite, so both modes agree on how a `bool`, `DateTime` or json field is
/// represented — one source of truth for the type rules.
Map<String, Object?> encodeQuery(MongoCollectionSchema schema, QuerySpec spec) {
  Object? encode(String field, Object? value) {
    if (value == null) return null;
    // Dot-paths address inside a json field; the backend matches them as
    // native nested paths, so the value must not be json-encoded.
    if (field.contains('.')) {
      return switch (value) {
        final DateTime date => date.toUtc().toIso8601String(),
        _ => value,
      };
    }
    return ValueCodec.encode(
      value,
      schema.fieldType(field),
      field: field,
      collection: schema.name,
    );
  }

  return {
    'collection': schema.name,
    'filters': [
      for (final filter in spec.filters)
        {
          'field': filter.field,
          'op': WireOperator.of(filter.operator),
          if (filter.operator == 'IN')
            'value': [
              for (final value in filter.value! as List<Object>)
                encode(filter.field, value),
            ]
          else if (filter.operator != 'IS NULL' &&
              filter.operator != 'IS NOT NULL')
            'value': encode(filter.field, filter.value),
        },
    ],
    'order': [
      for (final (field, descending) in spec.order)
        {'field': field, 'descending': descending},
    ],
    if (spec.limit != null) 'limit': spec.limit,
    if (spec.offset != null) 'offset': spec.offset,
  };
}
