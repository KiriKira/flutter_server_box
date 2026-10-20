import 'dart:io';

import 'package:fl_lib/fl_lib.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:server_box/data/model/server/adb_credential.dart';
import 'package:server_box/data/model/server/server_private_info.dart';
import 'package:server_box/data/store/migrations/m033_adb.dart';
import 'package:server_box/data/store/server.dart';
import 'package:server_box/data/store/tables.dart';
import '../helpers/server_ddl.dart';
import '../helpers/test_db.dart';

void main() {
  setUp(SqliteDb.openInMemory);
  tearDown(closeTestDb);

  test('upgrades v33 preserving parent values, children and cascades', () async {
    final db = SqliteDb.instance;
    await createTables(db);
    replaceServerTable(File('test/fixtures/sqlite_v33/server.sql').readAsStringSync());
    db.execute("INSERT INTO server (id,name,ssh_ip,ssh_port,ssh_user,rev,updated_at) VALUES ('old','router','10.0.0.1',22,'root',7,12345);");
    db.execute("INSERT INTO server_tag VALUES ('old','prod');");
    db.execute("INSERT INTO server_env VALUES ('old','LANG','C');");
    await const AdbMigration().apply();
    await const AdbMigration().apply();
    expect(db.select('SELECT * FROM server_tag;').single['tag'], 'prod');
    expect(db.select('SELECT * FROM server_env;').single['value'], 'C');
    final row = db.select('SELECT * FROM server;').single;
    expect(row['rev'], 7);
    expect(row['updated_at'], 12345);
    expect(row['adb_host'], isNull);
    expect(db.select('PRAGMA foreign_keys;').single.values.single, 1);
    expect(db.select('PRAGMA foreign_key_check;'), isEmpty);
    final store = ServerStore();
    final phone = Spi(name: 'phone', id: 'phone', adb: const AdbCredential(localDevice: true), adbEnabled: true);
    store.put(phone);
    expect(store.fetchOneRaw('phone')?.adb, phone.adb);
    expect(store.fetchOneRaw('phone')?.ssh, isNull);
    db.execute("DELETE FROM server WHERE id='old';");
    expect(db.select('SELECT * FROM server_tag;'), isEmpty);
    expect(db.select('SELECT * FROM server_env;'), isEmpty);
  });
}
