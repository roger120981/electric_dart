import 'dart:math';

import 'package:electricsql/src/migrators/triggers.dart';
import 'package:electricsql/src/util/index.dart';

enum Dialect {
  sqlite,
  postgres;

  String get name => switch (this) {
        Dialect.sqlite => 'SQLite',
        Dialect.postgres => 'PostgreSQL',
      };
}

enum SqlOpType {
  insert('INSERT'),
  update('UPDATE'),
  delete('DELETE');

  final String text;

  const SqlOpType(this.text);
}

abstract class QueryBuilder {
  const QueryBuilder();

  abstract final Dialect dialect;
  abstract final String paramSign; // '?' | '$'
  abstract final String defaultNamespace; // 'main' | 'public'

  /// The autoincrementing integer primary key type for the current SQL dialect.
  abstract final String autoincrementPkType;

  /// The type to use for BLOB for the current SQL dialect.
  abstract final String blobType;

  /// Queries the version of SQLite/Postgres we are using.
  abstract final String getVersion;

  /// Depending on the dialect, defers or disables foreign key checks for the duration of the transaction.
  abstract final String deferOrDisableFKsForTx;

  /// Returns the given query if the current SQL dialect is PostgreSQL.
  String pgOnly(String query);

  /// Returns the given query if the current SQL dialect is SQLite.
  String sqliteOnly(String query);

  /// Makes the i-th positional parameter,
  /// e.g. '$3' For Postgres when `i` is 3
  ///      and always '?' for SQLite
  String makePositionalParam(int i);

  /// Checks if the given table exists.
  Statement tableExists(QualifiedTablename table);

  /// Counts tables whose name is included in `tableNames`.
  Statement countTablesIn(List<String> tableNames);

  /// Converts a column value to a hexidecimal string.
  String toHex(String column);

  /// Converts a hexidecimal string to a hex value.
  String hexValue(String hexString);

  /// Create an index on a table.
  String createIndex(
    String indexName,
    QualifiedTablename onTable,
    List<String> columns,
  );

  /// Fetches the names of all tables that are not in `notIn`.
  Statement getLocalTableNames([List<String> notIn = const []]);

  /// Fetches information about the columns of a table.
  /// The information includes all column names, their type,
  /// whether or not they are nullable, and whether they are part of the PK.
  Statement getTableInfo(QualifiedTablename table);

  /// Insert a row into a table, ignoring it if it already exists.
  Statement insertOrIgnore(
    QualifiedTablename table,
    List<String> columns,
    List<Object?> values,
  );

  /// Insert a row into a table, replacing it if it already exists.
  Statement insertOrReplace(
    QualifiedTablename table,
    List<String> columns,
    List<Object?> values,
    List<String> conflictCols,
    List<String> updateCols,
  );

  /// Insert a row into a table.
  /// If it already exists we update the provided columns `updateCols`
  /// with the provided values `updateVals`
  Statement insertOrReplaceWith(
    QualifiedTablename table,
    List<String> columns,
    List<Object?> values,
    List<String> conflictCols,
    List<String> updateCols,
    List<Object?> updateVals,
  );

  /// Inserts a batch of rows into a table, replacing them if they already exist.
  List<Statement> batchedInsertOrReplace(
    QualifiedTablename table,
    List<String> columns,
    List<Map<String, Object?>> records,
    List<String> conflictCols,
    List<String> updateCols,
    int maxSqlParameters,
  );

  /// Drop a trigger if it exists.
  String dropTriggerIfExists(
    String triggerName,
    QualifiedTablename table,
  );

  /// Create a trigger that prevents updates to the primary key.
  List<String> createNoFkUpdateTrigger(
    QualifiedTablename table,
    List<String> pk,
  );

  /// Creates or replaces a trigger that prevents updates to the primary key.
  List<String> createOrReplaceNoFkUpdateTrigger(
    QualifiedTablename table,
    List<String> pk,
  ) {
    return [
      dropTriggerIfExists(
        'update_ensure_${table.namespace}_${table.tablename}_primarykey',
        table,
      ),
      ...createNoFkUpdateTrigger(table, pk),
    ];
  }

  /// Modifies the trigger setting for the table identified by its tablename and namespace.
  String setTriggerSetting(QualifiedTablename table, int value);

  /// Create a trigger that logs operations into the oplog.
  List<String> createOplogTrigger(
    SqlOpType opType,
    QualifiedTablename table,
    String newPKs,
    String newRows,
    String oldRows,
  );

