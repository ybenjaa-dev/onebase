import 'package:yaml/yaml.dart';

import '../errors.dart';
import 'schema.dart';
import 'storage_schema.dart';

/// Parses `onebase.yaml` into a [OnebaseSchema].
///
/// ```yaml
/// collections:
///   todos:
///     owner_field: owner_id
///     fields:
///       title: text!      # trailing ! → required, non-nullable in Dart
///       done: bool
///       owner_id: text
///   categories:
///     shared: true
///     fields:
///       name: text
/// ```
OnebaseSchema parseSchemaYaml(String yamlSource) {
  final Object? root;
  try {
    root = loadYaml(yamlSource);
  } on YamlException catch (error) {
    throw SchemaParseException(
      'onebase.yaml is not valid YAML: ${error.message}',
      hint: 'Fix the syntax error near line ${error.span?.start.line}.',
    );
  }

  if (root is! YamlMap) {
    throw const SchemaParseException(
      'onebase.yaml must be a YAML map with a top-level `collections` key.',
    );
  }

  final collectionsNode = root['collections'];
  if (collectionsNode is! YamlMap || collectionsNode.isEmpty) {
    throw const SchemaParseException(
      'onebase.yaml has no `collections`.',
      hint:
          'Declare at least one collection:\n'
          'collections:\n'
          '  todos:\n'
          '    owner_field: owner_id\n'
          '    fields:\n'
          '      title: text\n'
          '      owner_id: text',
    );
  }

  final collections = <MongoCollectionSchema>[];
  for (final MapEntry(:key, :value) in collectionsNode.entries) {
    final name = key.toString();
    if (value is! YamlMap) {
      throw SchemaParseException(
        'Collection "$name" must be a map.',
        hint: 'Give it at least a `fields` section.',
      );
    }

    const knownKeys = {
      'fields',
      'owner_field',
      'shared',
      'scope',
      'sync',
      'model',
    };
    final unknown = value.keys
        .map((k) => k.toString())
        .where((k) => !knownKeys.contains(k));
    if (unknown.isNotEmpty) {
      throw SchemaParseException(
        'Collection "$name" has unknown option(s): ${unknown.join(', ')}.',
        hint: 'Valid options: ${knownKeys.join(', ')}.',
      );
    }

    final fieldsNode = value['fields'];
    if (fieldsNode is! YamlMap || fieldsNode.isEmpty) {
      throw SchemaParseException(
        'Collection "$name" has no `fields`.',
        hint:
            'Declare its fields, e.g.\n'
            '  $name:\n'
            '    fields:\n'
            '      title: text',
      );
    }

    final fields = <String, MongoFieldType>{};
    final required = <String>{};
    for (final MapEntry(key: fieldKey, value: fieldValue)
        in fieldsNode.entries) {
      final fieldName = fieldKey.toString();
      if (fieldValue is! String) {
        throw SchemaParseException(
          'Field "$fieldName" of "$name" must map to a type string, '
          'got: $fieldValue.',
          hint:
              'Valid types: '
              '${MongoFieldType.values.map((t) => t.yamlName).join(', ')}. '
              'Add a trailing `!` to make a field required, e.g. `title: text!`.',
        );
      }
      // `text!` means "always present": non-nullable on the generated model
      // and enforced by the backend.
      final isRequired = fieldValue.endsWith('!');
      final typeName = isRequired
          ? fieldValue.substring(0, fieldValue.length - 1)
          : fieldValue;
      fields[fieldName] = MongoFieldType.parse(typeName.trim());
      if (isRequired) required.add(fieldName);
    }

    final shared = value['shared'];
    if (shared != null && shared is! bool) {
      throw SchemaParseException(
        '`shared` of collection "$name" must be true or false.',
      );
    }

    collections.add(
      MongoCollectionSchema(
        name,
        fields: fields,
        ownerField: value['owner_field']?.toString(),
        shared: shared as bool? ?? false,
        scope: _parseScope(value['scope'], name),
        requiredFields: required,
        sync: _parseSync(value['sync'], name),
        model: value['model']?.toString(),
      ),
    );
  }

  return OnebaseSchema(
    collections,
    storage: _parseStorage(root['storage']),
    memberships: _parseMemberships(root['memberships']),
  );
}

