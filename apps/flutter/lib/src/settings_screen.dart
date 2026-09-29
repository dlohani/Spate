import 'package:flutter/material.dart';

import 'app.dart' show kMotion, kMotionCurve;
import 'ffi/cascade_ffi.dart';
import 'model/job.dart' show humanBytes;
import 'model/settings.dart';
import 'model/ui_prefs.dart';

const _dayNames = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];

/// Settings: where downloads go (base folder, categories, site rules), speed
/// limits with time windows, the download window, recurring downloads, and
/// concurrency. Saved as one document through the C ABI.
class SettingsScreen extends StatefulWidget {
  final Cascade core;
  final UiPrefs prefs;
  const SettingsScreen({super.key, required this.core, required this.prefs});
  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late AppSettings s;
  late final TextEditingController _dir;
  late final TextEditingController _limit;
  late final TextEditingController _conc;
  bool _dirty = false;
  // Sections that are set once and list many rows start collapsed.
  final Set<String> _collapsed = {'Organize by category', 'Per-site folders', 'Recurring downloads'};

  @override
  void initState() {
    super.initState();
    s = AppSettings.fromJson(widget.core.settings());
    _dir = TextEditingController(text: s.downloadDir);
    _limit = TextEditingController(text: (s.limitBytesPerSec / 1024).round().toString());
    _conc = TextEditingController(text: s.maxConcurrent.toString());
  }

  void _touch() => setState(() => _dirty = true);

