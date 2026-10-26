import 'dart:async';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';

import 'app.dart' show kMotion, kMotionCurve;
import 'ffi/spate_ffi.dart';
import 'model/job.dart' show humanBytes;
import 'model/settings.dart';
import 'model/ui_prefs.dart';

const _dayNames = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];
const _supportUrl = 'https://buymeacoffee.com/dlohani';

/// Settings. Every change applies as soon as it is made (debounced for typed
/// fields); the core validates and a refused change reverts with the reason.
class SettingsScreen extends StatefulWidget {
  final Spate core;
  final UiPrefs prefs;
  const SettingsScreen({super.key, required this.core, required this.prefs});
  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late AppSettings s;
  late final TextEditingController _dir;
  late final TextEditingController _conc;
  late final TextEditingController _conns;
  late final TextEditingController _custom; // custom limit value in the chosen unit
  int _unit = 1000 * 1000; // bytes per unit: kB/s or MB/s
  Timer? _debounce;
  String? _error;
  final Set<String> _collapsed = {'Organize by category', 'Per-site folders', 'Recurring downloads', 'Advanced'};

  static const _presets = <int>[0, 256 * 1000, 1000 * 1000, 5 * 1000 * 1000, 20 * 1000 * 1000];

  @override
  void initState() {
    super.initState();
    s = AppSettings.fromJson(widget.core.settings());
    _dir = TextEditingController(text: s.downloadDir);
    _conc = TextEditingController(text: s.maxConcurrent.toString());
    _conns = TextEditingController(text: s.defaultConns.toString());
    _unit = s.limitBytesPerSec > 0 && s.limitBytesPerSec < 1000 * 1000 ? 1000 : 1000 * 1000;
    _custom = TextEditingController(text: _fmtUnit(s.limitBytesPerSec));
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _dir.dispose();
    _conc.dispose();
    _conns.dispose();
    _custom.dispose();
    super.dispose();
  }

  String _fmtUnit(int bps) {
    if (bps <= 0) return '';
    final v = bps / _unit;
    return v == v.roundToDouble() ? v.round().toString() : v.toStringAsFixed(1);
  }

  /// Applies now (controls) or after a short pause (typed fields).
  void _apply({bool now = false}) {
    _debounce?.cancel();
    if (now) {
      _commit();
    } else {
      _debounce = Timer(const Duration(milliseconds: 450), _commit);
    }
    setState(() {});
  }

  void _commit() {
    s.downloadDir = _dir.text.trim();
    s.maxConcurrent = int.tryParse(_conc.text) ?? s.maxConcurrent;
    s.defaultConns = int.tryParse(_conns.text) ?? s.defaultConns;
    final ok = widget.core.applySettings(s.toJson());
    if (!mounted) return;
    if (ok) {
      _error = null;
    } else {
      // Refused: keep what the core has and say why.
      _error = widget.core.lastError ?? 'The core refused these settings.';
      s = AppSettings.fromJson(widget.core.settings());
      _dir.text = s.downloadDir;
      _conc.text = s.maxConcurrent.toString();
      _conns.text = s.defaultConns.toString();
      _custom.text = _fmtUnit(s.limitBytesPerSec);
    }
    setState(() {});
  }

  Future<String?> _pickFolder(String current) async =>
      getDirectoryPath(initialDirectory: current.isEmpty || !Directory(current).existsSync() ? null : current);

