import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:server_box/core/adb/adb_transport.dart';
import 'package:server_box/data/model/server/server_exec.dart';
import 'package:server_box/data/model/server/shell_backend.dart';
import 'package:server_box/src/rust/api/android.dart' as android_ffi;

/// shell,v2 framing: stdin=0, stdout=1, stderr=2, exit=3,
/// close-stdin=4, window-size=5. Never infer success from stream closure.
class AdbShellSession implements ShellSession {
  AdbShellSession._(this.connection, this.stream) {
    _subscription = stream.bytes.listen(_receive, onError: (Object e, StackTrace st) {
      _stdout.addError(e, st);
      _finish();
    }, onDone: _finish);
  }

  static Future<AdbShellSession> open(AdbConnection connection, {
    String command = '', bool pty = false, int width = 80, int height = 24,
  }) async {
    final service = pty ? 'shell,v2,TERM=xterm-256color,pty:$command' : 'shell,v2,raw:$command';
    final session = AdbShellSession._(connection, await connection.open(service));
    if (pty) session.resizeTerminal(width, height);
    return session;
  }

  final AdbConnection connection;
  final AdbStream stream;
  final _stdout = StreamController<Uint8List>();
  final _stderr = StreamController<Uint8List>();
  final _done = Completer<void>();
  late final StreamSubscription<Uint8List> _subscription;
  Uint8List _buffer = Uint8List(0);
  Future<void> _writes = Future.value();
  int? exitCode;
  bool get closed => _done.isCompleted;
  Object? writeError;

  void _receive(Uint8List bytes) {
    try {
      _buffer = Uint8List.fromList([..._buffer, ...bytes]);
      while (_buffer.length >= 5) {
        final id = _buffer[0];
        final length = ByteData.sublistView(_buffer).getUint32(1, Endian.little);
        if (length > 1024 * 1024) throw const FormatException('ADB shell frame exceeds limit');
        if (_buffer.length < length + 5) return;
        final body = Uint8List.fromList(_buffer.sublist(5, length + 5));
        _buffer = _buffer.sublist(length + 5);
        switch (id) {
          case 1: _stdout.add(body);
          case 2: _stderr.add(body);
          case 3:
            if (body.length != 1) throw const FormatException('Invalid ADB exit status');
            exitCode = body[0];
            _finish();
            return;
          default: throw FormatException('Unexpected ADB shell packet: $id');
        }
      }
    } catch (e, st) { _stdout.addError(e, st); _finish(); }
  }

  Future<void> send(int id, List<int> bytes) {
    if (closed) return Future.error(StateError('ADB shell closed'));
    final frame = Uint8List(bytes.length + 5);
    frame[0] = id;
    ByteData.sublistView(frame).setUint32(1, bytes.length, Endian.little);
    frame.setRange(5, frame.length, bytes);
    final result = _writes.then((_) => stream.write(frame));
    _writes = result.catchError((Object error) {
      writeError = error;
      if (!closed) _stdout.addError(error);
      _finish();
    });
    return _writes;
  }

  Future<void> writeBytes(List<int> bytes) async {
    for (var at = 0; at < bytes.length; at += 32768) {
      await send(0, bytes.sublist(at, (at + 32768).clamp(0, bytes.length)));
      if (writeError case final error?) throw error;
    }
  }
  Future<void> closeStdin() => send(4, const []);
  @override
  Stream<Uint8List> get stdout => _stdout.stream;
  @override
  Stream<Uint8List> get stderr => _stderr.stream;
  @override
  Future<void> get done => _done.future;
  @override
  void write(List<int> data) { unawaited(writeBytes(data).catchError((Object _) {})); }
  @override
  void resizeTerminal(int width, int height) {
    if (!closed) unawaited(send(5, utf8.encode('${height}x$width,0x0\u0000')));
  }
  void _finish() {
    if (closed) return;
    _done.complete();
    unawaited(_stdout.close());
    unawaited(_stderr.close());
    connection.release(stream);
  }
  @override
  void close() { _finish(); unawaited(_subscription.cancel()); }
}

