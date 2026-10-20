import 'dart:async';
import 'dart:io';

import 'package:fl_lib/fl_lib.dart';
import 'package:material_ui/material_ui.dart';
import 'package:server_box/core/adb/adb_shell.dart';
import 'package:server_box/core/adb/adb_transport.dart';
import 'package:server_box/core/extension/context/locale.dart';
import 'package:server_box/data/model/server/adb_credential.dart';
import 'package:server_box/src/rust/api/android.dart' as android_ffi;


class AdbConnectionFields extends StatefulWidget {
  const AdbConnectionFields({super.key, required this.id, required this.value, required this.onChanged});
  final String id;
  final AdbCredential value;
  final ValueChanged<AdbCredential> onChanged;
  @override
  State<AdbConnectionFields> createState() => _AdbConnectionFieldsState();
}

class _AdbConnectionFieldsState extends State<AdbConnectionFields> {
  late final _host = TextEditingController(text: widget.value.host);
  late final _port = TextEditingController(text: '${widget.value.port}');
  late bool _local = widget.value.localDevice;
  late bool _tls = widget.value.tls;
  late String? _guid = widget.value.deviceGuid;
  bool _busy = false;
  String? _message;
  Timer? _pairTimer;
  List<Map<String, dynamic>> _found = const [];

  AdbCredential get _value => AdbCredential(host: _host.text.trim(), port: int.tryParse(_port.text) ?? -1,
    localDevice: _local, tls: _tls, deviceGuid: _guid);
  void _changed() { _guid = null; widget.onChanged(_value); }
  @override
  void dispose() { _host.dispose(); _port.dispose(); _pairTimer?.cancel(); super.dispose(); }

  Future<void> _run(Future<void> Function() action) async {
    setState(() { _busy = true; _message = null; });
    try { await action(); }
    catch (e) { if (mounted) setState(() => _message = e.toString()); }
    finally { if (mounted) setState(() => _busy = false); }
  }

  Future<void> _test() => _run(() async {
    final connection = await AdbService.connect('${widget.id}/test', _value);
    try {
      final result = await AdbExec(connection).run(android_ffi.androidCommand(action: 'guid', argument: '', root: false));
      if (!result.succeeded) throw StateError(result.combined);
      _guid = result.stdout.trim().selfNotEmptyOrNull;
      widget.onChanged(_value);
      if (mounted) setState(() => _message = l10n.adbConnected);
    } finally { AdbService.disconnect('${widget.id}/test'); }
  });

  Future<void> _pair() async {
    final host = TextEditingController(text: _host.text);
    final port = TextEditingController();
    final code = TextEditingController();
    final fields = await context.showRoundDialog<(String, int, String)>(
      title: l10n.adbPair,
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        TextField(controller: host, decoration: InputDecoration(labelText: l10n.adbHost)),
        TextField(controller: port, keyboardType: TextInputType.number, decoration: InputDecoration(labelText: l10n.adbPairPort)),
        TextField(controller: code, obscureText: true, keyboardType: TextInputType.number, maxLength: 6,
          decoration: InputDecoration(labelText: l10n.adbCode)),
      ]),
      actions: [Btn.cancel(), Btn.ok(onTap: () {
        final p = int.tryParse(port.text);
        if (p == null || p < 1 || p > 65535 || !RegExp(r'^\d{6}$').hasMatch(code.text)) return;
        context.popDialog((host.text.trim(), p, code.text));
      })],
    );
    WidgetsBinding.instance.addPostFrameCallback((_) { host.dispose(); port.dispose(); code.dispose(); });
    if (fields == null || !mounted) return;
    await _run(() async {
      await AdbService.pair(widget.id, fields.$1, fields.$2, fields.$3);
      _guid = null;
      widget.onChanged(_value);
      if (mounted) setState(() => _message = l10n.adbConnected);
    });
  }

  Future<void> _localPair() => _run(() async {
    await AdbService.channel.invokeMethod<void>('startLocalPairing');
    _pairTimer?.cancel();
    _pairTimer = Timer.periodic(const Duration(seconds: 2), (timer) async {
      try {
        final state = await AdbService.channel.invokeMethod<String>('pairingState');
        if (!mounted) { timer.cancel(); return; }
        if (state == 'paired') {
          timer.cancel();
          await _test();
        } else if (state == 'timeout' || state == 'cancelled') {
          timer.cancel(); setState(() => _message = state);
        }
      } catch (_) { timer.cancel(); }
    });
    if (mounted) setState(() => _message = l10n.adbPairWait);
    await AdbService.channel.invokeMethod<void>('settings');
  });

  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
    if (!AdbService.supported) Text(l10n.adbUnsupported),
    if (Platform.isAndroid || _local) SwitchListTile(
      title: Text(l10n.adbLocal), value: _local, onChanged: _busy ? null : (v) {
        setState(() { _local = v; if (v) { _host.text = '127.0.0.1'; _port.text = '0'; } }); _changed();
      }),
    SwitchListTile(title: Text(l10n.adbWireless), value: _tls, onChanged: _busy ? null : (v) { setState(() => _tls = v); _changed(); }),
    TextField(controller: _host, enabled: !_busy && !_local, onChanged: (_) => _changed(),
      decoration: InputDecoration(labelText: l10n.adbHost)),
    TextField(controller: _port, enabled: !_busy, keyboardType: TextInputType.number, onChanged: (_) => _changed(),
      decoration: InputDecoration(labelText: l10n.adbPort)),
    Padding(padding: const EdgeInsets.all(8), child: Text(l10n.adbTip, style: UIs.text12Grey)),
    Wrap(spacing: 8, runSpacing: 4, children: [
      if (_tls) TextButton(onPressed: _busy ? null : _pair, child: Text(l10n.adbPair)),
      if (_tls && _local && Platform.isAndroid) TextButton(onPressed: _busy ? null : _localPair, child: Text(l10n.adbLocalPair)),
      if (_tls && Platform.isAndroid) TextButton(onPressed: _busy ? null : () => _run(() async {
        final found = await AdbService.discover(local: _local);
        if (mounted) setState(() => _found = found);
      }), child: Text(l10n.adbDiscover)),
      TextButton(onPressed: _busy ? null : _test, child: Text(l10n.adbTest)),
    ]),
    for (final device in _found) ListTile(title: Text('${device['name']}'), subtitle: Text('${device['host']}:${device['port']}'),
      onTap: () { setState(() { _host.text = '${device['host']}'; _port.text = '${device['port']}'; _found = const []; }); _changed(); }),
    if (_busy) const LinearProgressIndicator(),
    if (_message case final message?) Padding(padding: const EdgeInsets.all(8), child: SelectableText(message)),
  ]);
}
