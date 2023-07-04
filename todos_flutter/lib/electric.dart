import 'package:electric_client/electric_dart.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:todos_electrified/migrations.dart';
import 'package:logging/logging.dart';

final Provider<Satellite> satelliteProvider =
    Provider((ref) => throw UnimplementedError());

final connectivityStateProvider = StateProvider<ConnectivityState>((ref) {
  return ConnectivityState.disconnected;
});

Future<Satellite> startElectric(String dbPath, DatabaseAdapter adapter) async {
  final dbName = dbPath;
  const app = "my-todos";
  const env = "local";

  final replicationConfig = ReplicationConfig(
    host: '127.0.0.1',
    port: 5133,
    ssl: false,
  );

  final consoleConfig = ConsoleConfig(
    host: '127.0.0.1',
    port: 4000,
    ssl: false,
  );

  setLogLevel(Level.ALL);

  final notifier = EventNotifier(dbName: dbName);

  final satellite = await globalRegistry.ensureStarted(
    dbName: dbName,
    adapter: adapter,
    migrator: BundleMigrator(adapter: adapter, migrations: todoMigrations),
    notifier: notifier,
    socketFactory: WebSocketIOFactory(),
    console: ConsoleHttpClient(
      ElectricConfig(
        app: app,
        env: env,
        console: consoleConfig,
        migrations: todoMigrations,
        replication: replicationConfig,
      ),
    ),
    config: HydratedConfig(
      app: app,
      env: env,
      console: consoleConfig,
      migrations: todoMigrations,
      replication: replicationConfig,
      debug: true,
    ),
  );

  return satellite;
}
