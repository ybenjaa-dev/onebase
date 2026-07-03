import 'package:powersync/powersync.dart' as ps;

import '../schema/schema.dart';

extension CollectionSchemaToPowerSync on MongoCollectionSchema {
  ps.Table toPowerSyncTable() {
    return ps.Table(name, [
      for (final MapEntry(key: field, value: type) in fields.entries)
        switch (type) {
          MongoFieldType.int || MongoFieldType.bool => ps.Column.integer(field),
          MongoFieldType.double => ps.Column.real(field),
          MongoFieldType.text ||
          MongoFieldType.datetime ||
          MongoFieldType.json =>
            ps.Column.text(field),
        },
    ]);
  }
}

extension SchemaToPowerSync on MongoEasySchema {
  ps.Schema toPowerSyncSchema() {
    return ps.Schema([
      for (final collection in collections.values)
        collection.toPowerSyncTable(),
    ]);
  }
}
