import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:server_box/core/adb/adb_files.dart';
import 'package:server_box/core/adb/adb_shell.dart';
import 'package:server_box/core/adb/adb_transport.dart';
import 'package:server_box/src/rust/api/android.dart' as android;
import 'package:server_box/src/rust/api/files.dart' as files;

enum AdbScreenState { preparing, connecting, streaming, failed, stopped }

/// A screen borrows an ADB connection; disposing it never disconnects that device.
class AdbScreenSession extends ChangeNotifier {
  AdbScreenSession(this.connection);
  final AdbConnection connection;
  final id = (Random.secure().nextInt(0x7ffffffe) + 1).toRadixString(16).padLeft(8, '0');
  static const _events = EventChannel('tech.kirikira.kiribox/scrcpy/events');
  static AdbScreenSession? _active;
  AdbScreenState state = AdbScreenState.preparing;
  int? texture;
  int width = 0;
  int height = 0;
  int revision = 0;
  double? progress;
  String? error;
  String _log = '';
  bool _closed = false;
  bool _disposed = false;
  bool _nativeStarted = false;
  bool _launched = false;
  bool _uploaded = false;
  String? _staging;
  AdbFileBackend? _upload;
  AdbShellSession? _shell;
  StreamSubscription<dynamic>? _subscription;
  final _logs = <StreamSubscription<String>>[];
  Future<void>? _starting;
  Future<void>? _closing;
  Future<void> _inputs = Future.value();

  void _notify() { if (!_disposed) notifyListeners(); }
  void _check() {
    if (_closed || !identical(_active, this) || !AdbService.isCurrent(connection)) {
      throw StateError('Screen session cancelled or device configuration changed');
    }
  }

  Future<void> start() => _starting ??= _start();
  Future<void> _start() async {
    try {
      if (!Platform.isAndroid || connection.credential.localDevice) throw UnsupportedError('Screen control requires another Android device');
      final previous = _active;
      _active = this;
      await previous?.close();
      _check();
      _subscription = _events.receiveBroadcastStream().listen(_event,
        onError: (Object e) => _fail('$e'), onDone: () { if (!_closed) _fail('Screen event channel closed'); });
      final asset = await AdbService.channel.invokeMapMethod<String, dynamic>('screenAsset');
      _check();
      if (asset?['version'] != '5.0.1' || asset?['bytes'] is! Uint8List) throw StateError('Bundled scrcpy version mismatch');
      final bytes = asset!['bytes'] as Uint8List;
      final backend = _upload = AdbFileBackend(connection);
      var sent = 0;
      await backend.write('/data/local/tmp/serverbox-scrcpy-$id.jar', Stream.fromIterable([bytes]).map((data) {
        _check(); sent += data.length; progress = sent / bytes.length; _notify(); return data;
      }), size: bytes.length, onStaging: (path) => _staging = path);
      _uploaded = true;
      await backend.close(); _upload = null; _staging = null;
      _check();
      state = AdbScreenState.connecting; progress = null; _notify();
      _shell = await AdbShellSession.open(connection,
        command: android.androidCommand(action: 'scrcpy_start', argument: id, root: false));
      _launched = true;
      _check();
      void log(String chunk) { _log = '$_log$chunk'; if (_log.length > 4096) _log = _log.substring(_log.length - 4096); }
      _logs.add(_shell!.stdout.cast<List<int>>().transform(const Utf8Decoder(allowMalformed: true)).listen(log, onError: (Object e) => _fail('$e')));
      _logs.add(_shell!.stderr.cast<List<int>>().transform(const Utf8Decoder(allowMalformed: true)).listen(log, onError: (Object e) => _fail('$e')));
      unawaited(_shell!.done.then((_) { if (!_closed) _fail('scrcpy server exited\n$_log'); }));
      _nativeStarted = true;
      texture = await connection.startScreen(id);
      _check(); _notify();
    } catch (e) {
      if (!_closed) _fail('$e');
      rethrow;
    }
  }

  void _event(dynamic raw) {
    if (_closed || raw is! Map || raw['session'] != id) return;
    switch (raw['state']) {
      case 'size':
        width = raw['width'] as int; height = raw['height'] as int; revision = raw['revision'] as int;
      case 'streaming': state = AdbScreenState.streaming;
      case 'error': _fail('${raw['stage']}: ${raw['message']}\n$_log'); return;
    }
    _notify();
  }

  void _fail(String message) {
    if (_closed) return;
    error = message.trim(); state = AdbScreenState.failed; _notify();
    unawaited(close());
  }

  Future<void> _send(String method, Map<String, Object> arguments) {
    final next = _inputs.then((_) async {
      if (!_closed && _nativeStarted) await AdbService.channel.invokeMethod<void>(method, {'session': id, ...arguments});
    }).catchError((Object e) { if (!_closed) _fail('$e'); });
    return _inputs = next;
  }
  Future<void> touch(int action, int pointer, double x, double y, int geometryRevision) => _send('screenTouch', {
    'action': action, 'pointer': pointer, 'x': x, 'y': y, 'revision': geometryRevision,
  });
  Future<void> key(int key) => _send('screenKey', {'key': key});
  Future<void> releasePointers() => _send('screenRelease', const {});

  Future<void> close() => _closing ??= _close();
  Future<void> _close() async {
    _closed = true;
    await _upload?.close();
    try { await _starting; } catch (_) { /* Starting may have been cancelled by close. */ }
    if (_nativeStarted) {
      try { await AdbService.channel.invokeMethod<void>('screenStop', {'session': id}).timeout(const Duration(seconds: 2)); } catch (_) {}
    }
    await _subscription?.cancel(); _subscription = null;
    _shell?.close();
    for (final log in _logs) { await log.cancel(); }
    _logs.clear();
    if ((_launched || _uploaded || _staging != null) && AdbService.isCurrent(connection)) {
      final cancelled = Completer<void>();
      final timer = Timer(const Duration(seconds: 3), cancelled.complete);
      try {
        if (_launched || _uploaded) await AdbExec(connection).run(android.androidCommand(action: 'scrcpy_stop', argument: id, root: false), cancel: cancelled.future);
        if (_staging case final path?) await AdbExec(connection).run(files.filesRemoveCommand(path: path, recursive: false, force: true), cancel: cancelled.future);
      } catch (_) {} finally { timer.cancel(); }
    }
    texture = null;
    if (state != AdbScreenState.failed) state = AdbScreenState.stopped;
    if (identical(_active, this)) _active = null;
    _notify();
  }

  @override
  void dispose() { _disposed = true; unawaited(close()); super.dispose(); }
}
