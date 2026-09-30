# Release Obfuscation and Reverse-Engineering Hardening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Make decompilation and casual copying of Cascade materially harder across all three code layers (Go core, C ABI surface, Flutter/Dart UI), applied as the last transformation before packaging, only for release builds, off by default for development.

**Architecture:** A single opt-in switch, `CASCADE_OBFUSCATE=1`, threads through the existing build scripts. When set, `go build` becomes `garble build`, `flutter build` gains `--obfuscate --split-debug-info`, and the linked C shared library exports only the documented `Cascade*` symbols. Nothing about the source changes; obfuscation is a build-time wrapper, so development builds stay fast and debuggable. `./build release` sets the switch automatically, so a release is always hardened and a dev build never pays the cost.

**Tech Stack:** garble v0.18.0 (Go obfuscator), Flutter `--obfuscate`/`--split-debug-info` (Dart AOT symbol stripping), platform linker export lists (macOS `-exported_symbols_list`, Linux version script, Windows `.def`), bash 3.2, Go 1.22+.

**Spec:** docs/delivery.md, "Tamper resistance" and the new "Release obfuscation" section this plan adds. Fits Phase 2 (signing and updates), since both are release-only build hardening.

## Verified facts (measured on this repo, 2026-09-30)

- garble builds the CLI and the `c-shared` core; leftover internal-name strings drop from 166 to 0; all 26 `Cascade*` C exports survive; the Flutter FFI test passes against a garbled `libcascade.dylib`; the garbled CLI runs.
- `-literals` roughly doubles size (6.7MB -> 17MB); `-tiny` without literals is smaller than plain. Choice per artifact.
- A normal release macOS `.app` leaks Dart identifiers (`SettingsScreen`, `_openSettings`, `handleAdd`, `ui_prefs.dart`). `flutter build macos --obfuscate --split-debug-info=<dir>` removes them.
- garble needs CGO for the c-shared build; `CC` must still be honoured (Windows cross-build uses mingw / gcc).

## Global Constraints

- Off by default. Every build path behaves exactly as today unless `CASCADE_OBFUSCATE=1` is set (or `./build release` sets it).
- The C ABI is the contract: the 26 exported `Cascade*` symbols and the header must be byte-for-byte identical in name and signature whether or not obfuscation is on. The Dart FFI binding looks them up by name.
- Obfuscation must never run in `flutter run`/`go build` development flows or in `go test`.
- garble is invoked as `garble [flags] build ...`, not `go build`; it must receive the same `-ldflags`, `-buildmode`, `CGO_ENABLED` and `CC` the plain build uses.
- Reproducibility for a given release: a fixed seed per release (from VERSION + git SHA) so a release can be rebuilt identically, but names differ across releases. Never a hardcoded literal seed in the repo.
- `--obfuscate` requires `--split-debug-info=<dir>`; the symbol map it writes is a build secret (needed to symbolize crash reports) and must be gitignored, never shipped in the artifact.
- Standard library only for Go; no emojis or em-dashes in text; VERSION is the single version source.

## Review Focus

- A release build with garble missing must fail loudly with an install hint, not silently fall back to `go build` (unobfuscated release is worse than a failed one). Test in Task 1.
- The c-shared library built with garble must still export all 26 `Cascade*` symbols and no fewer; a dropped export bricks the UI. Test in Task 2.
- `--obfuscate` without `--split-debug-info` is rejected by Flutter; the scripts must always pass both together. Test in Task 3.
- The symbol-map directory must not land inside the shipped bundle or zip. Test in Task 3.
- `go test` and `flutter test` must run unobfuscated even when `CASCADE_OBFUSCATE=1` is exported in the shell. Test in Task 1 and Task 3.

---

### Task 1: The obfuscation switch and the Go core (make lib, CLI)

**Files:**
- Create: `scripts/lib/obfuscate.sh` (helper: is it on, which go build command, is garble present)
- Modify: `Makefile` (the `lib` and `cli` targets consult the helper)
- Create: `scripts/test/obfuscate.test.sh`

**Interfaces:**
- Produces: `obf_on` (0 when `CASCADE_OBFUSCATE=1`); `obf_require_garble` (exits 2 with an install hint if on and garble absent); `go_build_cmd` (prints `garble -tiny -seed=<seed> build` when on, `go build` when off; seed derived from VERSION+SHA); reads `CASCADE_OBF_SEED` override for reproducible rebuilds.

