import '../errors.dart';
import 'storage_schema.dart';

/// Field types supported in `onebase.yaml` and the Dart schema.
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

  /// The name used in `onebase.yaml`.
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
    this.requiredFields = const {},
    String? model,
  }) : model = model ?? modelNameFor(name) {
    if (name.isEmpty) {
      throw const SchemaParseException('Collection name must not be empty.');
    }
    if (fields.containsKey('id') || fields.containsKey('_id')) {
      throw SchemaParseException(
        'Collection "$name" declares an id field.',
        hint:
            'The `id` column is managed automatically — remove it from '
            'the fields.',
      );
    }
    final reserved = fields.keys.where((field) => field.startsWith('_'));
    if (reserved.isNotEmpty) {
      throw SchemaParseException(
        'Collection "$name" declares reserved field(s): '
        '${reserved.join(', ')}.',
        hint:
            'Names starting with an underscore are managed by onebase '
            '(for example `_updated_at`). Rename the field.',
      );
    }
    final undeclaredRequired = requiredFields.where(
      (field) => !fields.containsKey(field),
    );
    if (undeclaredRequired.isNotEmpty) {
      throw SchemaParseException(
        'Collection "$name" marks undeclared field(s) as required: '
        '${undeclaredRequired.join(', ')}.',
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
        hint:
            'Per-user collections need `owner_field: <field>` so sync rules '
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

  /// Fields declared with a trailing `!` in `onebase.yaml`.
  ///
  /// They become non-nullable on the generated model and are enforced by the
  /// backend when a whole document is written.
  final Set<String> requiredFields;

  /// Name of the generated Dart model class. Defaults to a singularized,
  /// PascalCase form of [name]; override with `model:` in the YAML.
  final String model;

  bool isRequired(String field) => requiredFields.contains(field);

  /// `todos` → `Todo`, `categories` → `Category`, `people` → `People`.
  ///
  /// Deliberately simple: irregular plurals are not guessed, so set `model:`
  /// in `onebase.yaml` when the default reads wrong.
  static String modelNameFor(String collection) {
    var base = collection;
    if (base.endsWith('ies') && base.length > 3) {
      base = '${base.substring(0, base.length - 3)}y';
    } else if (base.endsWith('sses') ||
        base.endsWith('shes') ||
        base.endsWith('ches') ||
        base.endsWith('xes')) {
      base = base.substring(0, base.length - 2);
    } else if (base.endsWith('s') && !base.endsWith('ss')) {
      base = base.substring(0, base.length - 1);
    }
    return base
        .split(RegExp(r'[_\-\s]+'))
        .where((part) => part.isNotEmpty)
        .map((part) => part[0].toUpperCase() + part.substring(1))
        .join();
  }

  MongoFieldType fieldType(String field) {
    // Implicit on every collection, and sortable/filterable like any column.
    if (field == 'id') return MongoFieldType.text;
    final type = fields[field];
    if (type == null) {
      throw UnknownFieldException(field, name, fields.keys);
    }
    return type;
  }
}

/// The full schema: every collection the app syncs.
///
/// Usually generated into `lib/onebase_schema.g.dart` by
/// `dart run onebase:setup` from `onebase.yaml`.
class OnebaseSchema {
  OnebaseSchema(
    List<MongoCollectionSchema> collections, {
    StorageSchema? storage,
  }) : collections = {
         for (final collection in collections) collection.name: collection,
       },
       storage = storage ?? StorageSchema(const []) {
    if (collections.length != this.collections.length) {
      throw const SchemaParseException('Duplicate collection names in schema.');
    }
  }

  final Map<String, MongoCollectionSchema> collections;

  /// File buckets declared under `storage:`. Empty when the app stores no
  /// files.
  final StorageSchema storage;

  MongoCollectionSchema collection(String name) {
    final schema = collections[name];
    if (schema == null) {
      throw UnknownCollectionException(name, collections.keys);
    }
    return schema;
  }
}
