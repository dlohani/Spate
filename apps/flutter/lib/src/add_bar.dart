import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app.dart' show SpateController, kMotion, kMotionCurve, pickWhen;
import 'model/job.dart' show fmtWhen;

/// One field: paste one or more links, Return adds. Inside the field: a
/// folder button that opens the Save-to row, and a schedule button with a
/// menu of presets. The chosen folder and start time are shown as chips and
/// stay selected for the next links until cleared.
class AddBar extends StatefulWidget {
  final SpateController controller;
  const AddBar({super.key, required this.controller});

  @override
  State<AddBar> createState() => AddBarState();
}

class AddBarState extends State<AddBar> {
  final _url = TextEditingController();
  final _focus = FocusNode();
  String _dir = ''; // '' = folder rules
  DateTime? _startAt; // null = now
  bool _showFolder = false;

  @override
  void dispose() {
    _url.dispose();
    _focus.dispose();
    super.dispose();
  }

  /// Adds the text in the field (or [text] when given, e.g. a paste).
  void add([String? text]) {
    final src = text ?? _url.text;
    final urls = src.split(RegExp(r'\s+')).where((u) => u.isNotEmpty).toList();
    if (urls.isEmpty) return;
    final failed = widget.controller.addMany(urls, dir: _dir, startAt: _startAt);
    _url.text = failed.join(' '); // what was refused stays, to fix or drop
    setState(() {});
  }

  Future<void> _browse() async {
    final picked = await getDirectoryPath(initialDirectory: _dir.isEmpty ? null : _dir, confirmButtonText: 'Save here');
    if (picked == null || !mounted) return;
    setState(() => _dir = picked);
  }

  Future<void> _schedule(String choice) async {
    final now = DateTime.now();
    DateTime? at;
    switch (choice) {
      case 'tonight':
        at = DateTime(now.year, now.month, now.day, 22);
        if (!at.isAfter(now)) at = at.add(const Duration(days: 1));
      case 'tomorrow':
        at = DateTime(now.year, now.month, now.day + 1, 9);
      case 'window':
        at = widget.controller.nextDownloadWindowStart();
      case 'custom':
        at = await pickWhen(context, _startAt);
        if (at == null) return;
      case 'clear':
        at = null;
    }
    if (!mounted) return;
    setState(() => _startAt = at);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final err = widget.controller.lastError;
    final windowStart = widget.controller.nextDownloadWindowStart();
    final folderName = _dir.isEmpty ? '' : _dir.split(RegExp(r'[\\/]')).where((s) => s.isNotEmpty).last;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: SizedBox(
                height: 40,
                child: TextField(
                  controller: _url,
                  focusNode: _focus,
                  onSubmitted: (_) => add(),
                  inputFormatters: [FilteringTextInputFormatter.deny(RegExp(r'[\r\n]+'), replacementString: ' ')],
                  style: tt.bodyMedium,
                  decoration: InputDecoration(
                    hintText: 'Paste links to download',
                    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    prefixIcon: const Icon(Icons.link_rounded, size: 18),
                    prefixIconConstraints: const BoxConstraints(minWidth: 40),
                    suffixIcon: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          tooltip: _dir.isEmpty ? 'Choose a folder (otherwise the folder rules decide)' : 'Saving to $_dir',
                          icon: Icon(_dir.isEmpty ? Icons.folder_outlined : Icons.folder_rounded, size: 18, color: _dir.isEmpty ? null : cs.primary),
                          visualDensity: VisualDensity.compact,
                          onPressed: () {
                            if (_dir.isEmpty) {
                              _browse();
                            } else {
                              setState(() => _showFolder = !_showFolder);
                            }
                          },
                        ),
                        PopupMenuButton<String>(
                          tooltip: _startAt == null ? 'Schedule' : 'New links start ${fmtWhen(_startAt!)}',
                          icon: Icon(Icons.schedule_rounded, size: 18, color: _startAt == null ? null : cs.tertiary),
                          padding: EdgeInsets.zero,
                          onSelected: _schedule,
                          itemBuilder: (_) => [
                            const PopupMenuItem(value: 'tonight', height: 36, child: Text('Tonight at 22:00')),
                            const PopupMenuItem(value: 'tomorrow', height: 36, child: Text('Tomorrow at 09:00')),
                            if (windowStart != null)
                              PopupMenuItem(value: 'window', height: 36, child: Text('When the download window opens (${fmtWhen(windowStart)})')),
                            const PopupMenuItem(value: 'custom', height: 36, child: Text('Pick a date and time…')),
                            if (_startAt != null) const PopupMenuDivider(height: 8),
                            if (_startAt != null) const PopupMenuItem(value: 'clear', height: 36, child: Text('Start immediately')),
                          ],
                        ),
                        const SizedBox(width: 2),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            SizedBox(
              height: 40,
              child: FilledButton.icon(
                onPressed: add,
                icon: const Icon(Icons.download_rounded, size: 18),
                label: const Text('Download'),
                style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 14)),
              ),
            ),
          ],
        ),
        AnimatedSize(
          duration: kMotion,
          curve: kMotionCurve,
          alignment: Alignment.topLeft,
          child: (_dir.isNotEmpty || _startAt != null || err != null)
              ? Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 6,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      if (_dir.isNotEmpty)
                        InputChip(
                          avatar: const Icon(Icons.folder_rounded, size: 16),
                          label: Text(_showFolder ? _dir : 'Save to $folderName'),
                          tooltip: _dir,
                          onPressed: _browse,
                          onDeleted: () => setState(() {
                            _dir = '';
                            _showFolder = false;
                          }),
                          deleteButtonTooltipMessage: 'Back to the folder rules',
                          visualDensity: VisualDensity.compact,
                        ),
                      if (_startAt != null)
                        InputChip(
                          avatar: Icon(Icons.schedule_rounded, size: 16, color: cs.tertiary),
                          label: Text('New links start ${fmtWhen(_startAt!)}'),
                          onPressed: () => _schedule('custom'),
                          onDeleted: () => setState(() => _startAt = null),
                          deleteButtonTooltipMessage: 'Start immediately instead',
                          visualDensity: VisualDensity.compact,
                        ),
                      if (err != null) Text(err, style: tt.bodySmall?.copyWith(color: cs.error)),
                    ],
                  ),
                )
              : const SizedBox(width: double.infinity),
        ),
      ],
    );
  }
}