/// Parses one collection's optional `scope:` section.
///
/// ```yaml
/// scope:
///   membership: family     # a name from the top-level `memberships:`
///   field: family_id       # or `id` when the document id is the group id
///   write: member          # owner | member | admin | none
/// ```
GroupScope? _parseScope(Object? node, String collection) {
  if (node == null) return null;
  if (node is! YamlMap) {
    throw SchemaParseException(
      '`scope` of collection "$collection" must be a map.',
      hint: 'scope: {membership: family, field: family_id}',
    );
  }

  const knownKeys = {'membership', 'field', 'write'};
  final unknown = node.keys
      .map((k) => k.toString())
      .where((k) => !knownKeys.contains(k));
  if (unknown.isNotEmpty) {
    throw SchemaParseException(
      '`scope` of collection "$collection" has unknown option(s): '
      '${unknown.join(', ')}.',
      hint: 'Valid options: ${knownKeys.join(', ')}.',
    );
  }

  final membership = node['membership']?.toString();
  if (membership == null || membership.isEmpty) {
    throw SchemaParseException(
      '`scope` of collection "$collection" has no `membership`.',
      hint: 'Name one of the memberships declared under `memberships:`.',
    );
  }
  final field = node['field']?.toString();
  if (field == null || field.isEmpty) {
    throw SchemaParseException(
      '`scope` of collection "$collection" has no `field`.',
      hint:
          'Name the field holding the group id, or `field: id` when the '
          'document id is itself the group id.',
    );
  }

  final write = node['write']?.toString();
  return GroupScope(
    membership: membership,
    field: field,
    write: write == null ? GroupWrite.member : GroupWrite.parse(write),
  );
}

/// Parses the optional top-level `memberships:` section.
///
/// ```yaml
/// memberships:
///   family:
///     collection: family_members
///     user_field: user_id
///     group_field: family_id
///     role_field: role       # optional — required by `write: admin`
///     admin_role: admin      # optional — defaults to "admin"
/// ```
List<MembershipSchema> _parseMemberships(Object? node) {
  if (node == null) return const [];
  if (node is! YamlMap) {
    throw const SchemaParseException(
      '`memberships` must be a map of membership names.',
      hint:
          'memberships:\n'
          '  family:\n'
          '    collection: family_members\n'
          '    user_field: user_id\n'
          '    group_field: family_id',
    );
  }

  final memberships = <MembershipSchema>[];
  for (final MapEntry(:key, :value) in node.entries) {
    final name = key.toString();
    if (value is! YamlMap) {
      throw SchemaParseException(
        'Membership "$name" must be a map.',
        hint: 'Give it `collection`, `user_field` and `group_field`.',
      );
    }

    const knownKeys = {
      'collection',
      'user_field',
      'group_field',
      'role_field',
      'admin_role',
    };
    final unknown = value.keys
        .map((k) => k.toString())
        .where((k) => !knownKeys.contains(k));
    if (unknown.isNotEmpty) {
      throw SchemaParseException(
        'Membership "$name" has unknown option(s): ${unknown.join(', ')}.',
        hint: 'Valid options: ${knownKeys.join(', ')}.',
      );
    }

    String require(String option) {
      final raw = value[option]?.toString();
      if (raw == null || raw.isEmpty) {
        throw SchemaParseException(
          'Membership "$name" has no `$option`.',
          hint:
              'memberships:\n'
              '  $name:\n'
              '    collection: <collection holding the membership rows>\n'
              '    user_field: <field with the member id>\n'
              '    group_field: <field with the group id>',
        );
      }
      return raw;
    }

    memberships.add(
      MembershipSchema(
        name,
        collection: require('collection'),
        userField: require('user_field'),
        groupField: require('group_field'),
        roleField: value['role_field']?.toString(),
        adminRole: value['admin_role']?.toString() ?? 'admin',
      ),
    );
  }
  return memberships;
}

