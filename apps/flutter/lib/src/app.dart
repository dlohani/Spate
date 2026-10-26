import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';

import 'ffi/spate_ffi.dart';
import 'model/job.dart';
import 'model/ui_prefs.dart';
import 'settings_screen.dart';

/// App state: polls the core twice a second and exposes the queue.
class SpateController extends ChangeNotifier {
  final Spate core;
  List<JobStatus> jobs = const [];
  final Map<String, _Rate> _rates = {};
  bool pairShown = false; // a pairing dialog is currently on screen
  Timer? _timer;
  String? lastError;
  int _lastVersion = -1; // core queue version at the last full refresh
  int _lastLimit = -1; // bytes/sec cap shown at the last refresh

  /// Called when another launch of the app asked this instance to show its
  /// window (the desktop shell hooks window_manager here).
  void Function()? onShowRequested;

  /// Called after every refresh of [jobs], visible or not: the tray summary
  /// hooks here. Widgets listen through [addListener], which is only notified
  /// while the window is visible, so a hidden window does not rebuild and
  /// rasterise frames for every progress tick.
  void Function()? onJobsRefreshed;

  /// Whether the window is on screen. The shell sets it on show and hide;
  /// while false, widget listeners are not notified (see [onJobsRefreshed]).
  bool visible = true;

  SpateController(this.core) {
    _tick();
    _timer = Timer.periodic(const Duration(milliseconds: 500), (_) => _tick());
  }

  /// Refreshes from the core. [force] redraws even when the queue is
  /// unchanged (after a user action, so its result or error shows at once).
  void _tick({bool force = false}) {
    final now = DateTime.now();
    // Idle and unchanged: no status round trip and no redraw. The queue
    // version advances on any add, remove or state change; progress bytes do
    // not, so a running job keeps the full refresh going for its speed and
    // bar. Things outside the version are checked here: a pairing request,
    // the speed cap changing with its time windows, and a scheduled job
    // whose start time passes (its row then stops saying "Scheduled").
    final version = core.queueVersion;
    final limit = core.currentLimit;
    final running = jobs.any((j) => j.state == 'running');
    final scheduled = jobs.any((j) => j.startAt != null && j.state == 'pending');
    if (!force && version == _lastVersion && limit == _lastLimit && !running && !scheduled && !core.pairPending) {
      if (core.showPending) onShowRequested?.call();
      return;
    }
    _lastVersion = version;
    _lastLimit = limit;
    final next = core.statuses();
    for (final j in next) {
      _rates.putIfAbsent(j.id, () => _Rate()).observe(j.bytes, now);
    }
    _rates.removeWhere((id, _) => !next.any((j) => j.id == id));
    jobs = next;
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

  double speedOf(String id) => _rates[id]?.bps ?? 0;
  double get totalSpeed => jobs.where((j) => j.state == 'running').fold(0.0, (a, j) => a + speedOf(j.id));

  bool get pairPending => core.pairPending;

  /// Enqueues a link. An empty [dir] lets the destination rules decide
  /// (site rule > category > base folder); [startAt] schedules the start.
  bool add(String url, {String dir = '', int conns = 8, DateTime? startAt}) {
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
const _kRadius = 14.0;
const _kMaxWidth = 900.0;
// One motion language: short, decelerating, no slides. Reveal/hover use
// kMotion; progress bars ease over kMotionSlow so ticks look continuous.
const kMotion = Duration(milliseconds: 220);
const kMotionSlow = Duration(milliseconds: 420);
const kMotionCurve = Curves.easeOutCubic;

/// Date then time picker for a start time; null when the user cancelled.
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
  final t = await showTimePicker(context: context, initialTime: TimeOfDay.fromDateTime(initial));
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
  /// Both are seeded from the user's accent colour.
  static ThemeData theme(Brightness b, Color seed) {
    final cs = ColorScheme.fromSeed(seedColor: seed, brightness: b);
    final border = b == Brightness.dark ? const Color(0xFF26282D) : const Color(0xFFE5E7EB);
    return ThemeData(
      useMaterial3: true,
      colorScheme: cs,
      visualDensity: VisualDensity.comfortable,
      // Compact window: icons one step under Material defaults (24 / 18).
      iconTheme: const IconThemeData(size: 20),
      iconButtonTheme: IconButtonThemeData(style: IconButton.styleFrom(iconSize: 18)),
      scaffoldBackgroundColor: b == Brightness.dark ? const Color(0xFF0A0B0D) : const Color(0xFFF6F7F9),
      cardTheme: CardThemeData(
        elevation: 0,
        color: b == Brightness.dark ? const Color(0xFF141619) : Colors.white,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(_kRadius),
          side: BorderSide(color: border),
        ),
        margin: EdgeInsets.zero,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: b == Brightness.dark ? const Color(0xFF0A0B0D) : const Color(0xFFF3F4F6),
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: cs.primary, width: 1.5),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: cs.onSurfaceVariant,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
      ),
      tooltipTheme: const TooltipThemeData(waitDuration: Duration(milliseconds: 500)),
      dividerColor: border,
    );
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: prefs,
    builder: (context, _) => MaterialApp(
      title: 'Spate',
      debugShowCheckedModeBanner: false,
      themeMode: prefs.mode,
      themeAnimationDuration: kMotionSlow,
      themeAnimationCurve: kMotionCurve,
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
  final _url = TextEditingController();
  final _urlFocus = FocusNode();
  // Empty = automatic: the destination rules in Settings pick the folder.
  final _dir = TextEditingController();
  final _conns = TextEditingController(text: '8');
  bool _showOptions = false;
  DateTime? _startAt; // set by "Schedule"; null = start now

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_maybePromptPairing);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_maybePromptPairing);
    _urlFocus.dispose();
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

