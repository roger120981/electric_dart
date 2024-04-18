import 'package:drift/drift.dart';
import 'package:electricsql/drivers/drift.dart';
import 'package:electricsql/electricsql.dart';
import 'package:electricsql/src/client/model/client.dart';
import 'package:electricsql/src/client/model/relation.dart';
import 'package:electricsql/src/client/model/schema.dart';
import 'package:electricsql/src/client/model/transform.dart';
import 'package:electricsql/src/drivers/drift/sync_input.dart';
import 'package:electricsql/src/electric/electric.dart' as electrify_lib;
import 'package:electricsql/src/electric/electric.dart';
import 'package:electricsql/src/notifiers/notifiers.dart';
import 'package:electricsql/src/satellite/satellite.dart';
import 'package:electricsql/src/sockets/sockets.dart';
import 'package:electricsql/src/util/debug/debug.dart';
import 'package:electricsql/util.dart';
import 'package:meta/meta.dart';

Future<ElectricClient<DB>> electrify<DB extends GeneratedDatabase>({
  required String dbName,
  required DB db,
  required List<Migration> migrations,
  required ElectricConfig config,
  ElectrifyOptions? opts,
}) async {
  final adapter = opts?.adapter ?? DriftAdapter(db);
  final socketFactory = opts?.socketFactory ?? getDefaultSocketFactory();

  final dbDescription = DBSchemaDrift(
    db: db,
    migrations: migrations,
  );

  final namespace = await electrify_lib.electrifyBase(
    dbName: dbName,
    dbDescription: dbDescription,
    config: config,
    adapter: adapter,
    socketFactory: socketFactory,
    opts: ElectrifyBaseOptions(
      migrator: opts?.migrator,
      notifier: opts?.notifier,
      registry: opts?.registry,
    ),
  );

  final driftClient = DriftElectricClient(namespace as ElectricClientImpl, db);
  driftClient.init();

  return driftClient;
}

abstract interface class ElectricClient<DB extends GeneratedDatabase>
    implements BaseElectricClient {
  DB get db;

  /// Creates a Shape subscription. A shape is a set of related data that's synced
  /// onto the local device.
  /// https://electric-sql.com/docs/usage/data-access/shapes
  Future<ShapeSubscription> syncTable<T extends Table>(
    T table, {
    SyncIncludeBuilder<T>? include,
    SyncWhereBuilder<T>? where,
  });

  /// Same as [syncTable] but you would be providing table names, and foreign key
  /// relationships manually. This is more low-level and should be avoided if
  /// possible.
  Future<ShapeSubscription> syncTableRaw(SyncInputRaw syncInput);

  /// Puts transforms in place such that any data being replicated
  /// to or from this table is first handled appropriately while
  /// retaining type consistency.
  ///
  /// Can be used to encrypt sensitive fields before they are
  /// replicated outside of their secure local source.
  ///
  /// NOTE: usage is discouraged, but ensure transforms are
  /// set before replication is initiated using [syncTable]
  /// to avoid partially transformed tables.
  void setTableReplicationTransform<TableDsl extends Table, D>(
    TableInfo<TableDsl, D> table, {
    required Insertable<D> Function(D row) transformInbound,
    required Insertable<D> Function(D row) transformOutbound,
    Insertable<D> Function(D)? toInsertable,
  });

  /// Clears any replication transforms set using [setReplicationTransform]
  void clearTableReplicationTransform<TableDsl extends Table, D>(
    TableInfo<TableDsl, D> table,
  );
}

