import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

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
      final r = _rates.putIfAbsent(j.id, () => _Rate());
      r.observe(j.bytes, now);
    }
    _rates.removeWhere((id, _) => !next.any((j) => j.id == id));
    jobs = next;
    notifyListeners();
  }

  double speedOf(String id) => _rates[id]?.bps ?? 0;

  bool get pairPending => core.pairPending;

  void add(String url, {String dir = '', int conns = 8}) {
    final id = core.add(url, dir: dir, conns: conns);
    lastError = id == null ? 'Could not add this link' : null;
    _tick();
  }

  void pause(String id) { core.pause(id); _tick(); }
  void resume(String id) { core.resume(id); _tick(); }
  void cancel(String id) { core.cancel(id); _tick(); }
  void remove(String id) { core.remove(id); _tick(); }
  void clearFinished() { core.clearFinished(); _tick(); }
  void cancelAll() { core.cancelAll(); _tick(); }

  void reveal(String path) {
    if (Platform.isMacOS) {
      Process.start('open', ['-R', path]);
    } else if (Platform.isWindows) {
      Process.start('explorer', ['/select,', path]);
    } else {
      Process.start('xdg-open', [File(path).parent.path]);
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

class CascadeApp extends StatelessWidget {
  final CascadeController controller;
  const CascadeApp({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    final seed = const Color(0xFF2563EB);
    ThemeData theme(Brightness b) => ThemeData(
          useMaterial3: true,
          colorScheme: ColorScheme.fromSeed(seedColor: seed, brightness: b),
          visualDensity: VisualDensity.comfortable,
          cardTheme: CardThemeData(
            elevation: 0,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
              side: BorderSide(color: b == Brightness.dark ? const Color(0xFF2A303A) : const Color(0xFFE5E7EB)),
            ),
            margin: EdgeInsets.zero,
          ),
          inputDecorationTheme: InputDecorationTheme(
            filled: true,
            isDense: true,
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
          ),
        );
    return MaterialApp(
      title: 'Cascade',
      debugShowCheckedModeBanner: false,
      theme: theme(Brightness.light),
      darkTheme: theme(Brightness.dark),
      home: HomeScreen(controller: controller),
    );
  }
}

class HomeScreen extends StatefulWidget {
  final CascadeController controller;
  const HomeScreen({super.key, required this.controller});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _url = TextEditingController();
  late final TextEditingController _dir;
  final _conns = TextEditingController(text: '8');

  @override
  void initState() {
    super.initState();
    _dir = TextEditingController(text: (widget.controller.core.info()['dir'] as String?) ?? '');
    widget.controller.addListener(_maybePromptPairing);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_maybePromptPairing);
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
        title: const Text('Browser extension'),
        content: const Text('A browser extension wants to connect to Cascade to hand off downloads.'),
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
    widget.controller.add(u, dir: _dir.text.trim(), conns: int.tryParse(_conns.text) ?? 8);
    if (widget.controller.lastError == null) _url.clear();
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: cs.surfaceContainerLowest,
      body: AnimatedBuilder(
        animation: widget.controller,
        builder: (context, _) {
          final jobs = [...widget.controller.jobs]..sort((a, b) => a.id.compareTo(b.id));
          final active = jobs.where((j) => j.state == 'running').length;
          return CustomScrollView(
            slivers: [
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(24, 20, 24, 8),
                sliver: SliverToBoxAdapter(
                  child: Row(
                    children: [
                      Text('Cascade', style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700)),
                      const Spacer(),
                      if (jobs.isNotEmpty)
                        Text(active > 0 ? '$active active · ${jobs.length} in list' : '${jobs.length} in list',
                            style: Theme.of(context).textTheme.labelMedium?.copyWith(color: cs.onSurfaceVariant)),
                    ],
                  ),
                ),
              ),
              SliverPadding(
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
                sliver: SliverToBoxAdapter(child: _addCard(context)),
              ),
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(24, 16, 24, 4),
                sliver: SliverToBoxAdapter(
                  child: Row(
                    children: [
                      Text('Downloads', style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
                      const Spacer(),
                      TextButton.icon(onPressed: jobs.any((j) => !j.isTerminal) ? widget.controller.cancelAll : null,
                          icon: const Icon(Icons.close, size: 18), label: const Text('Cancel all')),
                      TextButton.icon(onPressed: jobs.any((j) => j.isTerminal) ? widget.controller.clearFinished : null,
                          icon: const Icon(Icons.cleaning_services_outlined, size: 18), label: const Text('Clear finished')),
                    ],
                  ),
                ),
              ),
              if (jobs.isEmpty)
                SliverFillRemaining(
                  hasScrollBody: false,
                  child: Center(
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      Icon(Icons.download_outlined, size: 40, color: cs.outline),
                      const SizedBox(height: 8),
                      Text('No downloads yet', style: Theme.of(context).textTheme.titleSmall),
                      Text('Downloads you start in the browser appear here.',
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
                    ]),
                  ),
                )
              else
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(24, 4, 24, 24),
                  sliver: SliverList.separated(
                    itemCount: jobs.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 10),
                    itemBuilder: (context, i) => DownloadCard(job: jobs[i], controller: widget.controller),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  Widget _addCard(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final err = widget.controller.lastError;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Expanded(
                child: TextField(
                  controller: _url,
                  onSubmitted: (_) => _add(),
                  decoration: const InputDecoration(hintText: 'Paste a link to download', prefixIcon: Icon(Icons.link)),
                ),
              ),
              const SizedBox(width: 10),
              FilledButton.icon(onPressed: _add, icon: const Icon(Icons.download), label: const Text('Download')),
            ]),
            const SizedBox(height: 10),
            Row(children: [
              Expanded(flex: 3, child: TextField(controller: _dir, decoration: const InputDecoration(labelText: 'Save to'))),
              const SizedBox(width: 10),
              SizedBox(width: 140, child: TextField(controller: _conns, decoration: const InputDecoration(labelText: 'Connections'))),
            ]),
            if (err != null) ...[
              const SizedBox(height: 8),
              Text(err, style: TextStyle(color: cs.error, fontSize: 12)),
            ],
          ],
        ),
      ),
    );
  }
}