/// Parses the optional `storage:` section.
///
/// ```yaml
/// storage:
///   avatars:
///     access: private        # default; each user sees only their own files
///     max_size: 5MB
///     content_types: [image/*]
///   brochures:
///     access: shared         # any signed-in user may read
/// ```
StorageSchema _parseStorage(Object? node) {
  if (node == null) return StorageSchema(const []);
  if (node is! YamlMap) {
    throw const SchemaParseException(
      '`storage` must be a map of bucket names.',
      hint: 'storage:\n  avatars:\n    access: private',
    );
  }

  final buckets = <StorageBucketSchema>[];
  for (final MapEntry(:key, :value) in node.entries) {
    final name = key.toString();
    if (value != null && value is! YamlMap) {
      throw SchemaParseException('Storage bucket "$name" must be a map.');
    }
    final options = value as YamlMap?;

    const knownKeys = {'access', 'max_size', 'content_types'};
    final unknown =
        options?.keys
            .map((k) => k.toString())
            .where((k) => !knownKeys.contains(k)) ??
        const <String>[];
    if (unknown.isNotEmpty) {
      throw SchemaParseException(
        'Storage bucket "$name" has unknown option(s): ${unknown.join(', ')}.',
        hint: 'Valid options: ${knownKeys.join(', ')}.',
      );
    }

    final contentTypesNode = options?['content_types'];
    final contentTypes = <String>[];
    if (contentTypesNode != null) {
      if (contentTypesNode is! YamlList) {
        throw SchemaParseException(
          '`content_types` of storage bucket "$name" must be a list.',
          hint: 'content_types: [image/png, image/jpeg]',
        );
      }
      contentTypes.addAll(contentTypesNode.map((v) => v.toString()));
    }

    buckets.add(
      StorageBucketSchema(
        name,
        access: StorageAccess.parse(
          options?['access']?.toString() ?? StorageAccess.private.yamlName,
        ),
        maxSizeBytes: _parseSize(options?['max_size'], name),
        contentTypes: contentTypes,
      ),
    );
  }
  return StorageSchema(buckets);
}

/// Accepts a plain byte count or a friendly suffix: `5MB`, `500KB`, `2GB`.
int? _parseSize(Object? value, String bucket) {
  if (value == null) return null;
  if (value is int) return value;

  final text = value.toString().trim().toUpperCase();
  final match = RegExp(r'^(\d+(?:\.\d+)?)\s*(B|KB|MB|GB)?$').firstMatch(text);
  if (match == null) {
    throw SchemaParseException(
      '`max_size` of storage bucket "$bucket" is not a size: $value.',
      hint: 'Use a number of bytes or a suffix, e.g. 5MB.',
    );
  }
  final amount = double.parse(match.group(1)!);
  final multiplier = switch (match.group(2)) {
    'KB' => 1024,
    'MB' => 1024 * 1024,
    'GB' => 1024 * 1024 * 1024,
    _ => 1,
  };
  return (amount * multiplier).round();
}

/// Parses one collection's optional `sync:` section.
///
/// ```yaml
/// sync: none              # never synced; reads go to the backend
///
/// sync:                   # or keep a rolling window on the device
///   window: 90d
///   field: created_at
/// ```
SyncPolicy _parseSync(Object? node, String collection) {
  if (node == null) return SyncPolicy.everything;

  // `sync: none` / `sync: full` as a bare word.
  if (node is String) {
    final mode = SyncMode.parse(node);
    if (mode == SyncMode.window) {
      throw SchemaParseException(
        '`sync: window` on "$collection" needs a duration and a field.',
        hint: 'sync:\n  window: 90d\n  field: created_at',
      );
    }
    return SyncPolicy(mode: mode);
  }

  if (node is! YamlMap) {
    throw SchemaParseException(
      '`sync` of collection "$collection" must be a mode or a map.',
      hint: 'sync: none, or sync: {window: 90d, field: created_at}',
    );
  }

  const knownKeys = {'mode', 'window', 'field'};
  final unknown = node.keys
      .map((k) => k.toString())
      .where((k) => !knownKeys.contains(k));
  if (unknown.isNotEmpty) {
    throw SchemaParseException(
      '`sync` of collection "$collection" has unknown option(s): '
      '${unknown.join(', ')}.',
      hint: 'Valid options: ${knownKeys.join(', ')}.',
    );
  }

  final window = _parseDuration(node['window'], collection);
  return SyncPolicy(
    mode: SyncMode.parse(
      node['mode']?.toString() ??
          (window != null ? SyncMode.window.yamlName : SyncMode.full.yamlName),
    ),
    field: node['field']?.toString(),
    window: window,
  );
}

/// Accepts `90d`, `12h`, `30m` — the units a sync window is actually
/// expressed in.
Duration? _parseDuration(Object? value, String collection) {
  if (value == null) return null;
  final text = value.toString().trim().toLowerCase();
  final match = RegExp(r'^(\d+)\s*([dhm])$').firstMatch(text);
  if (match == null) {
    throw SchemaParseException(
      '`window` of collection "$collection" is not a duration: $value.',
      hint: 'Use a number with d, h or m — for example 90d.',
    );
  }
  final amount = int.parse(match.group(1)!);
  return switch (match.group(2)) {
    'd' => Duration(days: amount),
    'h' => Duration(hours: amount),
    _ => Duration(minutes: amount),
  };
}
