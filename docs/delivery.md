# Delivering Cascade to every platform

This is the reference for how the app is built, shipped and kept the same on
macOS, Windows, Linux, Android and iOS. `architecture.md` says what the layers
are; this document says how they are delivered and what "done" means for a
feature. Work is measured against it.

## Where the design holds and where it leaks (September 2026)

The core idea is right: one Go engine, thin shells. The leaks are at the
edges, and they are where parity and cost problems come from.

- Two binding boundaries with different surfaces. The C ABI (`export/cshared`)
  exports the whole service: settings, destination rules, scheduling, limits,
  pairing, show-window. The gomobile package (`mobile/`) wraps the job manager
  directly, skipping `internal/service`, and exposes add, pause, resume,
  status and close. Mobile cannot reach parity while this is so.
- Policy gating (Wi-Fi-only, battery) has a macOS provider only.
- The resident desktop process is the Flutter app, autostarted hidden, hosting
  the Go core in-process. A Flutter engine idles at tens of megabytes to guard
  a Go loop that would idle at a few.
- The UI polls the core every 500 ms, serialising and parsing the whole job
  list even when idle and hidden.
- Delivery is manual and can degrade silently: the Windows UI is built by
  hand in a VM and copied back, and a build without it produced an installer
  that looked complete. Two Windows installers exist (Go setup exe, NSIS).
- Parity is enforced by convention. There is no checked-in statement of what
  each platform must support.

What already holds and must be kept: the Go core has no third-party modules;
the Flutter shell has four pinned packages; the loopback API binds 127.0.0.1
only, guards writes with a 0600 token compared in constant time and rejects
web-page origins; settings and state are written atomically with 0600.

## Principles

1. **One definition, generated outward.** Nothing platform-facing is written
   twice by hand. Every duplicated fact is a future drift.
2. **Verify at every boundary, fail loud.** Each hand-off (build to package,
   package to install, install to launch, extension to app) is checked, and a
   missing piece stops the pipeline instead of producing a degraded artifact.
3. **The boundary is the asset.** The C ABI and the loopback JSON protocol
   outlive every shell. Fields are added, never renamed or removed; changed
   behaviour gets a new call.
4. **Core owns behaviour, shell owns cosmetics.** Any setting that changes
   what is downloaded, when, or where lives in Go and is therefore identical
   everywhere by construction. `ui_prefs.dart` holds appearance only.
5. **Retire before you add.** Each phase deletes something.

## The plan

### Phase 1: build where it must be built, fail loud

- A CI matrix (macOS, Windows, Ubuntu runners). Each runner builds the Go core
  natively, builds the Flutter shell for its OS, packages the installer and
  uploads it. The Mac never packages Windows by hand.
- `./build windows` and `scripts/build-windows.sh` refuse to produce an
  installer without the Flutter bundle unless explicitly told to build a
  CLI-only artifact, and that artifact is named as such.
- `cascade-setup.exe` refuses to install without the UI in its payload unless
  told to (`--no-ui`), so a UI-less setup can never look like a full one.
- A release build requires a clean, tagged tree; dev builds keep the
  `+sha.dirty` label and cannot be published.
- Installer smoke test per OS in CI: install, launch, pair, download.
- Decide which Windows installer stays (NSIS for release, the Go setup exe for
  development, or one of them only) and delete the other path.

### Phase 2: signing and updates

- Developer ID signing and notarization on macOS, Authenticode on Windows, a
  detached signature on the deb. Builds from a clean checkout with pinned
  toolchains; the release job publishes a signed checksum manifest.
- An updater in the resident process fetches a signed release manifest,
  verifies signature and hash against a key compiled into the binary, then
  hands off to the platform installer.

### Phase 3: one boundary

- Build the C ABI for every target: `c-shared` for Android through the NDK,
  `c-archive` linked statically on iOS. Flutter uses the identical `dart:ffi`
  binding on all five platforms. gomobile is retired unless a native Kotlin or
  Swift shell is actually wanted.
- `CascadeABIVersion` export and the add-only rule for the JSON schema.
- The JSON crossing FFI and loopback is defined once in Go with a schema test;
  Dart models are generated from it.

### Phase 4: daemon, client interface, push

- On desktop the resident process becomes a headless Go daemon. The Flutter
  UI launches on demand and talks to it over the existing loopback API. On
  mobile the UI keeps FFI in-process.