class DownloadCard extends StatelessWidget {
  final JobStatus job;
  final CascadeController controller;
  const DownloadCard({super.key, required this.job, required this.controller});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final bps = controller.speedOf(job.id);
    final color = switch (job.state) {
      'done' => const Color(0xFF16A34A),
      'failed' => cs.error,
      'paused' || 'cancelled' => cs.outline,
      _ => cs.primary,
    };
    final meta = switch (job.state) {
      'running' => [
          job.host,
          '${humanBytes(bps.round())}/s',
          if (job.total > 0 && bps > 0) '${humanEta((job.total - job.bytes) / bps)} left',
          if (job.retries > 0) 'retry ${job.retries}',
        ].where((s) => s.isNotEmpty).join('  ·  '),
      'pending' => '${job.host}  ·  queued',
      'paused' => '${job.host}  ·  paused',
      'done' => '${job.host}  ·  completed',
      'failed' => '${job.host}  ·  failed${job.error != null ? ': ${job.error}' : ''}',
      _ => '${job.host}  ·  ${job.state}',
    };
    final right = job.total > 0
        ? '${humanBytes(job.bytes)} / ${humanBytes(job.total)}  ·  ${(job.fraction * 100).toStringAsFixed(0)}%'
        : humanBytes(job.bytes);

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 12, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(job.filename, maxLines: 1, overflow: TextOverflow.ellipsis,
                        style: tt.titleSmall?.copyWith(fontWeight: FontWeight.w600)),
                    const SizedBox(height: 2),
                    Text(meta, maxLines: 1, overflow: TextOverflow.ellipsis,
                        style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
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
                    duration: const Duration(milliseconds: 400),
                    curve: Curves.easeOutCubic,
                    builder: (_, v, _) => LinearProgressIndicator(
                      value: job.total > 0 ? v : null,
                      minHeight: 6,
                      color: color,
                      backgroundColor: cs.surfaceContainerHighest,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Text(right, style: tt.labelSmall?.copyWith(color: cs.onSurfaceVariant)),
            ]),
          ],
        ),
      ),
    );
  }

  List<Widget> _actions(BuildContext context) {
    IconButton btn(IconData icon, String tip, VoidCallback? onTap) =>
        IconButton(tooltip: tip, icon: Icon(icon, size: 20), onPressed: onTap, visualDensity: VisualDensity.compact);
    switch (job.state) {
      case 'running':
      case 'pending':
        return [btn(Icons.pause, 'Pause', () => controller.pause(job.id)), btn(Icons.close, 'Cancel', () => controller.cancel(job.id))];
      case 'paused':
        return [btn(Icons.play_arrow, 'Resume', () => controller.resume(job.id)), btn(Icons.close, 'Cancel', () => controller.cancel(job.id))];
      case 'done':
        return [
          btn(Icons.folder_open_outlined, Platform.isMacOS ? 'Show in Finder' : 'Show in folder', () => controller.reveal(job.out)),
          btn(Icons.delete_outline, 'Remove', () => controller.remove(job.id)),
        ];
      default:
        return [btn(Icons.delete_outline, 'Remove', () => controller.remove(job.id))];
    }
  }
}