class AdbExec implements ServerExec {
  const AdbExec(this.connection);
  final AdbConnection connection;
  @override
  Future<ExecResult> run(String script, {
    String? entry, Map<String, String>? env, String? stdin,
    OnExecOutput? onStdout, OnExecOutput? onStderr, Future<void>? cancel,
  }) async {
    final command = android_ffi.androidExecCommand(script: script, entry: entry, env: env ?? const {});
    final session = await AdbShellSession.open(connection, command: command);
    const limit = 4 * 1024 * 1024;
    var received = 0;
    var truncated = false;
    var cancelled = false;
    Object? error;
    final out = StringBuffer();
    final err = StringBuffer();
    void append(String data, StringBuffer buffer, OnExecOutput? callback) {
      if (received >= limit) { truncated = true; return; }
      final remaining = limit - received;
      final kept = data.length <= remaining ? data : data.substring(0, remaining);
      received += kept.length;
      truncated |= kept.length < data.length;
      buffer.write(kept); callback?.call(kept);
    }
    final outDone = Completer<void>();
    final errDone = Completer<void>();
    final stdout = session.stdout.cast<List<int>>().transform(const Utf8Decoder(allowMalformed: true)).listen(
      (s) => append(s, out, onStdout), onError: (Object e) => error = e, onDone: outDone.complete);
    final stderr = session.stderr.cast<List<int>>().transform(const Utf8Decoder(allowMalformed: true)).listen(
      (s) => append(s, err, onStderr), onError: (Object e) => error = e, onDone: errDone.complete);
    final timer = Timer(const Duration(seconds: 60), () { cancelled = true; session.close(); });
    unawaited(cancel?.then((_) { if (!session.closed) { cancelled = true; session.close(); } }));
    try {
      if (stdin != null) await session.writeBytes(utf8.encode(stdin));
      if (entry != null) await session.writeBytes(utf8.encode(script));
      await session.closeStdin();
      await session.done;
      await Future.wait([outDone.future, errDone.future]);
    } finally { timer.cancel(); session.close(); await stdout.cancel(); await stderr.cancel(); }
    return ExecResult(exitCode: session.exitCode, stdout: out.toString(), stderr: err.toString(),
      outputIncomplete: truncated || cancelled || session.exitCode == null,
      streamError: error ?? (cancelled ? StateError('ADB command cancelled or timed out') : session.exitCode == null ? StateError('ADB command ended without exit status') : null),
      mayStillRun: cancelled || session.exitCode == null);
  }
}

class AdbShellBackend implements ShellBackend {
  AdbShellBackend(this.connection);
  final AdbConnection connection;
  bool _closed = false;
  final _sessions = <AdbShellSession>[];
  @override
  bool get isClosed => _closed || connection.closed;
  @override
  bool get supportsExec => true;
  @override
  bool get supportsTmux => false;
  @override
  Future<ShellSession> openShell({required int width, required int height, Map<String, String>? environment}) async {
    final session = await AdbShellSession.open(connection, pty: true, width: width, height: height);
    if (_closed) { session.close(); throw StateError('ADB terminal closed'); }
    _sessions.add(session);
    unawaited(session.done.then((_) => _sessions.remove(session)));
    return session;
  }
  @override
  Future<ShellSession> execute(String command, {required int width, required int height, Map<String, String>? environment}) async {
    final session = await AdbShellSession.open(connection, command: command, pty: true, width: width, height: height);
    if (_closed) { session.close(); throw StateError('ADB terminal closed'); }
    _sessions.add(session);
    unawaited(session.done.then((_) => _sessions.remove(session)));
    return session;
  }
  @override
  Future<void> ping() async {
    if (isClosed) throw StateError('ADB terminal disconnected');
    final result = await AdbExec(connection).run('true');
    if (!result.succeeded) throw StateError('ADB terminal disconnected');
  }
  @override
  void close() {
    _closed = true;
    for (final session in _sessions.toList()) { session.close(); }
    _sessions.clear();
    // This backend owns its shells, not the shared device connection.
  }
}
