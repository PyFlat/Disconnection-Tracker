import 'dart:io';

import 'package:path/path.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class DatabaseHelper {
  static final DatabaseHelper _instance = DatabaseHelper._internal();
  factory DatabaseHelper() => _instance;
  DatabaseHelper._internal();

  static Database? _database;

  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDatabase();
    return _database!;
  }

  Future<Database> _initDatabase() async {
    if (Platform.isWindows || Platform.isLinux) {
      sqfliteFfiInit();
    }
    var databaseFactory = databaseFactoryFfi;
    String path = join(
      (await getApplicationSupportDirectory()).path,
      'connection_logs.db',
    );
    return await databaseFactory.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 3, // Upgraded to v3 for parallel tracking modes
        onCreate: (db, version) async {
          await db.execute('''
          CREATE TABLE IF NOT EXISTS logs (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            seriesId INTEGER DEFAULT 1,
            trackingMode TEXT DEFAULT 'external',
            disconnectTime INTEGER,
            reconnectTime INTEGER
          )
        ''');
        },
        onUpgrade: (db, oldVersion, newVersion) async {
          if (oldVersion < 2) {
            await db.execute(
              'ALTER TABLE logs ADD COLUMN seriesId INTEGER DEFAULT 1',
            );
          }
          if (oldVersion < 3) {
            await db.execute(
              'ALTER TABLE logs ADD COLUMN trackingMode TEXT DEFAULT "external"',
            );
          }
        },
      ),
    );
  }

  Future<int> getCurrentSeriesId(String mode) async {
    final db = await database;
    final result = await db.rawQuery(
      'SELECT MAX(seriesId) as maxId FROM logs WHERE trackingMode = ?',
      [mode],
    );
    int currentId = (result.first['maxId'] as int?) ?? 1;
    return currentId;
  }

  Future<void> logDisconnect(
    DateTime disconnectTime,
    int seriesId,
    String mode,
  ) async {
    final db = await database;
    await db.insert('logs', {
      'seriesId': seriesId,
      'trackingMode': mode,
      'disconnectTime': disconnectTime.millisecondsSinceEpoch,
    });
  }

  Future<void> logReconnect(
    DateTime reconnectTime,
    int seriesId,
    String mode,
  ) async {
    final db = await database;
    final lastDisconnect = await db.query(
      'logs',
      where: 'seriesId = ? AND trackingMode = ?',
      whereArgs: [seriesId, mode],
      orderBy: 'id DESC',
      limit: 1,
    );

    if (lastDisconnect.isNotEmpty) {
      int? id = lastDisconnect.first['id'] as int?;
      if (id != null) {
        await db.update(
          'logs',
          {'reconnectTime': reconnectTime.millisecondsSinceEpoch},
          where: 'id = ?',
          whereArgs: [id],
        );
      }
    }
  }

  Future<Map<String, dynamic>?> getLastLog(int seriesId, String mode) async {
    final db = await database;
    final query = await db.rawQuery(
      "SELECT * FROM logs WHERE seriesId = ? AND trackingMode = ? ORDER BY id DESC LIMIT 1",
      [seriesId, mode],
    );
    return query.isNotEmpty ? query.first : null;
  }

  Future<List<Map<String, dynamic>>> getLogsForSeries(
    int seriesId,
    String mode,
  ) async {
    final db = await database;
    return await db.query(
      'logs',
      where: 'seriesId = ? AND trackingMode = ?',
      whereArgs: [seriesId, mode],
    );
  }

  Future<bool> deleteLogEntry(int id) async {
    final db = await database;
    int count = await db.delete('logs', where: 'id = ?', whereArgs: [id]);
    return count > 0;
  }
}
