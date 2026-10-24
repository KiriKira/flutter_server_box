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

/// Video presets; the numbers live with the launch command (`sbm_parser::android::scrcpy_quality`).
enum AdbScreenQuality {
  auto, high, balanced, smooth, saver;

  /// A LAN address gets [high]. Anything else — a Tailscale (100.64.0.0/10, fd7a:115c:a1e0::/48,
  /// *.ts.net) or other VPN address, a public address, a bare host name — starts at [balanced]:
  /// over a relay or mobile data 8 Mbps only queues seconds of video behind every touch.
  AdbScreenQuality resolve(String host) {
    if (this != auto) return this;
    final name = host.trim().toLowerCase();
    if (name == 'localhost' || name.endsWith('.local') || name.endsWith('.lan')) return high;
    final address = InternetAddress.tryParse(name.startsWith('[') && name.endsWith(']') ? name.substring(1, name.length - 1) : name);
    if (address == null) return balanced;
    final b = address.rawAddress;
    if (address.type == InternetAddressType.IPv4) {
      final lan = b[0] == 10 || (b[0] == 172 && b[1] >= 16 && b[1] < 32) || (b[0] == 192 && b[1] == 168) ||
        (b[0] == 169 && b[1] == 254) || b[0] == 127;
      return lan ? high : balanced;
    }
    // Unique-local fc00::/7 holds Tailscale's fd7a:115c:a1e0::/48, so only link-local counts as LAN.
    return address.isLinkLocal || address.isLoopback ? high : balanced;
  }

  /// The next preset down, or null at the bottom.
  AdbScreenQuality? get lower => switch (this) {
    AdbScreenQuality.auto || AdbScreenQuality.high => AdbScreenQuality.balanced,
    AdbScreenQuality.balanced => AdbScreenQuality.smooth,
    AdbScreenQuality.smooth => AdbScreenQuality.saver,
    AdbScreenQuality.saver => null,
  };
}

