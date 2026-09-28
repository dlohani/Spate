import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'ffi/cascade_ffi.dart';
import 'model/job.dart';

/// App state: polls the core twice a second and exposes the queue.
class CascadeController extends ChangeNotifier {
  final Cascade core;
  List<JobStatus> jobs = const [];
  final Map<String, _Rate> _rates = {};
  bool pairShown = false; // a pairing dialog is currently on screen
  Timer? _timer;
  String? lastError;

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
    notifyListeners();
  }

  double speedOf(String id) => _rates[id]?.bps ?? 0;
  double get totalSpeed => jobs.where((j) => j.state == 'running').fold(0.0, (a, j) => a + speedOf(j.id));

  bool get pairPending => core.pairPending;

  bool add(String url, {String dir = '', int conns = 8}) {
    final id = core.add(url, dir: dir, conns: conns);
    lastError = id == null ? 'That does not look like a downloadable link.' : null;
    _tick();
    return id != null;
  }

  void pause(String id) { core.pause(id); _tick(); }
  void resume(String id) { core.resume(id); _tick(); }
  void cancel(String id) { core.cancel(id); _tick(); }
  void remove(String id) { core.remove(id); _tick(); }
  void clearFinished() { core.clearFinished(); _tick(); }
  void cancelAll() { core.cancelAll(); _tick(); }

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
const _kSeed = Color(0xFF2563EB);
const _kRadius = 14.0;
const _kMaxWidth = 900.0;

class CascadeApp extends StatelessWidget {
  final CascadeController controller;
  const CascadeApp({super.key, required this.controller});

  ThemeData _theme(Brightness b) {
    final cs = ColorScheme.fromSeed(seedColor: _kSeed, brightness: b);
    final border = b == Brightness.dark ? const Color(0xFF2A303A) : const Color(0xFFE5E7EB);
    return ThemeData(
      useMaterial3: true,
      colorScheme: cs,
      visualDensity: VisualDensity.comfortable,
      scaffoldBackgroundColor: b == Brightness.dark ? const Color(0xFF0F1217) : const Color(0xFFF6F7F9),
      cardTheme: CardThemeData(
        elevation: 0,
        color: b == Brightness.dark ? const Color(0xFF171B22) : Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(_kRadius), side: BorderSide(color: border)),
        margin: EdgeInsets.zero,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: b == Brightness.dark ? const Color(0xFF0F1217) : const Color(0xFFF3F4F6),
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
        focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: cs.primary, width: 1.5)),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(foregroundColor: cs.onSurfaceVariant, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8))),
      ),
      tooltipTheme: const TooltipThemeData(waitDuration: Duration(milliseconds: 500)),
      dividerColor: border,
    );
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Cascade',
        debugShowCheckedModeBanner: false,
        theme: _theme(Brightness.light),
        darkTheme: _theme(Brightness.dark),
        home: HomeScreen(controller: controller),
      );
}

class HomeScreen extends StatefulWidget {
  final CascadeController controller;
  const HomeScreen({super.key, required this.controller});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _url = TextEditingController();
  final _urlFocus = FocusNode();
  late final TextEditingController _dir;
  final _conns = TextEditingController(text: '8');
  bool _showOptions = false;

