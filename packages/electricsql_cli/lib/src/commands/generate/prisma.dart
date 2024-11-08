import 'dart:async';
import 'dart:io';

import 'package:collection/collection.dart';
import 'package:electricsql_cli/src/commands/generate/drift_gen_opts.dart';
import 'package:electricsql_cli/src/commands/generate/drift_schema.dart';
import 'package:electricsql_cli/src/config.dart';
import 'package:electricsql_cli/src/logger.dart';
import 'package:electricsql_cli/src/prisma_schema_parser.dart';
import 'package:electricsql_cli/src/util/util.dart';
import 'package:path/path.dart';
import 'package:recase/recase.dart';

// Version of Prisma supported by the Electric Proxy
const String _kPrismaVersion = '4.8.1';
const int _kNodeVersion = 20;

const _kPrismaCLIDockerfile = '''
FROM node:$_kNodeVersion

RUN npm install -g prisma@$_kPrismaVersion

WORKDIR /cli

ENTRYPOINT ["prisma"]
''';

/// Creates a fresh Prisma schema in the provided folder.
/// The Prisma schema is initialised with a generator and a datasource.
Future<File> createIntrospectionSchema(
  Directory folder, {
  required Config config,
}) async {
  final prismaDir = Directory(join(folder.path, 'prisma'));
  final prismaSchemaFile = File(join(prismaDir.path, 'schema.prisma'));
  await prismaDir.create(recursive: true);

  final proxyUrl = buildProxyUrlForIntrospection(config);

  final schema = '''
datasource db {
  provider = "postgresql"
  url      = "$proxyUrl"
}
''';

  await prismaSchemaFile.writeAsString(schema);
  return prismaSchemaFile;
}

String buildProxyUrlForIntrospection(Config config) {
  return buildDatabaseURL(
    // We use the "prisma" user to put the proxy into introspection mode
    user: 'prisma',
    password: config.read<String>('PG_PROXY_PASSWORD'),
    host: config.read<String>('PG_PROXY_HOST'),
    port: parsePgProxyPort(config.read<String>('PG_PROXY_PORT')).port,
    dbName: config.read<String>('DATABASE_NAME'),
  );
}

Future<void> introspectDB(PrismaCLI cli, File prismaSchema) async {
  await cli.runCommand(
    [
      'db',
      'pull',
      '--schema=${basename(prismaSchema.path)}',
    ],
    workingDirectory: prismaSchema.parent.path,
    errorMsg: 'Database introspection failed',
  );
}

class PrismaCLI {
  final Logger logger;
  final Directory folder;

  static const String _imageName = 'electric-dart/prisma-cli';

  PrismaCLI({required this.logger, required this.folder});

  // Build the Prisma CLI Docker image
  Future<void> install() async {
    await _createDockerfile();

    final res = await Process.run(
      'docker',
      [
        'build',
        '-t',
        _imageName,
        '.',
      ],
      workingDirectory: folder.path,
    );

    if (res.exitCode != 0) {
      throw Exception('Could not build Prisma CLI Docker image\n'
          'Exit code: $exitCode\n'
          'Stderr: ${res.stderr}\n'
          'Stdout: ${res.stdout}');
    }
  }

  Future<void> runCommand(
    List<String> args, {
    required String workingDirectory,
    String? errorMsg,
  }) async {
    final res = await Process.run(
      'docker',
      [
        'run',
        '--rm',
        '-v',
        '.:/cli',
        '--network',
        'host',
        _imageName,
        ...args,
      ],
      workingDirectory: workingDirectory,
    );

    //unawaited(stdout.addStream(process.stdout));

    final exitCode = res.exitCode;
    if (exitCode != 0) {
      final baseMsg = errorMsg ?? 'Could not run Prisma CLI with args: $args';
      throw Exception('$baseMsg\n'
          'Exit code: $exitCode\n'
          'Stderr: ${res.stderr}\n'
          'Stdout: ${res.stdout}');
    }
  }

  Future<File> _createDockerfile() async {
    final dockerfile = File(join(folder.path, 'Dockerfile'));
    await dockerfile.writeAsString(_kPrismaCLIDockerfile);
    return dockerfile;
  }
}

