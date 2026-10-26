import 'dart:async';
import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';

import 'add_bar.dart';
import 'brand.dart';
import 'ffi/spate_ffi.dart';
import 'model/job.dart';
import 'model/ui_prefs.dart';
import 'rows.dart';
import 'settings_screen.dart';

/// App state: polls the core twice a second and exposes the queue.
class SpateController extends ChangeNotifier {
  final Spate core;
  List<JobStatus> jobs = const [];
  final Map<String, _Rate> _rates = {};
  final Map<String, String> _lastState = {};
  bool pairShown = false; // a pairing dialog is currently on screen
  Timer? _timer;
  String? lastError;
  int _lastVersion = -1; // core queue version at the last full refresh
  int _lastLimit = -1; // bytes/sec cap shown at the last refresh

  /// Recent aggregate speed, one sample per tick while anything runs (about
  /// 30 s at two ticks a second), for the header sparkline.
  final List<double> speedHistory = [];

  /// Selected rows (click, Shift, Cmd/Ctrl, arrows).
  final SelectionModel selection = SelectionModel();

  /// Called when another launch of the app asked this instance to show its
  /// window, or a pairing request arrives while the window is hidden.
  void Function()? onShowRequested;

  /// Called after every refresh of [jobs], visible or not: the tray summary
  /// hooks here. Widgets listen through [addListener], which is only notified
  /// while the window is visible, so a hidden window does not rebuild and
  /// rasterise frames for every progress tick.
  void Function()? onJobsRefreshed;

  /// Called once when a job turns done or failed (notifications).
  void Function(JobStatus job)? onFinished;

  /// Whether the window is on screen, and whether it has keyboard focus.
  bool visible = true;
  bool focused = true;

  SpateController(this.core) {
    selection.addListener(notifyListeners);
    _tick();
    _timer = Timer.periodic(const Duration(milliseconds: 500), (_) => _tick());
  }

  /// Refreshes from the core. [force] redraws even when the queue is
  /// unchanged (after a user action, so its result or error shows at once).
  void _tick({bool force = false}) {
    final now = DateTime.now();
    final version = core.queueVersion;
    final limit = core.currentLimit;
    final running = jobs.any((j) => j.state == 'running');
    final scheduled = jobs.any((j) => j.startAt != null && j.state == 'pending');
    final pairing = core.pairPending;
    if (pairing && !visible) onShowRequested?.call();
    if (!force && version == _lastVersion && limit == _lastLimit && !running && !scheduled && !pairing) {
      if (core.showPending) onShowRequested?.call();
      return;
    }
    _lastVersion = version;
    _lastLimit = limit;
    final next = core.statuses();
    for (final j in next) {
      _rates.putIfAbsent(j.id, () => _Rate()).observe(j.bytes, now);
      final prev = _lastState[j.id];
      if (prev != null && prev != j.state && (j.state == 'done' || j.state == 'failed')) {
        onFinished?.call(j);
      }
      _lastState[j.id] = j.state;
    }
    final ids = next.map((j) => j.id).toSet();
    _rates.removeWhere((id, _) => !ids.contains(id));
    _lastState.removeWhere((id, _) => !ids.contains(id));
    jobs = next;
    selection.retain(ids);
    if (running || speedHistory.isNotEmpty) {
      speedHistory.add(totalSpeed);
      if (speedHistory.length > 60) speedHistory.removeAt(0);
      if (!running && speedHistory.every((v) => v == 0)) speedHistory.clear();
    }
    if (core.showPending) onShowRequested?.call();
    onJobsRefreshed?.call();
    if (visible || force) notifyListeners();
  }

  /// The shell calls this when the window becomes visible so the first frame
  /// shows the current queue rather than the one from before it was hidden.
  void setVisible(bool v) {
    visible = v;
    if (v) _tick(force: true);
  }

  void setFocused(bool f) => focused = f;

  double speedOf(String id) => _rates[id]?.bps ?? 0;
  double get totalSpeed => jobs.where((j) => j.state == 'running').fold(0.0, (a, j) => a + speedOf(j.id));

