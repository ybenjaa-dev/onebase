import 'package:flutter_test/flutter_test.dart';
import 'package:onebase/src/cli/generate_dart_schema.dart';
import 'package:onebase/src/schema/schema.dart';
import 'package:onebase/src/schema/schema_parser.dart';

void main() {
  final schema = parseSchemaYaml('''
collections:
  todos:
    owner_field: owner_id
    fields:
      title: text!
      done: bool!
      due_at: datetime
      score: double
      meta: json
      owner_id: text
  categories:
    shared: true
    fields:
      name: text!
  people:
    model: Person
    shared: true
    fields:
      full_name: text
''');

  final generated = generateDartSchema(schema);

  group('model naming', () {
    test('singularizes the collection name', () {
      expect(MongoCollectionSchema.modelNameFor('todos'), 'Todo');
      expect(MongoCollectionSchema.modelNameFor('categories'), 'Category');
      expect(MongoCollectionSchema.modelNameFor('boxes'), 'Box');
      expect(
        MongoCollectionSchema.modelNameFor('user_profiles'),
        'UserProfile',
      );
      expect(MongoCollectionSchema.modelNameFor('address'), 'Address');
    });

    test('an explicit model name wins', () {
      expect(schema.collection('people').model, 'Person');
      expect(generated, contains('class Person {'));
    });
  });

  group('generated models', () {
    test('emits one class per collection', () {
      expect(generated, contains('class Todo {'));
      expect(generated, contains('class Category {'));
    });

    test(
      'required fields are non-nullable and required in the constructor',
      () {
        expect(generated, contains('final String title;'));
        expect(generated, contains('final bool done;'));
        expect(generated, contains('required this.title,'));
        expect(generated, contains('required this.done,'));
      },
    );

    test('optional fields are nullable and optional', () {
      expect(generated, contains('final DateTime? dueAt;'));
      expect(generated, contains('final double? score;'));
      expect(generated, contains('this.dueAt,'));
    });

    test('snake_case fields become lowerCamelCase', () {
      expect(generated, contains('dueAt'));
      expect(generated, contains('ownerId'));
      expect(generated, contains("json['owner_id']"));
      expect(generated, contains("'owner_id': ownerId"));
    });

    test('id defaults to empty so a new model needs no id', () {
      expect(generated, contains("this.id = '',"));
      expect(generated, contains("if (id.isNotEmpty) 'id': id,"));
    });

    test('a missing required field fails loudly rather than silently', () {
      expect(generated, contains("_missing('title')"));
      expect(generated, contains('Never _missing(String field)'));
    });

    test('double is read through num, since SQLite may return an int', () {
      expect(generated, contains("(json['score'] as num?)?.toDouble()"));
    });

    test('json fields stay dynamic instead of a wrong cast', () {
      expect(generated, contains('final Object? meta;'));
      expect(generated, contains("meta: json['meta'],"));
    });

    test('emits copyWith, equality and toString', () {
      expect(generated, contains('Todo copyWith({'));
      expect(generated, contains('bool operator ==(Object other)'));
      expect(generated, contains('int get hashCode'));
      expect(generated, contains('String toString()'));
    });
  });

  group('typed accessors', () {
    test('exposes one per collection, already converted', () {
      expect(generated, contains('abstract final class OnebaseDb {'));
      expect(generated, contains('static TypedCollection<Todo> get todos =>'));
      expect(
        generated,
        contains('static TypedCollection<Category> get categories =>'),
      );
      expect(generated, contains('fromJson: Todo.fromJson,'));
    });
  });

  test('the helper is omitted when nothing is required', () {
    final relaxed = parseSchemaYaml('''
collections:
  notes:
    shared: true
    fields:
      body: text
''');
    expect(generateDartSchema(relaxed), isNot(contains('Never _missing')));
  });

  test('the schema literal round-trips required fields and model names', () {
    expect(generated, contains("requiredFields: {'title', 'done'}"));
    expect(generated, contains("model: 'Todo',"));
  });
}
