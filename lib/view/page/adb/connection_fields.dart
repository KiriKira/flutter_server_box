import 'dart:async';
import 'dart:io';

import 'package:fl_lib/fl_lib.dart';
import 'package:icons_plus/icons_plus.dart';
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
    final host = _host.text.trim();
    final address = TextEditingController(text: '${host.contains(':') ? '[$host]' : host}:');
    final code = TextEditingController();
    var submitted = false;
    final fields = await context.showRoundDialog<(String, int, String)>(
      title: l10n.adbPair,
      child: StatefulBuilder(builder: (dialogContext, setDialogState) {
        final endpoint = _pairEndpoint(address.text);
        final validCode = RegExp(r'^\d{6}$').hasMatch(code.text.trim());
        void submit() {
          setDialogState(() => submitted = true);
          if (endpoint == null || !validCode) return;
          dialogContext.popDialog((endpoint.$1, endpoint.$2, code.text.trim()));
        }
        return SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, children: [
          Padding(padding: const EdgeInsets.all(8), child: Text(l10n.adbPairTip, style: UIs.text12Grey)),
          Input(controller: address, type: TextInputType.url, label: l10n.adbPairAddress,
            hint: '192.168.1.100:37123', icon: BoxIcons.bx_server, suggestion: false,
            errorText: submitted && endpoint == null ? l10n.adbPairAddressInvalid : null,
            onChanged: (_) => setDialogState(() {})),
          Input(controller: code, type: TextInputType.number, label: l10n.adbCode,
            icon: Icons.pin_outlined, obscureText: true, maxLength: 6, suggestion: false,
            errorText: submitted && !validCode ? l10n.adbCodeInvalid : null,
            onChanged: (_) => setDialogState(() {}), onSubmitted: (_) => submit()),
          Row(mainAxisAlignment: MainAxisAlignment.end, children: [
            Btn.cancel(), Btn.text(text: l10n.adbPair, onTap: submit),
          ]),
        ]));
      }),
    );
    WidgetsBinding.instance.addPostFrameCallback((_) { address.dispose(); code.dispose(); });
    if (fields == null || !mounted) return;
    await _run(() async {
      await AdbService.pair(widget.id, fields.$1, fields.$2, fields.$3);
      if (!mounted) return;
      if (_host.text.trim() != fields.$1) _port.text = '0';
      _host.text = fields.$1;
      _tls = true;
      _guid = null;
      widget.onChanged(_value);
      setState(() => _message = l10n.adbPaired);
    });
  }

  Future<void> _localPair() => _run(() async {
    _tls = true;
    _changed();
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
    if (Platform.isAndroid || _local) ListTile(
      leading: const Icon(Icons.phone_android), title: Text(l10n.adbLocal),
      trailing: SwitchX(value: _local, onChanged: _busy ? null : (v) {
        setState(() { _local = v; if (v) { _host.text = '127.0.0.1'; _port.text = '0'; } }); _changed();
      }),
    ).cardx,
    ListTile(leading: const Icon(Icons.wifi), title: Text(l10n.adbWireless),
      trailing: SwitchX(value: _tls, onChanged: _busy ? null : (v) { setState(() => _tls = v); _changed(); }),
    ).cardx,
    Input(controller: _host, enabled: !_busy && !_local, onChanged: (_) => _changed(),
      label: l10n.adbHost, icon: BoxIcons.bx_server, type: TextInputType.url,
      hint: '192.168.1.100', suggestion: false),
    Input(controller: _port, enabled: !_busy, type: TextInputType.number, onChanged: (_) => _changed(),
      label: l10n.adbPort, icon: Bootstrap.number_123, suggestion: false),
    ListTile(
      leading: const Icon(Icons.link), title: Text(l10n.adbPairDevice),
      subtitle: Text(l10n.adbPair, style: UIs.text12Grey),
      trailing: const Icon(Icons.chevron_right), onTap: _busy ? null : _pair,
    ).cardx,
    if (_local && Platform.isAndroid) ListTile(
      leading: const Icon(Icons.notifications_outlined), title: Text(l10n.adbLocalPair),
      subtitle: Text(l10n.adbPairWait, style: UIs.text12Grey),
      trailing: const Icon(Icons.chevron_right), onTap: _busy ? null : _localPair,
    ).cardx,
    Padding(padding: const EdgeInsets.all(8), child: Text(l10n.adbTip, style: UIs.text12Grey)),
    Wrap(spacing: 8, runSpacing: 4, children: [
      if (_tls && Platform.isAndroid) Btn.text(onTap: _busy ? null : () => _run(() async {
        final found = await AdbService.discover(local: _local);
        if (mounted) setState(() => _found = found);
      }), text: l10n.adbDiscover),
      Btn.text(onTap: _busy ? null : _test, text: l10n.adbTest),
    ]),
    for (final device in _found) ListTile(title: Text('${device['name']}'), subtitle: Text('${device['host']}:${device['port']}'),
      onTap: () { setState(() { _host.text = '${device['host']}'; _port.text = '${device['port']}'; _found = const []; }); _changed(); }),
    if (_busy) const LinearProgressIndicator(),
    if (_message case final message?) Padding(padding: const EdgeInsets.all(8), child: SelectableText(message)),
  ]);
}

(String, int)? _pairEndpoint(String address) {
  try {
    final uri = Uri.parse('adb://${address.trim()}');
    if (uri.host.isEmpty || !uri.hasPort || uri.port < 1 || uri.port > 65535 ||
        uri.userInfo.isNotEmpty || uri.path.isNotEmpty || uri.hasQuery || uri.hasFragment) {
      return null;
    }
    return (uri.host, uri.port);
  } on FormatException {
    return null;
  }
}
