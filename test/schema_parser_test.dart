import 'package:flutter_test/flutter_test.dart';
import 'package:mongo_easy/src/errors.dart';
import 'package:mongo_easy/src/schema/schema.dart';
import 'package:mongo_easy/src/schema/schema_parser.dart';

void main() {
  test('parses a full schema', () {
    final schema = parseSchemaYaml('''
collections:
  todos:
    owner_field: owner_id
    fields:
      title: text
      done: bool
      priority: int
      score: double
      due_at: datetime
      meta: json
      owner_id: text
  categories:
    shared: true
    fields:
      name: text
''');

    final todos = schema.collection('todos');
    expect(todos.ownerField, 'owner_id');
    expect(todos.shared, isFalse);
    expect(todos.fields['done'], MongoFieldType.bool);
    expect(todos.fields['due_at'], MongoFieldType.datetime);

    final categories = schema.collection('categories');
    expect(categories.shared, isTrue);
    expect(categories.ownerField, isNull);
  });

  void expectParseError(String yaml, Pattern message) {
    expect(
      () => parseSchemaYaml(yaml),
      throwsA(isA<SchemaParseException>()
          .having((e) => e.toString(), 'toString', contains(message))),
    );
  }

  test('invalid YAML syntax', () {
    expectParseError('collections:\n  todos: [unclosed', 'not valid YAML');
  });

  test('missing collections key', () {
    expectParseError('other: true', 'no `collections`');
  });

  test('collection without fields', () {
    expectParseError(
        'collections:\n  todos:\n    owner_field: x', 'no `fields`');
  });

  test('unknown field type', () {
    expectParseError('''
collections:
  todos:
    shared: true
    fields:
      title: varchar
''', 'Unknown field type "varchar"');
  });

  test('unknown collection option', () {
    expectParseError('''
collections:
  todos:
    owner: owner_id
    fields:
      title: text
''', 'unknown option');
  });

  test('owner_field must be declared in fields', () {
    expectParseError('''
collections:
  todos:
    owner_field: owner_id
    fields:
      title: text
''', 'owner_field');
  });

  test('per-user collection without owner_field is rejected', () {
    expectParseError('''
collections:
  todos:
    fields:
      title: text
''', 'shared');
  });

  test('declaring id is rejected', () {
    expectParseError('''
collections:
  todos:
    shared: true
    fields:
      id: text
''', 'managed automatically');
  });

  test('unknown collection lookup lists known ones', () {
    final schema = parseSchemaYaml('''
collections:
  todos:
    shared: true
    fields:
      title: text
''');
    expect(
      () => schema.collection('missing'),
      throwsA(isA<UnknownCollectionException>()
          .having((e) => e.hint, 'hint', contains('todos'))),
    );
  });
}
