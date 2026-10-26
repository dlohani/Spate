import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app.dart' show SpateController, kMotion, kMotionCurve, pickWhen;
import 'model/job.dart';

/// Which rows are selected. Click selects one, Shift-click extends from the
/// anchor, Cmd/Ctrl-click toggles; arrows move the single selection.
class SelectionModel extends ChangeNotifier {
  final Set<String> ids = {};
  String? anchor;

  bool contains(String id) => ids.contains(id);
  int get count => ids.length;

  void click(String id, List<String> order, {bool shift = false, bool toggle = false}) {
    if (toggle) {
      if (!ids.remove(id)) ids.add(id);
      anchor = id;
    } else if (shift && anchor != null && order.contains(anchor)) {
      final a = order.indexOf(anchor!), b = order.indexOf(id);
      ids
        ..clear()
        ..addAll(order.sublist(a < b ? a : b, (a < b ? b : a) + 1));
    } else {
      ids
        ..clear()
        ..add(id);
      anchor = id;
    }
    notifyListeners();
  }

  /// Moves a single selection by [delta] rows within [order]; from nothing,
  /// selects the first or last row.
  void move(int delta, List<String> order) {
    if (order.isEmpty) return;
    var i = anchor == null ? -1 : order.indexOf(anchor!);
    i = i < 0 ? (delta > 0 ? 0 : order.length - 1) : (i + delta).clamp(0, order.length - 1);
    ids
      ..clear()
      ..add(order[i]);
    anchor = order[i];
    notifyListeners();
  }

  void selectAll(List<String> order) {
    ids
      ..clear()
      ..addAll(order);
    notifyListeners();
  }

  void clear() {
    if (ids.isEmpty) return;
    ids.clear();
    notifyListeners();
  }

  /// Drops ids that no longer exist.
  void retain(Iterable<String> existing) {
    final keep = existing.toSet();
    final before = ids.length;
    ids.retainWhere(keep.contains);
    if (ids.length != before) notifyListeners();
  }
}

/// The row menu, shared by the "..." button and the right-click menu. When
/// several rows are selected the actions apply to all of them.
List<PopupMenuEntry<String>> rowMenuEntries(JobStatus job, int selected) {
  final many = selected > 1;
  PopupMenuItem<String> item(String key, IconData icon, String label) => PopupMenuItem(
    value: key,
    height: 36,
    child: Row(children: [Icon(icon, size: 18), const SizedBox(width: 12), Text(label)]),
  );
  final active = job.state == 'running' || job.state == 'pending';
  return [
    if (!many) item('copy', Icons.link_rounded, 'Copy link'),
    if (job.isScheduled && !many) item('startnow', Icons.play_arrow_rounded, 'Start now'),
    if (job.state == 'running' || (job.state == 'pending' && !job.isScheduled))
      item('pause', Icons.pause_rounded, many ? 'Pause $selected' : 'Pause'),
    if (job.state == 'paused') item('resume', Icons.play_arrow_rounded, many ? 'Resume $selected' : 'Resume'),
    if (job.state == 'pending' || job.state == 'paused')
      item('schedule', Icons.schedule_rounded, job.isScheduled ? 'Reschedule' : 'Schedule'),
    if (job.state == 'done' && !many) item('open', Icons.open_in_new_rounded, 'Open file'),
    if (job.state == 'done' && !many)
      item('reveal', Icons.folder_open_rounded, Platform.isMacOS ? 'Show in Finder' : 'Show in folder'),
    if (job.state == 'failed' || job.state == 'cancelled') item('retry', Icons.refresh_rounded, 'Retry'),
    if (active) item('cancel', Icons.close_rounded, many ? 'Cancel $selected' : 'Cancel'),
    const PopupMenuDivider(height: 8),
    item(
      'remove',
      Icons.delete_outline_rounded,
      job.state == 'done' ? (many ? 'Remove $selected from list' : 'Remove from list') : (many ? 'Remove $selected and delete partial files' : 'Remove and delete partial file'),
    ),
  ];
}

/// Performs a menu action on [targets] (the selection, or the one row).
Future<void> runRowAction(BuildContext context, String key, SpateController c, List<JobStatus> targets) async {
  switch (key) {
    case 'copy':
      await Clipboard.setData(ClipboardData(text: targets.map((j) => j.url).join('\n')));
    case 'startnow':
      for (final j in targets) {
        c.startNow(j.id);
      }
    case 'pause':
      for (final j in targets) {
        c.pause(j.id);
      }
    case 'resume':
      for (final j in targets) {
        c.resume(j.id);
      }
    case 'schedule':
      final at = await pickWhen(context, targets.first.startAt);
      if (at != null) {
        for (final j in targets) {
          c.schedule(j.id, at);
        }
      }
    case 'open':
      c.openFile(targets.first.out);
    case 'reveal':
      c.reveal(targets.first.out);
    case 'retry':
      for (final j in targets) {
        c.retry(j);
      }
    case 'cancel':
      for (final j in targets) {
        c.cancel(j.id);
      }
    case 'remove':
      final running = targets.where((j) => j.state == 'running').length;
      if (running > 0 && context.mounted) {
        final ok = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: Text(running == 1 ? 'Stop and remove this download?' : 'Stop and remove $running downloads?'),
            content: const Text('The partial file is deleted. The link stays on the clipboard if you copy it first.'),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Keep')),
              FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Remove')),
            ],
          ),
        );
        if (ok != true) return;
      }
      for (final j in targets) {
        c.remove(j.id);
      }
  }
}

