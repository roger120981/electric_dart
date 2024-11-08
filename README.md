![Tests](https://github.com/SkillDevs/electric_dart/actions/workflows/tests.yml/badge.svg?branch=master)
![E2E](https://github.com/SkillDevs/electric_dart/actions/workflows/e2e.yml/badge.svg?branch=master)

[![pub package](https://img.shields.io/pub/v/electricsql.svg?label=electricsql&color=blue)](https://pub.dartlang.org/packages/electricsql)
[![pub package](https://img.shields.io/pub/v/electricsql_flutter.svg?label=electricsql_flutter&color=blue)](https://pub.dartlang.org/packages/electricsql_flutter)
[![pub package](https://img.shields.io/pub/v/electricsql_cli.svg?label=electricsql_cli&color=blue)](https://pub.dartlang.org/packages/electricsql_cli)

<h1>
    <img align="center" height="60" src="https://raw.githubusercontent.com/SkillDevs/electric_dart/master/resources/electric_dart_icon.png"/>
    Electric Dart
</h1>

#### ⚠️ DEPRECATION NOTICE ⚠️

With the introduction of Electric Next (https://next.electric-sql.com/about), the local first features from the original ElectricSQL project have been restructured. The team behind Electric has decided to improve reliability and performance by reducing the scope of the project and add more features incrementally.

Only the read path use case will be considered for the initial release. That is replicating rows to different devices via the Shapes API.
Regarding writes you will need to use a remote API endpoint that inserts, updates or deletes from your Postgres, and Electric Next will make sure to stream those changes to the clients .
What that means is that if your project needs offline CRUD operations on your apps, the new Electric won't be your best option for now. 

Electric Dart is open source and will remain as that, but with the announcement of Electric Next it can be considered deprecated until previous features from the original ElectricSQL local first vision are reintroduced back at an undetermined date.

The good news is that if your app is fine with offline reads, and writes through an API, implementing a client should be very simple, as it's basically an HTTP wrapper that outputs JSON. You have the JS source code in the electric next repository (https://github.com/electric-sql/electric-next).

Sorry for being the bearer of bad news for those who are affected. Hopefully the full local first experience can be reached one day. The development experience we had with drift and Electric has been awesome.

If you are interested in the new approach or have questions make sure to check out the official [ElectricSQL Discord](https://discord.gg/B7kHGwDcbj) server.

---

Unofficial Dart client implementation for [Electric](https://electric-sql.com/).

Client based on the Typescript client from the `clients/typescript` subfolder from [electric git repository](https://github.com/electric-sql/electric)

### Reference implementation:

* [NPM package](https://www.npmjs.com/package/electric-sql).
* Version `v0.12.0-dev`
* Commit: `ecdd4ab8e27461227172fcbaa1084715593fa78b`


### What is ElectricSQL?

ElectricSQL is a local-first sync layer for modern apps. Use it to build reactive, realtime, local-first apps using standard open source Postgres and SQLite.

The ElectricSQL client provides a type-safe database client autogenerated from your database schema and APIs for [Shape-based sync](https://electric-sql.com/docs/usage/data-access/shapes) and live queries. The client combines with the [`drift`](https://pub.dev/packages/drift) package to provide a seamless experience for building local-first apps in Dart.

[Local-first](https://www.inkandswitch.com/local-first/) is a new development paradigm where your app code talks directly to an embedded local database and data syncs in the background via active-active database replication. Because the app code talks directly to a local database, apps feel instant. Because data syncs in the background via active-active replication it naturally supports multi-user collaboration and conflict-free offline.

[Introduction & Live Demos](https://electric-sql.com/docs/intro/local-first)


### Run the Todos example

This is a simple Todos app which can sync across all the platforms supported by Flutter (iOS, Android, Web, Windows, macOS and Linux).

[Instructions](https://github.com/SkillDevs/electric_dart/blob/master/todos_flutter/README.md)

![Electric Flutter](https://github.com/SkillDevs/electric_dart/assets/22084723/4fa1d198-97c6-48ef-9500-24bd1cf788ea)

## Quickstart

[Quickstart](https://github.com/SkillDevs/electric_dart/blob/master/docs/quickstart.md) to integrate Electric into your own Flutter app.


## Usage

### Instantiate

To handle type conversions and reactivity of the sync system, this package can be integrated with [`drift`](https://pub.dev/packages/drift).
To start using Electric, you need to `electrify` your database as follows.

```dart
import 'package:electricsql/electricsql.dart';
import 'package:electricsql_flutter/drivers/drift.dart';

// This would be the Drift database
AppDatabase db;

final electric = await electrify<AppDatabase>(
    dbName: '<db_name>',
    db: db,
    // Bundled migrations. This variable is autogenerated using
    // `dart run electricsql_cli generate`
    migrations: kElectricMigrations,
    config: ElectricConfig(
        // Electric service URL
        url: 'http://<ip>:5133',
        // logger: LoggerConfig(
        //     level: Level.debug, // in production you can use Level.off
        // ),
    ),
);

// https://electric-sql.com/docs/usage/auth
// You can use the functions `insecureAuthToken` or `secureAuthToken` to generate one
final String jwtAuthToken = '<your JWT>';

// Connect to the Electric service
await electric.connect(jwtAuthToken);
```

### Sync data

Shapes are the core primitive for controlling sync in the ElectricSQL system. [Shapes docs](https://electric-sql.com/docs/usage/data-access/shapes)

#### Wait for sync finished

If the shape subscription is invalid, the first promise will be rejected. If the data load fails for some reason, the second promise will be rejected.

```dart
// Resolves once the shape subscription is confirmed by the server.
final shape = await electric.syncTable(<some_shape>);

// Resolves once the initial data load for the shape is complete.
await shape.synced
```

#### Sync a full table

```dart
final shape = await electric.syncTable(db.projects);
```

#### Sync a filtered set of rows

```dart
final shape = await electric.syncTable(
    db.projects,
    // Boolean expression with drift syntax
    where: (p) => p.status.equals('active') & p.title.contains('foo'),
);
```

#### Sync deep nested shapes

The `$relations` field is autogenerated by the Electric CLI as part of your `drift` schema.
In this example, projects are synced with all its related content (project issues, issue comments and comment authors).

```dart
final shape = await electric.syncTable(
    db.projects,
    include: (p) => [
        SyncInputRelation.from(
            p.$relations.issues,
            include: (i) => [
                SyncInputRelation.from(
                    i.$relations.comments,
                    include: (c) => [
                        SyncInputRelation.from(c.$relations.author),
                    ],
                ),
            ],
        ),
    ],
);
```

### Read data

Bind live data to the widgets. This can be possible when using drift + its Stream queries.

#### Create a `Stream` query with the `drift` `watch` API
```dart
AppDatabase db;
// Since we've electrified it, we can now read from the drift db as usual.
// https://drift.simonbinder.eu/docs/dart-api/select/

// Watch query using drift Dart API
final Stream<List<Todo>> todosStream = db.select(db.todos).watch();

// Watch query using raw SQL
final Stream<List<QueryRow>> rawTodosStream = db.customSelect(
    'SELECT * FROM todos',
    // This is important so that Drift knows when to run this query again
    // if the table changes
    readsFrom: {db.todos},
).watch();
```

#### Make widgets reactive
```dart
// Stateful Widget + initState
todosStream.listen((List<Todo> liveTodos) {
    setState(() => todos = liveTodos.toList());
});

// StreamBuilder
StreamBuilder<List<Todo>>(
    stream: todosStream,
    builder: (context, snapshot) {
        // Manage loading/error/loaded states
        ...
    },
);
```

### Write data

You can use the original database instance normally so you don't need to change your database code at all. The data will be synced automatically, even raw SQL statements.

```dart
AppDatabase db;

// Using the standard Drift API
// https://drift.simonbinder.eu/docs/dart-api/writes/
await db.into(db.todos).insert(
    TodosCompanion.insert(
        title: 'My todo',
        createdAt: DateTime.now(),
    ),
);

// Or raw SQL
// WARNING: Even though this is possible, it's not recommended to use raw SQL to
// insert/update data as you would be bypassing certain formats that Electric
// expects for some special data types like UUIDs, timestamps, int4, etc...
//
// It's perfectly safe to use raw SQL for SELECT queries though, you would only
// need to tell drift what tables are being used in the query so that Stream queries
// work correctly
//
// If you really need a raw INSERT/UPDATE you can encode the parameters using the
// `TypeConverters` class.
// Like: `TypeConverters.timestampTZ.encode(DateTime.now())`
await db.customInsert(
    'INSERT INTO todos (title, created_at) VALUES (?, ?)',
    variables: [
        Variable('My todo'),
        Variable(TypeConverters.timestampTZ.encode(DateTime.now())),
    ],
    updates: {db.todos}, // This will notify stream queries to rebuild the widget
);
```

This automatic reactivity works no matter where the write is made — locally, [on another device, by another user](https://electric-sql.com/docs/intro/multi-user), or [directly into Postgres](https://electric-sql.com/docs/intro/active-active).

## More about ElectricSQL

Check out the official docs from ElectricSQL [here](https://electric-sql.com/docs) to look at live demos, API docs and integrations.


## DevTools

The package provides a DevTools extension to interact with the Electric service during development. That is: check the status of the service connectivity, inspect the table schemas, delete the local database, check the status of the shape subscriptions...

<img align="center" max-height="500px" src="https://raw.githubusercontent.com/SkillDevs/electric_dart/master/resources/devtools.png"/>

### Reset local database

To add support for the reset local database button you need to tell Electric how to reset the local database. On non-web platforms is simply closing the database connection and deleting the file. You can see a cross platform implementation in the `todos_flutter` example.

```dart
ElectricDevtoolsBinding.registerDbResetCallback(
    electricClient, // output of `electrify`
    () async {
        await db.close();
        await deleteDbFile(db); 
    },
);
```

---

## Development instructions for maintainers and contributors

Dart 3.x and Melos required

`dart pub global activate melos`


### Bootstrap the workspace

`melos bs`


### Generate the Protobuf code

Install the `protoc_plugin` Dart package.

`dart pub global activate protoc_plugin`

To generate the code

`melos run generate_proto`


### Run the tests

`melos run test:all`
