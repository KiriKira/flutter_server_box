import 'dart:async';
import 'dart:math' as math;

import 'package:fl_lib/fl_lib.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:server_box/core/adb/adb_screen.dart';
import 'package:server_box/core/adb/adb_shell.dart';
import 'package:server_box/core/adb/adb_transport.dart';
import 'package:server_box/core/extension/context/locale.dart';
import 'package:server_box/data/model/server/server_private_info.dart';
import 'package:server_box/data/provider/server/single.dart';
import 'package:server_box/data/res/store.dart';
import 'package:server_box/src/rust/api/android.dart' as android;
import 'package:wakelock_plus/wakelock_plus.dart';

class AdbScreenPage extends ConsumerStatefulWidget {
  const AdbScreenPage({super.key, required this.spi});
  final Spi spi;
  static void open(BuildContext context, Spi spi) => Navigator.of(context).push(
    MaterialPageRoute<void>(builder: (_) => AdbScreenPage(spi: spi)));
  @override
  ConsumerState<AdbScreenPage> createState() => _AdbScreenPageState();
}

class _AdbScreenPageState extends ConsumerState<AdbScreenPage> with WidgetsBindingObserver {
  /// Presets automatic mode stepped down to, per server, for this app run: reopening the page
  /// over the same slow link should not fall behind all over again first.
  static final _learned = <String, AdbScreenQuality>{};
  static const _reconnectDelays = [1, 2, 4, 8, 8];
  AdbScreenSession? _session;
  final _pointers = <int, Offset>{};
  /// Repaints the local finger marks, which show at once whatever the round trip.
  final _touches = ValueNotifier(0);
  AdbScreenQuality _quality = AdbScreenQuality.values.asNameMap()[Stores.setting.adbScreenQuality.fetch()] ?? AdbScreenQuality.auto;
  int _laggy = 0;
  int _seenTicks = 0;
  int _reconnects = 0;
  Timer? _reconnect;
  bool _reconnectRunning = false;
  String? _notice;
  String? _error;
  bool _paused = false;
  bool _starting = false;
  bool _root = false;
  bool _waking = false;
  /// The lock kind last used in the unlock dialog, for this page's lifetime.
  bool _unlockPattern = false;
  String? _wakeMessage;
  int _generation = 0;
  int _revision = 0;
  Future<void> _stopping = Future.value();