/// One download, 56 pt: a state glyph, the name over a 3 pt bar (only while
/// downloading) or a meta line, a fixed figures column, and the actions.
class DownloadRow extends StatefulWidget {
  final JobStatus job;
  final SpateController controller;
  final bool selected;
  final int? queuePosition; // 1-based, for queued rows
  final void Function(bool shift, bool toggle) onSelect;
  final void Function(Offset globalPosition) onContextMenu;
  const DownloadRow({
    super.key,
    required this.job,
    required this.controller,
    required this.selected,
    required this.onSelect,
    required this.onContextMenu,
    this.queuePosition,
  });

  @override
  State<DownloadRow> createState() => _DownloadRowState();
}

class _DownloadRowState extends State<DownloadRow> {
  bool _hover = false;
  bool _expanded = false; // failed rows: full error shown

  @override
  Widget build(BuildContext context) {
    final job = widget.job;
    final c = widget.controller;
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final bps = c.speedOf(job.id);
    final mono = const TextStyle(fontFeatures: [FontFeature.tabularFigures()]);

    final (IconData glyph, Color color) = switch (job.state) {
      'running' => (Icons.arrow_downward_rounded, cs.primary),
      'done' => (Icons.check_rounded, cs.onSurfaceVariant),
      'failed' => (Icons.error_outline_rounded, cs.error),
      'cancelled' => (Icons.block_rounded, cs.onSurfaceVariant),
      'paused' => (Icons.pause_rounded, cs.onSurfaceVariant),
      'pending' when job.isScheduled => (Icons.schedule_rounded, cs.tertiary),
      _ => (Icons.more_horiz_rounded, cs.onSurfaceVariant),
    };

    // Left meta line (under the name) and the two figures lines on the right.
    String meta = '';
    String right1 = '';
    String right2 = '';
    switch (job.state) {
      case 'running':
        right1 = [if (bps > 0) '${humanBytes(bps.round())}/s', if (job.total > 0 && bps > 0) humanEta((job.total - job.bytes) / bps)]
            .join(' · ');
        right2 = job.total > 0 ? '${humanProgress(job.bytes, job.total)}  ${(job.fraction * 100).round()}%' : humanBytes(job.bytes);
        if (job.retries > 0) meta = 'retry ${job.retries}';
      case 'pending':
        if (job.isScheduled) {
          right1 = 'Starts ${fmtWhen(job.startAt!)}';
        } else {
          right1 = widget.queuePosition == null ? 'Queued' : 'Queued · ${ordinal(widget.queuePosition!)}';
        }
      case 'paused':
        right1 = 'Paused';
        if (job.total > 0) right2 = humanProgress(job.bytes, job.total);
      case 'done':
        right1 = [if (job.total > 0) humanBytes(job.total), if (job.finishedAt != null) fmtAgo(job.finishedAt!)].join(' · ');
      case 'failed':
        right1 = 'Failed';
        meta = job.error ?? '';
      case 'cancelled':
        right1 = 'Cancelled';
        if (job.total > 0) right2 = humanProgress(job.bytes, job.total);
    }

    final primary = switch (job.state) {
      'running' => _btn(Icons.pause_rounded, 'Pause', () => c.pause(job.id)),
      'pending' when job.isScheduled => _btn(Icons.play_arrow_rounded, 'Start now', () => c.startNow(job.id)),
      'pending' => _btn(Icons.pause_rounded, 'Pause', () => c.pause(job.id)),
      'paused' => _btn(Icons.play_arrow_rounded, 'Resume', () => c.resume(job.id)),
      'done' => _btn(Icons.folder_open_rounded, Platform.isMacOS ? 'Show in Finder' : 'Show in folder', () => c.reveal(job.out)),
      _ => _btn(Icons.refresh_rounded, 'Retry', () => c.retry(job)),
    };
    final more = PopupMenuButton<String>(
      tooltip: 'More',
      icon: const Icon(Icons.more_horiz_rounded, size: 18),
      padding: EdgeInsets.zero,
      onSelected: (k) => runRowAction(context, k, c, c.targetsFor(job)),
      itemBuilder: (_) => rowMenuEntries(job, c.selection.contains(job.id) ? c.selection.count : 1),
    );

    final recentlyDone = job.state == 'done' && job.finishedAt != null && DateTime.now().difference(job.finishedAt!).inSeconds < 3;
    final rowBg = widget.selected
        ? cs.primary.withValues(alpha: 0.10)
        : _hover
            ? cs.onSurface.withValues(alpha: 0.035)
            : Colors.transparent;

    final content = Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
      child: Row(
        children: [
          SizedBox(width: 26, child: Icon(glyph, size: 18, color: color)),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Tooltip(
                  waitDuration: const Duration(milliseconds: 700),
                  message: job.host.isEmpty ? job.url : '${job.host}\n${job.url}',
                  child: Text(job.filename, maxLines: 1, overflow: TextOverflow.ellipsis, style: tt.titleSmall?.copyWith(fontWeight: FontWeight.w600)),
                ),
                const SizedBox(height: 5),
                if (job.state == 'running')
                  RepaintBoundary(
                    child: TweenAnimationBuilder<double>(
                      tween: Tween(end: job.fraction),
                      duration: kMotion,
                      curve: kMotionCurve,
                      builder: (_, v, _) => LinearProgressIndicator(
                        value: job.total > 0 ? v : null,
                        minHeight: 3,
                        borderRadius: BorderRadius.circular(2),
                        color: cs.primary,
                        backgroundColor: cs.surfaceContainerHighest,
                      ),
                    ),
                  )
                else
                  SizedBox(
                    height: 16,
                    child: Text(
                      meta.isEmpty ? job.host : meta,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: tt.bodySmall?.copyWith(color: job.state == 'failed' ? cs.error : cs.onSurfaceVariant),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          SizedBox(
            width: 190,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(right1, maxLines: 1, overflow: TextOverflow.ellipsis, style: tt.bodySmall?.merge(mono).copyWith(color: job.state == 'running' ? cs.onSurface : cs.onSurfaceVariant)),
                const SizedBox(height: 5),
                SizedBox(height: 16, child: Text(right2, maxLines: 1, style: tt.bodySmall?.merge(mono).copyWith(color: cs.onSurfaceVariant))),
              ],
            ),
          ),
          const SizedBox(width: 6),
          primary,
          more,
        ],
      ),
    );

    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (d) {
          final k = HardwareKeyboard.instance;
          widget.onSelect(k.isShiftPressed, k.isMetaPressed || k.isControlPressed);
          if (job.state == 'failed') setState(() => _expanded = !_expanded);
        },
        onSecondaryTapDown: (d) => widget.onContextMenu(d.globalPosition),
        child: TweenAnimationBuilder<double>(
          key: ValueKey('flash-${job.id}-${job.finishedAt?.millisecondsSinceEpoch ?? 0}'),
          tween: Tween(begin: recentlyDone ? 1.0 : 0.0, end: 0.0),
          duration: const Duration(milliseconds: 1400),
          curve: Curves.easeOut,
          builder: (_, v, child) => Container(
            color: Color.lerp(rowBg, cs.primary.withValues(alpha: 0.22), v),
            child: child,
          ),
          child: Column(
            children: [
              SizedBox(height: 56, child: content),
              if (_expanded && job.state == 'failed' && job.error != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(38, 0, 12, 10),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(child: SelectableText(job.error!, style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant))),
                      const SizedBox(width: 12),
                      TextButton.icon(onPressed: () => c.retry(job), icon: const Icon(Icons.refresh_rounded, size: 16), label: const Text('Retry')),
                      IconButton(
                        tooltip: 'Copy error',
                        icon: const Icon(Icons.copy_rounded, size: 16),
                        onPressed: () => Clipboard.setData(ClipboardData(text: job.error!)),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _btn(IconData icon, String tip, VoidCallback onTap) =>
      IconButton(tooltip: tip, icon: Icon(icon, size: 18), onPressed: onTap, visualDensity: VisualDensity.compact);
}

/// The collapsible header above finished, failed and cancelled rows.
class FinishedHeader extends StatelessWidget {
  final int count;
  final bool open;
  final VoidCallback onToggle;
  final VoidCallback? onClear;
  const FinishedHeader({super.key, required this.count, required this.open, required this.onToggle, this.onClear});

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onToggle,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 8, 6),
        child: Row(
          children: [
            Icon(open ? Icons.expand_more_rounded : Icons.chevron_right_rounded, size: 18, color: cs.onSurfaceVariant),
            const SizedBox(width: 8),
            Text('Finished', style: tt.labelLarge?.copyWith(color: cs.onSurfaceVariant, fontWeight: FontWeight.w600)),
            const SizedBox(width: 8),
            Text('$count', style: tt.labelMedium?.copyWith(color: cs.onSurfaceVariant)),
            const Spacer(),
            if (onClear != null)
              TextButton.icon(
                onPressed: onClear,
                icon: const Icon(Icons.playlist_remove_rounded, size: 16),
                label: const Text('Clear'),
                style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
              ),
          ],
        ),
      ),
    );
  }
}
