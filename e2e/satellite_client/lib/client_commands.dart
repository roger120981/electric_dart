import 'dart:convert';
import 'dart:io';

import 'package:collection/collection.dart';
import 'package:drift/drift.dart';
import 'package:drift_postgres/drift_postgres.dart';
import 'package:electricsql/electricsql.dart';
import 'package:electricsql/migrators.dart';
import 'package:electricsql/satellite.dart';
import 'package:electricsql/util.dart';
import 'package:postgres/postgres.dart' as pg;
import 'package:satellite_dart_client/drift/database.dart';
import 'package:electricsql/drivers/drift.dart';
import 'package:drift/native.dart';
import 'package:satellite_dart_client/generated/electric/drift_schema.dart';
import 'package:satellite_dart_client/util/json.dart';
import 'package:satellite_dart_client/util/pretty_output.dart';

late String dbName;

final QueryBuilder builder =
    dialect() == Dialect.postgres ? kPostgresQueryBuilder : kSqliteQueryBuilder;
int? tokenExpirationMillis;

Dialect dialect() {
  final dialectEnv = Platform.environment['DIALECT'];
  switch (dialectEnv) {
    case 'Postgres':
      return Dialect.postgres;
    case 'SQLite':
    case '':
    case null:
      return Dialect.sqlite;
    default:
      throw Exception('Unrecognised dialect: $dialectEnv');
  }
}

typedef MyDriftElectricClient = ElectricClient<ClientDatabase>;

Future<ClientDatabase> makeDb(String name) async {
  dbName = name;
  final dialectEnv = Platform.environment['DIALECT'];
  print("DIALECT: $dialectEnv");

  ClientDatabase db;
  if (dialect() == Dialect.postgres) {
    final endpoint = makePgEndpoint(name);
    db = ClientDatabase(
      PgDatabase(
        endpoint: endpoint,
        settings: pg.ConnectionSettings(sslMode: pg.SslMode.disable),
        enableMigrations: false,
      ),
    );
    dbName = '${endpoint.host}:${endpoint.port}/${endpoint.database}';
  } else {
    db = ClientDatabase(NativeDatabase(File(name)));
    await db.customSelect('PRAGMA foreign_keys = ON;').get();
  }
  return db;
}

pg.Endpoint makePgEndpoint(String dbName) {
  return pg.Endpoint(
    host: 'pg_1',
    database: dbName,
    username: 'postgres',
    password: 'password',
  );
}

Future<MyDriftElectricClient> electrifyDb(
  ClientDatabase db,
  String host,
  int port,
  List<dynamic> migrationsJ,
  bool connectToElectric,
) async {
  final config = ElectricConfig(
    url: "electric://$host:$port",
    logger: LoggerConfig(level: Level.debug, colored: false),
  );
  print("(in electrify_db) config: ${electricConfigToJson(config)}");

  final migrations = migrationsFromJson(migrationsJ);

  final List<Migration> sqliteMigrations;
  final List<Migration> pgMigrations;
  if (builder.dialect == Dialect.postgres) {
    sqliteMigrations = [];
    pgMigrations = migrations;
  } else {
    sqliteMigrations = migrations;
    pgMigrations = [];
  }

  final electric = await electrify<ClientDatabase>(
    dbName: dbName,
    db: db,
    migrations: ElectricMigrations(
      sqliteMigrations: sqliteMigrations,
      pgMigrations: pgMigrations,
    ),
    config: config,
  );

  final Duration? exp = tokenExpirationMillis != null
      ? Duration(milliseconds: tokenExpirationMillis!)
      : null;
  final token = await mockSecureAuthToken(exp: exp);

  electric.notifier.subscribeToConnectivityStateChanges((x) =>
      print('Connectivity state changed: ${x.connectivityState.status.name}'));
  if (connectToElectric) {
    await electric.connect(token); // connect to Electric
  }

  return electric;
}

