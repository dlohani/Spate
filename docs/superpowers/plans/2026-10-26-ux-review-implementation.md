# UX Review Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement every finding of the 26 October 2026 UX review of the Spate desktop app (P0 defects and fundamentals, P1 density and desktop interaction, P2 polish) and remove the code and assets the redesign leaves behind.

**Architecture:** The Go core gains what the shell cannot do alone: a persisted finished history, pause-all and resume-all. Everything else is the Flutter shell: a compact row with a state glyph replacing the card, a collapsing add field, selection with keyboard and context menus, autosaving Settings, brand-pinned colour, native notifications, folder pickers and drag-and-drop through three pinned first-party or leanflutter packages. Stale exports, widgets, assets and screenshots are deleted in the same change.

**Tech Stack:** Go 1.22+ stdlib core; Flutter 3.47 with `window_manager`, `tray_manager`, `ffi`, plus new `local_notifier`, `file_selector`, `desktop_drop`.

**Spec:** The review page (artifact "Spate UX Review", 26 October 2026) and its "Order of work" table.

## Global Constraints

- `go.mod` keeps no `require` block.
- JSON fields crossing FFI or loopback are added, never renamed or removed.
- New Flutter packages are pinned to exact versions in `pubspec.yaml`.
- Every task leaves `go vet`, `go test -race ./...`, `scripts/test/run.sh`, `flutter analyze --no-fatal-infos` and `flutter test` green.

## Review Focus

1. A finished job restored from history must never run again or be counted as pending. Pinned in Task 1 (`TestHistoryRestoredAsDone`).
2. Autosaving Settings must not write an invalid document: a bad time keeps the previous value and shows the reason. Pinned in Task 5 (manual check plus `applySettings` returning false leaves `settings()` unchanged in the FFI test).
3. Keyboard focus must be visible on a selected row and Delete must never remove a running download without the confirm step the menu already implies. Pinned in Task 3 (Delete on a running row pauses the selection prompt).
4. Dropping a non-URL (a text file of notes) must add nothing and say so. Pinned in Task 4.
5. A notification must not fire for downloads that finished while the window was in front and visible; it fires when hidden or unfocused. Pinned in Task 6 (manual).

---

### Task 1: Core: finished history, pause all, resume all; drop compatibility exports

**Files:** `internal/job/manager.go`, `internal/job/manager_test.go`, `internal/service/queue.go`, `internal/service/queue_test.go`, `export/cshared/spate.go`, `export/cshared/symbols`, `scripts/test/exports.test.sh`, `apps/flutter/lib/src/ffi/spate_ffi.dart`, `apps/flutter/lib/src/model/job.dart`

**Interfaces:**
- `Record` gains `State string` ("done", "failed", "cancelled" for terminal; "" otherwise), `FinishedAt time.Time`, `Bytes int64`, `Total int64`, `Error string`. `Records()` returns terminal jobs too, newest first among terminal, capped to the most recent 200 and 30 days.
- `AddRecord` with a terminal `State` inserts the job in that state with its figures and never runs it.
- `Status`/`StatusJSON` gain `finishedAt` (Unix seconds, omitempty).
- `Manager.PauseAll()` and `Manager.ResumeAll()`; exports `SpatePauseAll`, `SpateResumeAll`. `SpateNew` and `SpateClose` removed (29 - 2 + 2 = 29 symbols).

- [x] Tests: `TestHistoryRestoredAsDone`, `TestRecordsCapHistory`, `TestPauseAllResumeAll`; FFI test asserts `finishedAt` on a done job.
- [x] Implement; `scripts/test/exports.test.sh` count stays 29.
- [x] Commit: `core: persisted finished history, pause all and resume all; drop SpateNew/SpateClose`.

### Task 2: Shell foundation: dependencies, theme, header, units

**Files:** `apps/flutter/pubspec.yaml`, `apps/flutter/lib/src/app.dart`, `apps/flutter/lib/src/model/job.dart`, `apps/flutter/lib/src/brand.dart` (new), `apps/flutter/lib/main.dart`