  List<String> createOrReplaceOplogTrigger(
    SqlOpType opType,
    QualifiedTablename table,
    String newPKs,
    String newRows,
    String oldRows,
  ) {
    final namespace = table.namespace;
    final tableName = table.tablename;

    return [
      dropTriggerIfExists(
        '${opType.text.toLowerCase()}_${namespace}_${tableName}_into_oplog',
        table,
      ),
      ...createOplogTrigger(
        opType,
        table,
        newPKs,
        newRows,
        oldRows,
      ),
    ];
  }

  /// Creates or replaces a trigger that logs insertions into the oplog.
  List<String> createOrReplaceInsertTrigger(
    QualifiedTablename table,
    String newPKs,
    String newRows,
    String oldRows,
  ) {
    return createOrReplaceOplogTrigger(
      SqlOpType.insert,
      table,
      newPKs,
      newRows,
      oldRows,
    );
  }

  /// Creates or replaces a trigger that logs updates into the oplog.
  List<String> createOrReplaceUpdateTrigger(
    QualifiedTablename table,
    String newPKs,
    String newRows,
    String oldRows,
  ) {
    return createOrReplaceOplogTrigger(
      SqlOpType.update,
      table,
      newPKs,
      newRows,
      oldRows,
    );
  }

  /// Creates or replaces a trigger that logs deletions into the oplog.
  List<String> createOrReplaceDeleteTrigger(
    QualifiedTablename table,
    String newPKs,
    String newRows,
    String oldRows,
  ) {
    return createOrReplaceOplogTrigger(
      SqlOpType.delete,
      table,
      newPKs,
      newRows,
      oldRows,
    );
  }

  /// Creates a trigger that logs compensations for operations into the oplog.
  List<String> createFkCompensationTrigger(
    String opType,
    QualifiedTablename table,
    String childKey,
    QualifiedTablename fkTable,
    String joinedFkPKs,
    ForeignKey foreignKey,
  );

  List<String> createOrReplaceFkCompensationTrigger(
    String opType,
    QualifiedTablename table,
    String childKey,
    QualifiedTablename fkTable,
    String joinedFkPKs,
    ForeignKey foreignKey,
  ) {
    return [
      dropTriggerIfExists(
        'compensation_${opType.toLowerCase()}_${table.namespace}_${table.tablename}_${childKey}_into_oplog',
        table,
      ),
      ...createFkCompensationTrigger(
        opType,
        table,
        childKey,
        fkTable,
        joinedFkPKs,
        foreignKey,
      ),
    ];
  }

  /// Creates a trigger that logs compensations for insertions into the oplog.
  List<String> createOrReplaceInsertCompensationTrigger(
    QualifiedTablename table,
    String childKey,
    QualifiedTablename fkTable,
    String joinedFkPKs,
    ForeignKey foreignKey,
  ) {
    return createOrReplaceFkCompensationTrigger(
      'INSERT',
      table,
      childKey,
      fkTable,
      joinedFkPKs,
      foreignKey,
    );
  }

  /// Creates a trigger that logs compensations for updates into the oplog.
  List<String> createOrReplaceUpdateCompensationTrigger(
    QualifiedTablename table,
    String childKey,
    QualifiedTablename fkTable,
    String joinedFkPKs,
    ForeignKey foreignKey,
  ) {
    return createOrReplaceFkCompensationTrigger(
      'UPDATE',
      table,
      childKey,
      fkTable,
      joinedFkPKs,
      foreignKey,
    );
  }

  /// For each affected shadow row, set new tag array, unless the last oplog operation was a DELETE
  String setTagsForShadowRows(
    QualifiedTablename oplogTable,
    QualifiedTablename shadowTable,
  );

  /// Deletes any shadow rows where the last oplog operation was a `DELETE`
  String removeDeletedShadowRows(
    QualifiedTablename oplogTable,
    QualifiedTablename shadowTable,
  );