// reconnects with Electric, e.g. after expiration of the JWT
Future<void> reconnect(ElectricClient electric, Duration? exp) async {
  final token = await mockSecureAuthToken(exp: exp);
  await electric.connect(token);
}

Future<void> checkTokenExpiration(
    ElectricClient electric, int minimalTime) async {
  final start = DateTime.now().millisecondsSinceEpoch;
  late void Function() unsubscribe;
  unsubscribe = electric.notifier.subscribeToConnectivityStateChanges((x) {
    if (x.connectivityState.status == ConnectivityStatus.disconnected &&
        x.connectivityState.reason?.code == SatelliteErrorCode.authExpired) {
      final delta = DateTime.now().millisecondsSinceEpoch - start;
      if (delta >= minimalTime) {
        print('JWT expired after $delta ms');
      } else {
        print('JWT expired too early, after only $delta ms');
      }
      unsubscribe();
    }
  });
}

void setSubscribers(DriftElectricClient db) {
  db.notifier.subscribeToAuthStateChanges((x) {
    print('auth state changes: ');
    print(x);
  });
  db.notifier.subscribeToPotentialDataChanges((x) {
    print('potential data change: ');
    print(x);
  });
  db.notifier.subscribeToDataChanges((x) {
    print('data changes: ');
    print(x.toMap());
  });
}

Future<void> syncItemsTable(
    MyDriftElectricClient electric, String shapeFilter) async {
  final subs = await electric.syncTable(
    electric.db.items,
    where: (_) => CustomExpression<bool>(shapeFilter),
  );
  return await subs.synced;
}

Future<void> syncOtherItemsTable(
    MyDriftElectricClient electric, String shapeFilter) async {
  final subs = await electric.syncTable(
    electric.db.otherItems,
    where: (_) => CustomExpression<bool>(shapeFilter),
  );
  return await subs.synced;
}

Future<void> syncTable(String table) async {
  final satellite = globalRegistry.satellites[dbName]!;
  final subs = await satellite.subscribe([Shape(tablename: table)]);
  return await subs.synced;
}

Future<void> lowLevelSubscribe(
  MyDriftElectricClient electric,
  Shape shape,
) async {
  final ShapeSubscription(:synced) = await electric.satellite.subscribe(
    [shape],
  );
  return await synced;
}

Future<Rows> getTables(DriftElectricClient electric) async {
  final rows = await electric.adapter.query(builder.getLocalTableNames());
  return Rows(rows);
}

Future<Rows> getColumns(DriftElectricClient electric, String table) async {
  final namespace = builder.defaultNamespace;
  final qualifiedTablename = QualifiedTablename(namespace, table);
  final rows = await electric.adapter.query(
    builder.getTableInfo(qualifiedTablename),
  );
  return Rows(rows);
}

Future<Rows> getRows(DriftElectricClient electric, String table) async {
  final rows = await electric.db
      .customSelect(
        'SELECT * FROM "$table";',
      )
      .get();
  return _toRows(rows);
}

Future<void> getTimestamps(MyDriftElectricClient electric) async {
  throw UnimplementedError();
  //await electric.db.timestamps.findMany();
}

Future<void> writeTimestamp(
    MyDriftElectricClient electric, Map<String, Object?> timestampMap) async {
  final companion = TimestampsCompanion.insert(
    id: timestampMap['id'] as String,
    createdAt: DateTime.parse(timestampMap['created_at'] as String),
    updatedAt: DateTime.parse(timestampMap['updated_at'] as String),
  );
  await electric.db.timestamps.insert().insert(companion);
}

Future<void> writeDatetime(
    MyDriftElectricClient electric, Map<String, Object?> datetimeMap) async {
  final companion = DatetimesCompanion.insert(
    id: datetimeMap['id'] as String,
    d: DateTime.parse(datetimeMap['d'] as String),
    t: DateTime.parse(datetimeMap['t'] as String),
  );
  await electric.db.datetimes.insert().insert(companion);
}

