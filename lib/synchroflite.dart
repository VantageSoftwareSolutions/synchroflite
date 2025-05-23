// Copyright 2023 Janez Stupar
// This code is based on Daniel Cachapa's work in sqlite_crdt:
// https://github.com/cachapa/sqlite_crdt
// SPDX-License-Identifier: Apache-2.0
library synchroflite;

import 'dart:async';

// ignore: implementation_imports
import 'package:sqflite_common/src/open_options.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sqflite_common_ffi_web/sqflite_ffi_web.dart';
import 'package:synchroflite/src/batch_api.dart';
import 'package:synchroflite/src/crdt_util.dart';
import 'package:synchroflite/src/sqflite_api.dart';
import 'package:sql_crdt/sql_crdt.dart';
import 'package:sqlparser/sqlparser.dart';
import 'package:sqlparser/utils/node_to_text.dart';

import 'src/is_web_locator.dart';

export 'package:sqflite_common/sqlite_api.dart';
export 'package:sql_crdt/sql_crdt.dart';
export 'package:synchroflite/src/sqflite_api.dart';

part 'package:synchroflite/src/sqflite_crdt_impl.dart';
part 'package:synchroflite/src/transaction.dart';
part 'package:synchroflite/src/batch.dart';

class Synchroflite extends SqlCrdt with SqfliteCrdtImplMixin {
  final SqfliteApi _db;

  Synchroflite(this._db) : super(_db);

  /// Open or create a SQLite container as a SqlCrdt instance.
  ///
  /// See the Sqflite documentation for more details on opening a database:
  /// https://github.com/tekartik/sqflite/blob/master/sqflite/doc/opening_db.md
  static Future<Synchroflite> open(
    String path, {
    bool singleInstance = true,
    int? version,
    FutureOr<void> Function(SqlCrdt crdt, int version)? onCreate,
    FutureOr<void> Function(SqlCrdt crdt, int from, int to)? onUpgrade,
    bool migrate = false,
  }) =>
      _open(path, false, singleInstance, version, onCreate, onUpgrade,
          migrate: migrate);

  /// Open a transient SQLite in memory.
  /// Useful for testing or temporary sessions.
  static Future<Synchroflite> openInMemory({
    bool singleInstance = false,
    int? version,
    FutureOr<void> Function(SqlCrdt crdt, int version)? onCreate,
    FutureOr<void> Function(SqlCrdt crdt, int from, int to)? onUpgrade,
    bool migrate = false,
  }) =>
      _open(null, true, singleInstance, version, onCreate, onUpgrade,
          migrate: migrate);

  static Future<Synchroflite> _open(
      String? path,
      bool inMemory,
      bool singleInstance,
      int? version,
      FutureOr<void> Function(SqlCrdt crdt, int version)? onCreate,
      FutureOr<void> Function(SqlCrdt crdt, int from, int to)? onUpgrade,
      {bool migrate = false}) async {
    if (sqliteCrdtIsWeb && !inMemory && path!.contains('/')) {
      path = path.substring(path.lastIndexOf('/') + 1);
    }
    assert(inMemory || path!.isNotEmpty);
    final databaseFactory =
        sqliteCrdtIsWeb ? databaseFactoryFfiWeb : databaseFactoryFfi;

    if (!sqliteCrdtIsWeb && sqliteCrdtIsLinux) {
      await databaseFactory.setDatabasesPath('.');
    }

    final db = await databaseFactory.openDatabase(
      inMemory ? inMemoryDatabasePath : path!,
      options: SqfliteOpenDatabaseOptions(
        singleInstance: singleInstance,
        version: version,
        onCreate: onCreate == null
            ? null
            : (db, version) =>
                onCreate.call(Synchroflite(SqfliteApi(db)), version),
        onUpgrade: onUpgrade == null
            ? null
            : (db, from, to) =>
                onUpgrade.call(Synchroflite(SqfliteApi(db)), from, to),
      ),
    );

    final crdt = Synchroflite(SqfliteApi(db));
    try {
      await crdt.init();
    } on DatabaseException catch (e) {
      // ignore
      final err = e.toString();
      if (e.getResultCode() == 1 &&
          err.contains('no such column: modified') &&
          migrate) {
        await crdt.migrate();
      } else {
        rethrow;
      }
    }
    return crdt;
  }

