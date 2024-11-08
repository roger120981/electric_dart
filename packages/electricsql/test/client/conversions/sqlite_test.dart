import 'dart:convert';
import 'dart:math';

import 'package:collection/collection.dart';
import 'package:drift/drift.dart';
import 'package:electricsql/src/util/converters/codecs/json.dart';
import 'package:test/test.dart';

import '../drift/client_test_util.dart';
import '../drift/database.dart';

void main() async {
  final db = TestsDatabase.memory();

  await electrifyTestDatabase(db);

  setUp(() async {
    await initClientTestsDb(db);
  });

  /*
 * The tests below check that JS values are correctly converted to SQLite values
 * based on the original PG type of that value.
 * e.g. PG `timestamptz` values are represented as `Date` objects in JS
 *      and are converted to ISO-8601 strings that are stored in SQLite.
 */

  test('date is converted correctly to SQLite', () async {
    const date = '2023-09-13';
    final d = DateTime.parse('${date}T23:33:04.271');
    await db.into(db.dataTypes).insert(
          DataTypesCompanion.insert(
            id: 1,
            date: Value(d),
          ),
        );

    final rawRes = await db.customSelect(
      'SELECT date FROM DataTypes WHERE id = ?',
      variables: [const Variable(1)],
    ).get();
    expect(rawRes[0].read<String>('date'), date);
  });

  test('time is converted correctly to SQLite', () async {
    // Check that we store the time without taking into account timezones
    // test with 2 different time zones such that they cannot both coincide with the machine's timezone
    final date = DateTime.parse('2023-08-07 18:28:35.421');
    await db.into(db.dataTypes).insert(
          DataTypesCompanion.insert(
            id: 1,
            time: Value(date),
          ),
        );

    final rawRes = await db.customSelect(
      'SELECT time FROM DataTypes WHERE id = ?',
      variables: [const Variable(1)],
    ).get();
    expect(rawRes[0].read<String>('time'), '18:28:35.421');
  });

  test('timetz is converted correctly to SQLite', () async {
    final date1 = DateTime.parse('2023-08-07 18:28:35.421+02');
    final date2 = DateTime.parse('2023-08-07 18:28:35.421+03');

    await db.dataTypes.insertAll([
      DataTypesCompanion.insert(
        id: 1,
        timetz: Value(date1),
      ),
      DataTypesCompanion.insert(
        id: 2,
        timetz: Value(date2),
      ),
    ]);

    final rawRes1 = await db.customSelect(
      'SELECT timetz FROM DataTypes WHERE id = ?',
      variables: [const Variable(1)],
    ).get();
    expect(
      rawRes1[0].read<String>('timetz'),
      '16:28:35.421',
    ); // time must have been converted to UTC time

    final rawRes2 = await db.customSelect(
      'SELECT timetz FROM DataTypes WHERE id = ?',
      variables: [const Variable(2)],
    ).get();
    expect(rawRes2[0].read<String>('timetz'), '15:28:35.421');
  });

  test('timestamp is converted correctly to SQLite', () async {
    final date = DateTime.parse('2023-08-07 18:28:35.421');
    expect(date.isUtc, isFalse);

    await db.into(db.dataTypes).insert(
          DataTypesCompanion.insert(
            id: 1,
            timestamp: Value(date),
          ),
        );

    final rawRes = await db.customSelect(
      'SELECT timestamp FROM DataTypes WHERE id = ?',
      variables: [const Variable(1)],
    ).get();
    expect(
      rawRes[0].read<String>('timestamp'),
      '2023-08-07 18:28:35.421',
    ); // time must have been converted to UTC time
  });

  test('timestamp is converted correctly to SQLite - input date utc', () async {
    // 2023-08-07 18:28:35.421 UTC
    final dateUTC = DateTime.utc(2023, 8, 7, 18, 28, 35, 421);
    expect(dateUTC.isUtc, isTrue);

    // The date is stored as String, without the T and Z characters
    const expectedLocalStr = '2023-08-07 18:28:35.421';

    await db.into(db.dataTypes).insert(
          DataTypesCompanion.insert(
            id: 1,
            timestamp: Value(dateUTC),
          ),
        );

    final rawRes = await db.customSelect(
      'SELECT timestamp FROM DataTypes WHERE id = ?',
      variables: [const Variable(1)],
    ).get();

    expect(
      rawRes[0].read<String>('timestamp'),
      expectedLocalStr,
    );
  });

  test('timestamptz is converted correctly to SQLite', () async {
    final date1 = DateTime.parse('2023-08-07 18:28:35.421+02');
    final date2 = DateTime.parse('2023-08-07 18:28:35.421+03');

    await db.dataTypes.insertAll([
      DataTypesCompanion.insert(
        id: 1,
        timestamptz: Value(date1),
      ),
      DataTypesCompanion.insert(
        id: 2,
        timestamptz: Value(date2),
      ),
    ]);

    final rawRes1 = await db.customSelect(
      'SELECT timestamptz FROM DataTypes WHERE id = ?',
      variables: [const Variable(1)],
    ).get();
    expect(
      rawRes1[0].read<String>('timestamptz'),
      '2023-08-07 16:28:35.421Z',
    ); // timestamp must have been converted to UTC timestamp

    final rawRes2 = await db.customSelect(
      'SELECT timestamptz FROM DataTypes WHERE id = ?',
      variables: [const Variable(2)],
    ).get();
    expect(rawRes2[0].read<String>('timestamptz'), '2023-08-07 15:28:35.421Z');
  });

  test('booleans are converted correctly to SQLite', () async {
    await db.dataTypes.insertAll([
      DataTypesCompanion.insert(
        id: 1,
        bool$: const Value(true),
      ),
      DataTypesCompanion.insert(
        id: 2,
        bool$: const Value(false),
      ),
    ]);

    final rawRes = await db.customSelect(
      'SELECT id, bool FROM DataTypes ORDER BY id ASC',
      variables: [],
    ).get();

    final row1 = rawRes[0].data;
    expect(row1['id'], 1);
    expect(row1['bool'], 1);

    final row2 = rawRes[1].data;
    expect(row2['id'], 2);
    expect(row2['bool'], 0);
  });

  test('floats are converted correctly to SQLite', () async {
    final List<(int id, double float4, double float8)> values = [
      (1, 1.234, 1.234),
      (2, double.nan, double.nan),
      (3, double.infinity, double.infinity),
      (4, double.negativeInfinity, double.negativeInfinity),
    ];

    for (final entry in values) {
      final (id, f4, f8) = entry;
      await db.into(db.dataTypes).insert(
            DataTypesCompanion.insert(
              id: id,
              float4: Value(f4),
              float8: Value(f8),
            ),
          );
    }

    final rawRes = await db.customSelect(
      'SELECT id, float4, float8 FROM DataTypes ORDER BY id ASC',
      variables: [],
    ).get();

    final List<(int id, Object float4, Object float8)> expected = [
      // 1.234 cannot be stored exactly in a float4
      // hence, there is a rounding error, which is observed when we
      // read the float4 value back into a 64-bit JS number
      // The value 1.2339999675750732 that we read back
      // is also what Math.fround(1.234) returns
      // as being the nearest 32-bit single precision
      // floating point representation of 1.234
      (1, 1.2339999675750732, 1.234),
      (2, 'NaN', 'NaN'),
      (3, double.infinity, double.infinity),
      (4, double.negativeInfinity, double.negativeInfinity),
    ];

    final List<(int id, Object float4, Object float8)> rowsRecords =
        rawRes.map((row) {
      final data = row.data;
      final id = data['id'] as int;
      final Object float4 = data['float4'] as Object;
      final Object float8 = data['float8'] as Object;
      return (id, float4, float8);
    }).toList();

    expect(rowsRecords, expected);
  });

  test('Int8s are converted correctly to SQLite', () async {
    const int8 = 9223372036854775807;

    await db.into(db.dataTypes).insert(
          DataTypesCompanion.insert(
            id: 1,
            int8: const Value(int8),
          ),
        );

    final rawRes = await db.customSelect(
      'SELECT id, int8 FROM DataTypes WHERE id = ?',
      variables: [const Variable(1)],
    ).get();

    final row = rawRes[0].data;
    expect(row['id'], 1);
    expect(row['int8'], int8);
  });

  test('BigInts are converted correctly to SQLite', () async {
    final bigInt = BigInt.parse('9223372036854775807');

    await db.into(db.extra).insert(
          ExtraCompanion.insert(
            id: const Value(1),
            int8BigInt: Value(bigInt),
          ),
        );

    final rawRes = await db.customSelect(
      'SELECT id, int8_big_int FROM Extra WHERE id = ?',
      variables: [const Variable(1)],
    ).get();

    // because we are executing a raw query,
    // the returned BigInt for the `id`
    // is not converted into a regular number
    final row = rawRes[0].data;
    expect(row['id'], 1);
    expect((row['int8_big_int'] as int).toString(), bigInt.toString());
  });

  test('drift files serialization/deserialization', () async {
    final date = DateTime.parse('2023-08-07 18:28:35.421+02');

    final res = await db.tableFromDriftFile.insertReturning(
      TableFromDriftFileCompanion.insert(
        id: 'abc',
        timestamp: date,
      ),
    );

    expect(res.timestamp, date);

    final rawRes1 = await db.customSelect(
      'SELECT timestamp FROM table_from_drift_file WHERE id = ?',
      variables: [const Variable('abc')],
    ).get();
    expect(
      rawRes1[0].read<String>('timestamp'),
      '2023-08-07 16:28:35.421Z',
    );
  });

  test('json is converted correctly to SQLite', () async {
    final json = {
      'a': 1,
      'b': true,
      'c': {'d': 'nested'},
      'e': [1, 2, 3],
      'f': null,
    };
    await db.into(db.dataTypes).insert(
          DataTypesCompanion.insert(
            id: 1,
            json: Value(json),
          ),
        );

    final rawRes = await db.customSelect(
      'SELECT json FROM DataTypes WHERE id = ?',
      variables: [const Variable(1)],
    ).get();

    expect(rawRes[0].read<String>('json'), jsonEncode(json));

    // Also test null values
    // this null value is not a JSON null
    // but a DB NULL that indicates absence of a value
    await db.into(db.dataTypes).insert(
          DataTypesCompanion.insert(
            id: 2,
            json: const Value(null),
          ),
        );

    final rawRes2 = await db.customSelect(
      'SELECT json FROM DataTypes WHERE id = ?',
      variables: [const Variable(2)],
    ).get();

    expect(rawRes2[0].read<String?>('json'), null);

    // Also test JSON null value
    await db.into(db.dataTypes).insert(
          DataTypesCompanion.insert(
            id: 3,
            json: const Value(kJsonNull),
          ),
        );

    final rawRes3 = await db.customSelect(
      'SELECT json FROM DataTypes WHERE id = ?',
      variables: [const Variable(3)],
    ).get();
    expect(rawRes3[0].read<String>('json'), 'null');
    expect(rawRes3[0].read<String>('json'), jsonEncode(null));

    // also test regular values
    await db.into(db.dataTypes).insert(
          DataTypesCompanion.insert(
            id: 4,
            json: const Value('foo'),
          ),
        );

    final rawRes4 = await db.customSelect(
      'SELECT json FROM DataTypes WHERE id = ?',
      variables: [const Variable(4)],
    ).get();
    expect(rawRes4[0].read<String>('json'), jsonEncode('foo'));

    // also test arrays
    await db.into(db.dataTypes).insert(
          DataTypesCompanion.insert(
            id: 5,
            json: const Value([1, 2, 3]),
          ),
        );

    final rawRes5 = await db.customSelect(
      'SELECT json FROM DataTypes WHERE id = ?',
      variables: [const Variable(5)],
    ).get();
    expect(rawRes5[0].read<String>('json'), jsonEncode([1, 2, 3]));
  });

  test('bytea is converted correctly to SQLite', () async {
    // inserting
    final bytea1 = Uint8List.fromList([1, 2, 3, 4]);
    await db.into(db.dataTypes).insert(
          DataTypesCompanion.insert(
            id: 1,
            bytea: Value(bytea1),
          ),
        );

    final rawRes1 = await db.customSelect(
      'SELECT bytea FROM DataTypes WHERE id = ?',
      variables: [const Variable(1)],
    ).get();
    expect(rawRes1[0].read<Uint8List>('bytea'), bytea1);

    // updating
    final bytea2 = Uint8List.fromList([1, 2, 3, 5]);
    await (db.update(db.dataTypes)..where((d) => d.id.equals(1))).write(
      DataTypesCompanion(
        bytea: Value(bytea2),
      ),
    );

    final rawRes2 = await db.customSelect(
      'SELECT bytea FROM DataTypes WHERE id = ?',
      variables: [const Variable(1)],
    ).get();
    expect(rawRes2[0].read<Uint8List>('bytea'), bytea2);

    // inserting null
    await db.into(db.dataTypes).insert(
          DataTypesCompanion.insert(
            id: 2,
            bytea: const Value(null),
          ),
        );

    final rawRes3 = await db.customSelect(
      'SELECT bytea FROM DataTypes WHERE id = ?',
      variables: [const Variable(2)],
    ).get();
    expect(rawRes3[0].read<Uint8List?>('bytea'), null);

    // inserting large buffer
    const sizeInBytes = 1000000;
    final bytea3 = Uint8List(sizeInBytes);
    final r = Random();
    bytea3.forEachIndexed((i, _) => bytea3[i] = r.nextInt(256));
    await db.into(db.dataTypes).insert(
          DataTypesCompanion.insert(
            id: 3,
            bytea: Value(bytea3),
          ),
        );

    final rawRes4 = await db.customSelect(
      'SELECT bytea FROM DataTypes WHERE id = ?',
      variables: [const Variable(3)],
    ).get();
    expect(rawRes4[0].read<Uint8List>('bytea'), bytea3);
  });
}
