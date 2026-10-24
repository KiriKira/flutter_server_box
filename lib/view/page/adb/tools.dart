import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:fl_lib/fl_lib.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:server_box/core/adb/adb_files.dart';
import 'package:server_box/core/adb/adb_operations.dart';
import 'package:server_box/core/adb/adb_shell.dart';
import 'package:server_box/core/extension/context/locale.dart';
import 'package:server_box/data/model/file/file_backend.dart';
import 'package:server_box/data/model/server/server_private_info.dart';
import 'package:server_box/data/provider/server/single.dart';
import 'package:server_box/view/page/adb/screen.dart';

class AdbToolsPage extends ConsumerStatefulWidget {
  const AdbToolsPage({super.key, required this.spi});
  final Spi spi;
  static void open(BuildContext context, Spi spi) => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => AdbToolsPage(spi: spi)));
  @override
  ConsumerState<AdbToolsPage> createState() => _AdbToolsPageState();
}

class _AdbToolsPageState extends ConsumerState<AdbToolsPage> {
  bool _busy = false;
  String? _result;
  double? _progress;
  List<Map<String, dynamic>> _apps = const [];
  String _search = '';
  Completer<void>? _cancel;
  @override
  void initState() { super.initState(); unawaited(_refresh()); }
  @override
  void dispose() { if (_cancel?.isCompleted == false) _cancel!.complete(); super.dispose(); }

  Future<AdbOperations> _operations() async {
    final state = ref.read(serverProvider(widget.spi.id));
    if (state.spi != widget.spi) throw StateError('Device configuration changed; reopen Android tools');
    final exec = await ref.read(serverProvider(widget.spi.id).notifier).ensureExec();
    if (exec is! AdbExec) throw StateError('Device no longer uses ADB');
    return AdbOperations(exec.connection);
  }
  Future<void> _run(Future<String> Function(AdbOperations) action) async {
    if (_busy) return;
    setState(() { _busy = true; _result = null; _progress = null; });
    final cancel = _cancel = Completer<void>();
    try {
      final result = await action(await _operations());
      if (mounted) setState(() => _result = result);
    } catch (e) { if (mounted) setState(() => _result = e.toString()); }
    finally { if (identical(_cancel, cancel)) _cancel = null; if (mounted) setState(() { _busy = false; _progress = null; }); }
  }
  Future<void> _refresh() => _run((ops) async {
    final apps = await ops.apps();
    if (mounted) setState(() => _apps = apps);
    return '${apps.length}';
  });
  Future<void> _install() async {
    final picked = await FilePicker.pickFile(type: FileType.custom, allowedExtensions: ['apk']);
    final path = picked?.path;
    if (path == null || !mounted) return;
    await _run((ops) async {
      final result = await ops.install(File(path), cancel: _cancel?.future, progress: (sent, total) {
        if (mounted) setState(() => _progress = sent / total);
      });
      final apps = await ops.apps();
      if (mounted) setState(() => _apps = apps);
      return result;
    });
  }
  Future<bool> _confirm(String action) async => await context.showRoundDialog<bool>(
    title: action, child: Text('${widget.spi.name}\n${widget.spi.displayAddr}\n\n${l10n.adbConfirm}'), actions: Btnx.cancelRedOk) == true;