Future<Timestamp?> getTimestamp(
    MyDriftElectricClient electric, String id) async {
  final timestamp = await (electric.db.timestamps.select()
        ..where((tbl) => tbl.id.equals(id)))
      .getSingleOrNull();
  return timestamp;
}

Future<Datetime?> getDatetime(MyDriftElectricClient electric, String id) async {
  final datetime = await (electric.db.datetimes.select()
        ..where((tbl) => tbl.id.equals(id)))
      .getSingleOrNull();

  final rowJ = JsonEncoder.withIndent('  ')
      .convert(toColumns(datetime)?.map((key, value) {
    final Object? effectiveValue;
    if (value is DateTime) {
      effectiveValue = value.toIso8601String();
    } else {
      effectiveValue = value;
    }
    return MapEntry(key, effectiveValue);
  }));
  print('Found date time?:\n$rowJ');

  return datetime;
}

Future<bool> assertTimestamp(MyDriftElectricClient electric, String id,
    String expectedCreatedAt, String expectedUpdatedAt) async {
  final timestamp = await getTimestamp(electric, id);
  final matches =
      checkTimestamp(timestamp, expectedCreatedAt, expectedUpdatedAt);
  return matches;
}

Future<bool> assertDatetime(MyDriftElectricClient electric, String id,
    String expectedDate, String expectedTime) async {
  final datetime = await getDatetime(electric, id);
  final matches = checkDatetime(datetime, expectedDate, expectedTime);
  return matches;
}

bool checkTimestamp(
    Timestamp? timestamp, String expectedCreatedAt, String expectedUpdatedAt) {
  if (timestamp == null) return false;

  return timestamp.createdAt.millisecondsSinceEpoch ==
          DateTime.parse(expectedCreatedAt).millisecondsSinceEpoch &&
      timestamp.updatedAt.millisecondsSinceEpoch ==
          DateTime.parse(expectedUpdatedAt).millisecondsSinceEpoch;
}

bool checkDatetime(
    Datetime? datetime, String expectedDate, String expectedTime) {
  if (datetime == null) return false;
  return datetime.d.millisecondsSinceEpoch ==
          DateTime.parse(expectedDate).millisecondsSinceEpoch &&
      datetime.t.millisecondsSinceEpoch ==
          DateTime.parse(expectedTime).millisecondsSinceEpoch;
}

Future<SingleRow> writeBool(
    MyDriftElectricClient electric, String id, bool b) async {
  final row = await electric.db.bools.insertReturning(
    BoolsCompanion.insert(
      id: id,
      b: Value(b),
    ),
  );
  return SingleRow.fromItem(row);
}

Future<bool?> getBool(MyDriftElectricClient electric, String id) async {
  final row = await (electric.db.bools.select()..where((t) => t.id.equals(id)))
      .getSingle();
  return row.b;
}

Future<void> getDatetimes(MyDriftElectricClient electric) async {
  // final rows = await electric.db.datetimes.select().get();
  throw UnimplementedError();
}

Future<Rows> getItems(MyDriftElectricClient electric) async {
  final rows = await electric.db
      .customSelect(
        'SELECT * FROM "items";',
      )
      .get();
  return _toRows(rows);
}

Future<Rows> getItemIds(MyDriftElectricClient electric) async {
  final rows = await electric.db
      .customSelect(
        'SELECT id FROM "items";',
      )
      .get();
  return _toRows(rows);
}

Future<bool> existsItemWithContent(
    MyDriftElectricClient electric, String content) async {
  final items = await electric.db.select(electric.db.items).get();
  final Item? item = items.cast<Item?>().firstWhere(
        (item) => item!.content == content,
        orElse: () => null,
      );
  return item != null;
}

Future<SingleRow> getUUID(MyDriftElectricClient electric, String id) async {
  final row = await (electric.db.uuids.select()..where((t) => t.id.equals(id)))
      .getSingle();
  return SingleRow.fromItem(row);
}