DriftSchemaInfo extractInfoFromPrismaSchema(
  String prismaSchema, {
  ElectricDriftGenOpts? genOpts,
}) {
  final enums = parseEnums(prismaSchema);
  final driftEnums = _buildDriftEnums(enums);

  final models = parseModels(prismaSchema);
  //print(models);

  final tableInfos = models.map((e) {
    final modelName = e.name;
    String tableName = modelName;

    final mapAttr = e.attributes
        .where(
          (a) => a.type == '@@map',
        )
        .firstOrNull;

    if (mapAttr != null) {
      final mappedNameLiteral = mapAttr.args.join(',');
      tableName = extractStringLiteral(mappedNameLiteral);
    }

    final tableGenOpts = genOpts?.tableGenOpts(tableName);

    final className = tableGenOpts?.driftTableName ?? modelName.pascalCase;

    final colsAndRels = _extractFromModel(
      e,
      e.fields,
      genOpts: genOpts,
      driftEnums: driftEnums,
    );

    return DriftTableInfo(
      prismaModelName: modelName,
      tableName: tableName,
      dartClassName: className,
      columns: colsAndRels.columns,
      relations: colsAndRels.relations,
    );
  }).toList();

  final schemaInfo = DriftSchemaInfo(
    tables: tableInfos,
    enums: driftEnums,
    genOpts: genOpts,
  );

  return schemaInfo;
}

Map<String, DriftEnum> _buildDriftEnums(List<EnumPrisma> enums) {
  return Map.fromEntries(
    enums.map((e) {
      final pgName = e.name;
      final dartType = 'Db${pgName.pascalCase}';

      final pgNameCamel = pgName.camelCase;

      final String enumFieldName = ensureValidDartIdentifier(pgNameCamel);

      // Prisma could reuse the name of the field for different enum values
      final fieldFreqs = <String, int>{};
      for (final val in e.values) {
        final fieldName = val.field;
        fieldFreqs[fieldName] = (fieldFreqs[fieldName] ?? 0) + 1;
      }

      final Map<String, int> usedDartValuesFreqs = {};
      final values = e.values.map((prismaEnumVal) {
        final pgValue = prismaEnumVal.pgValue;
        final String origField = prismaEnumVal.field;

        final usedNTimes = usedDartValuesFreqs[origField] ?? 0;

        String field = origField;
        // If the field is reused, append $n at the end
        if (fieldFreqs[origField]! > 1) {
          field = '$field\$${usedNTimes + 1}';
        }
        final dartVal = ensureValidDartIdentifier(field.camelCase);

        usedDartValuesFreqs[origField] = usedNTimes + 1;
        return (dartVal: dartVal, pgVal: pgValue);
      }).toList();

      return MapEntry(
        pgName,
        DriftEnum(
          pgName: pgName,
          values: values,
          dartEnumName: dartType,
          enumCodecName: enumFieldName,
          driftTypeName: enumFieldName,
        ),
      );
    }),
  );
}

class _ColumnsAndRelations {
  final List<DriftColumn> columns;
  final List<DriftRelationInfo> relations;

  _ColumnsAndRelations(this.columns, this.relations);
}

_ColumnsAndRelations _extractFromModel(
  Model model,
  List<Field> fields, {
  required ElectricDriftGenOpts? genOpts,
  required Map<String, DriftEnum> driftEnums,
}) {
  final primaryKeyFields = _getPrimaryKeysFromModel(model);

  final List<DriftColumn> columns = [];
  final List<DriftRelationInfo> relations = [];

  for (final field in fields) {
    final fieldName = field.field;

    final prismaType = field.type;

    final isArrayType = prismaType.endsWith('[]');

    final nonNullableType = _getNonNullableType(
      isArrayType ? field.type.substring(0, field.type.length - 2) : prismaType,
    );

    final driftType = _convertPrismaTypeToDrift(
      nonNullableType,
      field.attributes,
      driftEnums,
      genOpts,
    );

    // Handle relations
    if (isArrayType || driftType == null) {
      final relationAttr = field.attributes
          .firstWhereOrNull((element) => element.type == '@relation');

      if (relationAttr != null &&
          relationAttr.args.any((arg) => arg.startsWith('fields:'))) {
        // Outgoing relation
        relations.add(
          _extractOutgoindRelation(model, field, nonNullableType, relationAttr),
        );
      } else {
        // Incoming relation
        relations.add(
          _extractIncomingRelation(model, field, nonNullableType, relationAttr),
        );
      }

      continue;
    }

    String columnName = fieldName;

    // if (columnName == 'electric_user_id') {
    //   // Don't include "electric_user_id" special column in the client schema
    //   continue;
    // }

    final mapAttr = field.attributes
        .where(
          (a) => a.type == '@map',
        )
        .firstOrNull;
    if (mapAttr != null) {
      final mappedNameLiteral = mapAttr.args.join(',');
      columnName = extractStringLiteral(mappedNameLiteral);
    }

    String? dartName;

    final columnGenOpts = genOpts?.columnGenOpts(model.name, columnName);

    // First check if the column has a custom name
    dartName = columnGenOpts?.driftColumnName;

    dartName ??= ensureValidDartIdentifier(
      fieldName.camelCase,
      isReservedWord: _isInvalidDartIdentifierForDriftTable,
    );

    final bool isPrimaryKey = primaryKeyFields.contains(fieldName);

    String? enumPgType;
    if (driftType == DriftElectricColumnType.enumT) {
      final DriftEnum driftEnum = driftEnums[nonNullableType]!;
      enumPgType = driftEnum.pgName;
    }

    columns.add(
      DriftColumn(
        prismaFieldName: fieldName,
        columnName: columnName,
        dartName: dartName,
        type: driftType,
        isNullable: field.type.endsWith('?'),
        isPrimaryKey: isPrimaryKey,
        // If the type is an enum, hold the enum name in postgres
        enumPgType: enumPgType,
      ),
    );
  }

  return _ColumnsAndRelations(columns, relations);
}