  bool get pairPending => core.pairPending;

  /// The rows a menu action applies to: the selection when [job] is in it,
  /// else just [job].
  List<JobStatus> targetsFor(JobStatus job) =>
      selection.contains(job.id) && selection.count > 1 ? jobs.where((j) => selection.contains(j.id)).toList() : [job];

  /// Enqueues a link. An empty [dir] lets the destination rules decide
  /// (site rule > category > base folder); [startAt] schedules the start;
  /// [conns] 0 takes the Settings default.
  bool add(String url, {String dir = '', int conns = 0, DateTime? startAt}) {
    final id = core.addJson({
      'url': url,
      'dir': dir,
      'conns': conns,
      'startAt': startAt == null ? 0 : startAt.millisecondsSinceEpoch ~/ 1000,
    });
    lastError = id == null ? (core.lastError ?? 'That does not look like a downloadable link.') : null;
    _tick(force: true);
    return id != null;
  }

  /// Adds every link; returns the ones that were refused. [lastError]
  /// summarises the outcome when any failed.
  List<String> addMany(List<String> urls, {String dir = '', DateTime? startAt}) {
    final failed = <String>[];
    String? firstError;
    for (final u in urls) {
      if (!add(u, dir: dir, startAt: startAt)) {
        failed.add(u);
        firstError ??= lastError;
      }
    }
    lastError = failed.isEmpty
        ? null
        : urls.length == 1
            ? firstError
            : '${urls.length - failed.length} of ${urls.length} added; ${failed.length} not downloadable: $firstError';
    notifyListeners();
    return failed;
  }

  /// Links found in [text] (a paste, a dropped file): http(s) and ftp(s).
  static List<String> linksIn(String text) =>
      RegExp(r'(?:https?|ftps?)://[^\s<>"\x27]+').allMatches(text).map((m) => m.group(0)!).toList();

  /// When the download window next opens, if one is enabled and not open now.
  DateTime? nextDownloadWindowStart() {
    final s = core.settings();
    final qw = s['queueWindow'] as Map<String, dynamic>?;
    if (qw == null || qw['enabled'] != true) return null;
    final from = (qw['from'] as String? ?? '').split(':');
    if (from.length != 2) return null;
    final h = int.tryParse(from[0]), m = int.tryParse(from[1]);
    if (h == null || m == null) return null;
    final days = ((qw['days'] as List?) ?? const []).map((e) => (e as num).toInt()).toSet();
    final now = DateTime.now();
    for (var d = 0; d < 8; d++) {
      final t = DateTime(now.year, now.month, now.day + d, h, m);
      if (!t.isAfter(now)) continue;
      if (days.isEmpty || days.contains(t.weekday % 7)) return t;
    }
    return null;
  }

  /// Bytes/sec cap in force right now (0 = unlimited); changes with the
  /// speed-limit time windows in Settings.
  int get currentLimit => core.currentLimit;

  void startNow(String id) {
    core.startNow(id);
    _tick(force: true);
  }

  /// Schedules (or reschedules) a queued job; null starts it as soon as possible.
  void schedule(String id, DateTime? at) {
    core.schedule(id, at);
    _tick(force: true);
  }

  void pause(String id) {
    core.pause(id);
    _tick(force: true);
  }

  void resume(String id) {
    core.resume(id);
    _tick(force: true);
  }

  void cancel(String id) {
    core.cancel(id);
    _tick(force: true);
  }

  /// Removes a row. An unfinished download's partial file and resume sidecar
  /// are deleted with it; a finished file stays where it is.
  void remove(String id) {
    core.discard(id);
    _tick(force: true);
  }

  void clearFinished() {
    core.clearFinished();
    _tick(force: true);
  }

  void cancelAll() {
    core.cancelAll();
    _tick(force: true);
  }

  void pauseAll() {
    core.pauseAll();
    _tick(force: true);
  }

  void resumeAll() {
    core.resumeAll();
    _tick(force: true);
  }

