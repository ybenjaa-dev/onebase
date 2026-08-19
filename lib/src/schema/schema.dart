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

/// Who, inside a group, may write a group-scoped collection.
enum GroupWrite {
  /// Only the document's `owner_field` user. Requires an `owner_field`; the
  /// group grants read access only.
  owner('owner'),

  /// Any member of the group.
  member('member'),

  /// Only members whose membership row carries the admin role.
  admin('admin'),

  /// Nobody — the client can read but never write. Server-side jobs and
  /// custom endpoints still can.
  none('none');

  const GroupWrite(this.yamlName);

  /// The name used in `onebase.yaml`.
  final String yamlName;

  static GroupWrite parse(String value) {
    for (final mode in values) {
      if (mode.yamlName == value) return mode;
    }
    throw SchemaParseException(
      'Unknown scope write mode "$value".',
      hint: 'Valid modes: ${values.map((m) => m.yamlName).join(', ')}.',
    );
  }
}

/// A membership table: the rows that say which users belong to which group.
///
/// ```yaml
/// memberships:
///   family:
///     collection: family_members
///     user_field: user_id
///     group_field: family_id
///     role_field: role        # optional — required for `write: admin`
///     admin_role: admin       # optional — defaults to "admin"
/// ```
class MembershipSchema {
  MembershipSchema(
    this.name, {
    required this.collection,
    required this.userField,
    required this.groupField,
    this.roleField,
    this.adminRole = 'admin',
  }) {
    if (name.isEmpty) {
      throw const SchemaParseException('Membership name must not be empty.');
    }
    if (collection.isEmpty) {
      throw SchemaParseException(
        'Membership "$name" has no `collection`.',
        hint: 'Point it at the collection holding the membership rows.',
      );
    }
    for (final (label, value) in [
      ('user_field', userField),
      ('group_field', groupField),
    ]) {
      if (value.isEmpty) {
        throw SchemaParseException('Membership "$name" has no `$label`.');
      }
    }
    if (userField == groupField) {
      throw SchemaParseException(
        'Membership "$name" uses "$userField" as both `user_field` and '
        '`group_field`.',
        hint:
            'They must be two different fields — one holds the member, the '
            'other the group.',
      );
    }
  }

  /// The name used to reference this membership from a collection's `scope`.
  final String name;

  /// Collection holding the membership rows.
  final String collection;

  /// Field on [collection] holding the member's user id (the JWT `sub`).
  final String userField;

  /// Field on [collection] holding the group id.
  final String groupField;

  /// Field on [collection] holding the member's role. Required to use
  /// `write: admin`.
  final String? roleField;

  /// Value of [roleField] that grants admin rights.
  final String adminRole;
}

/// Group-based visibility for a collection: every member of the group sees
/// the group's documents, and [write] decides who may change them.
///
/// ```yaml
/// collections:
///   family_cheers:
///     scope: { membership: family, field: family_id, write: member }
/// ```
class GroupScope {
  const GroupScope({
    required this.membership,
    required this.field,
    this.write = GroupWrite.member,
  });

  /// Name of the [MembershipSchema] that resolves the user's group ids.
  final String membership;

  /// Field on this collection holding the group id. The literal [idField]
  /// means the document's own id *is* the group id — the shape the group
  /// collection itself has (`families.id` is the family id).
  final String field;

  /// Who inside the group may write.
  final GroupWrite write;

  /// Sentinel [field] value meaning "the document's own id".
  static const String idField = 'id';

  /// True when the group id lives in the document's id rather than a field.
  bool get scopesById => field == idField;
}

