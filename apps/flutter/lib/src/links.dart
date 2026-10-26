import 'dart:io';

import 'package:flutter/material.dart';

/// Where the project lives. REPLACE_OWNER is substituted when the repository
/// is published (the packaging templates carry the same placeholder).
const repoUrl = 'https://github.com/REPLACE_OWNER/spate';

/// The user guide, rendered by GitHub from docs/help.md in the repository.
const helpUrl = '$repoUrl/blob/main/docs/help.md';
const issuesUrl = '$repoUrl/issues/new';
const supportUrl = 'https://buymeacoffee.com/dlohani';

/// Opens a web page in the user's default browser.
void openUrl(String url) {
  if (Platform.isMacOS) {
    Process.start('open', [url]);
  } else if (Platform.isWindows) {
    Process.start('cmd', ['/c', 'start', '', url]);
  } else {
    Process.start('xdg-open', [url]);
  }
}

/// The keyboard reference, also in docs/help.md.
const keyboardShortcuts = <(String, String)>[
  ('Return', 'Add the links in the field'),
  ('Cmd-V', 'Paste links and add them, anywhere in the window'),
  ('Cmd-,', 'Settings'),
  ('Up / Down', 'Move the selection'),
  ('Shift-click, Cmd-click', 'Extend or toggle the selection'),
  ('Space', 'Pause or resume the selection'),
  ('Delete', 'Remove the selection'),
  ('Cmd-A', 'Select every row'),
  ('Escape', 'Clear the selection'),
  ('Cmd-?', 'Help'),
];

/// Shows the keyboard reference in a dialog.
Future<void> showShortcuts(BuildContext context) {
  final mod = Platform.isMacOS ? 'Cmd' : 'Ctrl';
  final tt = Theme.of(context).textTheme;
  final cs = Theme.of(context).colorScheme;
  return showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Keyboard shortcuts'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final (keys, what) in keyboardShortcuts)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 5),
                child: Row(
                  children: [
                    SizedBox(
                      width: 170,
                      child: Text(
                        keys.replaceAll('Cmd', mod),
                        style: tt.bodyMedium?.copyWith(fontWeight: FontWeight.w600, fontFeatures: const [FontFeature.tabularFigures()]),
                      ),
                    ),
                    Expanded(child: Text(what, style: tt.bodyMedium?.copyWith(color: cs.onSurfaceVariant))),
                  ],
                ),
              ),
          ],
        ),
      ),
      actions: [FilledButton(onPressed: () => Navigator.pop(ctx), child: const Text('Done'))],
    ),
  );
}

/// The Help entries, shared by the macOS Help menu (through the "spate/menu"
/// channel) and the in-app overflow menu on every platform.
enum HelpItem { help, shortcuts, report, coffee }

void runHelpItem(BuildContext context, HelpItem item) {
  switch (item) {
    case HelpItem.help:
      openUrl(helpUrl);
    case HelpItem.shortcuts:
      showShortcuts(context);
    case HelpItem.report:
      openUrl(issuesUrl);
    case HelpItem.coffee:
      openUrl(supportUrl);
  }
}
