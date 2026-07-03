import 'dart:convert';

import '../errors.dart';
import 'schema.dart';

/// Converts between Dart values and their SQLite representations according
/// to the declared [MongoFieldType].
abstract final class ValueCodec {
  /// Dart value → SQLite value for storage or query parameters.
  static Object? encode(Object? value, MongoFieldType type,
      {required String field, required String collection}) {
    if (value == null) return null;
    return switch (type) {
      MongoFieldType.text => _expect<String>(value, type, field, collection),
      MongoFieldType.int => _expect<int>(value, type, field, collection),
      MongoFieldType.double =>
        (_expect<num>(value, type, field, collection)).toDouble(),
      MongoFieldType.bool =>
        _expect<bool>(value, type, field, collection) ? 1 : 0,
      MongoFieldType.datetime =>
        _expect<DateTime>(value, type, field, collection)
            .toUtc()
            .toIso8601String(),
      MongoFieldType.json => value is Map || value is List
          ? jsonEncode(value)
          : throw QueryException(
              'Field "$field" on "$collection" is json but got '
              '${value.runtimeType}.',
              hint: 'Pass a Map or List for json fields.',
            ),
    };
  }

  /// SQLite value → Dart value for documents returned to the app.
  static Object? decode(Object? value, MongoFieldType type) {
    if (value == null) return null;
    return switch (type) {
      MongoFieldType.text => value,
      MongoFieldType.int => value,
      MongoFieldType.double => value is int ? value.toDouble() : value,
      MongoFieldType.bool => value == 1 || value == true,
      MongoFieldType.datetime =>
        value is String ? (DateTime.tryParse(value) ?? value) : value,
      MongoFieldType.json => value is String ? _tryJsonDecode(value) : value,
    };
  }

  /// Decodes a full SQLite row into a document, converting every declared
  /// field; undeclared columns (like `id`) pass through unchanged.
  static Map<String, Object?> decodeRow(
      Map<String, Object?> row, MongoCollectionSchema schema) {
    return {
      for (final MapEntry(:key, :value) in row.entries)
        key: schema.fields.containsKey(key)
            ? decode(value, schema.fields[key]!)
            : value,
    };
  }

  static Object? _tryJsonDecode(String value) {
    try {
      return jsonDecode(value);
    } on FormatException {
      return value;
    }
  }

  static T _expect<T>(
      Object value, MongoFieldType type, String field, String collection) {
    if (value is T) return value as T;
    throw QueryException(
      'Field "$field" on "$collection" is declared ${type.yamlName} but got '
      '${value.runtimeType} ($value).',
      hint: 'Fix the value or change the field type in mongo_easy.yaml and '
          're-run `dart run mongo_easy:setup`.',
    );
  }
}
