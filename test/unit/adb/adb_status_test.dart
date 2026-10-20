import 'package:flutter_test/flutter_test.dart';
import 'package:server_box/core/adb/adb_shell.dart';
import 'package:server_box/core/adb/adb_transport.dart';
import 'package:server_box/data/model/server/adb_credential.dart';
import 'package:server_box/data/model/server/server_exec.dart';
import 'package:server_box/data/provider/server/adb_source.dart';
import 'package:server_box/data/res/status.dart';

import '../../helpers/rust_lib_helper.dart';

class SnapshotExec extends AdbExec {
  SnapshotExec(this.responses) : super(AdbConnection('phone', const AdbCredential(host: 'phone', port: 1234)));
  final List<ExecResult> responses;
  @override
  Future<ExecResult> run(String script, {String? entry, Map<String, String>? env, String? stdin,
    OnExecOutput? onStdout, OnExecOutput? onStderr, Future<void>? cancel}) async => responses.removeAt(0);
}
String snapshot({String cpu = 'cpu 10 0 5 85 0 0 0\ncpu0 10 0 5 85 0 0 0', String cpuInfo = '', String mem = 'MemTotal: 1024 kB\nMemFree: 256 kB\nMemAvailable: 512 kB'}) => '''
__SB_ADB_identity__
uid=2000(shell) gid=2000(shell)
__SB_ADB_props__
[ro.product.model]: [Pixel]
[ro.product.brand]: [Google]
[ro.build.version.release]: [15]
__SB_ADB_cpu__
$cpu
__SB_ADB_cpuinfo__
$cpuInfo
__SB_ADB_mem__
$mem
__SB_ADB_batteryInfo__
 level: 25
 scale: 50
 status: 2
 temperature: 320
''';
ExecResult success(String output) => ExecResult(exitCode: 0, stdout: output, stderr: '');
void main() {
  setUpAll(initRustLibForTest);
  test('Android readings reach common metrics without inventing a first CPU sample', () async {
    final source = AdbDataSource(SnapshotExec([
      success(snapshot()), success(snapshot(cpu: 'cpu 20 0 5 95 0 0 0\ncpu0 20 0 5 95 0 0 0')),
    ]));
    var status = await source.fetchStatus(InitStatus.status);
    expect(status.android?['model'], 'Pixel');
    expect(status.android?['battery_temperature'], 32.0);
    expect(status.batteries.single.percent, 50);
    expect(status.mem.total, 1024);
    expect(status.cpu.usedPercent(), isNull);
    status = await source.fetchStatus(status);
    expect(status.cpu.usedPercent(), 50);
    expect(status.history.length, 2);
  });
  test('dumpsys CPU percentages become windows when proc counters are denied', () async {
    final source = AdbDataSource(SnapshotExec([
      success(snapshot(cpu: 'Permission denied', cpuInfo: '60% TOTAL: 40% user + 20% kernel')),
      success(snapshot(cpu: 'Permission denied', cpuInfo: '25% TOTAL: 15% user + 10% kernel')),
    ]));
    var status = await source.fetchStatus(InitStatus.status);
    expect(status.cpu.usedPercent(), isNull);
    status = await source.fetchStatus(status);
    expect(status.cpu.usedPercent(), 25);
    expect(status.sectionErrs.containsKey('cpu'), false);
  });
  test('root denial falls back to shell, while unavailable metrics stay absent', () async {
    final source = AdbDataSource(SnapshotExec([
      const ExecResult(exitCode: 1, stdout: '', stderr: 'su denied'),
      success(snapshot(cpu: 'Permission denied', mem: 'Permission denied')),
    ]))..rootGranted = true;
    final status = await source.fetchStatus(InitStatus.status);
    expect(source.rootGranted, false);
    expect(status.android?['root_enhancement'], false);
    expect(status.cpu.usedPercent(), isNull);
    expect(status.mem.total, 0);
    expect(status.sectionErrs['cpu'], isNotNull);
    expect(status.batteries.single.percent, 50);
  });
}
