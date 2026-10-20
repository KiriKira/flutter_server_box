import 'dart:convert';

import 'package:server_box/core/adb/adb_shell.dart';
import 'package:server_box/data/model/server/battery.dart';
import 'package:server_box/data/model/server/cpu.dart';
import 'package:server_box/data/model/server/memory.dart';
import 'package:server_box/data/model/server/net_speed.dart';
import 'package:server_box/data/model/server/server.dart';
import 'package:server_box/data/model/server/server_status_update_req.dart';
import 'package:server_box/data/model/server/status_history.dart';
import 'package:server_box/data/model/server/system.dart';
import 'package:server_box/data/provider/server/data_source.dart';
import 'package:server_box/src/rust/api/android.dart' as android_ffi;


class AdbDataSource implements ServerDataSource {
  AdbDataSource(this.exec);
  final AdbExec exec;
  bool rootGranted = false;
  int? lastRequestMs;

  @override
  Future<ServerStatus> fetchStatus(ServerStatus into) async {
    final clock = Stopwatch()..start();
    var result = await exec.run(android_ffi.androidCommand(action: 'status', argument: '', root: rootGranted));
    if (!result.succeeded && rootGranted) {
      rootGranted = false;
      result = await exec.run(android_ffi.androidCommand(action: 'status', argument: '', root: false));
    }
    lastRequestMs = clock.elapsedMilliseconds;
    if (!result.succeeded || result.outputIncomplete) {
      final reason = result.stderr.length > 1000 ? result.stderr.substring(0, 1000) : result.stderr;
      throw StateError('ADB status collection failed (exit ${result.exitCode}): $reason');
    }
    final parsed = jsonDecode(await android_ffi.parseAndroidStatusJson(raw: result.stdout)) as Map<String, dynamic>;
    final raw = Map<String, String>.from(parsed['raw'] as Map);
    final device = Map<String, dynamic>.from(parsed['device'] as Map);
    final available = Map<String, bool>.from(parsed['available'] as Map);
    final guid = exec.connection.credential.deviceGuid;
    if (!exec.connection.credential.localDevice && guid != null && guid.isNotEmpty && device['guid'] != guid) {
      throw StateError('ADB device identity changed; reconnect to the intended phone');
    }
    final status = await getStatus(ServerStatusUpdateReq(ss: into, parsedOutput: raw, system: SystemType.linux));
    status.android = {...device, 'root_enhancement': rootGranted};
    status.batteries.clear();
    if (device['battery_percent'] case final num percent) {
      status.batteries.add(Battery(name: 'Battery', percent: percent.round(), status: BatteryStatus.parse(device['battery_status'] as String?)));
    }
    if (available['mem'] != true) status.mem = const Memory(total: 0, free: 0, avail: 0);
    if (available['net'] != true) status.netSpeed = NetSpeed();
    status.ips = (device['addresses'] as List).cast<String>();
    // Modern Android can deny /proc/stat even to shell. dumpsys gives an
    // instantaneous aggregate; accumulate it rather than treating it as ticks.
    if (available['cpu'] != true) {
      final percent = (device['cpu_percent'] as num?)?.toDouble();
      if (percent != null) {
        final previous = into.cpu.now.firstOrNull;
        final busy = (percent * 1000).round();
        status.cpu.update([SingleCpuCore('cpu', (previous?.user ?? 0) + busy,
          previous?.sys ?? 0, previous?.nice ?? 0,
          (previous?.idle ?? 0) + 100000 - busy, 0, 0, 0)]);
        status.sectionErrs.remove('cpu');
      } else { status.cpu = Cpus(); }
    }
    status.recordSample(timeMs: DateTime.now().millisecondsSinceEpoch);
    return status;
  }
  @override
  Future<List<StatusHistorySample>> fetchHistory({int minutes = 60, int maxPoints = StatusHistory.capacity, DateTime? from, DateTime? to}) async => const [];
  @override
  void close() {}
}
