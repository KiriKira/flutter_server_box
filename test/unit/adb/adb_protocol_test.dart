import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:server_box/core/adb/adb_files.dart';
import 'package:server_box/core/adb/adb_shell.dart';
import 'package:server_box/core/adb/adb_transport.dart';
import 'package:server_box/data/model/server/adb_credential.dart';

class FakeStream implements AdbStream {
  final controller = StreamController<Uint8List>();
  final writes = <List<int>>[];
  bool closed = false;
  @override Stream<Uint8List> get bytes => controller.stream;
  @override Future<void> write(List<int> bytes) async { writes.add(bytes.toList()); }
  @override void close() { if (closed) return; closed = true; unawaited(controller.close()); }
}
class FakeConnection extends AdbConnection {
  FakeConnection(this.stream) : super('phone', const AdbCredential(host: 'phone', port: 1234));
  final FakeStream stream;
  String? service;
  @override Future<AdbStream> open(String service) async { this.service = service; return stream; }
  @override void release(AdbStream stream) { stream.close(); }
}
Uint8List shellFrame(int id, List<int> bytes) {
  final frame = Uint8List(5 + bytes.length)..[0] = id;
  ByteData.sublistView(frame).setUint32(1, bytes.length, Endian.little);
  frame.setRange(5, frame.length, bytes);
  return frame;
}
Uint8List syncFrame(String id, List<int> bytes) {
  final frame = Uint8List(8 + bytes.length)..setRange(0, 4, ascii.encode(id));
  ByteData.sublistView(frame).setUint32(4, bytes.length, Endian.little);
  frame.setRange(8, frame.length, bytes);
  return frame;
}
void main() {
  test('shell v2 handles fragmented UTF8 and preserves exit status', () async {
    final raw = FakeStream();
    final connection = FakeConnection(raw);
    final shell = await AdbShellSession.open(connection, pty: true, width: 100, height: 30);
    final stdout = shell.stdout.cast<List<int>>().transform(utf8.decoder).join();
    final stderr = shell.stderr.cast<List<int>>().transform(utf8.decoder).join();
    final bytes = shellFrame(1, utf8.encode('手机\n'));
    raw.controller.add(bytes.sublist(0, 3));
    raw.controller.add(bytes.sublist(3, 7));
    raw.controller.add(bytes.sublist(7));
    raw.controller.add(shellFrame(2, utf8.encode('denied')));
    raw.controller.add(shellFrame(3, [17]));
    await shell.done;
    expect(await stdout, '手机\n');
    expect(await stderr, 'denied');
    expect(shell.exitCode, 17);
    expect(connection.service, startsWith('shell,v2,'));
    expect(raw.writes.first[0], 5);
    expect(utf8.decode(raw.writes.first.sublist(5)), '30x100,0x0\u0000');
    expect(connection.closed, false);
  });
  test('a terminal closes only its streams, not the device connection', () async {
    final raw = FakeStream();
    final connection = FakeConnection(raw);
    final backend = AdbShellBackend(connection);
    final shell = await backend.openShell(width: 80, height: 24);
    final stdout = shell.stdout!.drain<void>();
    final stderr = shell.stderr!.drain<void>();
    backend.close();
    await shell.done;
    await Future.wait([stdout, stderr]);
    expect(raw.closed, true);
    expect(connection.closed, false);
  });
  test('sync streams binary bytes and honours file offset', () async {
    final raw = FakeStream();
    final connection = FakeConnection(raw);
    final backend = AdbFileBackend(connection);
    final future = backend.read('/sdcard/a\'b', offset: 2).expand((b) => b).toList();
    raw.controller.add(syncFrame('DATA', [0, 255, 1, 128, 13, 10]));
    raw.controller.add(syncFrame('DONE', const []));
    expect(await future, [1, 128, 13, 10]);
    expect(connection.service, 'sync:');
    expect(utf8.decode(raw.writes[1]), '/sdcard/a\'b');
    expect(raw.closed, true);
  });
  test('sync fails closed on a truncated transfer', () async {
    final raw = FakeStream();
    final backend = AdbFileBackend(FakeConnection(raw));
    final future = backend.read('/sdcard/file').toList();
    final assertion = expectLater(future, throwsStateError);
    raw.controller.add(syncFrame('DATA', [1, 2, 3]).sublist(0, 9));
    raw.close();
    await assertion;
    expect(raw.closed, true);
  });
}