Future<Rows> getUUIDs(MyDriftElectricClient electric) async {
  final rows = await electric.db
      .customSelect(
        'SELECT * FROM "Uuids";',
      )
      .get();
  return _toRows(rows);
}

Future<SingleRow> writeUUID(MyDriftElectricClient electric, String id) async {
  final item = await electric.db.uuids.insertReturning(
    UuidsCompanion.insert(
      id: id,
    ),
  );
  return SingleRow.fromItem(item);
}

Future<SingleRow> getInt(MyDriftElectricClient electric, String id) async {
  final item = await (electric.db.ints.select()..where((t) => t.id.equals(id)))
      .getSingle();
  return SingleRow.fromItem(item);
}

Future<SingleRow> writeInt(MyDriftElectricClient electric, String id, int? i2,
    int? i4, BigInt? i8) async {
  try {
    final item = await electric.db.ints.insertReturning(
      IntsCompanion.insert(
        id: id,
        i2: Value(i2),
        i4: Value(i4),
        i8: Value(i8),
      ),
    );
    return SingleRow.fromItem(item);
  } catch (e) {
    final eStr = e.toString();
    if (eStr
        .contains("Invalid argument (this): Should be in signed 64bit range")) {
      throw Exception("BigInt value exceeds the range of 64 bits");
    }
    rethrow;
  }
}

Future<SingleRow> getFloat(MyDriftElectricClient electric, String id) async {
  final item = await (electric.db.floats.select()
        ..where((t) => t.id.equals(id)))
      .getSingle();
  return SingleRow.fromItem(item);
}

Future<SingleRow> writeFloat(
    MyDriftElectricClient electric, String id, double f4, double f8) async {
  final item = await electric.db.floats.insertReturning(
    FloatsCompanion.insert(
      id: id,
      f4: Value(f4),
      f8: Value(f8),
    ),
  );
  return SingleRow.fromItem(item);
}

Future<String?> getJsonRaw(MyDriftElectricClient electric, String id) async {
  final res = await electric.db.customSelect(
    'SELECT js FROM jsons WHERE id = ${builder.makePositionalParam(1)};',
    variables: [Variable(id)],
  ).get();
  return res[0].read<String?>('js');
}

Future<String?> getJsonbRaw(MyDriftElectricClient electric, String id) async {
  final res = await electric.db.customSelect(
    'SELECT jsb FROM jsons WHERE id = ${builder.makePositionalParam(1)};',
    variables: [Variable(id)],
  ).get();

  final Object? j = res[0].data['jsb'];

  final Object? effectiveJ;
  if (builder.dialect == Dialect.postgres) {
    // Postgres stores JSON so we just use that one
    effectiveJ = j;
  } else {
    final jStr = j as String;
    effectiveJ = jsonDecode(jStr);
  }
  return valueToPrettyStr(effectiveJ);
}

Future<SingleRow> getJson(MyDriftElectricClient electric, String id) async {
  final item = await (electric.db.jsons.select()..where((t) => t.id.equals(id)))
      .getSingle();
  final cols = toColumns(item)!;
  cols.remove('jsb');
  return SingleRow.fromColumns(cols);
}

Future<SingleRow> getJsonb(MyDriftElectricClient electric, String id) async {
  final item = await (electric.db.jsons.select()..where((t) => t.id.equals(id)))
      .getSingle();
  final cols = toColumns(item)!;
  cols.remove('js');
  return SingleRow.fromColumns(cols);
}

Future<SingleRow> writeJson(
    MyDriftElectricClient electric, String id, Object? jsb) async {
  final item = await electric.db.jsons.insertReturning(
    JsonsCompanion.insert(
      id: id,
      jsb: Value(jsb),
    ),
  );
  return SingleRow.fromItem(item);
}

