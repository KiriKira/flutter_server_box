import 'package:fl_lib/fl_lib.dart';
import 'package:server_box/data/store/db.dart';
import 'package:server_box/data/store/schema.dart';

/// Adds ADB without changing existing SSH/monitor/local records or children.
class AdbMigration implements SchemaMigration {
  const AdbMigration();
  @override
  int get from => 33;

  @override
  Future<void> apply() async {
    final db = SqliteDb.instance;
    if (db.select('PRAGMA table_info(server);').any((r) => r['name'] == 'adb_host')) return;
    db.execute('PRAGMA foreign_keys = OFF;');
    db.execute('PRAGMA legacy_alter_table = ON;');
    try {
      db.execute('BEGIN;');
      try {
        db.execute('ALTER TABLE server ADD COLUMN adb_host TEXT;');
        db.execute('ALTER TABLE server ADD COLUMN adb_port INTEGER;');
        db.execute('ALTER TABLE server ADD COLUMN adb_local INTEGER NOT NULL DEFAULT 0 CHECK (adb_local IN (0,1));');
        db.execute('ALTER TABLE server ADD COLUMN adb_tls INTEGER NOT NULL DEFAULT 1 CHECK (adb_tls IN (0,1));');
        db.execute('ALTER TABLE server ADD COLUMN adb_enabled INTEGER NOT NULL DEFAULT 0 CHECK (adb_enabled IN (0,1));');
        db.execute('ALTER TABLE server ADD COLUMN adb_guid TEXT;');
        final original = db.select("SELECT sql FROM sqlite_master WHERE type='table' AND name='server';").single['sql'] as String;
        const oldCheck = 'CHECK (ssh_ip IS NOT NULL OR monitor_addr IS NOT NULL OR is_local = 1)';
        if (!original.contains(oldCheck)) throw StateError('Unexpected v33 server constraint');
        final sql = original.replaceFirst(RegExp(r'CREATE TABLE\s+"?server"?'), 'CREATE TABLE server_m033')
            .replaceFirst(oldCheck, 'CHECK (ssh_ip IS NOT NULL OR monitor_addr IS NOT NULL OR is_local = 1 OR adb_host IS NOT NULL)');
        db.execute(sql);
        db.execute('INSERT INTO server_m033 SELECT * FROM server;');
        db.execute('DROP TABLE server;');
        db.execute('ALTER TABLE server_m033 RENAME TO server;');
        for (final statement in AppDb.indexStatements) { db.execute(statement); }
        db.execute('COMMIT;');
      } catch (_) {
        db.execute('ROLLBACK;');
        rethrow;
      }
    } finally {
      db.execute('PRAGMA legacy_alter_table = OFF;');
      db.execute('PRAGMA foreign_keys = ON;');
    }
  }
}
