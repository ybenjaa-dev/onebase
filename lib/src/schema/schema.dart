import '../errors.dart';

/// Field types supported in `mongo_easy.yaml` and the Dart schema.
///
/// Each maps to a SQLite storage type; values are converted transparently
/// when reading and writing documents.
enum MongoFieldType {
  /// Stored as TEXT.
  text('text'),

  /// Stored as INTEGER.
  int('int'),

  /// Stored as REAL.
  double('double'),

  /// Stored as INTEGER 0/1, exposed as Dart [bool].
  bool('bool'),

  /// Stored as ISO-8601 TEXT (UTC), exposed as Dart [DateTime].
  datetime('datetime'),

  /// Stored as JSON TEXT, exposed as `Map`/`List`. Nested fields are
  /// queryable with dot-paths (`where('address.city', ...)`).
  json('json');

  const MongoFieldType(this.yamlName);

  /// The name used in `mongo_easy.yaml`.
  final String yamlName;

  static MongoFieldType parse(String value) {
    for (final type in values) {
      if (type.yamlName == value) return type;
    }
    throw SchemaParseException(
      'Unknown field type "$value".',
      hint: 'Valid types: ${values.map((t) => t.yamlName).join(', ')}.',
    );
  }
}

/// Schema for one MongoDB collection.
class MongoCollectionSchema {
  MongoCollectionSchema(
    this.name, {
    required this.fields,
    this.ownerField,
    this.shared = false,
  }) {
    if (name.isEmpty) {
      throw const SchemaParseException('Collection name must not be empty.');
    }
    if (fields.containsKey('id') || fields.containsKey('_id')) {
      throw SchemaParseException(
        'Collection "$name" declares an id field.',
        hint: 'The `id` column is managed automatically — remove it from '
            'the fields.',
      );
    }
    if (ownerField != null && !fields.containsKey(ownerField)) {
      throw SchemaParseException(
        'owner_field "$ownerField" of collection "$name" is not declared in '
        'its fields.',
        hint: 'Add `$ownerField: text` to the fields of "$name".',
      );
    }
    if (!shared && ownerField == null) {
      throw SchemaParseException(
        'Collection "$name" has no owner_field and is not marked shared.',
        hint: 'Per-user collections need `owner_field: <field>` so sync rules '
            'can isolate data by user. For public/shared data, set '
            '`shared: true` explicitly.',
      );
    }
  }

  /// MongoDB collection name (also the local table/view name).
  final String name;

  /// Field name → type. The `id` column is implicit — never declare it.
  final Map<String, MongoFieldType> fields;

  /// Field holding the owning user's id (JWT `sub`). Required unless
  /// [shared] is true. Auto-filled on insert when omitted from the document.
  final String? ownerField;

  /// When true, the collection is synced to all authenticated users instead
  /// of being filtered per user.
  final bool shared;

  MongoFieldType fieldType(String field) {
    final type = fields[field];
    if (type == null) {
      throw UnknownFieldException(field, name, fields.keys);
    }
    return type;
  }
}

/// The full schema: every collection the app syncs.
///
/// Usually generated into `lib/mongo_easy_schema.g.dart` by
/// `dart run mongo_easy:setup` from `mongo_easy.yaml`.
class MongoEasySchema {
  MongoEasySchema(List<MongoCollectionSchema> collections)
      : collections = {
          for (final collection in collections) collection.name: collection,
        } {
    if (collections.length != this.collections.length) {
      throw const SchemaParseException('Duplicate collection names in schema.');
    }
  }

  final Map<String, MongoCollectionSchema> collections;

  MongoCollectionSchema collection(String name) {
    final schema = collections[name];
    if (schema == null) {
      throw UnknownCollectionException(name, collections.keys);
    }
    return schema;
  }
}
