import 'package:electricsql/electricsql.dart';
import 'package:electricsql/src/devtools/shared.dart';

abstract interface class ToolbarInterface {
  List<String> getSatelliteNames();
  ConnectivityState? getSatelliteStatus(String name);

  UnsubscribeFunction subscribeToSatelliteStatus(
    String name,
    void Function(ConnectivityState) callback,
  );

  Future<void> toggleSatelliteStatus(String name);

  Future<List<DbTableInfo>> getDbTables(String dbName);
  Future<List<DbTableInfo>> getElectricTables(String dbName);

  List<DebugShape> getSatelliteShapeSubscriptions(String dbName);

  UnsubscribeFunction subscribeToSatelliteShapeSubscriptions(
    String name,
    void Function(List<DebugShape> shapes) callback,
  );

  Future<RemoteQueryRes> queryDb(
    String dbName,
    String sql,
    List<Object?> args,
  );

  UnsubscribeFunction subscribeToDbTable(
    String dbName,
    String tableName,
    void Function() callback,
  );
}