/// Schema for one MongoDB collection.
class MongoCollectionSchema {
  MongoCollectionSchema(
    this.name, {
    required this.fields,
    this.ownerField,
    this.shared = false,
    this.scope,
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
    if (!shared && ownerField == null && scope == null) {
      throw SchemaParseException(
        'Collection "$name" has no owner_field, no scope, and is not marked '
        'shared.',
        hint:
            'Per-user collections need `owner_field: <field>`. Group data '
            'needs `scope: {membership: <name>, field: <field>}`. For data '
            'every signed-in user may read and write, set `shared: true` '
            'explicitly.',
      );
    }
    if (shared && scope != null) {
      throw SchemaParseException(
        'Collection "$name" is both `shared` and `scope`d.',
        hint:
            '`shared: true` already exposes it to every signed-in user. '
            'Drop one of the two.',
      );
    }
    final groupField = scope?.field;
    if (groupField != null &&
        groupField != GroupScope.idField &&
        !fields.containsKey(groupField)) {
      throw SchemaParseException(
        'scope field "$groupField" of collection "$name" is not declared in '
        'its fields.',
        hint:
            'Add `$groupField: text` to the fields of "$name", or use '
            '`field: id` when the document id is itself the group id.',
      );
    }
    if (scope?.write == GroupWrite.owner && ownerField == null) {
      throw SchemaParseException(
        'Collection "$name" uses `write: owner` but declares no owner_field.',
        hint:
            'Add `owner_field: <field>` so the server knows whose write to '
            'accept, or use `write: member`.',
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

  /// Group visibility, when the collection is shared within a group rather
  /// than owned by one user. Combines with [ownerField]: the owner writes,
  /// the group reads.
  final GroupScope? scope;

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
    List<MembershipSchema> memberships = const [],
  }) : collections = {
         for (final collection in collections) collection.name: collection,
       },
       memberships = {
         for (final membership in memberships) membership.name: membership,
       },
       storage = storage ?? StorageSchema(const []) {
    if (collections.length != this.collections.length) {
      throw const SchemaParseException('Duplicate collection names in schema.');
    }
    if (memberships.length != this.memberships.length) {
      throw const SchemaParseException('Duplicate membership names in schema.');
    }
    _validateMemberships();
    _validateScopes();
  }

  final Map<String, MongoCollectionSchema> collections;

  /// Membership tables declared under `memberships:`, keyed by name. Empty
  /// when the app has no group-scoped data.
  final Map<String, MembershipSchema> memberships;

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

  /// The membership named [name].
  MembershipSchema membership(String name) {
    final schema = memberships[name];
    if (schema == null) {
      throw SchemaParseException(
        'Unknown membership "$name".',
        hint: memberships.isEmpty
            ? 'Declare it under a top-level `memberships:` section.'
            : 'Declared memberships: ${memberships.keys.join(', ')}.',
      );
    }
    return schema;
  }

  /// Every membership must live in a real collection whose user, group and
  /// role fields exist — otherwise the server would resolve group ids from
  /// fields nothing ever writes, and silently sync nothing.
  void _validateMemberships() {
    for (final membership in memberships.values) {
      final target = collections[membership.collection];
      if (target == null) {
        throw SchemaParseException(
          'Membership "${membership.name}" points at unknown collection '
          '"${membership.collection}".',
          hint: 'Declared collections: ${collections.keys.join(', ')}.',
        );
      }
      final referenced = <(String, String)>[
        ('user_field', membership.userField),
        ('group_field', membership.groupField),
        if (membership.roleField != null) ('role_field', membership.roleField!),
      ];
      for (final (label, field) in referenced) {
        if (!target.fields.containsKey(field)) {
          throw SchemaParseException(
            'Membership "${membership.name}" declares `$label: $field`, which '
            'collection "${membership.collection}" does not have.',
            hint:
                'Add `$field: text` to the fields of '
                '"${membership.collection}".',
          );
        }
      }
    }
  }

  void _validateScopes() {
    for (final collection in collections.values) {
      final scope = collection.scope;
      if (scope == null) continue;
      final membership = memberships[scope.membership];
      if (membership == null) {
        throw SchemaParseException(
          'Collection "${collection.name}" is scoped to unknown membership '
          '"${scope.membership}".',
          hint: memberships.isEmpty
              ? 'Declare it under a top-level `memberships:` section.'
              : 'Declared memberships: ${memberships.keys.join(', ')}.',
        );
      }
      if (scope.write == GroupWrite.admin && membership.roleField == null) {
        throw SchemaParseException(
          'Collection "${collection.name}" uses `write: admin` but membership '
          '"${membership.name}" declares no `role_field`.',
          hint:
              'Add `role_field: <field>` to the "${membership.name}" '
              'membership so the server can tell admins apart.',
        );
      }
    }
  }
}