- One Dart `CascadeClient` interface with two implementations (FFI, loopback)
  under one contract test suite run on every platform. Screens never branch on
  platform for behaviour.
- Push, not poll: the core signals change (version counter or `NativeCallable`
  callback) and the UI redraws on change. At minimum adaptive polling: fast
  while running and visible, seconds when idle, stopped when hidden.

### Throughout: the parity matrix and the manifest

A checked-in capability manifest lists every user-visible feature, the
platforms that support it and the settings key behind it. The Settings
sections, the extension options page and this table are validated against it.
Every "no" is a decision. Current state:

| Capability | macOS | Windows | Linux | Android | iOS |
|---|---|---|---|---|---|
| Segmented download, resume, limits | yes | yes | yes | yes | yes |
| Settings, rules, schedules, windows | yes | yes | yes | no | no |
| Browser capture | yes | yes | yes | n/a | n/a |
| Share-sheet capture | n/a | n/a | n/a | not built | not built |
| Wi-Fi / battery gating | yes | no | no | no | no |
| Tray, background, single instance | yes | yes | partial | n/a | n/a |

Gating providers to add: Windows (Network List Manager, power APIs), Linux
(NetworkManager and UPower over D-Bus), Android (WorkManager constraints),
iOS (background URLSession policy).

## Tamper resistance

- Signed, reproducible artifacts from CI only (Phase 2). A dirty or untagged
  tree cannot produce a release-labelled artifact (Phase 1).
- The FFI loader in release builds accepts exactly one location, the
  application bundle. `CASCADE_LIB` and the repo-relative candidates stay
  behind a debug flag. The native host launches the app only from its
  installed location.
- No silent fallbacks. The fixed capture token fallback is removed: if the
  config folder cannot be created the service starts with capture disabled
  and the UI says why.
- Extension: host permissions reduced to what capture needs; the fixed
  developer extension ID is absent from production host manifests; store IDs
  are pinned.
- The core stays standard-library only, enforced by a CI check. Flutter
  packages are pinned to exact versions and updates are reviewed as code.
- Queue state and settings carry a version field and a checksum; partial or
  foreign files are rejected, not loaded.
- Tests are the definition of done: schema contract tests, client interface
  tests per platform, and the installer smoke test per OS.

### Release obfuscation

`./build release <targets>` and tag-push CI (`refs/tags/v*`) build with
`CASCADE_OBFUSCATE=1`. Dev builds and PR/branch CI do not, for speed. Set the
variable yourself to try it on a dev build; a release without `garble` on PATH
(`go install mvdan.cc/garble@latest`) fails loudly instead of shipping plain
binaries. The garble seed derives from VERSION plus the git SHA (override with
`CASCADE_OBF_SEED`), so a release rebuilds identically.

Three layers:

- Go core (`make lib` / `cli`): garble strips and randomizes package,
  function and type names; the shared library also gets `-literals` (string
  and constant obfuscation) and `-tiny`; the CLI gets `-tiny` only.
- C ABI: the shared library exports only the 26 `Cascade*` symbols.
- Dart UI: `flutter build --obfuscate --split-debug-info` randomizes Dart
  identifiers on the macOS, Windows and Linux desktop builds.

Cost: `-literals` roughly doubles the size of the core library, and garble
builds are slower.

Symbol maps: `--split-debug-info` writes maps to
`dist/debug-symbols/<platform>-<version>/`. They are required to symbolize
crash traces from a release and must be kept per release. CI uploads them as a
separate `<platform>-debug-symbols` artifact (only present on obfuscated tag
builds); never ship them inside the installers.

What this does and does not buy: it raises decompilation cost sharply and
defeats casual copying, grep and off-the-shelf decompilers. It does not stop a
determined, skilled reverse engineer with time; the standard library, syscall
patterns and control flow remain. Anti-debugging, packers and control-flow
flattening are deliberately out of scope (fragile, antivirus-triggering, low
marginal value). Obfuscation is not secret storage: keep secrets out of the
binary (the capture token is already generated at runtime).

## Order of work

Phase 1 first: it removes the class of failure where a build ships without a
piece and makes every later step verifiable on real targets. Phase 2 right
after, since CI is where the keys live. Phase 3 next, because mobile parity is
impossible without it. Phase 4 last, with the manifest and contract tests as
the definition of done throughout. Principle 5 is enforced in review.