  Future<void> _save() async {
    s.downloadDir = _dir.text.trim();
    s.limitBytesPerSec = (int.tryParse(_limit.text) ?? 0) * 1024;
    s.maxConcurrent = int.tryParse(_conc.text) ?? s.maxConcurrent;
    final ok = widget.core.applySettings(s.toJson());
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(ok ? 'Settings saved' : 'Could not save: check times (HH:MM) and recurrence values'),
    ));
    if (ok) setState(() => _dirty = false);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Row(mainAxisSize: MainAxisSize.min, children: [
          const Text('Settings'),
          const SizedBox(width: 10),
          Text('Cascade ${widget.core.version}', style: Theme.of(context).textTheme.labelMedium?.copyWith(color: cs.onSurfaceVariant)),
        ]),
        actions: [
          FilledButton.icon(onPressed: _dirty ? _save : null, icon: const Icon(Icons.check), label: const Text('Save')),
          const SizedBox(width: 12),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 820),
          child: ListView(
            padding: const EdgeInsets.all(20),
            children: [
              _section(context, 'Appearance', Icons.palette_outlined, [
                // Applies immediately and is remembered; nothing to save.
                AnimatedBuilder(
                  animation: widget.prefs,
                  builder: (context, _) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    SegmentedButton<ThemeMode>(
                      segments: const [
                        ButtonSegment(value: ThemeMode.system, icon: Icon(Icons.brightness_auto_outlined), label: Text('System')),
                        ButtonSegment(value: ThemeMode.light, icon: Icon(Icons.light_mode_outlined), label: Text('Light')),
                        ButtonSegment(value: ThemeMode.dark, icon: Icon(Icons.dark_mode_outlined), label: Text('Dark')),
                      ],
                      selected: {widget.prefs.mode},
                      onSelectionChanged: (s) => widget.prefs.setMode(s.first),
                    ),
                    const SizedBox(height: 12),
                    Text('Accent', style: Theme.of(context).textTheme.labelLarge),
                    const SizedBox(height: 6),
                    Wrap(spacing: 8, runSpacing: 8, children: [
                      for (final e in accentColors.entries)
                        Tooltip(
                          message: e.key[0].toUpperCase() + e.key.substring(1),
                          child: InkWell(
                            borderRadius: BorderRadius.circular(999),
                            onTap: () => widget.prefs.setAccent(e.key),
                            child: Container(
                              width: 30, height: 30,
                              decoration: BoxDecoration(
                                color: e.value,
                                shape: BoxShape.circle,
                                border: Border.all(color: widget.prefs.accent == e.key ? cs.onSurface : Colors.transparent, width: 2.5),
                              ),
                              child: widget.prefs.accent == e.key ? const Icon(Icons.check, size: 16, color: Colors.white) : null,
                            ),
                          ),
                        ),
                    ]),
                  ]),
                ),
              ]),
              _section(context, 'Downloads folder', Icons.folder_outlined, [
                TextField(controller: _dir, onChanged: (_) => _touch(), decoration: const InputDecoration(labelText: 'Base folder')),
                const SizedBox(height: 8),
                TextField(controller: _conc, onChanged: (_) => _touch(), decoration: const InputDecoration(labelText: 'Downloads at the same time'), keyboardType: TextInputType.number),
              ]),
              _section(context, 'Organize by category', Icons.category_outlined, collapsible: true,
                  summary: '${s.organizeByCategory ? 'On' : 'Off'}  ·  ${s.categories.length} categories', [
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Put downloads into category folders'),
                  subtitle: const Text('Video, Audio, Documents, Archives… by file extension, under the base folder'),
                  value: s.organizeByCategory,
                  onChanged: (v) { s.organizeByCategory = v; _touch(); },
                ),
                for (final c in s.categories)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(c.name),
                    subtitle: Text('${c.extensions.join(', ')}  →  ${c.dir}', maxLines: 1, overflow: TextOverflow.ellipsis),
                    trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                      IconButton(icon: const Icon(Icons.edit_outlined), onPressed: () => _editCategory(c)),
                      IconButton(icon: const Icon(Icons.delete_outline), onPressed: () { s.categories.remove(c); _touch(); }),
                    ]),
                  ),
                TextButton.icon(onPressed: () => _editCategory(null), icon: const Icon(Icons.add), label: const Text('Add category')),
              ]),
              _section(context, 'Per-site folders', Icons.language, collapsible: true,
                  summary: s.siteRules.isEmpty ? 'None' : '${s.siteRules.length} ${s.siteRules.length == 1 ? 'rule' : 'rules'}', [
                Text('Downloads from a site (and its subdomains) go to a folder of your choice. Site rules win over categories.',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
                for (final r in s.siteRules)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(r.host),
                    subtitle: Text(r.dir),
                    trailing: IconButton(icon: const Icon(Icons.delete_outline), onPressed: () { s.siteRules.remove(r); _touch(); }),
                  ),
                TextButton.icon(onPressed: _addSiteRule, icon: const Icon(Icons.add), label: const Text('Add site rule')),
              ]),
              _section(context, 'Speed limit', Icons.speed, [
                TextField(controller: _limit, onChanged: (_) => _touch(), keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: 'Default limit (KB/s, 0 = unlimited)')),
                const SizedBox(height: 6),
                Text('Time windows override the default, e.g. slower during work hours and unlimited at night.',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
                for (final w in s.limitWindows)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text('${w.window.from} – ${w.window.to}  ·  ${w.bytesPerSec == 0 ? 'unlimited' : '${humanBytes(w.bytesPerSec)}/s'}'),
                    subtitle: Text(w.window.days.isEmpty ? 'Every day' : w.window.days.map((d) => _dayNames[d]).join(', ')),
                    trailing: IconButton(icon: const Icon(Icons.delete_outline), onPressed: () { s.limitWindows.remove(w); _touch(); }),
                  ),
                TextButton.icon(onPressed: _addLimitWindow, icon: const Icon(Icons.add), label: const Text('Add time window')),
              ]),
              _section(context, 'Download window', Icons.schedule, [
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Only start queued downloads during a time window'),
                  subtitle: Text('${s.queueWindow.from} – ${s.queueWindow.to}  ·  ${s.queueWindow.days.isEmpty ? 'every day' : s.queueWindow.days.map((d) => _dayNames[d]).join(', ')}. Running downloads finish normally.'),
                  value: s.queueWindowEnabled,
                  onChanged: (v) { s.queueWindowEnabled = v; _touch(); },
                ),
                TextButton.icon(onPressed: () => _editWindow(s.queueWindow, title: 'Download window'), icon: const Icon(Icons.edit_outlined), label: const Text('Edit window')),
              ]),
              _section(context, 'Recurring downloads', Icons.repeat, collapsible: true,
                  summary: s.recurring.isEmpty ? 'None' : '${s.recurring.where((r) => r.enabled).length} of ${s.recurring.length} active', [
                Text('Re-download a link on a schedule (a daily report, a nightly build…).',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
                for (final r in s.recurring)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(r.url, maxLines: 1, overflow: TextOverflow.ellipsis),
                    subtitle: Text('${r.every}  ·  next ${_fmt(r.nextAt)}${r.dir.isEmpty ? '' : '  ·  ${r.dir}'}'),
                    trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                      Switch(value: r.enabled, onChanged: (v) { r.enabled = v; _touch(); }),
                      IconButton(icon: const Icon(Icons.delete_outline), onPressed: () { s.recurring.remove(r); _touch(); }),
                    ]),
                  ),
                TextButton.icon(onPressed: _addRecurring, icon: const Icon(Icons.add), label: const Text('Add recurring download')),
              ]),
            ],
          ),
        ),
      ),
    );
  }

  /// A settings card. Collapsible sections show [summary] in the header and
  /// toggle on the header or the arrow; the rest are always open.
  Widget _section(BuildContext context, String title, IconData icon, List<Widget> children,
      {bool collapsible = false, String? summary}) {
    final tt = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    final open = !collapsible || !_collapsed.contains(title);
    final header = Row(children: [
      Icon(icon, size: 18),
      const SizedBox(width: 8),
      Text(title, style: tt.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
      if (summary != null && !open) ...[
        const SizedBox(width: 10),
        Expanded(child: Text(summary, maxLines: 1, overflow: TextOverflow.ellipsis, style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant))),
      ] else
        const Spacer(),
      if (collapsible) Icon(open ? Icons.expand_less_rounded : Icons.expand_more_rounded, size: 20, color: cs.onSurfaceVariant),
    ]);
    return Card(
      margin: const EdgeInsets.only(bottom: 14),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (collapsible)
            InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: () => setState(() => open ? _collapsed.add(title) : _collapsed.remove(title)),
              child: Padding(padding: const EdgeInsets.symmetric(vertical: 2), child: header),
            )
          else
            header,
          AnimatedSize(
            duration: kMotion,
            curve: kMotionCurve,
            alignment: Alignment.topCenter,
            child: open
                ? Column(crossAxisAlignment: CrossAxisAlignment.start, children: [const SizedBox(height: 10), ...children])
                : const SizedBox(width: double.infinity),
          ),
        ]),
      ),
    );
  }

  String _fmt(DateTime t) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${t.year}-${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}';
  }

  Future<void> _editCategory(Category? c) async {
    final name = TextEditingController(text: c?.name ?? '');
    final ext = TextEditingController(text: c?.extensions.join(', ') ?? '');
    final dir = TextEditingController(text: c?.dir ?? '');
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(c == null ? 'New category' : 'Edit category'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(controller: name, decoration: const InputDecoration(labelText: 'Name')),
          TextField(controller: ext, decoration: const InputDecoration(labelText: 'Extensions (comma separated)')),
          TextField(controller: dir, decoration: const InputDecoration(labelText: 'Folder (relative to base, or absolute)')),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('OK')),
        ],
      ),
    );
    if (ok != true) return;
    final exts = ext.text.split(',').map((e) => e.trim().toLowerCase().replaceFirst(RegExp(r'^\.'), '')).where((e) => e.isNotEmpty).toList();
    if (c == null) {
      s.categories.add(Category(name: name.text.trim(), extensions: exts, dir: dir.text.trim()));
    } else {
      c.name = name.text.trim(); c.extensions = exts; c.dir = dir.text.trim();
    }
    _touch();
  }

  Future<void> _addSiteRule() async {
    final host = TextEditingController();
    final dir = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Site rule'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(controller: host, decoration: const InputDecoration(labelText: 'Host (e.g. releases.ubuntu.com)')),
          TextField(controller: dir, decoration: const InputDecoration(labelText: 'Folder (relative to base, or absolute)')),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Add')),
        ],
      ),
    );
    if (ok == true && host.text.trim().isNotEmpty) {
      s.siteRules.add(SiteRule(host: host.text.trim().toLowerCase(), dir: dir.text.trim()));
      _touch();
    }
  }

  Future<void> _editWindow(TimeWindow w, {required String title}) async {
    final from = TextEditingController(text: w.from);
    final to = TextEditingController(text: w.to);
    final days = {...w.days};
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setInner) => AlertDialog(
          title: Text(title),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            Row(children: [
              Expanded(child: TextField(controller: from, decoration: const InputDecoration(labelText: 'From (HH:MM)'))),
              const SizedBox(width: 10),
              Expanded(child: TextField(controller: to, decoration: const InputDecoration(labelText: 'To (HH:MM)'))),
            ]),
            const SizedBox(height: 10),
            Wrap(spacing: 6, children: [
              for (var d = 0; d < 7; d++)
                FilterChip(label: Text(_dayNames[d]), selected: days.contains(d), onSelected: (v) => setInner(() => v ? days.add(d) : days.remove(d))),
            ]),
            const SizedBox(height: 4),
            Text('No days selected = every day', style: Theme.of(ctx).textTheme.bodySmall),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('OK')),
          ],
        ),
      ),
    );
    if (ok == true) {
      w.from = from.text.trim(); w.to = to.text.trim(); w.days = days.toList()..sort();
      _touch();
    }
  }

  Future<void> _addLimitWindow() async {
    final w = LimitWindow(window: TimeWindow(from: '09:00', to: '18:00'));
    final kb = TextEditingController(text: '500');
    await _editWindow(w.window, title: 'Speed limit window');
    if (!mounted) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Limit inside this window'),
        content: TextField(controller: kb, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'KB/s (0 = unlimited)')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Add')),
        ],
      ),
    );
    if (ok == true) {
      w.bytesPerSec = (int.tryParse(kb.text) ?? 0) * 1024;
      s.limitWindows.add(w);
      _touch();
    }
  }

  Future<void> _addRecurring() async {
    final url = TextEditingController();
    final dir = TextEditingController();
    var every = 'daily';
    var next = DateTime.now().add(const Duration(days: 1));
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setInner) => AlertDialog(
          title: const Text('Recurring download'),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(controller: url, decoration: const InputDecoration(labelText: 'Link')),
            TextField(controller: dir, decoration: const InputDecoration(labelText: 'Folder (optional; rules apply if empty)')),
            const SizedBox(height: 8),
            DropdownButtonFormField<String>(
              initialValue: every,
              decoration: const InputDecoration(labelText: 'Repeat'),
              items: const [
                DropdownMenuItem(value: 'hourly', child: Text('Every hour')),
                DropdownMenuItem(value: 'daily', child: Text('Every day')),
                DropdownMenuItem(value: 'weekly', child: Text('Every week')),
              ],
              onChanged: (v) => setInner(() => every = v ?? 'daily'),
            ),
            const SizedBox(height: 8),
            Row(children: [
              Expanded(child: Text('First run: ${_fmt(next)}')),
              TextButton(
                onPressed: () async {
                  final d = await showDatePicker(context: ctx, initialDate: next, firstDate: DateTime.now(), lastDate: DateTime.now().add(const Duration(days: 365)));
                  if (d == null || !ctx.mounted) return;
                  final t = await showTimePicker(context: ctx, initialTime: TimeOfDay.fromDateTime(next));
                  if (t == null) return;
                  setInner(() => next = DateTime(d.year, d.month, d.day, t.hour, t.minute));
                },
                child: const Text('Change'),
              ),
            ]),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Add')),
          ],
        ),
      ),
    );
    if (ok == true && url.text.trim().isNotEmpty) {
      s.recurring.add(Recurring(url: url.text.trim(), dir: dir.text.trim(), every: every, nextAt: next));
      _touch();
    }
  }
}