  @override
  Widget build(BuildContext context) {
    final device = ref.watch(serverProvider(widget.spi.id)).status.android;
    final actions = <(String, IconData, VoidCallback)>[
      (l10n.adbInstall, Icons.install_mobile, _install),
      if (Platform.isAndroid && widget.spi.adbOn?.localDevice == false)
        (l10n.adbScreen, Icons.phonelink, () => AdbScreenPage.open(context, widget.spi)),
      (l10n.adbFiles, Icons.folder_open, () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => AdbFilesPage(spi: widget.spi)))),
      (l10n.adbLogcat, Icons.notes, () => _run((ops) async => (await ops.action('logcat', cancel: _cancel?.future)).stdout)),
      (l10n.adbScreenshot, Icons.screenshot, () => _run((ops) async {
        final bytes = await ops.screenshot(cancel: _cancel?.future);
        final saved = await FilePicker.saveFile(fileName: 'android-${DateTime.now().millisecondsSinceEpoch}.png', bytes: bytes);
        return saved?.toString() ?? libL10n.cancel;
      })),
      (device?['root_enhancement'] == true ? l10n.adbRootDisable : l10n.adbRoot, Icons.admin_panel_settings, () async {
        if (device?['root_enhancement'] == true) { ref.read(serverProvider(widget.spi.id).notifier).disableAdbRoot(); return; }
        if (!await _confirm(l10n.adbRootTip) || !mounted) return;
        await _run((_) async {
          final notifier = ref.read(serverProvider(widget.spi.id).notifier);
          final allowed = await notifier.requestAdbRoot();
          await notifier.refresh(interactive: true);
          return allowed ? l10n.adbRootAllowed : l10n.adbRootDenied;
        });
      }),
      (l10n.adbReboot, Icons.restart_alt, () async {
        if (!await _confirm(l10n.adbReboot) || !mounted) return;
        await _run((ops) async => (await ops.action('reboot', cancel: _cancel?.future)).combined);
      }),
    ];
    return Scaffold(appBar: CustomAppBar(title: Text('${widget.spi.name} · ADB')), body: ListView(padding: const EdgeInsets.all(16), children: [
      if (device != null) AdbDeviceCard(device: device),
      Wrap(spacing: 8, runSpacing: 8, children: [for (final action in actions)
        OutlinedButton.icon(onPressed: _busy ? null : action.$3, icon: Icon(action.$2), label: Text(action.$1))]),
      if (_busy) ...[LinearProgressIndicator(value: _progress), TextButton(onPressed: () { if (_cancel?.isCompleted == false) _cancel!.complete(); }, child: Text(libL10n.cancel))],
      if (_result case final result?) ...[
        Padding(padding: const EdgeInsets.symmetric(vertical: 12), child: SelectableText(result)),
        TextButton.icon(onPressed: () => FilePicker.saveFile(fileName: 'android-output.txt', bytes: Uint8List.fromList(utf8.encode(result))), icon: const Icon(Icons.save_alt), label: Text(libL10n.export)),
      ],
      Row(children: [Expanded(child: TextField(decoration: InputDecoration(labelText: libL10n.search), onChanged: (value) => setState(() => _search = value))),
        IconButton(onPressed: _busy ? null : _refresh, icon: const Icon(Icons.refresh))]),
      for (final app in _apps.where((a) => '${a['package']}'.contains(_search))) ListTile(
        title: Text('${app['package']}'), subtitle: Text('${app['version']}'),
        trailing: PopupMenuButton<String>(enabled: !_busy, onSelected: (action) async {
          if (action != 'app_info' && action != 'launch' && !await _confirm('${app['package']} · $action')) return;
          if (!mounted) return;
          await _run((ops) async {
            final result = await ops.action(action, argument: '${app['package']}', cancel: _cancel?.future);
            if (action == 'uninstall') { final apps = await ops.apps(); if (mounted) setState(() => _apps = apps); }
            return result.combined;
          });
        }, itemBuilder: (_) => [
          PopupMenuItem(value: 'app_info', child: Text(l10n.viewDetails)),
          PopupMenuItem(value: 'launch', child: Text(l10n.adbLaunch)),
          PopupMenuItem(value: 'stop', child: Text(l10n.adbStop)),
          PopupMenuItem(value: 'uninstall', child: Text(l10n.adbUninstall)),
          PopupMenuItem(value: 'clear', child: Text(l10n.adbClear)),
        ])),
    ]));
  }
}

class AdbDeviceCard extends StatelessWidget {
  const AdbDeviceCard({super.key, required this.device});
  final Map<String, dynamic> device;
  @override
  Widget build(BuildContext context) {
    final facts = <String, Object?>{
      'Android user': '0',
      l10n.adbDevice: '${device['brand']} ${device['model']}',
      'Android / API': '${device['android']} / ${device['api']}',
      'Security patch': device['patch'], 'ABI': device['abi'], 'Kernel': device['kernel'],
      l10n.adbIdentity: device['identity'],
      l10n.adbTemperature: device['battery_temperature'] == null ? null : '${device['battery_temperature']} °C',
      'Battery': device['battery_percent'] == null ? null : '${device['battery_percent']}% · ${device['battery_status']}',
      'Voltage': device['battery_voltage_mv'] == null ? null : '${device['battery_voltage_mv']} mV',
    };
    return Card(child: Padding(padding: const EdgeInsets.all(12), child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      for (final fact in facts.entries) if (fact.value != null && '${fact.value}'.isNotEmpty)
        Padding(padding: const EdgeInsets.symmetric(vertical: 3), child: Text('${fact.key}: ${fact.value}')),
    ])));
  }
}

