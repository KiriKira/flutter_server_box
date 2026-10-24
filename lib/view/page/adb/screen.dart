import 'dart:async';
import 'dart:math' as math;

import 'package:fl_lib/fl_lib.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:server_box/core/adb/adb_screen.dart';
import 'package:server_box/core/adb/adb_shell.dart';
import 'package:server_box/core/extension/context/locale.dart';
import 'package:server_box/data/model/server/server_private_info.dart';
import 'package:server_box/data/provider/server/single.dart';

class AdbScreenPage extends ConsumerStatefulWidget {
  const AdbScreenPage({super.key, required this.spi});
  final Spi spi;
  static void open(BuildContext context, Spi spi) => Navigator.of(context).push(
    MaterialPageRoute<void>(builder: (_) => AdbScreenPage(spi: spi)));
  @override
  ConsumerState<AdbScreenPage> createState() => _AdbScreenPageState();
}

class _AdbScreenPageState extends ConsumerState<AdbScreenPage> with WidgetsBindingObserver {
  AdbScreenSession? _session;
  final _pointers = <int, Offset>{};
  String? _error;
  bool _paused = false;
  bool _starting = false;
  bool _root = false;
  bool _waking = false;
  String? _wakeMessage;
  int _generation = 0;
  int _revision = 0;
  Future<void> _stopping = Future.value();

