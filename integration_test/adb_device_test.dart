import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:server_box/core/adb/adb_files.dart';
import 'package:server_box/core/adb/adb_operations.dart';
import 'package:server_box/core/adb/adb_shell.dart';
import 'package:server_box/core/adb/adb_transport.dart';
import 'package:server_box/data/model/server/adb_credential.dart';
import 'package:server_box/data/provider/server/adb_source.dart';
import 'package:server_box/data/res/status.dart';
import 'package:server_box/src/rust/frb_generated.dart';

/// This is intentionally opt-in: the CI harness controls the emulator's
/// Settings pairing dialog, while the actual app performs TLS pairing and IO.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Wireless debugging pairs and manages an Android device', (_) async {
    await RustLib.init();
    final support = await getApplicationSupportDirectory();
    File state(String name) => File('${support.path}/kiribox-adb-$name');
    Future<void> waitFor(String name) async {
      final deadline = DateTime.now().add(const Duration(minutes: 2));
      while (!await state(name).exists()) {
        if (DateTime.now().isAfter(deadline)) throw StateError('CI pairing harness did not produce $name');
        await Future<void>.delayed(const Duration(milliseconds: 300));
      }
    }
    await state('ready').writeAsString('ready');
    await waitFor('permission');
    await AdbService.channel.invokeMethod<void>('startLocalPairing');
    await state('foreground').writeAsString('ready');
    try {
      await waitFor('pair.json');
      final pairing = jsonDecode(await state('pair.json').readAsString()) as Map<String, dynamic>;
      await AdbService.pair('integration-phone', pairing['host'] as String,
        pairing['port'] as int, pairing['code'] as String);
      await state('pair.json').delete();
      final connection = await AdbService.connect('integration-phone', const AdbCredential(localDevice: true));
      await state('paired').writeAsString('paired');
      await waitFor('resumed');
      final exec = AdbExec(connection);
      final output = await exec.run("printf 'KIRIBOX_ADB_OK'; printf 'separate-error' >&2; exit 17");
      expect(output.stdout, 'KIRIBOX_ADB_OK');
      expect(output.stderr, 'separate-error');
      expect(output.exitCode, 17);
      expect(output.outputIncomplete, false);

      final status = await AdbDataSource(exec).fetchStatus(InitStatus.status);
      expect(status.android?['model'], isNotEmpty);
      expect(status.android?['api'], '35');

      final files = AdbFileBackend(connection);
      final remote = '/data/local/tmp/serverbox-integration.bin';
      final bytes = List<int>.generate(100000, (i) => i % 256);
      try {
        await files.write(remote, Stream.value(bytes), size: bytes.length);
        expect(await files.read(remote).expand((chunk) => chunk).toList(), bytes);
        expect((await files.list('/data/local/tmp')).any((entry) => entry.name == 'serverbox-integration.bin'), true);
      } finally { await files.remove(remote); await files.close(); }

      final terminal = AdbShellBackend(connection);
      final shell = await terminal.openShell(width: 90, height: 28);
      final terminalOutput = StringBuffer();
      final marker = Completer<void>();
      final reader = shell.stdout!.cast<List<int>>().transform(utf8.decoder).listen((text) {
        terminalOutput.write(text);
        if (!marker.isCompleted && terminalOutput.toString().contains('TERMINAL_READY')) marker.complete();
      });
      shell.resizeTerminal(100, 32);
      shell.write(utf8.encode("printf 'TERMINAL_%s\\n' READY\n"));
      await marker.future.timeout(const Duration(seconds: 15));
      terminal.close();
      await reader.cancel();
      expect((await exec.run('true')).succeeded, true);

      final ops = AdbOperations(connection);
      final screenshot = await ops.screenshot();
      expect(screenshot.take(8), [137, 80, 78, 71, 13, 10, 26, 10]);
      await state('screenshot.png').writeAsBytes(screenshot);
      expect((await ops.apps()).any((app) => app['package'] == 'com.android.settings'), true);
      final install = await ops.install(state('fixture.apk'));
      expect(install, contains('tech.kirikira.kiribox.fixture'));
      expect((await ops.apps()).any((app) => app['package'] == 'tech.kirikira.kiribox.fixture'), true);
      await ops.action('uninstall', argument: 'tech.kirikira.kiribox.fixture');
      final cancel = Completer<void>();
      final running = exec.run('sleep 30', cancel: cancel.future);
      await Future<void>.delayed(const Duration(milliseconds: 500));
      cancel.complete();
      expect((await running.timeout(const Duration(seconds: 10))).outputIncomplete, true);
      expect((await exec.run('true')).succeeded, true);
      await state('passed').writeAsString('TLS pairing, status, shell v2, PTY, sync, screenshot, APK install and cancellation passed');
    } finally {
      AdbService.disconnect('integration-phone');
      await AdbService.channel.invokeMethod<void>('stopPairing');
    }
  }, skip: !Platform.isAndroid || !const bool.fromEnvironment('KIRIBOX_ADB_E2E'),
    timeout: const Timeout(Duration(minutes: 8)));
}