Future<SingleRow> getEnum(MyDriftElectricClient electric, String id) async {
  final item = await (electric.db.enums.select()..where((t) => t.id.equals(id)))
      .getSingle();
  return _enumClassToRawRow(item);
}

Future<SingleRow> writeEnum(
    MyDriftElectricClient electric, String id, String? enumStr) async {
  final enumValue =
      enumStr == null ? null : ElectricEnumCodecs.color.decode(enumStr);

  final item = await electric.db.enums.insertReturning(
    EnumsCompanion.insert(
      id: id,
      c: Value(enumValue),
    ),
  );

  return _enumClassToRawRow(item);
}

// Converts the dart enum into string for the Lux expected output
SingleRow _enumClassToRawRow(Enum item) {
  final driftCols = toColumns(item)!;
  final colorEnum = driftCols['c'] as DbColor?;
  if (colorEnum != null) {
    driftCols['c'] = ElectricEnumCodecs.color.encode(colorEnum);
  }

  return SingleRow(driftCols);
}

Future<SingleRow> getBlob(MyDriftElectricClient electric, String id) async {
  final item = await (electric.db.blobs.select()..where((t) => t.id.equals(id)))
      .getSingle();
  return SingleRow.fromItem(item);
}

Future<SingleRow> writeBlob(
    MyDriftElectricClient electric, String id, List<int>? blob) async {
  final item = await electric.db.blobs.insertReturning(
    BlobsCompanion.insert(
      id: id,
      blob$: Value(blob == null ? null : Uint8List.fromList(blob)),
    ),
  );
  return SingleRow.fromItem(item);
}

Future<Rows> getItemColumns(
    MyDriftElectricClient electric, String table, String column) async {
  final rows = await electric.db
      .customSelect(
        'SELECT $column FROM "$table";',
      )
      .get();
  return _toRows(rows);
}

Future<void> insertItem(
    MyDriftElectricClient electric, List<String> keys) async {
  await electric.db.transaction(() async {
    for (final key in keys) {
      await electric.db.customStatement(
        'INSERT INTO "items"(id, content) VALUES (${builder.makePositionalParam(1)}, ${builder.makePositionalParam(2)});',
        _createRawArgs([genUUID(), key]),
      );
    }
  });
}

Future<void> insertExtendedItem(
  MyDriftElectricClient electric,
  Map<String, Object?> values,
) async {
  insertExtendedInto(electric, "items", values);
}

Future<void> insertExtendedInto(
  MyDriftElectricClient electric,
  String table,
  Map<String, Object?> values,
) async {
  final fixedColumns = <String, Object? Function()>{
    "id": genUUID,
  };

  final colToVal = <String, Object?>{
    ...Map.fromEntries(
      fixedColumns.entries.map((e) => MapEntry(e.key, e.value())),
    ),
    ...values,
  };

  final columns = colToVal.keys.toList();
  final columnNames = columns.join(", ");
  final placeholders = columns
      .mapIndexed((i, _) => builder.makePositionalParam(i + 1))
      .join(", ");

  final args = colToVal.values.toList();

  await electric.db.customStatement(
    'INSERT INTO "$table"($columnNames) VALUES ($placeholders) RETURNING *;',
    _createRawArgs(args),
  );
}

Future<void> deleteItem(
  MyDriftElectricClient electric,
  List<String> keys,
) async {
  for (final key in keys) {
    await electric.db.customUpdate(
      'DELETE FROM "items" WHERE content = ${builder.makePositionalParam(1)};',
      variables: [Variable.withString(key)],
    );
  }
}

Future<Rows> getOtherItems(MyDriftElectricClient electric) async {
  final rows = await electric.db
      .customSelect(
        'SELECT * FROM "other_items";',
      )
      .get();
  return _toRows(rows);
}