/// A screen borrows an ADB connection; disposing it never disconnects that device.
class AdbScreenSession extends ChangeNotifier {
  AdbScreenSession(this.connection, {this.root = false, this.quality = AdbScreenQuality.high})
    : assert(quality != AdbScreenQuality.auto);
  final AdbConnection connection;
  final bool root;
  final AdbScreenQuality quality;
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
  String? inputWarning;
  int inputRequests = 0;
  int nativeAccepted = 0;
  int coalesced = 0;
  /// Whether video ever played: a later failure is then the link, worth reconnecting.
  bool streamed = false;
  String? failureStage;
  /// Smoothed control round trip in ms, -1 until measured.
  int rtt = -1;
  /// How far video runs behind the fastest frame seen recently, in ms.
  int lag = 0;
  /// How long the oldest control write has waited for adbd's acknowledgement, in ms.
  int pending = 0;
  int kbps = 0;
  int fps = 0;
  /// Counts the native side's once-a-second statistics.
  int statsTicks = 0;
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
  final _pending = <(String, Map<String, Object>)>[];
  bool _pumping = false;
  Future<void> _pumped = Future.value();

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
      if (root) {
        final cancel = Completer<void>();
        final timer = Timer(const Duration(seconds: 12), cancel.complete);
        try {
          final probe = await AdbExec(connection).run(android.androidCommand(action: 'root_probe', argument: '', root: false), cancel: cancel.future);
          if (!probe.succeeded) throw StateError('ADB shell root permission was not granted. Allow su for shell on the target before retrying.\n${probe.combined}');
        } finally { timer.cancel(); }
        _check();
      }
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
        command: android.androidCommand(action: 'scrcpy_start', argument: '$id:${quality.name}', root: root));
      _launched = true;
      _check();
      void log(String chunk) {
        _log = '$_log$chunk'; if (_log.length > 8192) _log = _log.substring(_log.length - 8192);
        if (_log.contains('INJECT_EVENTS permission')) {
          if (inputWarning == null) { inputWarning = 'input_permission'; _notify(); }
        } else if (_log.contains('InputManager.injectInputEvent')) {
          if (inputWarning == null) { inputWarning = 'input_api'; _notify(); }
        } else if (_log.contains('Ignore positional event generated for size')) {
          if (inputWarning == null) { inputWarning = 'input_geometry'; _notify(); }
        }
      }
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
      case 'streaming': state = AdbScreenState.streaming; streamed = true;
      case 'stats':
        rtt = raw['rtt'] as int; lag = raw['lag'] as int; pending = raw['pending'] as int;
        kbps = raw['kbps'] as int; fps = raw['fps'] as int; statsTicks++;
      case 'error':
        failureStage = raw['stage'] as String?;
        _fail('${raw['stage']}: ${raw['message']}\n$_log'); return;
    }
    _notify();
  }

  void _fail(String message) {
    if (_closed) return;
    error = message.trim(); state = AdbScreenState.failed; _notify();
    unawaited(close());
  }

  /// One platform call in flight; a queued move is replaced by the next move of the same
  /// finger, so a busy platform thread delays the latest position rather than a backlog.
  Future<void> _send(String method, Map<String, Object> arguments) {
    if (method != 'screenRelease') inputRequests++;
    if (method == 'screenTouch' && arguments['action'] == 2) {
      for (var i = _pending.length - 1; i >= 0; i--) {
        final (queued, previous) = _pending[i];
        if (queued == 'screenRelease') break;
        if (queued == 'screenTouch' && previous['pointer'] == arguments['pointer']) {
          // Never across this finger's DOWN/UP or a geometry change.
          if (previous['action'] == 2 && previous['revision'] == arguments['revision']) {
            _pending[i] = (method, arguments); coalesced++;
            return _pumped;
          }
          break;
        }
      }
    }
    _pending.add((method, arguments));
    if (!_pumping) { _pumping = true; _pumped = _pump(); }
    return _pumped;
  }

  Future<void> _pump() async {
    try {
      while (_pending.isNotEmpty && !_closed) {
        final (method, arguments) = _pending.removeAt(0);
        if (!_nativeStarted) continue;
        await AdbService.channel.invokeMethod<void>(method, {'session': id, ...arguments});
        if (method != 'screenRelease') nativeAccepted++;
      }
    } catch (e) {
      _pending.clear();
      if (!_closed) _fail('$e');
    } finally {
      _pumping = false;
    }
  }
  Future<void> touch(int action, int pointer, double x, double y, int geometryRevision) => _send('screenTouch', {
    'action': action, 'pointer': pointer, 'x': x, 'y': y, 'revision': geometryRevision,
  });
  Future<void> key(int key) => _send('screenKey', {'key': key});
  Future<void> releasePointers() => _send('screenRelease', const {});

  String get diagnostics => 'scrcpy 5.0.1; mode=${root ? 'root' : 'shell'}; quality=${quality.name}; state=${state.name}\n'
    'video=$width x $height; revision=$revision; $kbps kbps; $fps fps; lag=$lag ms\n'
    'control rtt=${rtt < 0 ? 'unknown' : '$rtt ms'}; awaiting ack=$pending ms\n'
    'input requests=$inputRequests; coalesced moves=$coalesced; accepted by native queue=$nativeAccepted (not a target execution acknowledgement)\n'
    '${error ?? ''}\n$_log';

  Future<void> wake() async {
    if (!AdbService.isCurrent(connection)) throw StateError('ADB connection changed');
    final cancel = Completer<void>();
    final timer = Timer(const Duration(seconds: 10), cancel.complete);
    try {
      final result = await AdbExec(connection).run(android.androidCommand(action: 'screen_wake', argument: '', root: root), cancel: cancel.future);
      if (!result.succeeded || result.outputIncomplete) throw StateError(result.combined.isEmpty ? 'Wake request timed out or failed' : result.combined);
    } finally { timer.cancel(); }
  }

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
        if (_launched || _uploaded) await AdbExec(connection).run(android.androidCommand(action: 'scrcpy_stop', argument: id, root: root), cancel: cancelled.future);
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
