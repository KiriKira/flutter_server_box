import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:server_box/core/adb/adb_shell.dart';
import 'package:server_box/data/model/server/adb_credential.dart';
import 'package:server_box/src/rust/api/android.dart' as android_ffi;


/// Raw ADB services. Shell v2 and sync framing live above this boundary, so
/// desktop and Android use exactly the same terminal and command semantics.
abstract interface class AdbStream {
  Stream<Uint8List> get bytes;
  Future<void> write(List<int> bytes);
  void close();
}

class AdbService {
  static const channel = MethodChannel('tech.lolli.toolbox/adb');
  static bool get supported => Platform.isAndroid || Platform.isLinux || Platform.isMacOS || Platform.isWindows;
  static final _connections = <String, AdbConnection>{};
  static final _connecting = <String, Future<AdbConnection>>{};
  static final _generation = <String, int>{};
  static final _configured = <String, AdbCredential?>{};

  /// A terminal opened before an edit must not reconnect the old address under
  /// a record that now names a different phone or execution environment.
  static void configure(String id, AdbCredential? credential) {
    if (_configured.containsKey(id) && _configured[id] != credential) disconnect(id);
    _configured[id] = credential;
  }

  static Future<AdbConnection> connect(String id, AdbCredential credential) {
    if (_configured.containsKey(id) && _configured[id] != credential) {
      return Future.error(StateError('ADB device configuration changed; reopen this terminal'));
    }
    final current = _connections[id];
    if (current != null && !current.closed && current.credential == credential) return Future.value(current);
    final pending = _connecting[id];
    if (pending != null) return pending;
    late final Future<AdbConnection> future;
    future = _connect(id, credential).whenComplete(() {
      if (identical(_connecting[id], future)) _connecting.remove(id);
    });
    return _connecting[id] = future;
  }

  static Future<AdbConnection> _connect(String id, AdbCredential credential) async {
    if (!supported) throw UnsupportedError('ADB is unavailable on this platform');
    if (!credential.isValid) throw const FormatException('Invalid ADB address or port');
    final generation = _generation[id] ?? 0;
    final connection = AdbConnection(id, credential);
    try {
      await connection.connect();
      final expectedGuid = credential.deviceGuid;
      if (!credential.localDevice && expectedGuid != null && expectedGuid.isNotEmpty) {
        final result = await AdbExec(connection).run(android_ffi.androidCommand(action: 'guid', argument: '', root: false));
        if (!result.succeeded || result.stdout.trim() != expectedGuid) throw StateError('ADB device identity changed; check the connection address');
      }
      if ((_generation[id] ?? 0) != generation) throw StateError('ADB connection cancelled');
      _connections.remove(id)?.close();
      return _connections[id] = connection;
    } catch (_) { connection.close(); rethrow; }
  }

  static bool isCurrent(AdbConnection connection) => !connection.closed && identical(_connections[connection.id], connection);
  static void disconnect(String id) {
    _generation[id] = (_generation[id] ?? 0) + 1;
    _connections.remove(id)?.close();
    _connecting.remove(id);
  }

  static Future<List<Map<String, dynamic>>> discover({bool local = false, bool pairing = false}) async {
    if (!Platform.isAndroid) return const [];
    final found = await channel.invokeListMethod<dynamic>('discover', {'local': local, 'pairing': pairing});
    return [for (final item in found ?? []) Map<String, dynamic>.from(item as Map)];
  }

  static Future<void> pair(String id, String host, int port, String code) async {
    if (Platform.isAndroid) {
      await channel.invokeMethod<void>('pair', {'id': id, 'host': host, 'port': port, 'code': code});
    } else {
      // Code travels on stdin, never in the process arguments or saved config.
      final process = await Process.start('adb', ['pair', '$host:$port']);
      final stdout = process.stdout.transform(const SystemEncoding().decoder).join();
      final stderr = process.stderr.transform(const SystemEncoding().decoder).join();
      process.stdin.writeln(code);
      await process.stdin.close();
      try {
        final exit = await process.exitCode.timeout(const Duration(seconds: 20));
        final output = '${await stdout}\n${await stderr}';
        if (exit != 0 || !output.contains('Successfully paired')) throw StateError('ADB pairing failed');
      } finally { process.kill(); }
    }
  }
}