  /// Retry a failed/cancelled download: re-queue the same link into the same
  /// folder (the engine resumes from any partial file) and drop the old row.
  void retry(JobStatus j) {
    final dir = File(j.out).parent.path;
    core.remove(j.id);
    core.add(j.url, dir: dir);
    _tick(force: true);
  }

  void reveal(String path) {
    if (Platform.isMacOS) {
      Process.start('open', ['-R', path]);
    } else if (Platform.isWindows) {
      Process.start('explorer', ['/select,', path]);
    } else {
      Process.start('xdg-open', [File(path).parent.path]);
    }
  }

  void openFile(String path) {
    if (Platform.isMacOS) {
      Process.start('open', [path]);
    } else if (Platform.isWindows) {
      Process.start('cmd', ['/c', 'start', '', path]);
    } else {
      Process.start('xdg-open', [path]);
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    selection.dispose();
    super.dispose();
  }
}

class _Rate {
  int lastBytes = 0;
  DateTime? lastAt;
  double bps = 0;
  void observe(int bytes, DateTime now) {
    if (lastAt != null && bytes >= lastBytes) {
      final dt = now.difference(lastAt!).inMilliseconds / 1000.0;
      if (dt > 0) {
        final sample = (bytes - lastBytes) / dt;
        bps = bps == 0 ? sample : 0.4 * sample + 0.6 * bps;
      }
    }
    lastBytes = bytes;
    lastAt = now;
  }
}

// Design tokens shared by both brightnesses.
const _kRadius = 12.0;
const _kMaxWidth = 1100.0;
// One motion language: short, decelerating, no slides.
const kMotion = Duration(milliseconds: 220);
const kMotionCurve = Curves.easeOutCubic;

/// Date then time picker for a start time; null when the user cancelled.
/// The time picker opens in keyboard-entry mode, which suits a desktop.
Future<DateTime?> pickWhen(BuildContext context, DateTime? current) async {
  final now = DateTime.now();
  final initial = (current != null && current.isAfter(now)) ? current : now.add(const Duration(hours: 1));
  final d = await showDatePicker(
    context: context,
    initialDate: initial,
    firstDate: now,
    lastDate: now.add(const Duration(days: 365)),
  );
  if (d == null || !context.mounted) return null;
  final t = await showTimePicker(
    context: context,
    initialTime: TimeOfDay.fromDateTime(initial),
    initialEntryMode: TimePickerEntryMode.input,
  );
  if (t == null) return null;
  return DateTime(d.year, d.month, d.day, t.hour, t.minute);
}

/// Fade-through page transition (opacity + a 1.5% scale settle) instead of
/// the platform slide, which reads as heavy on desktop.
Route<T> fadeRoute<T>(Widget page) => PageRouteBuilder<T>(
  transitionDuration: kMotion,
  reverseTransitionDuration: const Duration(milliseconds: 160),
  pageBuilder: (_, _, _) => page,
  transitionsBuilder: (_, anim, _, child) {
    final a = CurvedAnimation(parent: anim, curve: kMotionCurve, reverseCurve: Curves.easeIn);
    return FadeTransition(
      opacity: a,
      child: ScaleTransition(scale: Tween(begin: 0.985, end: 1.0).animate(a), child: child),
    );
  },
);

class SpateApp extends StatelessWidget {
  final SpateController controller;
  final UiPrefs prefs;
  const SpateApp({super.key, required this.controller, required this.prefs});

