import '../errors.dart';
import '../schema/schema.dart';
import '../schema/value_codec.dart';

final _identifier = RegExp(r'^[a-zA-Z_][a-zA-Z0-9_]*$');

/// A compiled SQL fragment with its parameters.
class SqlFragment {
  const SqlFragment(this.sql, this.parameters);

  final String sql;
  final List<Object?> parameters;
}

/// Resolves a field reference (plain or dot-path) to a SQL expression.
///
/// `title` → `"title"`; `address.city` → `json_extract("address", '$.city')`
/// (the root segment must be a declared json field).
SqlFragment resolveField(String field, MongoCollectionSchema schema) {
  final segments = field.split('.');
  for (final segment in segments) {
    if (!_identifier.hasMatch(segment)) {
      throw InvalidFieldNameException(field);
    }
  }

  final root = segments.first;
  final rootType = schema.fieldType(root);

  if (segments.length == 1) {
    return SqlFragment('"$root"', const []);
  }

  if (rootType != MongoFieldType.json) {
    throw QueryException(
      'Dot-path "$field" requires "$root" to be a json field, but it is '
      '${rootType.yamlName}.',
      hint: 'Only json fields support nested access.',
    );
  }
  final path = segments.skip(1).join('.');
  return SqlFragment("json_extract(\"$root\", '\$.$path')", const []);
}

/// One `where` condition.
class Filter {
  const Filter._(this.field, this.operator, this.value);

  final String field;
  final String operator;
  final Object? value;

  static Filter equals(String field, Object? value) =>
      Filter._(field, '=', value);
  static Filter notEquals(String field, Object? value) =>
      Filter._(field, '!=', value);
  static Filter greaterThan(String field, Object value) =>
      Filter._(field, '>', value);
  static Filter greaterThanOrEqual(String field, Object value) =>
      Filter._(field, '>=', value);
  static Filter lessThan(String field, Object value) =>
      Filter._(field, '<', value);
  static Filter lessThanOrEqual(String field, Object value) =>
      Filter._(field, '<=', value);
  static Filter inList(String field, List<Object> values) =>
      Filter._(field, 'IN', values);
  static Filter isNull(String field, {required bool isNull}) =>
      Filter._(field, isNull ? 'IS NULL' : 'IS NOT NULL', null);

  SqlFragment compile(MongoCollectionSchema schema) {
    final column = resolveField(field, schema);
    final isDotPath = field.contains('.');

    Object? encodeValue(Object? raw) {
      if (isDotPath) {
        // json_extract returns JSON scalars: bools surface as 0/1, dates as
        // whatever string was stored.
        return switch (raw) {
          final bool value => value ? 1 : 0,
          final DateTime value => value.toUtc().toIso8601String(),
          _ => raw,
        };
      }
      return ValueCodec.encode(raw, schema.fieldType(field),
          field: field, collection: schema.name);
    }

    switch (operator) {
      case 'IS NULL':
      case 'IS NOT NULL':
        return SqlFragment('${column.sql} $operator', const []);
      case 'IN':
        final values = value as List<Object>;
        if (values.isEmpty) {
          throw QueryException(
            'whereIn on "$field" received an empty list.',
            hint: 'Provide at least one value, or skip the filter.',
          );
        }
        final placeholders = List.filled(values.length, '?').join(', ');
        return SqlFragment('${column.sql} IN ($placeholders)',
            [for (final v in values) encodeValue(v)]);
      default:
        return SqlFragment('${column.sql} $operator ?', [encodeValue(value)]);
    }
  }
}