- [x] Add `local_notifier`, `file_selector`, `desktop_drop` pinned.
- [x] `brand.dart`: `SpateGlyph` CustomPainter (the merging-streams glyph), `brandPrimary(accent, brightness)`.
- [x] Theme: primary pinned per accent (dark: lifted); hint and subtle text at 4.5:1; `scrolledUnderElevation: 0`, `surfaceTintColor: transparent` on app bars.
- [x] `humanBytes` decimal (kB, MB, GB), no decimal above 100; all figures `tabular-nums`.
- [x] Header: glyph mark, speed pill with a 60-sample sparkline, overflow menu (Pause all, Resume all, Clear finished, Settings), no separate "Downloads" row. Remove `kMaxWindowSize`.
- [x] Commit: `shell: brand glyph and pinned primary, decimal units, header with sparkline and overflow menu, no window maximum`.

### Task 3: Rows: compact, grouped, selectable, keyboard, context menu, error disclosure

**Files:** `apps/flutter/lib/src/rows.dart` (new), `apps/flutter/lib/src/app.dart`

- [x] `DownloadRow` 56 pt: state glyph, name, meta; 3 pt bar only while running; figures column fixed 190 pt; scheduled shows start time; queued shows position.
- [x] Groups: Active (running, queued, scheduled, paused) then Finished (done, failed, cancelled) collapsed by default with count; sort by state group then insertion (numeric id).
- [x] Selection: click, Shift and Cmd/Ctrl click; arrows move; Space pause/resume; Delete removes (running rows ask first); context menu on right-click acts on the selection; the "..." menu stays.
- [x] Error disclosure: failed rows show the message in a tooltip and a second line on click, with Retry.
- [x] Completion flash: background tween when a row turns done.
- [x] Delete `DownloadCard`, `_Pill` where unused, `kMotionSlow` if unused.
- [x] Commit: `rows: compact grouped list with selection, keyboard, context menus and error disclosure`.

### Task 4: Add flow: collapsing field, schedule menu, folder picker, drop and paste

**Files:** `apps/flutter/lib/src/add_bar.dart` (new), `apps/flutter/lib/src/app.dart`

- [x] One 40 pt field; Options and Schedule as icon buttons inside; options row (Save to with Browse, no Connections) expands on toggle or focus.
- [x] Schedule menu: Tonight 22:00, Tomorrow 09:00, When the download window opens (when enabled), Custom; chip with X.
- [x] `DropTarget` over the window: URLs and `.txt`/`.url` files add; anything else shows "Nothing downloadable in what you dropped".
- [x] Cmd-V anywhere pastes and adds; Return adds; Cmd-, opens Settings.
- [x] Commit: `add bar: collapsing field, schedule presets, folder picker, drag-and-drop and paste anywhere`.

### Task 5: Settings: autosave, bar, about row, pickers, presets, advanced

**Files:** `apps/flutter/lib/src/settings_screen.dart`, `apps/flutter/lib/src/model/settings.dart`, `apps/flutter/lib/src/model/ui_prefs.dart`

- [x] Autosave with 400 ms debounce; validation failure reverts the field and shows the reason inline; Save button removed.
- [x] Bar: no scroll tint, no version; About section at the bottom with version, licence, support link, "Check the log".
- [x] Base folder, category and site-rule folders: Browse buttons.
- [x] Speed limit: presets menu plus custom with unit; preview sentence. Time windows: time pickers in input mode.
- [x] Advanced section: connections per download (moved from the add bar). Notifications toggle under Behaviour.
- [x] Commit: `settings: autosave, folder pickers, speed presets, time pickers, about and advanced sections`.

### Task 6: Presence and feedback: notifications, pairing, tray

**Files:** `apps/flutter/lib/main.dart`, `apps/flutter/lib/src/app.dart`

- [x] `local_notifier` on completion and failure when the window is hidden or unfocused; actions Open and Show in Finder; honours the toggle.
- [x] A pairing request with the window hidden shows the window.
- [x] Tray: template glyph on macOS (`isTemplate`), colour icon elsewhere; menu gains Pause all and Resume all; tooltip carries speed.
- [x] Commit: `feedback: completion notifications, pairing shows the window, tray template icon with pause and resume all`.

### Task 7: Cleanup, docs, captures

- [x] Remove unused Dart members (analyzer `unused_element`), unused Go functions (`drain`, others found by grep), stale `docs/ui-*.png` replaced by fresh captures, stale README sections.
- [x] Update `docs/delivery.md` dependency statement (seven pinned packages) and README features.
- [x] Final: all checks, build, reinstall, capture light and dark for the README.
- [x] Commit: `cleanup: remove retired exports, widgets and assets; refresh screenshots and docs`.