  @override
  void initState() {
    super.initState();
    _dir = TextEditingController(text: (widget.controller.core.info()['dir'] as String?) ?? '');
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
    final ok = widget.controller.add(u, dir: _dir.text.trim(), conns: int.tryParse(_conns.text) ?? 8);
    if (ok) _url.clear();
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
          return Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: _kMaxWidth),
              child: CustomScrollView(
                slivers: [
                  SliverPadding(padding: const EdgeInsets.fromLTRB(24, 22, 24, 10), sliver: SliverToBoxAdapter(child: _header(context, jobs))),
                  SliverPadding(padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 6), sliver: SliverToBoxAdapter(child: _addCard(context))),
                  SliverPadding(padding: const EdgeInsets.fromLTRB(24, 18, 24, 6), sliver: SliverToBoxAdapter(child: _sectionBar(context, jobs))),
                  if (jobs.isEmpty)
                    SliverFillRemaining(hasScrollBody: false, child: _empty(context))
                  else
                    SliverPadding(
                      padding: const EdgeInsets.fromLTRB(24, 2, 24, 28),
                      sliver: SliverList.separated(
                        itemCount: jobs.length,
                        separatorBuilder: (_, _) => const SizedBox(height: 10),
                        itemBuilder: (context, i) => DownloadCard(key: ValueKey(jobs[i].id), job: jobs[i], controller: widget.controller),
                      ),
                    ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _header(BuildContext context, List<JobStatus> jobs) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final active = jobs.where((j) => j.state == 'running').length;
    final speed = widget.controller.totalSpeed;
    return Row(
      children: [
        Container(
          width: 34, height: 34,
          decoration: BoxDecoration(color: cs.primary, borderRadius: BorderRadius.circular(10)),
          child: const Icon(Icons.arrow_downward_rounded, color: Colors.white, size: 20),
        ),
        const SizedBox(width: 12),
        Text('Cascade', style: tt.headlineSmall?.copyWith(fontWeight: FontWeight.w700, letterSpacing: -0.3)),
        const Spacer(),
        if (active > 0) ...[
          _Pill(text: '${humanBytes(speed.round())}/s', color: cs.primary),
          const SizedBox(width: 8),
          _Pill(text: '$active active', color: cs.onSurfaceVariant, subtle: true),
        ] else if (jobs.isNotEmpty)
          _Pill(text: '${jobs.length} in list', color: cs.onSurfaceVariant, subtle: true),
      ],
    );
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
            Row(children: [
              Expanded(
                child: TextField(
                  controller: _url,
                  focusNode: _urlFocus,
                  onSubmitted: (_) => _add(),
                  decoration: InputDecoration(
                    hintText: 'Paste a link to download',
                    prefixIcon: const Icon(Icons.link_rounded),
                    suffixIcon: IconButton(tooltip: 'Paste and download', icon: const Icon(Icons.content_paste_rounded, size: 20), onPressed: _paste),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              FilledButton.icon(onPressed: _add, icon: const Icon(Icons.download_rounded), label: const Text('Download')),
            ]),
            AnimatedSize(
              duration: const Duration(milliseconds: 180),
              curve: Curves.easeOut,
              alignment: Alignment.topCenter,
              child: _showOptions
                  ? Padding(
                      padding: const EdgeInsets.only(top: 10),
                      child: Row(children: [
                        Expanded(flex: 3, child: TextField(controller: _dir, decoration: const InputDecoration(labelText: 'Save to', prefixIcon: Icon(Icons.folder_outlined)))),
                        const SizedBox(width: 10),
                        SizedBox(width: 150, child: TextField(controller: _conns, decoration: const InputDecoration(labelText: 'Connections', prefixIcon: Icon(Icons.call_split_rounded)))),
                      ]),
                    )
                  : const SizedBox(width: double.infinity),
            ),
            Row(children: [
              TextButton.icon(
                onPressed: () => setState(() => _showOptions = !_showOptions),
                icon: Icon(_showOptions ? Icons.expand_less_rounded : Icons.tune_rounded, size: 18),
                label: Text(_showOptions ? 'Hide options' : 'Options'),
              ),
              const Spacer(),
              if (err != null) Text(err, style: tt.bodySmall?.copyWith(color: cs.error)),
            ]),
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
          icon: const Icon(Icons.stop_circle_outlined, size: 18), label: const Text('Cancel all'),
        ),
        TextButton.icon(
          onPressed: jobs.any((j) => j.isTerminal) ? widget.controller.clearFinished : null,
          icon: const Icon(Icons.playlist_remove_rounded, size: 18), label: const Text('Clear finished'),
        ),
      ],
    );
  }

  Widget _empty(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    return Center(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Container(
          width: 64, height: 64,
          decoration: BoxDecoration(color: cs.primary.withValues(alpha: 0.08), shape: BoxShape.circle),
          child: Icon(Icons.download_outlined, size: 30, color: cs.primary),
        ),
        const SizedBox(height: 14),
        Text('Nothing downloading', style: tt.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
        const SizedBox(height: 4),
        Text('Downloads you start in the browser show up here.\nOr paste a link above.',
            textAlign: TextAlign.center, style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
      ]),
    );
  }
}

class _Pill extends StatelessWidget {
  final String text;
  final Color color;
  final bool subtle;
  const _Pill({required this.text, required this.color, this.subtle = false});
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(color: color.withValues(alpha: subtle ? 0.10 : 0.12), borderRadius: BorderRadius.circular(999)),
        child: Text(text, style: Theme.of(context).textTheme.labelSmall?.copyWith(color: color, fontWeight: FontWeight.w600)),
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
      'pending' => (cs.onSurfaceVariant, 'Queued'),
      _ => (cs.primary, 'Downloading'),
    };
    final details = <String>[
      if (job.host.isNotEmpty) job.host,
      if (job.state == 'running') '${humanBytes(bps.round())}/s',
      if (job.state == 'running' && job.total > 0 && bps > 0) '${humanEta((job.total - job.bytes) / bps)} left',
      if (job.state == 'running' && job.retries > 0) 'retry ${job.retries}',
      if (job.state == 'failed' && job.error != null) job.error!,
    ].join('  ·  ');
    final right = job.total > 0
        ? '${humanBytes(job.bytes)} / ${humanBytes(job.total)}'
        : humanBytes(job.bytes);
    final pct = job.total > 0 ? '${(job.fraction * 100).toStringAsFixed(0)}%' : '';

    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(_kRadius),
          boxShadow: _hover ? [BoxShadow(color: Colors.black.withValues(alpha: 0.06), blurRadius: 14, offset: const Offset(0, 4))] : const [],
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
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Row(children: [
                          Flexible(child: Text(job.filename, maxLines: 1, overflow: TextOverflow.ellipsis, style: tt.titleSmall?.copyWith(fontWeight: FontWeight.w600))),
                          const SizedBox(width: 8),
                          _Pill(text: label, color: color),
                        ]),
                        const SizedBox(height: 3),
                        Text(details, maxLines: 1, overflow: TextOverflow.ellipsis, style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
                      ]),
                    ),
                    const SizedBox(width: 8),
                    ..._actions(context),
                  ],
                ),
                const SizedBox(height: 10),
                Row(children: [
                  Expanded(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: TweenAnimationBuilder<double>(
                        tween: Tween(end: job.fraction),
                        duration: const Duration(milliseconds: 450),
                        curve: Curves.easeOutCubic,
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
                    child: Text('$right${pct.isEmpty ? '' : '  ·  $pct'}', textAlign: TextAlign.right, style: tt.labelSmall?.copyWith(color: cs.onSurfaceVariant, fontFeatures: const [FontFeature.tabularFigures()])),
                  ),
                ]),
              ],
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
        IconButton(tooltip: tip, icon: Icon(icon, size: 20), onPressed: onTap, visualDensity: VisualDensity.compact);
    final primary = switch (job.state) {
      'running' || 'pending' => btn(Icons.pause_rounded, 'Pause', () => c.pause(job.id)),
      'paused' => btn(Icons.play_arrow_rounded, 'Resume', () => c.resume(job.id)),
      'done' => btn(Icons.folder_open_rounded, Platform.isMacOS ? 'Show in Finder' : 'Show in folder', () => c.reveal(job.out)),
      _ => btn(Icons.refresh_rounded, 'Retry', () => c.retry(job)),
    };
    final more = PopupMenuButton<String>(
      tooltip: 'More',
      icon: const Icon(Icons.more_horiz_rounded, size: 20),
      onSelected: (k) {
        switch (k) {
          case 'copy':
            Clipboard.setData(ClipboardData(text: job.url));
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
        const PopupMenuItem(value: 'copy', child: ListTile(dense: true, leading: Icon(Icons.link_rounded), title: Text('Copy link'))),
        if (job.state == 'done') const PopupMenuItem(value: 'open', child: ListTile(dense: true, leading: Icon(Icons.open_in_new_rounded), title: Text('Open file'))),
        if (job.state == 'done') PopupMenuItem(value: 'reveal', child: ListTile(dense: true, leading: const Icon(Icons.folder_open_rounded), title: Text(Platform.isMacOS ? 'Show in Finder' : 'Show in folder'))),
        if (!job.isTerminal) const PopupMenuItem(value: 'cancel', child: ListTile(dense: true, leading: Icon(Icons.close_rounded), title: Text('Cancel'))),
        const PopupMenuDivider(),
        const PopupMenuItem(value: 'remove', child: ListTile(dense: true, leading: Icon(Icons.delete_outline_rounded), title: Text('Remove from list'))),
      ],
    );
    return [primary, more];
  }
}