DriftRelationInfo _extractOutgoindRelation(
  Model model,
  Field field,
  String nonNullableType,
  Attribute relationAttr,
) {
  final fieldName = field.field;
  final fieldNameDart = ensureValidDartIdentifier(fieldName.camelCase);
  final relatedModel = nonNullableType;

  final List<String> fieldsInRel =
      _extractFromList(_getPrismaRelationValue(relationAttr, 'fields'));
  final List<String> referencesInRel =
      _extractFromList(_getPrismaRelationValue(relationAttr, 'references'));

  if (fieldsInRel.length != 1 || referencesInRel.length != 1) {
    throw Exception(
      'Composite FKs are not supported yet. Model: ${model.name} - Field: $fieldName',
    );
  }

  final String relationName = _extractExplicitRelationName(relationAttr) ??
      _buildRelationName(
        originModel: model.name,
        relatedModel: relatedModel,
      );

  final fromField = fieldsInRel.first;
  final toField = referencesInRel.first;

  return DriftRelationInfo(
    relationField: fieldName,
    relationFieldDartName: fieldNameDart,
    relatedModel: relatedModel,
    fromField: fromField,
    toField: toField,
    relationName: relationName,
  );
}

DriftRelationInfo _extractIncomingRelation(
  Model model,
  Field field,
  String nonNullableType,
  Attribute? relationAttr,
) {
  final fieldName = field.field;
  final fieldNameDart = ensureValidDartIdentifier(fieldName.camelCase);
  final relatedModel = nonNullableType;

  final String relationName = (relationAttr != null
          ? _extractExplicitRelationName(relationAttr)
          : null) ??
      _buildRelationName(
        originModel: relatedModel,
        relatedModel: model.name,
      );

  return DriftRelationInfo(
    relationField: fieldName,
    relationFieldDartName: fieldNameDart,
    relatedModel: relatedModel,
    fromField: '',
    toField: '',
    relationName: relationName,
  );
}

String _buildRelationName({
  required String originModel,
  required String relatedModel,
}) {
  return '${originModel.pascalCase}To${relatedModel.pascalCase}';
}

String? _extractExplicitRelationName(Attribute relationAttr) {
  final args = relationAttr.args;

  final nameArg = args.firstOrNull;
  if (nameArg == null) {
    return null;
  }

  try {
    return extractStringLiteral(nameArg);
  } catch (e) {
    return null;
  }
}

String _getPrismaRelationValue(Attribute relationAttr, String name) {
  final key = '$name:';
  final String value =
      relationAttr.args.firstWhere((arg) => arg.startsWith(key));
  return value.substring(key.length).trim();
}

String _getNonNullableType(String prismaType) {
  final nonNullableType = prismaType.endsWith('?')
      ? prismaType.substring(0, prismaType.length - 1)
      : prismaType;
  return nonNullableType;
}