  @override
  void initState() {
    super.initState(); WidgetsBinding.instance.addObserver(this);
    // Remote control is watched more than touched; the controller must not sleep under it.
    unawaited(WakelockPlus.enable());
    WidgetsBinding.instance.addPostFrameCallback((_) { if (mounted) unawaited(_start()); });
  }
  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _generation++; _reconnect?.cancel();
    unawaited(_stop());
    if (!Stores.setting.generalWakeLock.fetch()) unawaited(WakelockPlus.disable());
    _touches.dispose();
    super.dispose();
  }

  AdbScreenQuality get _effective => _quality != AdbScreenQuality.auto ? _quality
    : _learned[widget.spi.id] ?? AdbScreenQuality.auto.resolve(widget.spi.adbOn?.host ?? '');

  String _qualityName(AdbScreenQuality quality) => switch (quality) {
    AdbScreenQuality.auto => l10n.adbScreenQualityAuto,
    AdbScreenQuality.high => l10n.adbScreenQualityHigh,
    AdbScreenQuality.balanced => l10n.adbScreenQualityBalanced,
    AdbScreenQuality.smooth => l10n.adbScreenQualitySmooth,
    AdbScreenQuality.saver => l10n.adbScreenQualitySaver,
  };

  void _select(Object value) {
    if (value is bool) {
      _root = value;
    } else if (value is AdbScreenQuality) {
      _quality = value; _learned.remove(widget.spi.id);
      Stores.setting.adbScreenQuality.put(value.name);
    }
    _wakeMessage = null; _notice = null; _reconnects = 0; _reconnect?.cancel(); _reconnect = null;
    unawaited(_start());
  }

  Future<void> _stop() {
    final session = _session;
    _session = null; _pointers.clear();
    session?.removeListener(_changed);
    _touches.value++;
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
      final session = _session = AdbScreenSession(exec.connection, root: _root, quality: _effective);
      _revision = 0; _laggy = 0; _seenTicks = 0;
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
      _revision = session?.revision ?? 0; _pointers.clear(); _touches.value++;
    }
    if (session != null) {
      if (session.state == AdbScreenState.streaming) {
        if (_reconnects > 0) { _reconnects = 0; _notice = null; }
        _stepDown(session);
      } else if (session.state == AdbScreenState.failed) {
        _scheduleReconnect();
      }
    }
    setState(() {});
  }

  /// Automatic mode: video a second or more behind for four straight seconds means the link
  /// carries less than this preset sends, so restart one preset lower.
  void _stepDown(AdbScreenSession session) {
    if (_quality != AdbScreenQuality.auto || _starting || session.statsTicks == _seenTicks) return;
    _seenTicks = session.statsTicks;
    _laggy = session.lag >= 1000 ? _laggy + 1 : 0;
    final lower = session.quality.lower;
    if (_laggy < 4 || lower == null) return;
    _learned[widget.spi.id] = lower;
    _notice = l10n.adbScreenQualityLowered;
    unawaited(_start());
  }

  /// A session that had played video and then failed lost its link (Wi-Fi roam, VPN relay
  /// switch, a tunnel restart): try again a few times before asking for Retry.
  void _scheduleReconnect() {
    final session = _session;
    if (_paused || !mounted || _reconnectRunning || (_reconnect?.isActive ?? false)) return;
    if (session != null && session.failureStage == 'surface') return;
    if (!(session?.streamed ?? false) && _reconnects == 0) return;
    if (_reconnects >= _reconnectDelays.length) { _notice = null; return; }
    final delay = _reconnectDelays[_reconnects++];
    _notice = '${l10n.adbScreenReconnecting} ($_reconnects/${_reconnectDelays.length})';
    _reconnect = Timer(Duration(seconds: delay), () => unawaited(_reconnectNow()));
  }

  Future<void> _reconnectNow() async {
    if (!mounted || _paused) return;
    _reconnectRunning = true;
    try { await _reconnectOnce(); } finally { _reconnectRunning = false; }
    // Failing again before any video played does not reach [_changed] as a playing session.
    if (mounted && !_paused && (_session == null || _session!.state == AdbScreenState.failed)) {
      _scheduleReconnect();
      setState(() {});
    }
  }

  Future<void> _reconnectOnce() async {
    // A dead TCP link still looks open from here; an unanswered no-op says so. Dropping it lets
    // the next connect dial again; anything else on it is gone with the link already.
    try {
      final exec = await ref.read(serverProvider(widget.spi.id).notifier).ensureExec().timeout(const Duration(seconds: 10));
      if (exec is AdbExec) {
        final cancel = Completer<void>();
        final timer = Timer(const Duration(seconds: 5), cancel.complete);
        try {
          final probe = await exec.run(android.androidCommand(action: 'identity', argument: '', root: false), cancel: cancel.future);
          if (!probe.succeeded || probe.outputIncomplete) AdbService.disconnect(widget.spi.id);
        } finally { timer.cancel(); }
      }
    } catch (_) {
      AdbService.disconnect(widget.spi.id);
    }
    if (mounted && !_paused) await _start();
  }
  void _release() {
    _pointers.clear(); _touches.value++; unawaited(_session?.releasePointers());
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
    final session = _session;
    final target = await session?.targetState();
    if (!mounted) return;
    await context.showRoundDialog<void>(title: l10n.adbScreenDiagnostics,
      child: SingleChildScrollView(child: SelectableText([
        if (target != null) 'target: ${target.replaceAll('\n', '; ')}',
        session?.diagnostics ?? _error ?? 'No active screen session',
      ].join('\n'))),
      actions: [Btn.ok()]);
  }

  Future<void> _unlock() async {
    final session = _session;
    if (session == null || _waking) return;
    _release();
    final controller = TextEditingController();
    final pattern = ValueNotifier(_unlockPattern);
    final accepted = await context.showRoundDialog<bool>(title: l10n.adbScreenUnlockSecret,
      child: ValueListenableBuilder(valueListenable: pattern, builder: (context, isPattern, _) =>
        Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          SegmentedButton<bool>(segments: [
            ButtonSegment(value: false, label: Text(l10n.adbScreenUnlockPin)),
            ButtonSegment(value: true, label: Text(l10n.adbScreenUnlockPattern)),
          ], selected: {isPattern}, onSelectionChanged: (value) => pattern.value = value.first),
          const SizedBox(height: 8),
          Text(isPattern ? l10n.adbScreenUnlockPatternTip : l10n.adbScreenUnlockSecretTip, style: UIs.text12Grey),
          Input(controller: controller, obscureText: true, autoFocus: true, suggestion: false, autoCorrect: false,
            type: isPattern ? TextInputType.number : TextInputType.visiblePassword, onSubmitted: (_) => context.popDialog(true)),
        ])),
      actions: Btnx.cancelOk);
    final secret = controller.text;
    final isPattern = _unlockPattern = pattern.value;
    controller.dispose(); pattern.dispose();
    if (accepted != true || secret.isEmpty || !mounted || !identical(session, _session)) return;
    setState(() { _waking = true; _wakeMessage = null; });
    try {
      await session.unlock(secret, pattern: isPattern);
      if (mounted && identical(session, _session)) setState(() => _wakeMessage = l10n.adbScreenUnlockSent);
    } catch (e) {
      if (mounted && identical(session, _session)) setState(() => _wakeMessage = '$e');
    } finally { if (mounted) setState(() => _waking = false); }
  }
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) _release();
    if (state == AppLifecycleState.paused || state == AppLifecycleState.detached) {
      _paused = true; _generation++; _reconnect?.cancel(); _reconnects = 0; _notice = null; unawaited(_stop());
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
    final reconnecting = _reconnectRunning || _reconnect?.isActive == true;
    final gestureInsets = MediaQuery.systemGestureInsetsOf(context);
    return Scaffold(
      appBar: CustomAppBar(title: Text('${widget.spi.name} · ${l10n.adbScreen}'),
        leading: BackButton(onPressed: () => Navigator.of(context).pop()), actions: [
          TextButton.icon(onPressed: _diagnostics, icon: const Icon(Icons.bug_report_outlined), label: Text(l10n.adbScreenDiagnostics)),
          PopupMenuButton<Object>(enabled: !_starting, icon: Icon(_root ? Icons.admin_panel_settings : Icons.more_vert),
            tooltip: l10n.adbScreenMode, onSelected: _select, itemBuilder: (_) => [
              CheckedPopupMenuItem(value: false, checked: !_root, child: Text(l10n.adbScreenShellMode)),
              CheckedPopupMenuItem(value: true, checked: _root, child: Text(l10n.adbScreenRootMode)),
              const PopupMenuDivider(),
              PopupMenuItem(enabled: false, child: Text(l10n.adbScreenQuality)),
              for (final quality in AdbScreenQuality.values)
                CheckedPopupMenuItem(value: quality, checked: _quality == quality, child: Text(
                  quality == AdbScreenQuality.auto && session != null ? '${_qualityName(quality)} · ${_qualityName(session.quality)}' : _qualityName(quality))),
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
                _touches.value++;
                unawaited(session.touch(action, event.pointer, point.dx, point.dy, geometryRevision));
              }
              return Center(child: SizedBox(width: size.width, height: size.height,
                child: Listener(behavior: HitTestBehavior.opaque,
                  onPointerDown: (event) => pointer(event, 0), onPointerMove: (event) => pointer(event, 2),
                  onPointerUp: (event) => pointer(event, 1), onPointerCancel: (event) {
                    final point = _pointers.remove(event.pointer);
                    _touches.value++;
                    if (point != null) unawaited(session.touch(1, event.pointer, point.dx, point.dy, geometryRevision));
                  },
                  child: CustomPaint(foregroundPainter: _TouchMarks(_pointers, _touches),
                    child: Texture(textureId: session.texture!, filterQuality: FilterQuality.low)))));
            })),
            if (!ready) Positioned.fill(child: ColoredBox(color: const Color(0xcc000000), child: Center(
              child: SingleChildScrollView(padding: const EdgeInsets.all(24), child: Column(mainAxisSize: MainAxisSize.min, children: [
                if ((error == null || reconnecting) && !_paused) const CircularProgressIndicator(),
                const SizedBox(height: 16),
                Text(reconnecting ? _notice ?? l10n.adbScreenReconnecting : error != null ? l10n.adbScreenFailed : _paused ? l10n.adbScreenPaused : session?.state == AdbScreenState.preparing || session == null
                  ? l10n.adbScreenPreparing : l10n.adbScreenConnecting, style: const TextStyle(color: Colors.white)),
                if (session?.progress case final progress?) LinearProgressIndicator(value: progress),
                if (error != null && !reconnecting) ...[
                  const SizedBox(height: 12), SelectableText(error, style: const TextStyle(color: Colors.white70)),
                  const SizedBox(height: 12), OutlinedButton.icon(onPressed: _starting ? null : () => _select(_root),
                    icon: const Icon(Icons.refresh), label: Text(libL10n.retry)),
                ],
              ])),
            ))),
          ])))),
          if (ready && session != null) Padding(padding: const EdgeInsets.only(top: 4), child: Text(
            session.pending >= 2000 ? '${l10n.adbScreenStalled} ${(session.pending / 1000).toStringAsFixed(0)} s'
              : [
                  _qualityName(session.quality),
                  if (session.rtt >= 0) 'RTT ${session.rtt} ms',
                  if (session.lag >= 300) '+${(session.lag / 1000).toStringAsFixed(1)} s',
                  '${(session.kbps / 1000).toStringAsFixed(1)} Mbps', '${session.fps} fps',
                ].join(' · '),
            style: session.pending >= 2000 || session.lag >= 1000 ? const TextStyle(fontSize: 12, color: Colors.orange) : UIs.text12Grey)),
          if (ready && _notice != null) Padding(padding: const EdgeInsets.all(4), child: Text(_notice!, style: UIs.text12Grey)),
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
            OutlinedButton.icon(onPressed: session != null && !_waking ? _unlock : null,
              icon: const Icon(Icons.password), label: Text(l10n.adbScreenUnlockSecret)),
            OutlinedButton.icon(onPressed: ready ? () => session!.key(4) : null, icon: const Icon(Icons.arrow_back), label: Text(l10n.adbScreenBack)),
            OutlinedButton.icon(onPressed: ready ? () => session!.key(3) : null, icon: const Icon(Icons.home_outlined), label: Text(l10n.adbScreenHome)),
            OutlinedButton.icon(onPressed: ready ? () => session!.key(187) : null, icon: const Icon(Icons.recent_actors_outlined), label: Text(l10n.adbScreenRecent)),
          ])),
        ]))),
    );
  }
}

/// Where the controller's fingers are, drawn locally so a long round trip still feels answered.
class _TouchMarks extends CustomPainter {
  _TouchMarks(this.points, Listenable repaint) : super(repaint: repaint);
  final Map<int, Offset> points;

  @override
  void paint(Canvas canvas, Size size) {
    final fill = Paint()..color = const Color(0x55ffffff);
    final ring = Paint()..color = const Color(0xccffffff)..style = PaintingStyle.stroke..strokeWidth = 2;
    for (final point in points.values) {
      final center = Offset(point.dx * size.width, point.dy * size.height);
      canvas.drawCircle(center, 18, fill);
      canvas.drawCircle(center, 18, ring);
    }
  }

  @override
  bool shouldRepaint(_TouchMarks oldDelegate) => !identical(points, oldDelegate.points);
}