  /// Prepare multiple batched insert statements for an array of records.
  ///
  /// Since SQLite only supports a limited amount of positional `?` parameters,
  /// we generate multiple insert statements with each one being filled as much
  /// as possible from the given data. All statements are derived from same `baseSql` -
  /// the positional parameters will be appended to this string.
  ///
  /// @param baseSql base SQL string to which inserts should be appended
  /// @param columns columns that describe records
  /// @param records records to be inserted
  /// @param maxParameters max parameters this SQLite can accept - determines batching factor
  /// @param suffixSql optional SQL string to append to each insert statement
  /// @returns array of statements ready to be executed by the adapter
  List<Statement> prepareInsertBatchedStatements(
    String baseSql,
    List<String> columns,
    List<Map<String, Object?>> records,
    int maxParameters, [
    String suffixSql = '',
  ]) {
    final stmts = <Statement>[];
    final columnCount = columns.length;
    final recordCount = records.length;

    // Amount of rows we can insert at once
    final batchMaxSize = (maxParameters / columnCount).floor();

    // keep a temporary join array for joining strings, to avoid
    // the overhead of generating a new array every time
    final tempColJoinArray =
        List<String>.filled(columnCount, '', growable: false);

    int processed = 0;
    int prevInsertCount = -1;
    String insertPattern = '';

    while (processed < recordCount) {
      final currentInsertCount = min(recordCount - processed, batchMaxSize);

      // cache insert pattern as it is going to be the same for every batch
      // of `batchMaxSize` - ideally we can externalize this cache since for a
      // given adapter this is _always_ going to be the same
      if (currentInsertCount != prevInsertCount) {
        insertPattern = List.generate(currentInsertCount, (recordIdx) {
          for (int i = 0; i < columnCount; i++) {
            tempColJoinArray[i] = makePositionalParam(
              recordIdx * columnCount + i + 1,
            );
          }
          return ' (${tempColJoinArray.join(', ')})';
        }).join(',');
      }

      String sql = baseSql + insertPattern;

      if (suffixSql != '') {
        sql += ' $suffixSql';
      }

      final List<Object?> args = [];
      for (int i = 0; i < currentInsertCount; i++) {
        for (int j = 0; j < columnCount; j++) {
          args.add(records[processed + i][columns[j]]);
        }
      }

      processed += currentInsertCount;
      prevInsertCount = currentInsertCount;
      stmts.add(Statement(sql, args));
    }
    return stmts;
  }

  /// Prepare multiple batched DELETE statements for an array of records.
  ///
  /// Since SQLite only supports a limited amount of positional `?` parameters,
  /// we generate multiple delete statements with each one being filled as much
  /// as possible from the given data. This function only supports column equality checks
  ///
  /// @param baseSql base SQL string to which inserts should be appended
  /// @param columns columns that describe records
  /// @param records records to be inserted
  /// @param maxParameters max parameters this SQLite can accept - determines batching factor
  /// @param suffixSql optional SQL string to append to each insert statement
  /// @returns array of statements ready to be executed by the adapter
  List<Statement> prepareDeleteBatchedStatements(
    String baseSql,
    List<String> columns,
    List<Map<String, Object?>> records,
    int maxParameters, {
    String suffixSql = '',
  }) {
    final stmts = <Statement>[];
    final columnCount = columns.length;
    final recordCount = records.length;

    // Amount of rows we can delete at once
    final batchMaxSize = (maxParameters / columnCount).floor();

    // keep a temporary join array for joining strings, to avoid
    // the overhead of generating a new array every time
    final tempColumnComparisonJoinArr =
        List<String>.filled(columnCount, '', growable: false);

    int processed = 0;
    int prevDeleteCount = -1;
    String deletePattern = '';

    while (processed < recordCount) {
      final currentDeleteCount = min(recordCount - processed, batchMaxSize);

      // cache delete pattern as it is going to be the same for every batch
      // of `batchMaxSize` - ideally we can externalize this cache since for a
      // given adapter this is _always_ going to be the same
      if (currentDeleteCount != prevDeleteCount) {
        deletePattern = List.generate(currentDeleteCount, (recordIdx) {
          for (int i = 0; i < columnCount; i++) {
            tempColumnComparisonJoinArr[i] =
                '"${columns[i]}" = ${makePositionalParam(recordIdx * columnCount + i + 1)}';
          }
          return ' (${tempColumnComparisonJoinArr.join(' AND ')})';
        }).join(' OR');
      }
      String sql = baseSql + deletePattern;

      if (suffixSql != '') {
        sql += ' $suffixSql';
      }

      final List<Object?> args = [];
      for (int i = 0; i < currentDeleteCount; i++) {
        for (int j = 0; j < columnCount; j++) {
          args.add(records[processed + i][columns[j]]);
        }
      }

      processed += currentDeleteCount;
      prevDeleteCount = currentDeleteCount;
      stmts.add(Statement(sql, args));
    }
    return stmts;
  }

  QualifiedTablename makeQT(String tablename) {
    return QualifiedTablename(defaultNamespace, tablename);
  }
}