class AdbFilesPage extends ConsumerStatefulWidget {
  const AdbFilesPage({super.key, required this.spi});
  final Spi spi;
  @override
  ConsumerState<AdbFilesPage> createState() => _AdbFilesPageState();
}
class _AdbFilesPageState extends ConsumerState<AdbFilesPage> {
  final _path = TextEditingController(text: '/sdcard');
  AdbFileBackend? _backend;
  List<FileEntry> _entries = const [];
  String? _error;
  bool _busy = false;
  @override void initState() { super.initState(); unawaited(_load()); }
  @override void dispose() { _path.dispose(); unawaited(_backend?.close()); super.dispose(); }
  Future<void> _load() async {
    setState(() { _busy = true; _error = null; });
    try {
      if (ref.read(serverProvider(widget.spi.id)).spi != widget.spi) throw StateError('Device configuration changed; reopen files');
      final exec = await ref.read(serverProvider(widget.spi.id).notifier).ensureExec();
      if (exec is! AdbExec) throw StateError('ADB unavailable');
      await _backend?.close();
      final backend = _backend = AdbFileBackend(exec.connection);
      final entries = await backend.list(_path.text);
      entries.sort((a, b) => a.name.compareTo(b.name));
      if (mounted) setState(() => _entries = entries);
    } catch (e) { if (mounted) setState(() { _error = '$e'; _entries = const []; }); }
    finally { if (mounted) setState(() => _busy = false); }
  }
  @override Widget build(BuildContext context) => Scaffold(appBar: CustomAppBar(title: Text(l10n.adbFiles)), body: ListView(padding: const EdgeInsets.all(16), children: [
    Row(children: [IconButton(onPressed: _busy ? null : () {
      final segments = _path.text.split('/')..removeWhere((s) => s.isEmpty);
      if (segments.isNotEmpty) segments.removeLast();
      _path.text = '/${segments.join('/')}'; unawaited(_load());
    }, icon: const Icon(Icons.arrow_upward)), Expanded(child: TextField(controller: _path, onSubmitted: (_) => _load())),
      IconButton(onPressed: _busy ? null : _load, icon: const Icon(Icons.refresh)),
      IconButton(onPressed: _busy || _backend == null ? null : () async {
        final picked = await FilePicker.pickFile();
        final file = picked;
        if (file?.path == null || !mounted) return;
        setState(() => _busy = true);
        try { await _backend!.write('${_path.text}/${file!.name}', File(file.path!).openRead(), size: await File(file.path!).length()); }
        catch (e) { if (mounted) setState(() => _error = '$e'); }
        finally { if (mounted) await _load(); }
      }, icon: const Icon(Icons.upload_file), tooltip: l10n.adbUpload),
    ]),
    if (_busy) const LinearProgressIndicator(),
    if (_error case final error?) SelectableText(error),
    for (final entry in _entries) ListTile(leading: Icon(entry.isDir ? Icons.folder : Icons.description), title: Text(entry.name), subtitle: Text('${entry.size ?? ''}'),
      onTap: _busy ? null : () async {
        final path = '${_path.text}/${entry.name}';
        if (entry.isDir) { _path.text = path; await _load(); return; }
        setState(() => _busy = true);
        try {
          // FilePicker's mobile save API requires bytes; cap this UI shortcut.
          // The streaming backend remains available to tools and transfers.
          if ((entry.size ?? 0) > 32 * 1024 * 1024) throw StateError('Download shortcut supports files up to 32 MiB');
          final bytes = <int>[];
          await for (final chunk in _backend!.read(path)) {
            if (bytes.length + chunk.length > 32 * 1024 * 1024) throw StateError('File exceeds 32 MiB');
            bytes.addAll(chunk);
          }
          await FilePicker.saveFile(fileName: entry.name, bytes: Uint8List.fromList(bytes));
        } catch (e) { if (mounted) setState(() => _error = '$e'); }
        finally { if (mounted) setState(() => _busy = false); }
      }),
  ]));
}