class AdbConnection {
  AdbConnection(this.id, this.credential);
  final String id;
  final AdbCredential credential;
  static int _next = 0;
  late final String _nativeId = '$id/${_next++}';
  bool closed = false;
  String? _serial;
  final _streams = <AdbStream>{};

  Future<void> connect() async {
    if (Platform.isAndroid) {
      await AdbService.channel.invokeMethod<void>('connect', {'id': _nativeId, ...credential.toJson()});
      if (closed) {
        await AdbService.channel.invokeMethod<void>('disconnect', {'id': _nativeId});
        throw StateError('ADB connection cancelled');
      }
    } else {
      if (credential.localDevice) throw UnsupportedError('Local Android ADB requires Android');
      final host = credential.host.contains(':') ? '[${credential.host}]' : credential.host;
      _serial = '$host:${credential.port}';
      if (credential.tls) await _requireTls(credential.host, credential.port);
      final result = await Process.run('adb', ['connect', _serial!]).timeout(const Duration(seconds: 20));
      if (result.exitCode != 0 || !RegExp(r'(connected to|already connected to)').hasMatch('${result.stdout}')) {
        throw StateError('ADB connect failed: ${result.stdout} ${result.stderr}');
      }
    }
  }

  Future<AdbStream> open(String service) async {
    if (closed) throw StateError('ADB connection closed');
    final AdbStream stream;
    if (Platform.isAndroid) {
      final streamId = await AdbService.channel.invokeMethod<String>('open', {'id': _nativeId, 'service': service});
      if (streamId == null) throw StateError('ADB service did not open');
      stream = _AndroidStream(streamId);
    } else {
      final socket = await Socket.connect(InternetAddress.loopbackIPv4, 5037, timeout: const Duration(seconds: 10));
      final desktop = _DesktopStream(socket);
      try {
        await desktop.request('host:transport:$_serial').timeout(const Duration(seconds: 10));
        await desktop.request(service).timeout(const Duration(seconds: 10));
        stream = desktop;
      } catch (_) { desktop.close(); rethrow; }
    }
    if (closed) { stream.close(); throw StateError('ADB connection closed'); }
    _streams.add(stream);
    return stream;
  }

  void release(AdbStream stream) { _streams.remove(stream); stream.close(); }
  void close() {
    if (closed) return;
    closed = true;
    for (final stream in _streams.toList()) { stream.close(); }
    _streams.clear();
    if (Platform.isAndroid) {
      unawaited(AdbService.channel.invokeMethod<void>('disconnect', {'id': _nativeId}).catchError((Object _) {}));
    }
  }
}

class _AndroidStream implements AdbStream {
  _AndroidStream(this.id) {
    _controller = StreamController<Uint8List>(onListen: _read, onCancel: close);
  }
  final String id;
  late final StreamController<Uint8List> _controller;
  bool _closed = false;
  @override
  Stream<Uint8List> get bytes => _controller.stream;
  Future<void> _read() async {
    try {
      while (!_closed) {
        final data = await AdbService.channel.invokeMethod<Uint8List>('read', {'stream': id});
        if (data == null || data.isEmpty) break;
        _controller.add(data);
        // A paused consumer must not cause an unbounded native read queue.
        while (_controller.isPaused && !_closed) { await Future<void>.delayed(const Duration(milliseconds: 10)); }
      }
    } catch (e, st) { if (!_closed) _controller.addError(e, st); }
    finally { close(); }
  }
  @override
  Future<void> write(List<int> bytes) async {
    if (_closed) throw StateError('ADB stream closed');
    await AdbService.channel.invokeMethod<void>('write', {'stream': id, 'bytes': Uint8List.fromList(bytes)});
  }
  @override
  void close() {
    if (_closed) return;
    _closed = true;
    unawaited(AdbService.channel.invokeMethod<void>('close', {'stream': id}).catchError((Object _) {}));
    unawaited(_controller.close());
  }
}