DriftElectricColumnType? _convertPrismaTypeToDrift(
  String nonNullableType,
  List<Attribute> attrs,
  Map<String, DriftEnum> driftEnums,
  ElectricDriftGenOpts? genOpts,
) {
  final dbAttr = attrs.where((a) => a.type.startsWith('@db.')).firstOrNull;
  final dbAttrName = dbAttr?.type.substring('@db.'.length);

  if (driftEnums.containsKey(nonNullableType)) {
    return DriftElectricColumnType.enumT;
  }

  switch (nonNullableType) {
    case 'Int':
      if (dbAttrName != null) {
        if (dbAttrName == 'SmallInt') {
          return DriftElectricColumnType.int2;
        }
      }
      return DriftElectricColumnType.int4;
    case 'Float':
      if (dbAttrName == 'Real') {
        return DriftElectricColumnType.float4;
      }
      return DriftElectricColumnType.float8;
    case 'String':
      if (dbAttrName != null) {
        if (dbAttrName == 'Uuid') {
          return DriftElectricColumnType.uuid;
        }
      }
      return DriftElectricColumnType.string;
    case 'Boolean':
      return DriftElectricColumnType.bool;
    case 'DateTime':
      // Expect to have a db. attribute with a PG type
      if (dbAttrName == null) {
        throw Exception('Expected DateTime field to have a @db. attribute');
      }

      switch (dbAttrName) {
        case 'Date':
          return DriftElectricColumnType.date;
        case 'Time':
          return DriftElectricColumnType.time;
        case 'Timetz':
          return DriftElectricColumnType.timeTZ;
        case 'Timestamp':
          return DriftElectricColumnType.timestamp;
        case 'Timestamptz':
          return DriftElectricColumnType.timestampTZ;
        default:
          throw Exception('Unknown DateTime @db. attribute: $dbAttrName');
      }
    case 'Json':
      if (dbAttrName == null) {
        return DriftElectricColumnType.jsonb;
      }

      switch (dbAttrName) {
        case 'Json':
          return DriftElectricColumnType.json;
        case 'JsonB':
          return DriftElectricColumnType.jsonb;
        default:
          throw Exception('Unknown Json @db. attribute: $dbAttrName');
      }
    case 'BigInt':
      if (genOpts?.int8AsBigInt == true) {
        return DriftElectricColumnType.bigint;
      }
      return DriftElectricColumnType.int8;
    case 'Bytes':
      return DriftElectricColumnType.blob;
    default:
      return null;
  }
}

Set<String> _getPrimaryKeysFromModel(Model m) {
  final idFields =
      m.fields.where((f) => f.attributes.any((a) => a.type == '@id'));
  final Set<String> idFieldsSet = idFields.map((f) => f.field).toSet();

  final Attribute? modelIdAttr =
      m.attributes.where((a) => a.type == '@@id').firstOrNull;

  if (modelIdAttr == null) {
    return idFieldsSet;
  }

  final modelIdAttrArgs = modelIdAttr.args.join(',').trim();
  assert(
    modelIdAttrArgs.startsWith('[') && modelIdAttrArgs.endsWith(']'),
    'Expected @@id to have arguments in the form of [field1, field2, ...]',
  );

  final compositeFields = _extractFromList(modelIdAttrArgs);

  return <String>{
    ...compositeFields,
    ...idFieldsSet,
  };
}

List<String> _extractFromList(String rawListStr) {
  assert(
    rawListStr.startsWith('[') && rawListStr.endsWith(']'),
    'Expected value to be a list in the form of a String',
  );
  return rawListStr
      .substring(1, rawListStr.length - 1)
      .split(',')
      .map((s) => s.trim())
      .toList();
}

String ensureValidDartIdentifier(
  String name, {
  bool Function(String)? isReservedWord,
  String suffix = '\$',
}) {
  String newName = name;
  if (name.startsWith(RegExp('[0-9]'))) {
    newName = '\$$name';
  }

  final bool Function(String name) effectiveIsReservedWord =
      isReservedWord ?? _isInvalidDartIdentifier;

  if (effectiveIsReservedWord(newName)) {
    newName = '$newName$suffix';
  }
  return newName;
}

bool _isInvalidDartIdentifier(String name) {
  return const [
    // dart primitive types
    'int',
    'bool',
    'double',
    'null',
    'true',
    'false',
    'class',
    'mixin',
    'enum',
  ].contains(name);
}

bool _isInvalidDartIdentifierForDriftTable(String name) {
  if (_isInvalidDartIdentifier(name)) {
    return true;
  }

  return const [
    // drift table getters
    'tableName',
    'withoutRowId',
    'dontWriteConstraints',
    'isStrict',
    'primaryKey',
    'uniqueKeys',
    'customConstraints',
    'integer',
    'int64',
    'intEnum',
    'text',
    'textEnum',
    'boolean',
    'dateTime',
    'blob',
    'real',
    'customType',
  ].contains(name);
}
