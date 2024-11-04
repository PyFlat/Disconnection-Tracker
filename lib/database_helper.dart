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
        (await getApplicationSupportDirectory()).path, 'connection_logs.db');
    return await databaseFactory.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 1,
        onCreate: (db, version) async {
          await db.execute('''
          CREATE TABLE IF NOT EXISTS logs (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            disconnectTime INTEGER,
            reconnectTime INTEGER
          )
        ''');
        },
      ),
    );
  }

  Future<void> logDisconnect(DateTime disconnectTime) async {
    final db = await database;
    await db.insert(
        'logs', {'disconnectTime': disconnectTime.millisecondsSinceEpoch});
  }

  Future<void> logReconnect(DateTime reconnectTime) async {
    final db = await database;
    final lastDisconnect = await db.query(
      'logs',
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

  Future<List<Map<String, dynamic>>> getAllLogs() async {
    final db = await database;
    return await db.query('logs');
  }
}