/// The adb server's length-prefixed client protocol, followed by raw service
/// bytes. Preserve bytes arriving in the same packet as the OKAY handshake.
class _DesktopStream implements AdbStream {
  _DesktopStream(this.socket) : _iterator = StreamIterator(socket);
  final Socket socket;
  final StreamIterator<Uint8List> _iterator;
  Uint8List _pending = Uint8List(0);
  bool _closed = false;
  Future<Uint8List> _take(int count) async {
    final result = BytesBuilder(copy: false);
    while (result.length < count) {
      if (_pending.isEmpty) {
        if (!await _iterator.moveNext()) throw StateError('ADB server closed');
        _pending = _iterator.current;
      }
      final n = (count - result.length).clamp(0, _pending.length);
      result.add(_pending.sublist(0, n));
      _pending = _pending.sublist(n);
    }
    return result.takeBytes();
  }
  Future<void> request(String request) async {
    final payload = Uint8List.fromList(utf8.encode(request));
    if (payload.length > 65535) throw const FormatException('ADB request too large');
    socket.add(payload.length.toRadixString(16).padLeft(4, '0').codeUnits);
    socket.add(payload);
    await socket.flush();
    final answer = String.fromCharCodes(await _take(4));
    if (answer == 'OKAY') return;
    if (answer == 'FAIL') {
      final length = int.parse(String.fromCharCodes(await _take(4)), radix: 16);
      throw StateError(String.fromCharCodes(await _take(length)));
    }
    throw const FormatException('Invalid ADB server response');
  }
  @override
  Stream<Uint8List> get bytes async* {
    if (_pending.isNotEmpty) { yield _pending; _pending = Uint8List(0); }
    while (!_closed && await _iterator.moveNext()) { yield _iterator.current; }
  }
  @override
  Future<void> write(List<int> bytes) async { socket.add(bytes); await socket.flush(); }
  @override
  void close() { if (_closed) return; _closed = true; socket.destroy(); unawaited(_iterator.cancel()); }
}

/// Verify the Wireless debugging endpoint before asking the desktop adb server
/// to connect. Legacy ADB must be selected explicitly.
Future<void> _requireTls(String host, int port) async {
  final socket = await Socket.connect(host, port, timeout: const Duration(seconds: 5));
  final iterator = StreamIterator(socket);
  try {
    final payload = utf8.encode('host::\u0000');
    final packet = Uint8List(24 + payload.length);
    const command = 0x4e584e43;
    final header = ByteData.sublistView(packet);
    header.setUint32(0, command, Endian.little);
    header.setUint32(4, 0x01000001, Endian.little);
    header.setUint32(8, 1024 * 1024, Endian.little);
    header.setUint32(12, payload.length, Endian.little);
    header.setUint32(16, payload.fold<int>(0, (sum, byte) => sum + byte), Endian.little);
    header.setUint32(20, command ^ 0xffffffff, Endian.little);
    packet.setRange(24, packet.length, payload);
    socket.add(packet); await socket.flush();
    final received = BytesBuilder(copy: false);
    while (received.length < 24) {
      if (!await iterator.moveNext().timeout(const Duration(seconds: 5))) throw StateError('ADB handshake ended early');
      received.add(iterator.current);
    }
    final reply = ByteData.sublistView(received.takeBytes());
    if (reply.getUint32(0, Endian.little) != 0x534c5453 || reply.getUint32(20, Endian.little) != (0x534c5453 ^ 0xffffffff)) {
      throw StateError('This endpoint is not Wireless debugging TLS');
    }
  } finally { socket.destroy(); unawaited(iterator.cancel()); }
}
