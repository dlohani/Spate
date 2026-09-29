import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';

import 'ffi/cascade_ffi.dart';
import 'model/job.dart';
import 'model/ui_prefs.dart';
import 'settings_screen.dart';

/// App state: polls the core twice a second and exposes the queue.
class CascadeController extends ChangeNotifier {
  final Cascade core;
  List<JobStatus> jobs = const [];
  final Map<String, _Rate> _rates = {};
  bool pairShown = false; // a pairing dialog is currently on screen
  Timer? _timer;
  String? lastError;

  /// Called when another launch of the app asked this instance to show its
  /// window (the desktop shell hooks window_manager here).
  void Function()? onShowRequested;

  CascadeController(this.core) {
    _tick();
    _timer = Timer.periodic(const Duration(milliseconds: 500), (_) => _tick());
  }

  void _tick() {
    final now = DateTime.now();
    final next = core.statuses();
    for (final j in next) {
      _rates.putIfAbsent(j.id, () => _Rate()).observe(j.bytes, now);
    }
    _rates.removeWhere((id, _) => !next.any((j) => j.id == id));
    jobs = next;
    if (core.showPending) onShowRequested?.call();
    notifyListeners();
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
    lastError = id == null ? 'That does not look like a downloadable link.' : null;
    _tick();
    return id != null;
  }

  /// Bytes/sec cap in force right now (0 = unlimited); changes with the
  /// speed-limit time windows in Settings.
  int get currentLimit => core.currentLimit;

  void startNow(String id) {
    core.startNow(id);
    _tick();
  }

  void pause(String id) {
    core.pause(id);
    _tick();
  }

  void resume(String id) {
    core.resume(id);
    _tick();
  }

  void cancel(String id) {
    core.cancel(id);
    _tick();
  }

  /// Removes a row. An unfinished download's partial file and resume sidecar
  /// are deleted with it; a finished file stays where it is.
  void remove(String id) {
    core.discard(id);
    _tick();
  }

  void clearFinished() {
    core.clearFinished();
    _tick();
  }

  void cancelAll() {
    core.cancelAll();
    _tick();
  }

  /// Retry a failed/cancelled download: re-queue the same link into the same
  /// folder (the engine resumes from any partial file) and drop the old row.
  void retry(JobStatus j) {
    final dir = File(j.out).parent.path;
    core.remove(j.id);
    core.add(j.url, dir: dir);
    _tick();
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

class CascadeApp extends StatelessWidget {
  final CascadeController controller;
  final UiPrefs prefs;
  const CascadeApp({super.key, required this.controller, required this.prefs});

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
      title: 'Cascade',
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
  final CascadeController controller;
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
        content: const Text('The Cascade browser extension wants to hand downloads to this app.'),
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

  void _add() {
    final u = _url.text.trim();
    if (u.isEmpty) return;
    final ok = widget.controller.add(
      u,
      dir: _dir.text.trim(),
      conns: int.tryParse(_conns.text) ?? 8,
      startAt: _startAt,
    );
    if (ok) {
      _url.clear();
      _startAt = null;
    }
    setState(() {});
  }

  Future<void> _pickSchedule() async {
    final now = DateTime.now();
    final initial = _startAt ?? now.add(const Duration(hours: 1));
    final d = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: now,
      lastDate: now.add(const Duration(days: 365)),
    );
    if (d == null || !mounted) return;
    final t = await showTimePicker(context: context, initialTime: TimeOfDay.fromDateTime(initial));
    if (t == null) return;
    setState(() => _startAt = DateTime(d.year, d.month, d.day, t.hour, t.minute));
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
          Text('Cascade', style: tt.titleMedium?.copyWith(fontWeight: FontWeight.w700, letterSpacing: -0.2)),
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
                    decoration: InputDecoration(
                      hintText: 'Paste a link to download',
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
                  label: Text(_startAt == null ? 'Schedule' : 'Starts ${_fmtWhen(_startAt!)}'),
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
  final CascadeController controller;
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
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(4),
                          child: TweenAnimationBuilder<double>(
                            tween: Tween(end: job.fraction),
                            duration: kMotionSlow,
                            curve: kMotionCurve,
                            builder: (_, v, _) => LinearProgressIndicator(
                              value: job.total > 0 ? v : (job.state == 'running' ? null : 0),
                              minHeight: 6,
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