  /// Light is white surfaces on a soft grey; dark is near-black surfaces.
  /// Surfaces are derived from the accent, the primary is the accent itself.
  static ThemeData theme(Brightness b, Color seed) {
    final dark = b == Brightness.dark;
    final primary = brandPrimary(seed, b);
    final cs = ColorScheme.fromSeed(seedColor: seed, brightness: b).copyWith(
      primary: primary,
      onPrimary: dark ? const Color(0xFF0B1220) : Colors.white,
    );
    final border = dark ? const Color(0xFF26282D) : const Color(0xFFE2E5EB);
    final hint = dark ? const Color(0xFF9AA3B5) : const Color(0xFF5C6475); // 4.5:1 on both grounds
    return ThemeData(
      useMaterial3: true,
      colorScheme: cs,
      visualDensity: VisualDensity.comfortable,
      iconTheme: const IconThemeData(size: 20),
      iconButtonTheme: IconButtonThemeData(style: IconButton.styleFrom(iconSize: 18)),
      scaffoldBackgroundColor: dark ? const Color(0xFF0A0B0D) : const Color(0xFFF6F7F9),
      cardTheme: CardThemeData(
        elevation: 0,
        color: dark ? const Color(0xFF141619) : Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(_kRadius), side: BorderSide(color: border)),
        margin: EdgeInsets.zero,
      ),
      appBarTheme: AppBarTheme(
        elevation: 0,
        scrolledUnderElevation: 0,
        surfaceTintColor: Colors.transparent,
        backgroundColor: dark ? const Color(0xFF0A0B0D) : const Color(0xFFF6F7F9),
        shape: Border(bottom: BorderSide(color: border)),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: dark ? const Color(0xFF141619) : Colors.white,
        isDense: true,
        hintStyle: TextStyle(color: hint),
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: border)),
        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: border)),
        focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: cs.primary, width: 1.5)),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: cs.onSurfaceVariant,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
      ),
      popupMenuTheme: PopupMenuThemeData(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10), side: BorderSide(color: border)),
        surfaceTintColor: Colors.transparent,
      ),
      tooltipTheme: const TooltipThemeData(waitDuration: Duration(milliseconds: 500)),
      dividerColor: border,
      dividerTheme: DividerThemeData(color: border, space: 1, thickness: 1),
    );
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: prefs,
    builder: (context, _) => MaterialApp(
      title: 'Spate',
      debugShowCheckedModeBanner: false,
      themeMode: prefs.mode,
      theme: theme(Brightness.light, prefs.seed),
      darkTheme: theme(Brightness.dark, prefs.seed),
      home: HomeScreen(controller: controller, prefs: prefs),
    ),
  );
}