Future<void> insertOtherItem(
    MyDriftElectricClient electric, List<String> keys) async {
  await electric.db.transaction(() async {
    for (final key in keys) {
      await electric.db.customStatement(
        'INSERT INTO "other_items"(id, content) VALUES (${builder.makePositionalParam(1)}, ${builder.makePositionalParam(2)});',
        _createRawArgs([genUUID(), key]),
      );
    }
  });
}

void setItemReplicatonTransform(MyDriftElectricClient electric) {
  electric.setTableReplicationTransform(
    electric.db.items,
    transformOutbound: (item) {
      final newContent = item.content
          .split('')
          .map((char) => String.fromCharCode(char.codeUnitAt(0) + 1))
          .join('');
      return item.copyWith(content: newContent);
    },
    transformInbound: (item) {
      final newContent = item.content
          .split('')
          .map((char) => String.fromCharCode(char.codeUnitAt(0) - 1))
          .join('');
      return item.copyWith(content: newContent);
    },
  );
}

Future<void> stop(MyDriftElectricClient db) async {
  await globalRegistry.stopAll();
}

Future<void> rawStatement(MyDriftElectricClient db, String statement) async {
  await db.db.customStatement(statement);
}

void setTokenExpirationMillis(int millis) {
  tokenExpirationMillis = millis;
}

void connect(MyDriftElectricClient db) {
  db.connect();
}

void disconnect(MyDriftElectricClient db) {
  db.disconnect();
}

Future<void> custom0325SyncItems(MyDriftElectricClient electric) async {
  final subs = await electric.syncTable(
    electric.db.items,
    where: (items) => items.content.like('items-_-'),
    include: (items) => [SyncInputRelation.from(items.$relations.otherItems)],
  );

  await subs.synced;
}

/////////////////////////////////

/// On postgres, let the type inference do its job,
/// instead of doing strict casts via drift_postgres
/// https://github.com/simolus3/drift/issues/2986
List<Object?> _createRawArgs(List<Object?> args) {
  if (builder.dialect == Dialect.postgres) {
    // Allow Postgres to infer the types
    return args.map((arg) => pg.TypedValue(pg.Type.unspecified, arg)).toList();
  } else {
    return args;
  }
}

// It has a custom toString to match Lux expects
Rows _toRows(List<QueryRow> rows) {
  return Rows(
    rows.map((r) {
      final data = r.data;
      return data;
    }).toList(),
  );
}

List<Variable> dynamicArgsToVariables(List<Object?>? args) {
  return (args ?? const [])
      .map((Object? arg) {
        if (arg == null) {
          return const Variable<Object>(null);
        }
        if (arg is bool) {
          return Variable.withBool(arg);
        } else if (arg is int) {
          return Variable.withInt(arg);
        } else if (arg is String) {
          return Variable.withString(arg);
        } else if (arg is double) {
          return Variable.withReal(arg);
        } else if (arg is DateTime) {
          return Variable.withDateTime(arg);
        } else if (arg is Uint8List) {
          return Variable.withBlob(arg);
        } else if (arg is Variable) {
          return arg;
        } else {
          assert(false, 'unknown type $arg');
          return Variable<Object>(arg);
        }
      })
      .cast<Variable>()
      .toList();
}

class Rows {
  final List<Map<String, Object?>> rows;

  Rows(this.rows);

  @override
  String toString() {
    return listToPrettyStr(rows, withNewLine: true);
  }
}

class SingleRow {
  final Map<String, Object?> row;

  SingleRow(this.row);

  factory SingleRow.fromItem(Insertable item) {
    return SingleRow(toColumns(item)!);
  }

  factory SingleRow.fromColumns(Map<String, Object?> cols) {
    return SingleRow(cols);
  }

  @override
  String toString() {
    return mapToPrettyStr(row);
  }
}

Map<String, Object?>? toColumns(Insertable? o) {
  if (o == null) return null;
  final cols = o.toColumns(false);
  return cols.map((key, value) => MapEntry(key, (value as Variable).value));
}