  @override
  void initState() {
    super.initState(); WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) { if (mounted) unawaited(_start()); });
  }
  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _generation++;
    unawaited(_stop());
    super.dispose();
  }

  Future<void> _stop() {
    final session = _session;
    _session = null; _pointers.clear();
    session?.removeListener(_changed);
    return _stopping = _stopping.then((_) async {
      await session?.close(); session?.dispose();
    });
  }

  Future<void> _start() async {
    if (_starting || _paused || !mounted) return;
    final generation = ++_generation;
    _starting = true;
    setState(() => _error = null);
    try {
      await _stop();
      if (!mounted || _paused || generation != _generation) return;
      final state = ref.read(serverProvider(widget.spi.id));
      if (state.spi != widget.spi || widget.spi.adbOn?.localDevice != false) throw StateError(l10n.adbScreenChanged);
      final exec = await ref.read(serverProvider(widget.spi.id).notifier).ensureExec();
      if (!mounted || _paused || generation != _generation) return;
      if (exec is! AdbExec) throw StateError(l10n.adbScreenChanged);
      final session = _session = AdbScreenSession(exec.connection, root: _root);
      _revision = 0;
      session.addListener(_changed);
      await session.start();
    } catch (error) {
      if (mounted && !_paused && generation == _generation) setState(() => _error = '$error');
    } finally {
      _starting = false;
      if (mounted) {
        setState(() {});
        // A resume can arrive while teardown of the previous start is pending.
        if (!_paused && generation != _generation && _session == null && _error == null) unawaited(_start());
      }
    }
  }

  void _changed() {
    if (!mounted) return;
    final session = _session;
    if (session?.revision != _revision) {
      _revision = session?.revision ?? 0; _pointers.clear();
    }
    setState(() {});
  }
  void _release() {
    _pointers.clear(); unawaited(_session?.releasePointers());
  }

  Future<void> _wake() async {
    final session = _session;
    if (session == null || _waking) return;
    setState(() { _waking = true; _wakeMessage = null; });
    try {
      await session.wake();
      if (mounted && identical(session, _session)) setState(() => _wakeMessage = l10n.adbScreenUnlockTip);
    } catch (e) {
      if (mounted && identical(session, _session)) setState(() => _wakeMessage = '$e');
    } finally { if (mounted) setState(() => _waking = false); }
  }

  Future<void> _diagnostics() async {
    _release();
    await context.showRoundDialog<void>(title: l10n.adbScreenDiagnostics,
      child: SingleChildScrollView(child: SelectableText(_session?.diagnostics ?? _error ?? 'No active screen session')),
      actions: [Btn.ok()]);
  }
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) _release();
    if (state == AppLifecycleState.paused || state == AppLifecycleState.detached) {
      _paused = true; _generation++; unawaited(_stop());
      if (mounted) setState(() {});
    } else if (state == AppLifecycleState.resumed && _paused) {
      _paused = false;
      if (mounted && ModalRoute.of(context)?.isCurrent == true) unawaited(_start());
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(serverProvider(widget.spi.id).select((value) => value.spi), (_, next) {
      if (next != widget.spi) {
        _generation++; _error = l10n.adbScreenChanged; unawaited(_stop());
        if (mounted) setState(() {});
      }
    });
    final session = _session;
    final ready = session?.state == AdbScreenState.streaming && session?.texture != null;
    final error = _error ?? session?.error;
    final gestureInsets = MediaQuery.systemGestureInsetsOf(context);
    return Scaffold(
      appBar: CustomAppBar(title: Text('${widget.spi.name} · ${l10n.adbScreen}'),
        leading: BackButton(onPressed: () => Navigator.of(context).pop()), actions: [
          TextButton.icon(onPressed: _diagnostics, icon: const Icon(Icons.bug_report_outlined), label: Text(l10n.adbScreenDiagnostics)),
          PopupMenuButton<bool>(enabled: !_starting, icon: Icon(_root ? Icons.admin_panel_settings : Icons.more_vert),
            tooltip: l10n.adbScreenMode, onSelected: (root) {
              _root = root; _wakeMessage = null; unawaited(_start());
            }, itemBuilder: (_) => [
              CheckedPopupMenuItem(value: false, checked: !_root, child: Text(l10n.adbScreenShellMode)),
              CheckedPopupMenuItem(value: true, checked: _root, child: Text(l10n.adbScreenRootMode)),
            ]),
        ]),
      body: SafeArea(child: Focus(autofocus: true, onFocusChange: (focused) { if (!focused) _release(); },
        child: Column(children: [
          Expanded(child: ColoredBox(color: const Color(0xff000000), child: Padding(
            // Keep remote edge swipes clear of the host's system-back gesture area.
            padding: EdgeInsets.only(left: gestureInsets.left, right: gestureInsets.right), child: Stack(children: [
            Positioned.fill(child: LayoutBuilder(builder: (_, constraints) {
              if (session == null || session.texture == null || session.width == 0 || session.height == 0) return const SizedBox.expand();
              if (constraints.maxWidth <= 0 || constraints.maxHeight <= 0) return const SizedBox.shrink();
              final scale = math.min(constraints.maxWidth / session.width, constraints.maxHeight / session.height);
              final size = Size(session.width * scale, session.height * scale);
              final geometryRevision = session.revision;
              void pointer(PointerEvent event, int action) {
                // Coordinates belong to the layout that produced this callback.
                if (!ready || geometryRevision != session.revision) return;
                final point = Offset((event.localPosition.dx / size.width).clamp(0.0, 1.0), (event.localPosition.dy / size.height).clamp(0.0, 1.0));
                if (action == 0) {
                  if (_pointers.length >= 10) return;
                  _pointers[event.pointer] = point;
                } else if (!_pointers.containsKey(event.pointer)) { return; }
                if (action == 1) {
                  _pointers.remove(event.pointer);
                } else {
                  _pointers[event.pointer] = point;
                }
                unawaited(session.touch(action, event.pointer, point.dx, point.dy, geometryRevision));
              }
              return Center(child: SizedBox(width: size.width, height: size.height,
                child: Listener(behavior: HitTestBehavior.opaque,
                  onPointerDown: (event) => pointer(event, 0), onPointerMove: (event) => pointer(event, 2),
                  onPointerUp: (event) => pointer(event, 1), onPointerCancel: (event) {
                    final point = _pointers.remove(event.pointer);
                    if (point != null) unawaited(session.touch(1, event.pointer, point.dx, point.dy, geometryRevision));
                  },
                  child: Texture(textureId: session.texture!, filterQuality: FilterQuality.low))));
            })),
            if (!ready) Positioned.fill(child: ColoredBox(color: const Color(0xcc000000), child: Center(
              child: SingleChildScrollView(padding: const EdgeInsets.all(24), child: Column(mainAxisSize: MainAxisSize.min, children: [
                if (error == null && !_paused) const CircularProgressIndicator(),
                const SizedBox(height: 16),
                Text(error != null ? l10n.adbScreenFailed : _paused ? l10n.adbScreenPaused : session?.state == AdbScreenState.preparing || session == null
                  ? l10n.adbScreenPreparing : l10n.adbScreenConnecting, style: const TextStyle(color: Colors.white)),
                if (session?.progress case final progress?) LinearProgressIndicator(value: progress),
                if (error != null) ...[
                  const SizedBox(height: 12), SelectableText(error, style: const TextStyle(color: Colors.white70)),
                  const SizedBox(height: 12), OutlinedButton.icon(onPressed: _starting ? null : _start,
                    icon: const Icon(Icons.refresh), label: Text(libL10n.retry)),
                ],
              ])),
            ))),
          ])))),
          if (_root) Padding(padding: const EdgeInsets.all(4), child: Text(l10n.adbScreenRootTip, style: UIs.text12Grey)),
          if (session?.inputWarning != null) Padding(padding: const EdgeInsets.all(8),
            child: Text(switch (session?.inputWarning) {
              'input_geometry' => l10n.adbScreenGeometryWarning,
              'input_permission' => l10n.adbScreenInputDenied,
              _ => l10n.adbScreenInputError,
            })),
          if (_wakeMessage case final message?) Padding(padding: const EdgeInsets.all(8), child: Text(message)),
          Padding(padding: const EdgeInsets.symmetric(vertical: 8), child: Wrap(spacing: 12, runSpacing: 8, alignment: WrapAlignment.center, children: [
            OutlinedButton.icon(onPressed: session != null && !_waking ? _wake : null,
              icon: const Icon(Icons.lock_open), label: Text(l10n.adbScreenWake)),
            OutlinedButton.icon(onPressed: ready ? () => session!.key(4) : null, icon: const Icon(Icons.arrow_back), label: Text(l10n.adbScreenBack)),
            OutlinedButton.icon(onPressed: ready ? () => session!.key(3) : null, icon: const Icon(Icons.home_outlined), label: Text(l10n.adbScreenHome)),
            OutlinedButton.icon(onPressed: ready ? () => session!.key(187) : null, icon: const Icon(Icons.recent_actors_outlined), label: Text(l10n.adbScreenRecent)),
          ])),
        ]))),
    );
  }
}