  /// Adds every link in the field (several may be pasted at once, separated
  /// by spaces or line breaks), all with the same folder, connections and
  /// start time. The start time stays selected so more links can be queued
  /// for the same slot; the X beside it clears it.
  void _add() {
    final urls = _url.text.split(RegExp(r'\s+')).where((u) => u.isNotEmpty).toList();
    if (urls.isEmpty) return;
    final c = widget.controller;
    final failed = <String>[];
    String? firstError;
    for (final u in urls) {
      final ok = c.add(u, dir: _dir.text.trim(), conns: int.tryParse(_conns.text) ?? 8, startAt: _startAt);
      if (!ok) {
        failed.add(u);
        firstError ??= c.lastError;
      }
    }
    if (failed.isEmpty) {
      _url.clear();
      c.lastError = null;
    } else {
      _url.text = failed.join(' '); // leave only what was refused, to fix or drop
      c.lastError = urls.length == 1
          ? firstError
          : '${urls.length - failed.length} of ${urls.length} added; ${failed.length} not downloadable: $firstError';
    }
    setState(() {});
  }

  Future<void> _pickSchedule() async {
    final at = await pickWhen(context, _startAt);
    if (at == null || !mounted) return;
    setState(() => _startAt = at);
  }

  Future<void> _openSettings() async {
    await Navigator.of(context).push(fadeRoute(SettingsScreen(core: widget.controller.core, prefs: widget.prefs)));
    setState(() {});
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim() ?? '';
    if (text.isEmpty) return;
    _url.text = text;
    _add();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: AnimatedBuilder(
        animation: widget.controller,
        builder: (context, _) {
          final jobs = [...widget.controller.jobs]..sort((a, b) => a.id.compareTo(b.id));
          return Column(
            children: [
              _header(context, jobs),
              Expanded(
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: _kMaxWidth),
                    child: CustomScrollView(
                      slivers: [
                        SliverPadding(
                          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 6),
                          sliver: SliverToBoxAdapter(child: _addCard(context)),
                        ),
                        SliverPadding(
                          padding: const EdgeInsets.fromLTRB(24, 18, 24, 6),
                          sliver: SliverToBoxAdapter(child: _sectionBar(context, jobs)),
                        ),
                        if (jobs.isEmpty)
                          SliverFillRemaining(hasScrollBody: false, child: _empty(context))
                        else
                          SliverPadding(
                            padding: const EdgeInsets.fromLTRB(24, 2, 24, 28),
                            sliver: SliverList.separated(
                              itemCount: jobs.length,
                              separatorBuilder: (_, _) => const SizedBox(height: 10),
                              itemBuilder: (context, i) =>
                                  DownloadCard(key: ValueKey(jobs[i].id), job: jobs[i], controller: widget.controller),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  /// The window's top row. On macOS it *is* the title bar: the native title
  /// is hidden, the traffic lights stay (96px inset: they end at 80pt in a unified toolbar), the row is draggable and
  /// 52px tall to match the taller title bar. Elsewhere the native bar shows
  /// the name, so this is a slim toolbar with just status and settings.
  Widget _header(BuildContext context, List<JobStatus> jobs) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final active = jobs.where((j) => j.state == 'running').length;
    final speed = widget.controller.totalSpeed;
    final limit = widget.controller.currentLimit;
    final mac = Platform.isMacOS;
    final row = Row(
      children: [
        if (mac) ...[
          const SizedBox(width: 96), // unified-toolbar traffic lights end at 80pt
          Container(
            width: 24,
            height: 24,
            decoration: BoxDecoration(color: cs.primary, borderRadius: BorderRadius.circular(7)),
            child: const Icon(Icons.arrow_downward_rounded, color: Colors.white, size: 15),
          ),
          const SizedBox(width: 10),
          Text('Spate', style: tt.titleMedium?.copyWith(fontWeight: FontWeight.w700, letterSpacing: -0.2)),
        ],
        const Spacer(),
        if (active > 0) ...[
          _Pill(text: '${humanBytes(speed.round())}/s', color: cs.primary),
          const SizedBox(width: 8),
          _Pill(text: '$active active', color: cs.onSurfaceVariant, subtle: true),
        ] else if (jobs.isNotEmpty)
          _Pill(text: '${jobs.length} in list', color: cs.onSurfaceVariant, subtle: true),
        if (limit > 0) ...[
          const SizedBox(width: 8),
          Tooltip(
            message: 'Speed limit in force (Settings)',
            child: _Pill(text: 'limit ${humanBytes(limit)}/s', color: cs.tertiary),
          ),
        ],
        const SizedBox(width: 6),
        IconButton(tooltip: 'Settings', icon: const Icon(Icons.settings_outlined), onPressed: _openSettings),
      ],
    );
    if (mac) {
      // Hairline under the header so it reads as a title bar, not a gap.
      return DragToMoveArea(
        child: Container(
          height: 52,
          padding: const EdgeInsets.only(right: 12),
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: Theme.of(context).dividerColor)),
          ),
          child: row,
        ),
      );
    }
    return Padding(padding: const EdgeInsets.fromLTRB(24, 8, 12, 0), child: row);
  }

  Widget _addCard(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final err = widget.controller.lastError;
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 14, 14, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _url,
                    focusNode: _urlFocus,
                    onSubmitted: (_) => _add(),
                    // Several links pasted with line breaks become one
                    // space-separated line; _add splits them again.
                    inputFormatters: [FilteringTextInputFormatter.deny(RegExp(r'[\r\n]+'), replacementString: ' ')],
                    decoration: InputDecoration(
                      hintText: 'Paste one or more links to download',
                      prefixIcon: const Icon(Icons.link_rounded),
                      suffixIcon: IconButton(
                        tooltip: 'Paste and download',
                        icon: const Icon(Icons.content_paste_rounded, size: 18),
                        onPressed: _paste,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                FilledButton.icon(
                  onPressed: _add,
                  icon: const Icon(Icons.download_rounded),
                  label: const Text('Download'),
                ),
              ],
            ),
            AnimatedSize(
              duration: kMotion,
              curve: kMotionCurve,
              alignment: Alignment.topCenter,
              child: _showOptions
                  ? Padding(
                      padding: const EdgeInsets.only(top: 10),
                      child: Row(
                        children: [
                          Expanded(
                            flex: 3,
                            child: TextField(
                              controller: _dir,
                              decoration: const InputDecoration(
                                labelText: 'Save to',
                                hintText: 'Automatic (folder rules in Settings)',
                                prefixIcon: Icon(Icons.folder_outlined),
                              ),
                            ),
                          ),
                          const SizedBox(width: 10),
                          SizedBox(
                            width: 150,
                            child: TextField(
                              controller: _conns,
                              decoration: const InputDecoration(
                                labelText: 'Connections',
                                prefixIcon: Icon(Icons.call_split_rounded),
                              ),
                            ),
                          ),
                        ],
                      ),
                    )
                  : const SizedBox(width: double.infinity),
            ),
            Row(
              children: [
                TextButton.icon(
                  onPressed: () => setState(() => _showOptions = !_showOptions),
                  icon: Icon(_showOptions ? Icons.expand_less_rounded : Icons.tune_rounded, size: 18),
                  label: Text(_showOptions ? 'Hide options' : 'Options'),
                ),
                TextButton.icon(
                  onPressed: _pickSchedule,
                  icon: const Icon(Icons.schedule_rounded, size: 18),
                  label: Text(_startAt == null ? 'Schedule' : 'New links start ${_fmtWhen(_startAt!)}'),
                ),
                if (_startAt != null)
                  IconButton(
                    tooltip: 'Start immediately instead',
                    icon: const Icon(Icons.close_rounded, size: 16),
                    visualDensity: VisualDensity.compact,
                    onPressed: () => setState(() => _startAt = null),
                  ),
                const Spacer(),
                if (err != null) Text(err, style: tt.bodySmall?.copyWith(color: cs.error)),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _sectionBar(BuildContext context, List<JobStatus> jobs) {
    final tt = Theme.of(context).textTheme;
    return Row(
      children: [
        Text('Downloads', style: tt.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
        const Spacer(),
        TextButton.icon(
          onPressed: jobs.any((j) => !j.isTerminal) ? widget.controller.cancelAll : null,
          icon: const Icon(Icons.stop_circle_outlined, size: 18),
          label: const Text('Cancel all'),
        ),
        TextButton.icon(
          onPressed: jobs.any((j) => j.isTerminal) ? widget.controller.clearFinished : null,
          icon: const Icon(Icons.playlist_remove_rounded, size: 18),
          label: const Text('Clear finished'),
        ),
      ],
    );
  }

  Widget _empty(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(color: cs.primary.withValues(alpha: 0.08), shape: BoxShape.circle),
            child: Icon(Icons.download_outlined, size: 26, color: cs.primary),
          ),
          const SizedBox(height: 14),
          Text('Nothing downloading', style: tt.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
          const SizedBox(height: 4),
          Text(
            'Downloads you start in the browser show up here.\nOr paste a link above.',
            textAlign: TextAlign.center,
            style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

/// "14:30" for today, "Tue 14:30" within a week, else "2026-10-03 14:30".
String _fmtWhen(DateTime t) {
  String two(int n) => n.toString().padLeft(2, '0');
  final now = DateTime.now();
  final hm = '${two(t.hour)}:${two(t.minute)}';
  final sameDay = t.year == now.year && t.month == now.month && t.day == now.day;
  if (sameDay) return hm;
  if (t.difference(now).inDays < 6) {
    const names = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    return '${names[t.weekday - 1]} $hm';
  }
  return '${t.year}-${two(t.month)}-${two(t.day)} $hm';
}

class _Pill extends StatelessWidget {
  final String text;
  final Color color;
  final bool subtle;
  const _Pill({required this.text, required this.color, this.subtle = false});
  @override
  Widget build(BuildContext context) => AnimatedContainer(
    duration: kMotion,
    curve: kMotionCurve,
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
    decoration: BoxDecoration(
      color: color.withValues(alpha: subtle ? 0.10 : 0.12),
      borderRadius: BorderRadius.circular(999),
    ),
    child: AnimatedDefaultTextStyle(
      duration: kMotion,
      curve: kMotionCurve,
      style: Theme.of(context).textTheme.labelSmall!.copyWith(color: color, fontWeight: FontWeight.w600),
      child: Text(text),
    ),
  );
}

class DownloadCard extends StatefulWidget {
  final JobStatus job;
  final SpateController controller;
  const DownloadCard({super.key, required this.job, required this.controller});
  @override
  State<DownloadCard> createState() => _DownloadCardState();
}

class _DownloadCardState extends State<DownloadCard> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final job = widget.job;
    final c = widget.controller;
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final bps = c.speedOf(job.id);
    final (Color color, String label) = switch (job.state) {
      'done' => (const Color(0xFF16A34A), 'Completed'),
      'failed' => (cs.error, 'Failed'),
      'paused' => (cs.outline, 'Paused'),
      'cancelled' => (cs.outline, 'Cancelled'),
      'pending' when job.isScheduled => (cs.tertiary, 'Scheduled'),
      'pending' => (cs.onSurfaceVariant, 'Queued'),
      _ => (cs.primary, 'Downloading'),
    };
    final details = <String>[
      if (job.host.isNotEmpty) job.host,
      if (job.isScheduled) 'starts ${_fmtWhen(job.startAt!)}',
      if (job.state == 'running') '${humanBytes(bps.round())}/s',
      if (job.state == 'running' && job.total > 0 && bps > 0) '${humanEta((job.total - job.bytes) / bps)} left',
      if (job.state == 'running' && job.retries > 0) 'retry ${job.retries}',
      if (job.state == 'failed' && job.error != null) job.error!,
    ].join('  ·  ');
    final right = job.total > 0 ? '${humanBytes(job.bytes)} / ${humanBytes(job.total)}' : humanBytes(job.bytes);
    final pct = job.total > 0 ? '${(job.fraction * 100).toStringAsFixed(0)}%' : '';

    // New rows rise in once (keyed by job id), then hover only lifts the shadow.
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: kMotion,
      curve: kMotionCurve,
      builder: (context, v, child) => Opacity(
        opacity: v,
        child: Transform.translate(offset: Offset(0, (1 - v) * 6), child: child),
      ),
      child: MouseRegion(
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: AnimatedContainer(
          duration: kMotion,
          curve: kMotionCurve,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(_kRadius),
            boxShadow: _hover
                ? [BoxShadow(color: Colors.black.withValues(alpha: 0.06), blurRadius: 14, offset: const Offset(0, 4))]
                : const [],
          ),
          child: Card(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 8, 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Flexible(
                                  child: Text(
                                    job.filename,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: tt.titleSmall?.copyWith(fontWeight: FontWeight.w600),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                _Pill(text: label, color: color),
                              ],
                            ),
                            const SizedBox(height: 3),
                            Text(
                              details,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      ..._actions(context),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        // The bar animates for most of every 500 ms tick, so
                        // it gets its own repaint boundary (the card and the
                        // list around it do not re-rasterise) and draws its
                        // rounded corners itself instead of through a clip
                        // layer, which the renderer would back with an
                        // offscreen surface per row.
                        child: RepaintBoundary(
                          child: TweenAnimationBuilder<double>(
                            tween: Tween(end: job.fraction),
                            duration: kMotionSlow,
                            curve: kMotionCurve,
                            builder: (_, v, _) => LinearProgressIndicator(
                              value: job.total > 0 ? v : (job.state == 'running' ? null : 0),
                              minHeight: 6,
                              borderRadius: BorderRadius.circular(4),
                              color: color,
                              backgroundColor: cs.surfaceContainerHighest,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      SizedBox(
                        width: 190,
                        child: Text(
                          '$right${pct.isEmpty ? '' : '  ·  $pct'}',
                          textAlign: TextAlign.right,
                          style: tt.labelSmall?.copyWith(
                            color: cs.onSurfaceVariant,
                            fontFeatures: const [FontFeature.tabularFigures()],
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _actions(BuildContext context) {
    final job = widget.job;
    final c = widget.controller;
    IconButton btn(IconData icon, String tip, VoidCallback? onTap) =>
        IconButton(tooltip: tip, icon: Icon(icon, size: 18), onPressed: onTap, visualDensity: VisualDensity.compact);
    final primary = switch (job.state) {
      'pending' when job.isScheduled => btn(Icons.play_arrow_rounded, 'Start now', () => c.startNow(job.id)),
      'running' || 'pending' => btn(Icons.pause_rounded, 'Pause', () => c.pause(job.id)),
      'paused' => btn(Icons.play_arrow_rounded, 'Resume', () => c.resume(job.id)),
      'done' => btn(
        Icons.folder_open_rounded,
        Platform.isMacOS ? 'Show in Finder' : 'Show in folder',
        () => c.reveal(job.out),
      ),
      _ => btn(Icons.refresh_rounded, 'Retry', () => c.retry(job)),
    };
    final more = PopupMenuButton<String>(
      tooltip: 'More',
      icon: const Icon(Icons.more_horiz_rounded, size: 18),
      onSelected: (k) {
        switch (k) {
          case 'copy':
            Clipboard.setData(ClipboardData(text: job.url));
          case 'startnow':
            c.startNow(job.id);
          case 'schedule':
            pickWhen(context, job.startAt).then((at) {
              if (at != null) c.schedule(job.id, at);
            });
          case 'open':
            c.openFile(job.out);
          case 'reveal':
            c.reveal(job.out);
          case 'cancel':
            c.cancel(job.id);
          case 'remove':
            c.remove(job.id);
        }
      },
      itemBuilder: (_) => [
        const PopupMenuItem(
          value: 'copy',
          child: ListTile(dense: true, leading: Icon(Icons.link_rounded), title: Text('Copy link')),
        ),
        if (job.isScheduled)
          const PopupMenuItem(
            value: 'startnow',
            child: ListTile(dense: true, leading: Icon(Icons.play_arrow_rounded), title: Text('Start now')),
          ),
        if (job.state == 'pending' || job.state == 'paused')
          PopupMenuItem(
            value: 'schedule',
            child: ListTile(
              dense: true,
              leading: const Icon(Icons.schedule_rounded),
              title: Text(job.isScheduled ? 'Reschedule' : 'Schedule'),
            ),
          ),
        if (job.state == 'done')
          const PopupMenuItem(
            value: 'open',
            child: ListTile(dense: true, leading: Icon(Icons.open_in_new_rounded), title: Text('Open file')),
          ),
        if (job.state == 'done')
          PopupMenuItem(
            value: 'reveal',
            child: ListTile(
              dense: true,
              leading: const Icon(Icons.folder_open_rounded),
              title: Text(Platform.isMacOS ? 'Show in Finder' : 'Show in folder'),
            ),
          ),
        if (!job.isTerminal)
          const PopupMenuItem(
            value: 'cancel',
            child: ListTile(dense: true, leading: Icon(Icons.close_rounded), title: Text('Cancel')),
          ),
        const PopupMenuDivider(),
        PopupMenuItem(
          value: 'remove',
          child: ListTile(
            dense: true,
            leading: const Icon(Icons.delete_outline_rounded),
            title: Text(job.state == 'done' ? 'Remove from list' : 'Remove and delete partial file'),
          ),
        ),
      ],
    );
    return [primary, more];
  }
}