  void _open(String url) {
    if (Platform.isMacOS) {
      Process.start('open', [url]);
    } else if (Platform.isWindows) {
      Process.start('cmd', ['/c', 'start', '', url]);
    } else {
      Process.start('xdg-open', [url]);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final mac = Platform.isMacOS;
    return Scaffold(
      appBar: PreferredSize(
        preferredSize: Size.fromHeight(mac ? 52 : kToolbarHeight),
        child: DragToMoveArea(
          child: AppBar(
            toolbarHeight: mac ? 52 : null,
            leadingWidth: mac ? 96 + 48 : null,
            leading: mac ? const Padding(padding: EdgeInsets.only(left: 96), child: BackButton()) : null,
            title: const Text('Settings'),
            actions: [
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(right: 12),
                  child: Row(children: [Icon(Icons.error_outline_rounded, size: 16, color: cs.error), const SizedBox(width: 6), Text('Not saved: $_error', style: tt.bodySmall?.copyWith(color: cs.error))]),
                )
              else
                Padding(
                  padding: const EdgeInsets.only(right: 16),
                  child: Text('Changes apply immediately', style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
                ),
            ],
          ),
        ),
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 820),
          child: ListView(
            padding: const EdgeInsets.all(20),
            children: [
              _section(context, 'Appearance', Icons.palette_outlined, [_appearance(context)]),
              _section(context, 'Behaviour', Icons.tune_outlined, [_behaviour(context)]),
              _section(context, 'Downloads folder', Icons.folder_outlined, [
                _folderField(_dir, label: 'Base folder', onChanged: () => _apply()),
                const SizedBox(height: 8),
                TextField(
                  controller: _conc,
                  onChanged: (_) => _apply(),
                  decoration: const InputDecoration(labelText: 'Downloads at the same time', helperText: 'Others wait in the queue'),
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                ),
              ]),
              _section(context, 'Organize by category', Icons.category_outlined, collapsible: true,
                  summary: '${s.organizeByCategory ? 'On' : 'Off'}  ·  ${s.categories.length} categories', [
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Put downloads into category folders'),
                  subtitle: const Text('Video, Audio, Documents, Archives… by file extension, under the base folder'),
                  value: s.organizeByCategory,
                  onChanged: (v) {
                    s.organizeByCategory = v;
                    _apply(now: true);
                  },
                ),
                for (final c in s.categories)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(c.name),
                    subtitle: Text('${c.extensions.join(', ')}  →  ${c.dir}', maxLines: 1, overflow: TextOverflow.ellipsis),
                    trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                      IconButton(icon: const Icon(Icons.edit_outlined), onPressed: () => _editCategory(c)),
                      IconButton(
                        icon: const Icon(Icons.delete_outline),
                        onPressed: () {
                          s.categories.remove(c);
                          _apply(now: true);
                        },
                      ),
                    ]),
                  ),
                TextButton.icon(onPressed: () => _editCategory(null), icon: const Icon(Icons.add), label: const Text('Add category')),
              ]),
              _section(context, 'Per-site folders', Icons.language, collapsible: true,
                  summary: s.siteRules.isEmpty ? 'None' : '${s.siteRules.length} ${s.siteRules.length == 1 ? 'rule' : 'rules'}', [
                Text('Downloads from a site (and its subdomains) go to a folder of your choice. Site rules win over categories.', style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
                for (final r in s.siteRules)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(r.host),
                    subtitle: Text(r.dir),
                    trailing: IconButton(
                      icon: const Icon(Icons.delete_outline),
                      onPressed: () {
                        s.siteRules.remove(r);
                        _apply(now: true);
                      },
                    ),
                  ),
                TextButton.icon(onPressed: _addSiteRule, icon: const Icon(Icons.add), label: const Text('Add site rule')),
              ]),
              _section(context, 'Speed limit', Icons.speed, [_speedLimit(context)]),
              _section(context, 'Download window', Icons.schedule, [
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Only start queued downloads during a time window'),
                  subtitle: Text(
                    s.queueWindow.from.isEmpty || s.queueWindow.to.isEmpty
                        ? 'No window set yet: use Edit window. Running downloads always finish normally.'
                        : '${s.queueWindow.from} – ${s.queueWindow.to}  ·  ${s.queueWindow.days.isEmpty ? 'every day' : s.queueWindow.days.map((d) => _dayNames[d]).join(', ')}. Running downloads finish normally.',
                  ),
                  value: s.queueWindowEnabled,
                  onChanged: (v) {
                    s.queueWindowEnabled = v;
                    _apply(now: true);
                  },
                ),
                TextButton.icon(onPressed: () => _editWindow(s.queueWindow, title: 'Download window'), icon: const Icon(Icons.edit_outlined), label: const Text('Edit window')),
              ]),
              _section(context, 'Recurring downloads', Icons.repeat, collapsible: true,
                  summary: s.recurring.isEmpty ? 'None' : '${s.recurring.where((r) => r.enabled).length} of ${s.recurring.length} active', [
                Text('Re-download a link on a schedule (a daily report, a nightly build…).', style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
                for (final r in s.recurring)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(r.url, maxLines: 1, overflow: TextOverflow.ellipsis),
                    subtitle: Text('${r.every}  ·  next ${_fmt(r.nextAt)}${r.dir.isEmpty ? '' : '  ·  ${r.dir}'}'),
                    trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                      Switch(
                        value: r.enabled,
                        onChanged: (v) {
                          r.enabled = v;
                          _apply(now: true);
                        },
                      ),
                      IconButton(
                        icon: const Icon(Icons.delete_outline),
                        onPressed: () {
                          s.recurring.remove(r);
                          _apply(now: true);
                        },
                      ),
                    ]),
                  ),
                TextButton.icon(onPressed: _addRecurring, icon: const Icon(Icons.add), label: const Text('Add recurring download')),
              ]),
              _section(context, 'Advanced', Icons.settings_suggest_outlined, collapsible: true, summary: '${s.defaultConns} connections per download', [
                TextField(
                  controller: _conns,
                  onChanged: (_) => _apply(),
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  decoration: const InputDecoration(
                    labelText: 'Connections per download',
                    helperText: 'Parallel connections for each file (1 to 32). Spate drops to what the server allows by itself.',
                  ),
                ),
              ]),
              _section(context, 'About', Icons.info_outline, [_about(context)]),
            ],
          ),
        ),
      ),
    );
  }

  Widget _appearance(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return AnimatedBuilder(
      animation: widget.prefs,
      builder: (context, _) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SegmentedButton<ThemeMode>(
            segments: const [
              ButtonSegment(value: ThemeMode.system, icon: Icon(Icons.brightness_auto_outlined), label: Text('System')),
              ButtonSegment(value: ThemeMode.light, icon: Icon(Icons.light_mode_outlined), label: Text('Light')),
              ButtonSegment(value: ThemeMode.dark, icon: Icon(Icons.dark_mode_outlined), label: Text('Dark')),
            ],
            selected: {widget.prefs.mode},
            onSelectionChanged: (sel) => widget.prefs.setMode(sel.first),
          ),
          const SizedBox(height: 12),
          Text('Accent', style: Theme.of(context).textTheme.labelLarge),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final e in accentColors.entries)
                Tooltip(
                  message: e.key[0].toUpperCase() + e.key.substring(1),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(999),
                    onTap: () => widget.prefs.setAccent(e.key),
                    child: Container(
                      width: 30,
                      height: 30,
                      decoration: BoxDecoration(
                        color: e.value,
                        shape: BoxShape.circle,
                        border: Border.all(color: widget.prefs.accent == e.key ? cs.onSurface : Colors.transparent, width: 2.5),
                      ),
                      child: widget.prefs.accent == e.key ? const Icon(Icons.check, size: 16, color: Colors.white) : null,
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _behaviour(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    return AnimatedBuilder(
      animation: widget.prefs,
      builder: (context, _) {
        final mac = Platform.isMacOS;
        final bar = mac ? 'menu bar' : 'tray';
        final dock = mac ? 'Dock' : 'taskbar';
        final presence = widget.prefs.presence;
        final closeNote = switch (presence) {
          'dock' => mac
              ? 'Closing the window keeps Spate running; the Dock icon brings it back. Quit with Cmd-Q.'
              : 'Closing the window quits Spate (there is no tray icon to reopen it from).',
          'tray' => 'No $dock entry; the window opens from the $bar icon. Closing hides it; quit from the $bar icon.',
          _ => 'Closing the window hides it; quit from the $bar icon.',
        };
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(padding: const EdgeInsets.only(top: 4, bottom: 6), child: Text('Show Spate in', style: tt.titleSmall)),
            SegmentedButton<String>(
              segments: [
                ButtonSegment(value: 'both', label: Text(mac ? 'Menu bar and Dock' : 'Tray and taskbar')),
                ButtonSegment(value: 'tray', label: Text(mac ? 'Menu bar only' : 'Tray only')),
                ButtonSegment(value: 'dock', label: Text(mac ? 'Dock only' : 'Taskbar only')),
              ],
              selected: {presence},
              onSelectionChanged: (sel) => widget.prefs.setPresence(sel.first),
              showSelectedIcon: false,
            ),
            Padding(padding: const EdgeInsets.only(top: 6, bottom: 4), child: Text(closeNote, style: tt.bodySmall)),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text('Minimise to the $bar'),
              subtitle: Text(widget.prefs.hasTray ? 'Minimising hides the window into the $bar instead of the $dock.' : 'Needs a $bar icon: minimising goes to the $dock.'),
              value: widget.prefs.minimizeToTray && widget.prefs.hasTray,
              onChanged: widget.prefs.hasTray ? widget.prefs.setMinimizeToTray : null,
            ),
            if (mac) ...[
              Padding(padding: const EdgeInsets.only(top: 10, bottom: 6), child: Text('Menu bar icon', style: tt.titleSmall)),
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment(value: 'mono', label: Text('Monochrome, like the system items')),
                  ButtonSegment(value: 'color', label: Text('Colour')),
                ],
                selected: {widget.prefs.trayIconStyle},
                onSelectionChanged: widget.prefs.hasTray ? (sel) => widget.prefs.setTrayIconStyle(sel.first) : null,
                showSelectedIcon: false,
              ),
              const SizedBox(height: 4),
            ],
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text('Pulse the $bar icon while downloading'),
              subtitle: Text('The icon fades in and out once a second while anything is downloading; solid when idle.'),
              value: widget.prefs.pulseTray && widget.prefs.hasTray,
              onChanged: widget.prefs.hasTray ? widget.prefs.setPulseTray : null,
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Notify when a download finishes'),
              subtitle: const Text('A system notification, with Open and Show in folder, when the window is hidden or in the background.'),
              value: widget.prefs.notify,
              onChanged: widget.prefs.setNotify,
            ),
          ],
        );
      },
    );
  }

  Widget _speedLimit(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final isPreset = _presets.contains(s.limitBytesPerSec);
    final preview = s.limitBytesPerSec <= 0
        ? 'No limit: downloads use what the connection gives.'
        : 'A 1 GB file takes about ${_eta(1000 * 1000 * 1000, s.limitBytesPerSec)} at this limit.';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: DropdownButtonFormField<int>(
                key: ValueKey(isPreset ? s.limitBytesPerSec : -1),
                initialValue: isPreset ? s.limitBytesPerSec : -1,
                decoration: const InputDecoration(labelText: 'Default limit'),
                items: [
                  for (final p in _presets) DropdownMenuItem(value: p, child: Text(p == 0 ? 'Unlimited' : '${humanBytes(p)}/s')),
                  const DropdownMenuItem(value: -1, child: Text('Custom…')),
                ],
                onChanged: (v) {
                  if (v == null) return;
                  if (v >= 0) {
                    s.limitBytesPerSec = v;
                    _custom.text = _fmtUnit(v);
                    _apply(now: true);
                  } else {
                    setState(() {
                      if (s.limitBytesPerSec == 0) {
                        s.limitBytesPerSec = 2 * 1000 * 1000;
                        _custom.text = _fmtUnit(s.limitBytesPerSec);
                        _apply(now: true);
                      }
                    });
                  }
                },
              ),
            ),
            if (!isPreset) ...[
              const SizedBox(width: 10),
              SizedBox(
                width: 120,
                child: TextField(
                  controller: _custom,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(labelText: 'Limit'),
                  onChanged: (v) {
                    final x = double.tryParse(v);
                    if (x == null || x <= 0) return;
                    s.limitBytesPerSec = (x * _unit).round();
                    _apply();
                  },
                ),
              ),
              const SizedBox(width: 6),
              SegmentedButton<int>(
                segments: const [ButtonSegment(value: 1000, label: Text('kB/s')), ButtonSegment(value: 1000 * 1000, label: Text('MB/s'))],
                selected: {_unit},
                showSelectedIcon: false,
                onSelectionChanged: (sel) => setState(() {
                  _unit = sel.first;
                  _custom.text = _fmtUnit(s.limitBytesPerSec);
                }),
              ),
            ],
          ],
        ),
        const SizedBox(height: 6),
        Text(preview, style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
        const SizedBox(height: 10),
        Text('Time windows override the default, e.g. slower during work hours and unlimited at night.', style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
        for (final w in s.limitWindows)
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text('${w.window.from} – ${w.window.to}  ·  ${w.bytesPerSec == 0 ? 'unlimited' : '${humanBytes(w.bytesPerSec)}/s'}'),
            subtitle: Text(w.window.days.isEmpty ? 'Every day' : w.window.days.map((d) => _dayNames[d]).join(', ')),
            trailing: IconButton(
              icon: const Icon(Icons.delete_outline),
              onPressed: () {
                s.limitWindows.remove(w);
                _apply(now: true);
              },
            ),
          ),
        TextButton.icon(onPressed: _addLimitWindow, icon: const Icon(Icons.add), label: const Text('Add time window')),
      ],
    );
  }

  Widget _about(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final info = widget.core.info();
    final configDir = info['configDir'] as String? ?? '';
    // Buy Me a Coffee's own yellow, so the button reads as theirs.
    const bmcYellow = Color(0xFFFFDD00);
    const bmcInk = Color(0xFF0D0C22);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Spate ${widget.core.version} by AMLabs', style: tt.titleSmall?.copyWith(fontWeight: FontWeight.w600)),
        const SizedBox(height: 2),
        Text('Free and open source under the MIT licence.', style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
        const SizedBox(height: 14),
        Container(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
          decoration: BoxDecoration(
            color: bmcYellow.withValues(alpha: Theme.of(context).brightness == Brightness.dark ? 0.10 : 0.18),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: bmcYellow.withValues(alpha: 0.55)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.coffee_rounded, size: 20),
                  const SizedBox(width: 8),
                  Text('Buy me a coffee', style: tt.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                'Spate is built and kept up by one developer and will stay free. If it saves you time, a coffee keeps the next release coming.',
                style: tt.bodySmall?.copyWith(color: cs.onSurface),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 10,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  FilledButton.icon(
                    onPressed: () => _open(_supportUrl),
                    style: FilledButton.styleFrom(backgroundColor: bmcYellow, foregroundColor: bmcInk, padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12)),
                    icon: const Icon(Icons.coffee_rounded, size: 18),
                    label: const Text('Buy me a coffee', style: TextStyle(fontWeight: FontWeight.w700)),
                  ),
                  SelectableText(_supportUrl.replaceFirst('https://', ''), style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant, fontFeatures: const [FontFeature.tabularFigures()])),
                  IconButton(
                    tooltip: 'Copy link',
                    icon: const Icon(Icons.copy_rounded, size: 16),
                    visualDensity: VisualDensity.compact,
                    onPressed: () {
                      Clipboard.setData(const ClipboardData(text: _supportUrl));
                      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Link copied'), duration: Duration(seconds: 2)));
                    },
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        OutlinedButton.icon(
          onPressed: configDir.isEmpty ? null : () => Process.start(Platform.isMacOS ? 'open' : Platform.isWindows ? 'explorer' : 'xdg-open', [Platform.isMacOS ? '-R' : '', '$configDir/spate.log'].where((a) => a.isNotEmpty).toList()),
          icon: const Icon(Icons.description_outlined, size: 16),
          label: const Text('Show log file'),
        ),
      ],
    );
  }

  /// A path field with a Browse button that opens the native folder picker.
  Widget _folderField(TextEditingController ctl, {required String label, required VoidCallback onChanged, String? hint}) => Row(
    children: [
      Expanded(child: TextField(controller: ctl, onChanged: (_) => onChanged(), decoration: InputDecoration(labelText: label, hintText: hint))),
      const SizedBox(width: 8),
      SizedBox(
        height: 44,
        child: OutlinedButton.icon(
          onPressed: () async {
            final p = await _pickFolder(ctl.text.trim());
            if (p == null) return;
            ctl.text = p;
            onChanged();
          },
          icon: const Icon(Icons.folder_open_rounded, size: 16),
          label: const Text('Browse'),
        ),
      ),
    ],
  );

  String _eta(int bytes, int bps) {
    final sec = bytes / bps;
    if (sec < 90) return '${sec.round()} seconds';
    if (sec < 5400) return '${(sec / 60).round()} minutes';
    return '${(sec / 3600).toStringAsFixed(1)} hours';
  }

  String _fmt(DateTime t) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${t.year}-${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}';
  }

  /// A settings card. Collapsible sections show [summary] in the header and
  /// toggle on the header or the arrow; the rest are always open.
  Widget _section(BuildContext context, String title, IconData icon, List<Widget> children, {bool collapsible = false, String? summary}) {
    final tt = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    final open = !collapsible || !_collapsed.contains(title);
    final header = Row(
      children: [
        Icon(icon, size: 18),
        const SizedBox(width: 8),
        Text(title, style: tt.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
        if (summary != null && !open) ...[
          const SizedBox(width: 10),
          Expanded(child: Text(summary, maxLines: 1, overflow: TextOverflow.ellipsis, style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant))),
        ] else
          const Spacer(),
        if (collapsible) Icon(open ? Icons.expand_less_rounded : Icons.expand_more_rounded, size: 20, color: cs.onSurfaceVariant),
      ],
    );
    return Card(
      margin: const EdgeInsets.only(bottom: 14),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
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
          ],
        ),
      ),
    );
  }

  /// One layout for every editor dialog: fixed width, fields 12px apart,
  /// Cancel / confirm. Returns true on confirm.
  Future<bool> _formDialog(BuildContext context, {required String title, required List<Widget> fields, String confirm = 'OK'}) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        contentPadding: const EdgeInsets.fromLTRB(24, 16, 24, 8),
        content: SizedBox(
          width: 460,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [for (var i = 0; i < fields.length; i++) ...[if (i > 0) const SizedBox(height: 12), fields[i]]],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(confirm)),
        ],
      ),
    );
    return ok == true;
  }

  Future<void> _editCategory(Category? c) async {
    final name = TextEditingController(text: c?.name ?? '');
    final ext = TextEditingController(text: c?.extensions.join(', ') ?? '');
    final dir = TextEditingController(text: c?.dir ?? '');
    final ok = await _formDialog(
      context,
      title: c == null ? 'New category' : 'Edit category',
      confirm: c == null ? 'Add' : 'Save',
      fields: [
        TextField(controller: name, autofocus: true, decoration: const InputDecoration(labelText: 'Name')),
        TextField(controller: ext, decoration: const InputDecoration(labelText: 'Extensions', hintText: 'mp4, mkv, avi')),
        _folderField(dir, label: 'Folder', hint: 'Relative to the base folder, or absolute', onChanged: () {}),
      ],
    );
    if (!ok) return;
    final exts = ext.text.split(',').map((e) => e.trim().toLowerCase().replaceFirst(RegExp(r'^\.'), '')).where((e) => e.isNotEmpty).toList();
    if (c == null) {
      s.categories.add(Category(name: name.text.trim(), extensions: exts, dir: dir.text.trim()));
    } else {
      c.name = name.text.trim();
      c.extensions = exts;
      c.dir = dir.text.trim();
    }
    _apply(now: true);
  }

  Future<void> _addSiteRule() async {
    final host = TextEditingController();
    final dir = TextEditingController();
    final ok = await _formDialog(
      context,
      title: 'Site rule',
      confirm: 'Add',
      fields: [
        TextField(controller: host, autofocus: true, decoration: const InputDecoration(labelText: 'Site', hintText: 'releases.ubuntu.com (subdomains included)')),
        _folderField(dir, label: 'Folder', hint: 'Relative to the base folder, or absolute', onChanged: () {}),
      ],
    );
    if (ok && host.text.trim().isNotEmpty) {
      s.siteRules.add(SiteRule(host: host.text.trim().toLowerCase(), dir: dir.text.trim()));
      _apply(now: true);
    }
  }

  /// A time shown as a button; tapping opens the time picker in keyboard mode.
  Widget _timeField(BuildContext ctx, String label, String value, ValueChanged<String> onPicked) {
    final parts = value.split(':');
    final initial = TimeOfDay(hour: int.tryParse(parts.elementAtOrNull(0) ?? '') ?? 22, minute: int.tryParse(parts.elementAtOrNull(1) ?? '') ?? 0);
    String two(int n) => n.toString().padLeft(2, '0');
    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: () async {
        final t = await showTimePicker(context: ctx, initialTime: initial, initialEntryMode: TimePickerEntryMode.input);
        if (t != null) onPicked('${two(t.hour)}:${two(t.minute)}');
      },
      child: InputDecorator(
        decoration: InputDecoration(labelText: label, suffixIcon: const Icon(Icons.schedule_rounded, size: 18)),
        child: Text(value.isEmpty ? '${two(initial.hour)}:${two(initial.minute)}' : value),
      ),
    );
  }

  /// Time-window editor; with [limit] it also asks for the cap that applies
  /// inside the window (speed-limit windows), in kB/s or MB/s.
  Future<bool> _editWindow(TimeWindow w, {required String title, ValueNotifier<int>? limit}) async {
    var from = w.from.isEmpty ? '22:00' : w.from;
    var to = w.to.isEmpty ? '06:00' : w.to;
    final days = {...w.days};
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setInner) => AlertDialog(
          title: Text(title),
          contentPadding: const EdgeInsets.fromLTRB(24, 16, 24, 8),
          content: SizedBox(
            width: 460,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(child: _timeField(ctx, 'From', from, (v) => setInner(() => from = v))),
                    const SizedBox(width: 12),
                    Expanded(child: _timeField(ctx, 'To', to, (v) => setInner(() => to = v))),
                  ],
                ),
                if (limit != null) ...[
                  const SizedBox(height: 12),
                  DropdownButtonFormField<int>(
                    initialValue: _presets.contains(limit.value) ? limit.value : 1000 * 1000,
                    decoration: const InputDecoration(labelText: 'Limit inside this window'),
                    items: [for (final p in _presets) DropdownMenuItem(value: p, child: Text(p == 0 ? 'Unlimited' : '${humanBytes(p)}/s'))],
                    onChanged: (v) => setInner(() => limit.value = v ?? 0),
                  ),
                ],
                const SizedBox(height: 14),
                Text('Days', style: Theme.of(ctx).textTheme.labelLarge),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (var d = 0; d < 7; d++)
                      FilterChip(label: Text(_dayNames[d]), selected: days.contains(d), onSelected: (v) => setInner(() => v ? days.add(d) : days.remove(d))),
                  ],
                ),
                const SizedBox(height: 6),
                Text('None selected = every day. Windows may span midnight.', style: Theme.of(ctx).textTheme.bodySmall?.copyWith(color: Theme.of(ctx).colorScheme.onSurfaceVariant)),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(limit == null ? 'Save' : 'Add')),
          ],
        ),
      ),
    );
    if (ok == true) {
      w.from = from;
      w.to = to;
      w.days = days.toList()..sort();
      _apply(now: true);
    }
    return ok == true;
  }

  Future<void> _addLimitWindow() async {
    final w = LimitWindow(window: TimeWindow(from: '09:00', to: '18:00'));
    final limit = ValueNotifier<int>(1000 * 1000);
    if (await _editWindow(w.window, title: 'Speed limit window', limit: limit)) {
      w.bytesPerSec = limit.value;
      s.limitWindows.add(w);
      _apply(now: true);
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
          contentPadding: const EdgeInsets.fromLTRB(24, 16, 24, 8),
          content: SizedBox(
            width: 460,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextField(controller: url, autofocus: true, decoration: const InputDecoration(labelText: 'Link')),
                const SizedBox(height: 12),
                _folderField(dir, label: 'Folder', hint: 'Optional; folder rules apply if empty', onChanged: () {}),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: DropdownButtonFormField<String>(
                        initialValue: every,
                        decoration: const InputDecoration(labelText: 'Repeat'),
                        items: const [
                          DropdownMenuItem(value: 'hourly', child: Text('Every hour')),
                          DropdownMenuItem(value: 'daily', child: Text('Every day')),
                          DropdownMenuItem(value: 'weekly', child: Text('Every week')),
                        ],
                        onChanged: (v) => setInner(() => every = v ?? 'daily'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: InkWell(
                        borderRadius: BorderRadius.circular(10),
                        onTap: () async {
                          final d = await showDatePicker(context: ctx, initialDate: next, firstDate: DateTime.now(), lastDate: DateTime.now().add(const Duration(days: 365)));
                          if (d == null || !ctx.mounted) return;
                          final t = await showTimePicker(context: ctx, initialTime: TimeOfDay.fromDateTime(next), initialEntryMode: TimePickerEntryMode.input);
                          if (t == null) return;
                          setInner(() => next = DateTime(d.year, d.month, d.day, t.hour, t.minute));
                        },
                        child: InputDecorator(
                          decoration: const InputDecoration(labelText: 'First run', suffixIcon: Icon(Icons.edit_calendar_outlined, size: 18)),
                          child: Text(_fmt(next), maxLines: 1, overflow: TextOverflow.ellipsis),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Add')),
          ],
        ),
      ),
    );
    if (ok == true && url.text.trim().isNotEmpty) {
      s.recurring.add(Recurring(url: url.text.trim(), dir: dir.text.trim(), every: every, nextAt: next));
      _apply(now: true);
    }
  }
}
