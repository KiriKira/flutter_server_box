import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:server_box/core/adb/adb_transport.dart';
import 'package:server_box/data/model/ai/ask_ai_models.dart';
import 'package:server_box/data/model/server/adb_credential.dart';
import 'package:server_box/data/model/server/capabilities.dart';
import 'package:server_box/data/model/server/server_private_info.dart';
import 'package:server_box/data/model/server/ssh_credential.dart';

void main() {
  test('a stale terminal cannot reconnect after its device configuration changes', () async {
    const old = AdbCredential(host: 'old-phone', port: 1234);
    const next = AdbCredential(host: 'new-phone', port: 2345);
    AdbService.configure('edited-phone', old);
    AdbService.configure('edited-phone', next);
    await expectLater(AdbService.connect('edited-phone', old), throwsStateError);
    AdbService.configure('edited-phone', null);
  });
  test('ADB never falls through to a parked SSH environment', () {
    final phone = Spi(name: 'phone', adbEnabled: true, adb: const AdbCredential(localDevice: true),
      ssh: const SshCredential(ip: 'localhost', user: 'termux'));
    expect(phone.transport, ServerTransport.adb);
    expect(phone.fallbackTransport, isNull);
    expect(ServerCapabilities.ofSpi(phone), isA<AdbCapabilities>());
    expect(phone.copyWith(adbEnabled: false).transport, ServerTransport.ssh);
    expect(Spi.fromJson(jsonDecode(jsonEncode(phone)) as Map<String, dynamic>).adb, phone.adb);
    expect(phone.toJson().toString(), isNot(contains('privateKey')));
  });
  test('Android destructive commands cannot be marked as read-only', () {
    for (final command in ['pm clear com.example', 'pm uninstall com.example', 'settings put global a 1', 'su -c id']) {
      final proposal = AskAiCommand(command: command, modelSafeToRun: true);
      expect(proposal.canAutoRun, false, reason: command);
    }
    final proposal = AskAiCommand.fromToolCall(id: 'x', name: 'android_device', args: {
      'server_id': 'phone', 'action': 'clear', 'argument': 'com.example', 'safe_to_run': true,
    });
    expect(proposal.risk, AskAiCommandRisk.destructive);
  });
}