class DriftElectricClient<DB extends GeneratedDatabase>
    implements ElectricClient<DB> {
  @override
  final DB db;

  final ElectricClientImpl _baseClient;

  void Function()? _disposeHook;

  DriftElectricClient(this._baseClient, this.db);

  @visibleForTesting
  void init() {
    assert(_disposeHook == null, 'Already initialized');

    _disposeHook = _hookToNotifier();
  }

  @override
  Future<void> close() async {
    await _baseClient.close();

    _disposeHook?.call();
    _disposeHook = null;
  }

  void Function() _hookToNotifier() {
    final _unsubDataChanges = notifier.subscribeToDataChanges(
      (notification) {
        final tablesChanged = notification.changes.map((e) {
          final tableName = e.qualifiedTablename.tablename;
          return tableName;
        }).toSet();

        final Set<_TableUpdateFromElectric> tableUpdates =
            tablesChanged.map((e) => _TableUpdateFromElectric(e)).toSet();

        if (tableUpdates.isNotEmpty) {
          // Notify drift
          db.notifyUpdates(tableUpdates);
        }
      },
    );

    final tableUpdateSub = db.tableUpdates().listen((updatedTables) {
      final tableNames = updatedTables
          .where((update) => update is! _TableUpdateFromElectric)
          .map((update) => update.table)
          .toSet();

      // Only notify Electric for the tables that were not triggered
      // by Electric itself in "notifier.subscribeToDataChanges"
      if (tableNames.isNotEmpty) {
        logger.info(
          'Notifying Electric about tables changed in the client. Changed tables: $tableNames',
        );
        notifier.potentiallyChanged();
      }
    });

    return () {
      _unsubDataChanges();
      tableUpdateSub.cancel();
    };
  }

  @override
  DatabaseAdapter get adapter => _baseClient.adapter;

  @override
  DBSchema get dbDescription => _baseClient.dbDescription;

  @override
  bool get isConnected => _baseClient.isConnected;

  @override
  Notifier get notifier => _baseClient.notifier;

  @override
  String get dbName => _baseClient.dbName;

  @override
  Registry get registry => _baseClient.registry;

  @override
  void potentiallyChanged() {
    return _baseClient.potentiallyChanged();
  }

  @override
  Satellite get satellite => _baseClient.satellite;

  @override
  void setIsConnected(ConnectivityState connectivityState) {
    return _baseClient.setIsConnected(connectivityState);
  }

  @override
  Future<void> connect([String? token]) {
    return _baseClient.connect(token);
  }

  @override
  void disconnect() {
    return _baseClient.disconnect();
  }

  @override
  Future<ShapeSubscription> syncTable<T extends Table>(
    T table, {
    SyncIncludeBuilder<T>? include,
    SyncWhereBuilder<T>? where,
  }) {
    final shape = computeShapeForDrift<T>(
      db,
      table,
      include: include,
      where: where,
    );

    // print("SHAPE ${shape.toMap()}");

    return _baseClient.syncShapeInternal(shape);
  }

  @override
  Future<ShapeSubscription> syncTableRaw(SyncInputRaw syncInput) async {
    final shape = computeShape(syncInput);
    return _baseClient.syncShapeInternal(shape);
  }

  @override
  void setTableReplicationTransform<TableDsl extends Table, D>(
    TableInfo<TableDsl, D> table, {
    required Insertable<D> Function(D row) transformInbound,
    required Insertable<D> Function(D row) transformOutbound,
    Insertable<D> Function(D)? toInsertable,
  }) {
    // forbid transforming relation keys to avoid breaking
    // referential integrity
    final relations = getTableRelations(table.asDslTable)?.$relationsList ?? [];
    final immutableFields = relations.map((r) => r.fromField).toList();

    final QualifiedTablename qualifiedTableName = _getQualifiedTableName(table);

    // ignore: invalid_use_of_protected_member
    _baseClient.replicationTransformManager.setTableTransform(
      qualifiedTableName,
      ReplicatedRowTransformer(
        transformInbound: (Record record) {
          final dataClass = table.map(record) as D;
          final insertable = transformTableRecord<TableDsl, D, Record>(
            table,
            dataClass,
            transformInbound,
            immutableFields,
            toInsertable: toInsertable,
          );
          return insertable
              .toColumns(false)
              .map((key, val) => MapEntry(key, expressionToValue(val)));
        },
        transformOutbound: (Record record) {
          final dataClass = table.map(record) as D;
          final insertable = transformTableRecord<TableDsl, D, Record>(
            table,
            dataClass,
            transformOutbound,
            immutableFields,
            toInsertable: toInsertable,
          );
          return insertable
              .toColumns(false)
              .map((key, val) => MapEntry(key, expressionToValue(val)));
        },
      ),
    );
  }

  Object? expressionToValue(Expression<Object?> expression) {
    if (expression is Variable) {
      return expression.value;
    } else if (expression is Constant) {
      return expression.value;
    } else {
      throw ArgumentError('Unsupported expression type: $expression');
    }
  }

  @override
  void clearTableReplicationTransform<TableDsl extends Table, D>(
    TableInfo<TableDsl, D> table,
  ) {
    final qualifiedTableName = _getQualifiedTableName(table);
    // ignore: invalid_use_of_protected_member
    _baseClient.replicationTransformManager
        .clearTableTransform(qualifiedTableName);
  }

  QualifiedTablename _getQualifiedTableName<TableDsl extends Table, D>(
    TableInfo<TableDsl, D> table,
  ) {
    return QualifiedTablename('main', table.actualTableName);
  }
}

class _TableUpdateFromElectric extends TableUpdate {
  _TableUpdateFromElectric(super.table);
}
