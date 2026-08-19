import 'package:yaml/yaml.dart';

import '../errors.dart';
import 'schema.dart';

/// Parses `mongo_easy.yaml` into a [MongoEasySchema].
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
MongoEasySchema parseSchemaYaml(String yamlSource) {
  final Object? root;
  try {
    root = loadYaml(yamlSource);
  } on YamlException catch (error) {
    throw SchemaParseException(
      'mongo_easy.yaml is not valid YAML: ${error.message}',
      hint: 'Fix the syntax error near line ${error.span?.start.line}.',
    );
  }

  if (root is! YamlMap) {
    throw const SchemaParseException(
      'mongo_easy.yaml must be a YAML map with a top-level `collections` key.',
    );
  }

  final collectionsNode = root['collections'];
  if (collectionsNode is! YamlMap || collectionsNode.isEmpty) {
    throw const SchemaParseException(
      'mongo_easy.yaml has no `collections`.',
      hint: 'Declare at least one collection:\n'
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

    const knownKeys = {'fields', 'owner_field', 'shared', 'model'};
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
        hint: 'Declare its fields, e.g.\n'
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
          hint: 'Valid types: '
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
          '`shared` of collection "$name" must be true or false.');
    }

    collections.add(MongoCollectionSchema(
      name,
      fields: fields,
      ownerField: value['owner_field']?.toString(),
      shared: shared as bool? ?? false,
      requiredFields: required,
      model: value['model']?.toString(),
    ));
  }

  return MongoEasySchema(collections);
}
