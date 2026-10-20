import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:server_box/core/adb/adb_files.dart';
import 'package:server_box/core/adb/adb_shell.dart';
import 'package:server_box/core/adb/adb_transport.dart';
import 'package:server_box/data/model/server/server_exec.dart';
import 'package:server_box/src/rust/api/android.dart' as android_ffi;


class AdbOperations {
  const AdbOperations(this.connection);
  final AdbConnection connection;
  Future<ExecResult> action(String action, {String argument = '', Future<void>? cancel}) async {
    final result = await AdbExec(connection).run(android_ffi.androidCommand(action: action, argument: argument, root: false), cancel: cancel);
    if (!result.succeeded || result.outputIncomplete) throw StateError(result.combined.isEmpty ? 'ADB operation did not finish' : result.combined);
    return result;
  }
  Future<List<Map<String, dynamic>>> apps() async {
    final result = await action('apps');
    return (jsonDecode(await android_ffi.parseAndroidAppsJson(raw: result.stdout)) as List)
        .map((e) => Map<String, dynamic>.from(e as Map)).toList();
  }

  /// Stream the chosen APK to a unique path. Do not replay an install after a
  /// dropped connection; package manager may have committed it already.
  Future<String> install(File file, {void Function(int sent, int total)? progress, Future<void>? cancel}) async {
    if (!file.path.toLowerCase().endsWith('.apk')) throw const FormatException('Select an APK file');
    final size = await file.length();
    if (size == 0) throw const FormatException('Empty APK');
    final Map<String, dynamic>? metadata = Platform.isAndroid
        ? Map<String, dynamic>.from((await AdbService.channel.invokeMapMethod<String, dynamic>('apkInfo', {'path': file.path}))!)
        : null;
    final backend = AdbFileBackend(connection);
    final path = '/data/local/tmp/serverbox-${DateTime.now().microsecondsSinceEpoch}-${_next++}.apk';
    var sent = 0;
    var cancelled = false;
    unawaited(cancel?.then((_) { cancelled = true; return backend.close(); }));
    try {
      await backend.write(path, file.openRead().map((bytes) {
        sent += bytes.length; progress?.call(sent, size); return bytes;
      }), size: size);
      if (cancelled) throw StateError('APK upload cancelled');
      final result = await action('install', argument: path, cancel: cancel);
      if (metadata != null) {
        final verification = await action('verify_install', argument: metadata['package'] as String, cancel: cancel);
        final installed = jsonDecode(await android_ffi.parseAndroidAppsJson(raw: verification.stdout)) as List;
        if (!installed.any((e) => e['package'] == metadata['package'] && e['version'] == metadata['version'])) {
          throw StateError('Package manager reported success, but the installed version could not be verified');
        }
        return '${metadata['package']} · ${metadata['version']} · ${result.stdout.trim()}';
      }
      return result.stdout.trim();
    } finally {
      await backend.close();
      try { await action('remove_temp', argument: path); } catch (_) {}
    }
  }
  static int _next = 0;

  Future<Uint8List> screenshot({Future<void>? cancel}) async {
    final session = await AdbShellSession.open(connection,
      command: android_ffi.androidCommand(action: 'screenshot', argument: '', root: false));
    final bytes = BytesBuilder(copy: false);
    final error = StringBuffer();
    final stderr = session.stderr.listen((chunk) {
      if (error.length < 4096) error.write(utf8.decode(chunk, allowMalformed: true));
    });
    unawaited(cancel?.then((_) => session.close()));
    try {
      await for (final chunk in session.stdout.timeout(const Duration(seconds: 20))) {
        if (bytes.length + chunk.length > 32 * 1024 * 1024) throw StateError('Screenshot exceeds 32 MiB');
        bytes.add(chunk);
      }
      if (session.exitCode != 0) throw StateError('ADB screenshot failed: $error');
      final result = bytes.takeBytes();
      const png = [137, 80, 78, 71, 13, 10, 26, 10];
      if (result.length < png.length || !List.generate(8, (i) => result[i] == png[i]).every((e) => e)) {
        throw StateError('ADB screenshot did not return PNG data');
      }
      return result;
    } finally { session.close(); await stderr.cancel(); }
  }
}