class HomeScreen extends StatefulWidget {
  final SpateController controller;
  final UiPrefs prefs;
  const HomeScreen({super.key, required this.controller, required this.prefs});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _addKey = GlobalKey<AddBarState>();
  final _listFocus = FocusNode(debugLabel: 'downloads');
  bool? _finishedOpen; // null = automatic (open only when nothing is active)
  bool _dragging = false;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_maybePromptPairing);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_maybePromptPairing);
    _listFocus.dispose();
    super.dispose();
  }

  // Pairing prompt: the extension asked to connect; the user allows once.
  void _maybePromptPairing() {
    final c = widget.controller;
    if (!c.pairPending || c.pairShown) return;
    c.pairShown = true;
    showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: const Icon(Icons.extension_outlined),
        title: const Text('Connect browser extension?'),
        content: const Text('The Spate browser extension wants to hand downloads to this app.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Deny')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Allow')),
        ],
      ),
    ).then((ok) {
      c.core.resolvePair(ok ?? false);
      c.pairShown = false;
    });
  }

  Future<void> _openSettings() async {
    await Navigator.of(context).push(fadeRoute(SettingsScreen(core: widget.controller.core, prefs: widget.prefs)));
    setState(() {});
  }

  Future<void> _pasteAnywhere() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final links = SpateController.linksIn(data?.text ?? '');
    if (links.isEmpty) {
      widget.controller.lastError = 'The clipboard has no link.';
      setState(() {});
      return;
    }
    _addKey.currentState?.add(links.join(' '));
  }

  Future<void> _dropped(DropDoneDetails d) async {
    final links = <String>[];
    var files = 0;
    for (final item in d.files) {
      final p = item.path;
      if (RegExp(r'^(https?|ftps?)://').hasMatch(p)) {
        links.add(p);
        continue;
      }
      final lower = p.toLowerCase();
      if (lower.endsWith('.txt') || lower.endsWith('.url') || lower.endsWith('.webloc') || lower.endsWith('.desktop')) {
        try {
          links.addAll(SpateController.linksIn(await File(p).readAsString()));
          continue;
        } catch (_) {}
      }
      files++;
    }
    if (links.isEmpty) {
      widget.controller.lastError = files > 0
          ? 'Nothing downloadable in what you dropped: drop links, or a text file of links.'
          : 'Nothing downloadable in what you dropped.';
      setState(() {});
      return;
    }
    _addKey.currentState?.add(links.join(' '));
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (e is! KeyDownEvent && e is! KeyRepeatEvent) return KeyEventResult.ignored;
    final c = widget.controller;
    final order = sortedForList(c.jobs).map((j) => j.id).toList();
    final k = e.logicalKey;
    final meta = HardwareKeyboard.instance.isMetaPressed || HardwareKeyboard.instance.isControlPressed;
    if (k == LogicalKeyboardKey.arrowDown) {
      c.selection.move(1, order);
    } else if (k == LogicalKeyboardKey.arrowUp) {
      c.selection.move(-1, order);
    } else if (k == LogicalKeyboardKey.escape) {
      c.selection.clear();
    } else if (meta && k == LogicalKeyboardKey.keyA) {
      c.selection.selectAll(order);
    } else if (k == LogicalKeyboardKey.space && c.selection.count > 0) {
      for (final j in c.jobs.where((j) => c.selection.contains(j.id))) {
        if (j.state == 'running' || (j.state == 'pending' && !j.isScheduled)) {
          c.pause(j.id);
        } else if (j.state == 'paused') {
          c.resume(j.id);
        }
      }
    } else if ((k == LogicalKeyboardKey.delete || k == LogicalKeyboardKey.backspace) && c.selection.count > 0) {
      final targets = c.jobs.where((j) => c.selection.contains(j.id)).toList();
      runRowAction(context, 'remove', c, targets);
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Shortcuts(
      shortcuts: {
        SingleActivator(LogicalKeyboardKey.keyV, meta: Platform.isMacOS, control: !Platform.isMacOS): const _PasteIntent(),
        SingleActivator(LogicalKeyboardKey.comma, meta: Platform.isMacOS, control: !Platform.isMacOS): const _SettingsIntent(),
      },
      child: Actions(
        actions: {
          _PasteIntent: CallbackAction<_PasteIntent>(onInvoke: (_) {
            // In a text field, let the field paste; elsewhere paste as links.
            if (FocusManager.instance.primaryFocus?.context?.widget is EditableText) return null;
            _pasteAnywhere();
            return null;
          }),
          _SettingsIntent: CallbackAction<_SettingsIntent>(onInvoke: (_) {
            _openSettings();
            return null;
          }),
        },
        child: Scaffold(
          body: DropTarget(
            onDragEntered: (_) => setState(() => _dragging = true),
            onDragExited: (_) => setState(() => _dragging = false),
            onDragDone: (d) {
              setState(() => _dragging = false);
              _dropped(d);
            },
            child: Stack(
              children: [
                AnimatedBuilder(
                  animation: widget.controller,
                  builder: (context, _) {
                    final all = sortedForList(widget.controller.jobs);
                    final active = all.where((j) => j.isActive).toList();
                    final finished = all.where((j) => j.isTerminal).toList();
                    final finishedOpen = _finishedOpen ?? active.isEmpty;
                    return Column(
                      children: [
                        _header(context, all),
                        Expanded(
                          child: Center(
                            child: ConstrainedBox(
                              constraints: const BoxConstraints(maxWidth: _kMaxWidth),
                              child: Focus(
                                focusNode: _listFocus,
                                onKeyEvent: _onKey,
                                child: CustomScrollView(
                                  slivers: [
                                    SliverPadding(
                                      padding: const EdgeInsets.fromLTRB(20, 10, 20, 6),
                                      sliver: SliverToBoxAdapter(child: AddBar(key: _addKey, controller: widget.controller)),
                                    ),
                                    if (all.isEmpty)
                                      SliverFillRemaining(hasScrollBody: false, child: _empty(context))
                                    else ...[
                                      SliverPadding(
                                        padding: const EdgeInsets.fromLTRB(20, 6, 20, 0),
                                        sliver: SliverToBoxAdapter(child: _groupCard(context, active, finished, finishedOpen)),
                                      ),
                                      const SliverToBoxAdapter(child: SizedBox(height: 24)),
                                    ],
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    );
                  },
                ),
                if (_dragging)
                  Positioned.fill(
                    child: IgnorePointer(
                      child: Container(
                        color: cs.primary.withValues(alpha: 0.08),
                        alignment: Alignment.center,
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
                          decoration: BoxDecoration(color: cs.primary, borderRadius: BorderRadius.circular(10)),
                          child: Text('Drop to download', style: TextStyle(color: cs.onPrimary, fontWeight: FontWeight.w600)),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// The list: active rows, then a collapsible Finished group, in one card.
  Widget _groupCard(BuildContext context, List<JobStatus> active, List<JobStatus> finished, bool finishedOpen) {
    final c = widget.controller;
    final order = [...active, ...finished].map((j) => j.id).toList();
    var queuePos = 0;
    Widget row(JobStatus j) {
      final pos = (j.state == 'pending' && !j.isScheduled) ? ++queuePos : null;
      return DownloadRow(
        key: ValueKey(j.id),
        job: j,
        controller: c,
        selected: c.selection.contains(j.id),
        queuePosition: pos,
        onSelect: (shift, toggle) {
          _listFocus.requestFocus();
          c.selection.click(j.id, order, shift: shift, toggle: toggle);
        },
        onContextMenu: (pos) async {
          if (!c.selection.contains(j.id)) c.selection.click(j.id, order);
          final targets = c.targetsFor(j);
          final box = Overlay.of(context).context.findRenderObject() as RenderBox;
          final key = await showMenu<String>(
            context: context,
            position: RelativeRect.fromRect(pos & const Size(1, 1), Offset.zero & box.size),
            items: rowMenuEntries(j, targets.length),
          );
          if (key != null && context.mounted) runRowAction(context, key, c, targets);
        },
      );
    }

    final children = <Widget>[];
    for (var i = 0; i < active.length; i++) {
      if (i > 0) children.add(const Divider(indent: 12, endIndent: 12));
      children.add(row(active[i]));
    }
    if (finished.isNotEmpty) {
      if (active.isNotEmpty) children.add(const Divider());
      children.add(FinishedHeader(
        count: finished.length,
        open: finishedOpen,
        onToggle: () => setState(() => _finishedOpen = !finishedOpen),
        onClear: c.clearFinished,
      ));
      if (finishedOpen) {
        for (var i = 0; i < finished.length; i++) {
          children.add(const Divider(indent: 12, endIndent: 12));
          children.add(row(finished[i]));
        }
      }
    }
    return Card(child: Column(children: children));
  }

  /// The window's top row. On macOS it *is* the title bar: the native title
  /// is hidden, the traffic lights stay, the row is draggable and 52px tall.
  /// Elsewhere the native bar shows the name, so this is a slim toolbar.
  Widget _header(BuildContext context, List<JobStatus> jobs) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final c = widget.controller;
    final active = jobs.where((j) => j.state == 'running').length;
    final queued = jobs.where((j) => j.state == 'pending').length;
    final paused = jobs.where((j) => j.state == 'paused').length;
    final speed = c.totalSpeed;
    final limit = c.currentLimit;
    final mac = Platform.isMacOS;
    final row = Row(
      children: [
        if (mac) ...[
          const SizedBox(width: 96), // unified-toolbar traffic lights end at 80pt
          SizedBox(width: 22, height: 22, child: CustomPaint(painter: SpateGlyph(cs.primary))),
          const SizedBox(width: 10),
          Text('Spate', style: tt.titleMedium?.copyWith(fontWeight: FontWeight.w700, letterSpacing: -0.2)),
        ],
        const Spacer(),
        if (active > 0) ...[
          Tooltip(
            message: 'Total speed over the last 30 seconds',
            child: _Pill(
              text: '${humanBytes(speed.round())}/s',
              color: cs.primary,
              leading: SizedBox(width: 44, height: 14, child: CustomPaint(painter: Sparkline(List.of(c.speedHistory), cs.primary))),
            ),
          ),
          const SizedBox(width: 8),
          _Pill(text: '$active downloading${queued > 0 ? ' · $queued queued' : ''}', color: cs.onSurfaceVariant, subtle: true),
        ] else if (jobs.any((j) => j.isActive))
          _Pill(text: [if (queued > 0) '$queued queued', if (paused > 0) '$paused paused'].join(' · '), color: cs.onSurfaceVariant, subtle: true),
        if (limit > 0) ...[
          const SizedBox(width: 8),
          Tooltip(message: 'Speed limit in force (Settings)', child: _Pill(text: 'limit ${humanBytes(limit)}/s', color: cs.tertiary)),
        ],
        const SizedBox(width: 4),
        PopupMenuButton<String>(
          tooltip: 'Queue',
          icon: const Icon(Icons.more_horiz_rounded),
          onSelected: (k) => switch (k) {
            'pauseall' => c.pauseAll(),
            'resumeall' => c.resumeAll(),
            'clear' => c.clearFinished(),
            _ => _openSettings(),
          },
          itemBuilder: (_) => [
            PopupMenuItem(value: 'pauseall', height: 36, enabled: active + queued > 0, child: const Text('Pause all')),
            PopupMenuItem(value: 'resumeall', height: 36, enabled: paused > 0, child: const Text('Resume all')),
            PopupMenuItem(value: 'clear', height: 36, enabled: jobs.any((j) => j.isTerminal), child: const Text('Clear finished')),
            const PopupMenuDivider(height: 8),
            const PopupMenuItem(value: 'settings', height: 36, child: Text('Settings…')),
          ],
        ),
        IconButton(tooltip: 'Settings (Cmd-,)', icon: const Icon(Icons.settings_outlined), onPressed: _openSettings),
      ],
    );
    if (mac) {
      return DragToMoveArea(
        child: Container(
          height: 52,
          padding: const EdgeInsets.only(right: 12),
          decoration: BoxDecoration(border: Border(bottom: BorderSide(color: Theme.of(context).dividerColor))),
          child: row,
        ),
      );
    }
    return Padding(padding: const EdgeInsets.fromLTRB(20, 8, 12, 0), child: row);
  }

  Widget _empty(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(width: 44, height: 44, child: CustomPaint(painter: SpateGlyph(cs.primary.withValues(alpha: 0.55)))),
          const SizedBox(height: 14),
          Text('Nothing downloading', style: tt.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
          const SizedBox(height: 4),
          Text(
            'Downloads you start in the browser show up here.\nPaste links above, drop them on the window, or press ${Platform.isMacOS ? 'Cmd' : 'Ctrl'}-V.',
            textAlign: TextAlign.center,
            style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

class _PasteIntent extends Intent {
  const _PasteIntent();
}

class _SettingsIntent extends Intent {
  const _SettingsIntent();
}

class _Pill extends StatelessWidget {
  final String text;
  final Color color;
  final bool subtle;
  final Widget? leading;
  const _Pill({required this.text, required this.color, this.subtle = false, this.leading});
  @override
  Widget build(BuildContext context) => AnimatedContainer(
    duration: kMotion,
    curve: kMotionCurve,
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
    decoration: BoxDecoration(color: color.withValues(alpha: subtle ? 0.10 : 0.12), borderRadius: BorderRadius.circular(999)),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (leading != null) ...[leading!, const SizedBox(width: 8)],
        Text(
          text,
          style: Theme.of(context).textTheme.labelSmall!.copyWith(
            color: color,
            fontWeight: FontWeight.w600,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
      ],
    ),
  );
}