- [ ] Step 1: write obfuscate.test.sh asserting obf_on off/on, obf_require_garble exit, go_build_cmd wording both ways, and that `-literals` appears only for the lib profile.
- [ ] Step 2: run it, watch it fail (no helper yet).
- [ ] Step 3: write scripts/lib/obfuscate.sh.
- [ ] Step 4: wire Makefile `lib` (garble with `-literals -tiny` when on) and `cli` (`-tiny` when on) through the helper; keep CGO/CC/ldflags.
- [ ] Step 5: run the test; build `make lib` plain and with the switch, confirm both produce a loadable dylib and the switched one has zero `cascade/internal` strings.
- [ ] Step 6: confirm `go test ./...` is untouched with the switch exported.
- [ ] Step 7: commit.

### Task 2: The C ABI export list

**Files:**
- Create: `export/cshared/exported_symbols.txt` (the 26 `Cascade*` names, macOS format) and a Linux version script + Windows `.def` generated from one source list
- Modify: `Makefile` `lib`, `scripts/build-windows.sh` (pass the platform export flag when linking the shared lib)

**Interfaces:**
- Consumes: the switch from Task 1 (export restriction applies whenever the shared lib is built, obfuscated or not; it is pure hardening).
- Produces: a single `export/cshared/symbols` list; a small generator turning it into each platform's linker format.

- [ ] Step 1: test asserting the generated macOS list has all 26 names and the count matches `grep -c //export export/cshared/*.go`.
- [ ] Step 2: run, fail.
- [ ] Step 3: add the source list + generator; wire the linker flag per platform.
- [ ] Step 4: build the lib, `nm -gU` shows exactly the 26 `Cascade*` symbols and no internal Go symbols beyond the required runtime ones.
- [ ] Step 5: run the Flutter FFI test against the restricted lib.
- [ ] Step 6: commit.

### Task 3: The Flutter/Dart UI

**Files:**
- Modify: `scripts/flutter-macos.sh`, `scripts/flutter-windows.ps1`, `scripts/package-linux.sh` (add `--obfuscate --split-debug-info=<dir>` when the switch is on)
- Modify: `.gitignore` (the symbol-map dir)

**Interfaces:**
- Consumes: the switch (bash reads `CASCADE_OBFUSCATE`; PowerShell reads `$env:CASCADE_OBFUSCATE`).
- Produces: symbol maps under `dist/debug-symbols/<platform>-<version>/`, gitignored, never copied into the bundle.

- [ ] Step 1 (macos/linux): guard the flags behind the switch; symbol dir outside the bundle.
- [ ] Step 2: build with the switch, confirm the release `.app` no longer leaks `SettingsScreen`/`_openSettings`/`ui_prefs.dart` and the symbol map exists outside the bundle.
- [ ] Step 3: confirm `flutter test` and `flutter run` ignore the switch.
- [ ] Step 4 (windows ps1): same guard, `$env:CASCADE_OBFUSCATE`.
- [ ] Step 5: `.gitignore` the symbol-map dir; confirm the bundle/zip never contains it.
- [ ] Step 6: commit.

### Task 4: Wire the switch into ./build release and document

**Files:**
- Modify: `build` (the `release` branch exports `CASCADE_OBFUSCATE=1`; the seed derives from VERSION+SHA)
- Modify: `docs/delivery.md` (new "Release obfuscation" subsection), `README.md`
- Modify: `.github/workflows/build.yml` (install garble; keep normal PR builds unobfuscated for speed; obfuscate only on tag pushes)

- [ ] Step 1: `require_release`/release branch sets and exports the switch and a per-release seed.
- [ ] Step 2: CI installs garble; a tag push builds obfuscated, a PR build does not; upload the symbol maps as a private CI artifact for crash symbolication.
- [ ] Step 3: docs: what each layer does, the size cost, that the symbol map is required to read crash traces and must be kept.
- [ ] Step 4: verify `./build release version` still refuses appropriately and, on a tag, a full build produces obfuscated artifacts.
- [ ] Step 5: commit.

## What this does and does not buy (state honestly in the docs)

- Raises decompilation cost sharply for all three layers: Go names gone, Dart names randomized, C surface minimized.
- Does NOT make the binary unreadable to a determined, skilled reverse engineer with time; the standard library, syscall patterns and control flow remain. It defeats casual copying, grep, and off-the-shelf decompilers, which is the stated goal.
- Anti-debugging, packers and control-flow flattening are explicitly out of scope: fragile, antivirus-triggering, and low marginal value here. Reconsider only for a specific named asset.
- Secrets are not protected by obfuscation. The capture token is already runtime-generated; keep any future secret out of the binary.