  /// migrate an existing database to support sql_crdt
  Future<void> migrate() async {
    canonicalTime = Hlc.zero(generateNodeId());
    final tables = await _db.getTables();
    if (tables.isEmpty) return;

    // write a query that adds CRDT columns to tables
    final tableStatements = [];
    for (var table in tables) {
      tableStatements.add(
          'ALTER TABLE $table ADD COLUMN is_deleted INTEGER NOT NULL DEFAULT 0;');
      tableStatements.add(
          'ALTER TABLE $table ADD COLUMN hlc TEXT NOT NULL DEFAULT \'${canonicalTime.toString()}\';');
      tableStatements.add(
          'ALTER TABLE $table ADD COLUMN node_id TEXT NOT NULL DEFAULT \'${canonicalTime.nodeId}\';');
      tableStatements.add(
          'ALTER TABLE $table ADD COLUMN modified TEXT NOT NULL DEFAULT \'${canonicalTime.toString()}\';');
    }

    // run the query on the database as batch
    await _db.transaction((txn) async {
      for (final statement in tableStatements) {
        await txn.execute(statement);
      }
    });
  }

  Future<void> close() async {
    await _db.close();
  }

  Batch batch() => BatchSynchroflite(
      (_db.batch()), canonicalTime.increment(), onDatasetChanged);

  @override
  Future<void> transaction(
      Future<void> Function(TransactionSynchroflite txn) action) async {
    late final TransactionSynchroflite transaction;
    await _db.transaction((txn) async {
      transaction = TransactionSynchroflite(txn, canonicalTime.increment());
      await action(transaction);
    });
    // Notify on changes
    if (transaction.affectedTables.isNotEmpty) {
      await onDatasetChanged(transaction.affectedTables, transaction.hlc);
    }
  }

  @override
  Future<R> _rawInsert<T, R>(
      T db, InsertStatement statement, List<Object?>? args,
      [Hlc? hlc]) async {
    final result = await super._rawInsert(db, statement, args, hlc) as R;
    await onDatasetChanged([statement.table.tableName], hlc!);
    return result;
  }

  @override
  Future<R> _rawUpdate<T, R>(
      T db, UpdateStatement statement, List<Object?>? args,
      [Hlc? hlc]) async {
    final result = await super._rawUpdate(db, statement, args, hlc) as R;
    await onDatasetChanged([statement.table.tableName], hlc!);
    return result;
  }

  @override
  Future<R> _rawDelete<T, R>(
      T db, DeleteStatement statement, List<Object?>? args,
      [Hlc? hlc]) async {
    final result = await super._rawDelete(db, statement, args, hlc) as R;
    await onDatasetChanged([statement.table.tableName], hlc!);
    return result;
  }

  Future<List<Map<String, Object?>>> rawQuery(String sql,
      [List<Object?>? args]) {
    return _innerRawQuery(_db, sql, args);
  }

  Future<int> rawUpdate(String sql, [List<Object?>? args]) {
    final hlc = canonicalTime.increment();
    return _innerRawUpdate(_db, sql, args ?? [], hlc);
  }

  Future<int> rawInsert(String sql, [List<Object?>? args]) {
    final hlc = canonicalTime.increment();
    return _innerRawInsert(_db, sql, args ?? [], hlc);
  }

  Future<int> rawDelete(String sql, [List<Object?>? args]) {
    final hlc = canonicalTime.increment();
    return _innerRawDelete(_db, sql, args ?? [], hlc);
  }

  @override
  Future<void> execute(String sql, [List<Object?>? args]) async {
    return _innerExecute(_db, sql, () => canonicalTime.increment(), args ?? []);
  }

  @override
  Future<Iterable<String>> getTableKeys(String table) async {
    return _db.getPrimaryKeys(table);
  }

  @override
  Future<Iterable<String>> getTables() async {
    return await _db.getTables();
  }
}
