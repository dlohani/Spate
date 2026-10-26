# Review Hardening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close the self-contained findings of the October 2026 architecture review: a persisted queue, `.part` naming for partial downloads, an error channel and logging in the core, server-side filename sanitising, a Linux gating provider, one status schema, Flutter checks in CI, and the stale docs.

**Architecture:** The Go core keeps owning behaviour. A new `job.Record` is the serialisable view of a job; `internal/service` persists records to `queue.json` whenever `Manager.Version()` changes and restores them at start, with the sidecar scan kept as a fallback. The engine writes to `<out>.part` and renames on completion; the sidecar stays `<out>.cascade`. Every C export records its failure in a last-error slot the Dart shell reads. Logging is `log/slog` to a file under the config folder.

**Tech Stack:** Go 1.22+ standard library only (CI-enforced), Flutter 3.47 / Dart 3.13, bash, GitHub Actions.

**Spec:** The review findings in this conversation (26 October 2026); background in `docs/delivery.md` ("Where the design holds and where it leaks"). The daemon split (finding 3) is out of scope and gets its own plan.

## Global Constraints

- `go.mod` has no `require` block. CI fails otherwise.
- JSON fields crossing FFI or loopback are added, never renamed or removed.
- Files under the config folder are written atomically with mode 0600.
- `go vet ./...`, `go test -race ./...` and `scripts/test/run.sh` stay green after every task.
- No em-dashes or emojis in docs or messages.

## Review Focus

1. A restored job whose `.part` file was deleted by the user while the app was closed: it must start over, not fail. Pinned in Task 2 (`TestResumeWithoutPartStartsFresh`).
2. A `queue.json` from a future version or hand-edited to garbage: the service must start with an empty queue and log it, not refuse to start. Pinned in Task 3 (`TestLoadQueueRejectsGarbage`).
3. A hand-off with filename `../x`: the file lands in the resolved folder as `x`. Pinned in Task 5 (`TestAddSanitisesFilename`).
4. A completed download whose final name already exists on disk (second download of the same link after the first finished): the rename must not overwrite the existing file. Pinned in Task 2 (`TestCompleteDoesNotOverwriteExisting`).
5. Corrupt `settings.json` on a machine where Cascade is not running: the app shows the error instead of exiting. Pinned in Task 4 (Dart: `main.dart` shows `_FatalApp`); the Go side pinned by `TestLastErrorAfterFailedStart`.

---

### Task 1: Queue version counter and records in `internal/job`

**Files:**
- Modify: `internal/job/manager.go`
- Test: `internal/job/manager_test.go`

**Interfaces:**
- Produces: `func (m *Manager) Version() uint64` (incremented under `m.mu` on every state or membership change, including progress-free transitions; starts at 1 after `New`).
- Produces: `type Record struct { ID string; URL string; Out string; Priority int; StartAt time.Time; Paused bool; Conns int; SHA256 string; Headers map[string]string; Cookie string; BasicUser, BasicPassword string }` with JSON tags in camelCase (`id`, `url`, `out`, `priority`, `startAt` as RFC3339 omitempty, `paused`, `conns`, `sha256`, `headers`, `cookie`, `basicUser`, `basicPassword`, all omitempty except id/url/out).
- Produces: `func (m *Manager) Records() []Record` returning non-terminal jobs (Pending, Running, Paused) in insertion order. Running jobs are recorded with `Paused: false`.
- Produces: `func (m *Manager) AddRecord(r Record, base download.Options) (string, error)` which builds a `Spec` from the record, copies Headers/Cookie/Basic*/Conns/SHA256 onto `base`, sets `Resume: true`, and when `r.Paused` adds the job in `Paused` state (new helper path inside `Add`, not a second map insert).

- [ ] **Step 1: Write the failing tests**

```go
func TestVersionAdvancesOnChange(t *testing.T) {
	m := New(1)
	v0 := m.Version()
	id, _ := m.Add(Spec{URL: "http://x/a", Out: filepath.Join(t.TempDir(), "a")})
	if m.Version() <= v0 { t.Fatal("Add did not bump version") }
	v1 := m.Version()
	_ = m.Pause(id)
	if m.Version() <= v1 { t.Fatal("Pause did not bump version") }
}

func TestRecordsRoundTrip(t *testing.T) {
	m := New(1)
	out := filepath.Join(t.TempDir(), "a.bin")
	at := time.Now().Add(time.Hour).Truncate(time.Second)
	id, _ := m.Add(Spec{URL: "http://x/a", Out: out, Priority: 3, StartAt: at,
		Options: download.Options{Conns: 2, Cookie: "s=1", Headers: map[string]string{"Referer": "http://x/"}}})
	_ = m.Pause(id)
	recs := m.Records()
	if len(recs) != 1 || !recs[0].Paused || recs[0].Cookie != "s=1" || recs[0].Headers["Referer"] != "http://x/" ||
		!recs[0].StartAt.Equal(at) || recs[0].Priority != 3 || recs[0].Conns != 2 {
		t.Fatalf("record lost fields: %+v", recs)
	}
	m2 := New(1)
	nid, err := m2.AddRecord(recs[0], download.Options{})
	if err != nil { t.Fatal(err) }
	st, _ := m2.Status(nid)
	if st.State != Paused || st.Priority != 3 || !st.StartAt.Equal(at) { t.Fatalf("restored wrong: %+v", st) }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `go test ./internal/job -run 'TestVersionAdvancesOnChange|TestRecordsRoundTrip' -v`
Expected: FAIL, `m.Version undefined`.

- [ ] **Step 3: Implement**

Add `version uint64` to `Manager`; bump it inside every method that mutates a job under `m.mu` and in the goroutine epilogue in `launchLocked`. Implement `Records`, `Record`, `AddRecord`. `AddRecord` with `Paused` sets `state: Paused` on the new job before `m.signal()`.

- [ ] **Step 4: Run the package tests**

Run: `go test -race ./internal/job`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add internal/job
git commit -m "job: version counter and serialisable records for queue persistence"
```

---

### Task 2: `.part` naming in the engine

**Files:**
- Modify: `internal/download/manager.go` (`prepare`, `Run`, `streamWhole`, `canResume`)
- Modify: `internal/download/resume.go` (`RemovePartial`)
- Test: `internal/download/download_test.go`

**Interfaces:**
- Produces: `func PartPath(out string) string` returning `out + ".part"`.
- Produces: `func RemovePartial(out string) error` now removes `out`, `PartPath(out)` and the sidecar.
- Behaviour: data is written to `PartPath(out)`; on success (after SHA check) the engine renames it to `out`. If `out` already exists, the rename target becomes the first free `name (N).ext` and `Downloader.Output()` reports it. `streamWhole` follows the same rule. Resume opens `PartPath(out)`; if it is missing but a sidecar and a legacy `out` exist, `out` is renamed to the part path first; if neither exists, the sidecar is discarded and the download starts fresh.

- [ ] **Step 1: Write the failing tests**

```go
func TestWritesPartThenRenames(t *testing.T) // during download only out+".part" exists; after Run, out exists and part does not
func TestResumeWithoutPartStartsFresh(t *testing.T) // sidecar present, part deleted: Run succeeds, checksum matches
func TestCompleteDoesNotOverwriteExisting(t *testing.T) // pre-create out with other bytes; after Run, out unchanged and d.Output() == "<name> (1).bin"
func TestLegacyPartialIsAdopted(t *testing.T) // sidecar + data at out (old layout): Run resumes and reuses bytes (server records no request for completed ranges)
```

Use `manualServer` from the existing tests. Hold the download mid-way with the server's delay to observe the `.part` file.

- [ ] **Step 2: Run to verify failure**

Run: `go test ./internal/download -run 'Part|Fresh|Overwrite|Legacy' -v`
Expected: FAIL (`PartPath` undefined, or `out` exists during download).

- [ ] **Step 3: Implement**

`prepare` and `streamWhole` open `PartPath(d.out)`. Add `func (d *Downloader) finalize() error` called after verification in both paths: picks a free name with `uniquePath(out)` (`name (1).ext`, `name (2).ext` ...), renames, updates `d.out` under `d.mu`. `verifySHA256` runs on the part path. Update `ResumeOrphans` in Task 3 to stat the part path.

- [ ] **Step 4: Run the package and dependants**

Run: `go test -race ./internal/download ./internal/job ./internal/localapi ./internal/service`
Expected: PASS (fix any test that asserted on `out` mid-download).

- [ ] **Step 5: Commit**

```bash
git add internal/download
git commit -m "download: write to <out>.part and rename on completion"
```

---

### Task 3: Persist and restore the queue in `internal/service`

**Files:**
- Create: `internal/service/queue.go`
- Modify: `internal/service/service.go` (`StartWith`, `Stop`, `ResumeOrphans`)
- Test: `internal/service/queue_test.go`

**Interfaces:**
- Consumes: `job.Record`, `Manager.Records()`, `Manager.AddRecord`, `Manager.Version()` (Task 1); `download.PartPath` (Task 2).
- Produces: `type queueFile struct { Version int `json:"version"`; Jobs []job.Record `json:"jobs"` }` with `Version` = 1.
- Produces: `func saveQueue(path string, recs []job.Record) error` (atomic, 0600, `os.CreateTemp` in the same dir then rename).
- Produces: `func loadQueue(path string) ([]job.Record, error)`; a missing file returns `nil, nil`; garbage or `Version > 1` returns an error.
- Behaviour: `StartWith` loads `<configDir>/queue.json`, calls `AddRecord` for each with `SharedLimiter: s.limiter`, then runs `ResumeOrphans` skipping any `out` already queued. A goroutine saves when `Mgr.Version()` changed, checked every second; `Stop` saves once more synchronously.

- [ ] **Step 1: Write the failing tests**

```go
func TestQueueSurvivesRestart(t *testing.T) // start, add a paused job with Cookie "s=1" and a scheduled job, Stop; start again with the same settings path: both jobs present, cookie preserved in Records(), states Paused and Pending
func TestLoadQueueRejectsGarbage(t *testing.T) // write "{" to queue.json; StartWith succeeds with zero jobs
func TestOrphanScanSkipsQueuedOutputs(t *testing.T) // a queued record and a sidecar for the same out: exactly one job after start
```

- [ ] **Step 2: Run to verify failure**

Run: `go test ./internal/service -run 'Queue|Orphan' -v`
Expected: FAIL, `saveQueue` undefined.

- [ ] **Step 3: Implement** `queue.go` and wire it into `StartWith`/`Stop`. The queue path is `filepath.Join(filepath.Dir(spath), "queue.json")`.

- [ ] **Step 4: Run tests**

Run: `go test -race ./internal/service`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add internal/service
git commit -m "service: persist the queue to queue.json and restore it at start"
```

---

### Task 4: Error channel across the C ABI and the Dart shell

**Files:**
- Modify: `export/cshared/cascade.go`
- Modify: `apps/flutter/lib/src/ffi/cascade_ffi.dart`
- Modify: `apps/flutter/lib/main.dart`
- Modify: `apps/flutter/lib/src/app.dart` (`CascadeController.add`)
- Modify: `internal/service/service.go` (`AddWith` error text)
- Test: `export/cshared/cascade_test.go` (new), `apps/flutter/test/ffi_test.dart`

**Interfaces:**
- Produces: `//export CascadeLastError` returning `*C.char` (caller frees) with the most recent failure message set by any export in this library, `""` when none. Guarded by a mutex; cleared by a successful `CascadeServiceStartJSON`.
- Produces: `var ErrAlreadyRunning` text stays `cascade is already running` (Dart matches on it).
- Produces (Dart): `class CascadeException implements Exception { final String message; }` thrown by `Cascade.start` and returned via `String? Cascade.lastError`.
- Produces (Dart): `CascadeController.add` sets `lastError` from `core.lastError` when the core returns null.
- Behaviour: `main.dart` on `CascadeException` whose message contains `already running` calls `requestShow` and exits; on any other message runs `runApp(_FatalApp(message))`, a minimal MaterialApp showing the message and the settings path.

- [ ] **Step 1: Write the failing Go test**

```go
func TestLastErrorAfterFailedStart(t *testing.T) {
	dir := t.TempDir()
	os.WriteFile(filepath.Join(dir, "settings.json"), []byte("{"), 0o600)
	spec := C.CString(fmt.Sprintf(`{"settingsPath":%q,"allowMultiple":true}`, filepath.Join(dir, "settings.json")))
	if h := CascadeServiceStartJSON(spec); h != 0 { t.Fatal("expected failure") }
	msg := C.GoString(CascadeLastError())
	if !strings.Contains(msg, "settings") { t.Fatalf("last error = %q", msg) }
}
```

Note: cgo tests run with `go test ./export/cshared` as an ordinary package (the `main` func is empty).

- [ ] **Step 2: Run to verify failure**

Run: `go test ./export/cshared -run TestLastErrorAfterFailedStart -v`
Expected: FAIL, `CascadeLastError` undefined.

- [ ] **Step 3: Implement** `setErr(err error)` and `CascadeLastError`; call `setErr` on every export's failure path (`CascadeServiceStart*`, `CascadeAdd*`, `CascadeSettingsApply`, `act`). Add `CascadeLastError` to `export/cshared/symbols`.

- [ ] **Step 4: Dart side**

Add the binding and `CascadeException`; update `main.dart` and `CascadeController.add`. Extend `ffi_test.dart`: after `applySettings` with the bad window returns false, `core.lastError` contains `bad time`.

- [ ] **Step 5: Run**

Run: `go test -race ./export/cshared && scripts/test/exports.test.sh && make lib && (cd apps/flutter && flutter analyze && flutter test)`
Expected: all PASS.

- [ ] **Step 6: Commit**

```bash
git add export/cshared apps/flutter/lib apps/flutter/test
git commit -m "cshared: CascadeLastError; Flutter shows start failures instead of exiting"
```

---

### Task 5: Sanitise the hand-off filename and fix the settings temp-file race

**Files:**
- Modify: `internal/localapi/server.go` (`handleAdd`)
- Modify: `internal/settings/settings.go` (`Save`)
- Test: `internal/localapi/server_test.go`, `internal/settings/settings_test.go`

- [ ] **Step 1: Write the failing tests**

```go
func TestAddSanitisesFilename(t *testing.T) // POST /add with filename "../../evil.bin": job Out is filepath.Join(defaultDir, "evil.bin")
func TestAddEmptyFilenameFallsBack(t *testing.T) // filename "." : Out basename derives from the URL path
func TestSaveConcurrent(t *testing.T) // 20 goroutines call Save on the same path; no error, file parses as JSON
```

- [ ] **Step 2: Run to verify failure**

Run: `go test ./internal/localapi ./internal/settings -run 'Sanitises|FallsBack|SaveConcurrent' -v`
Expected: FAIL (Out escapes; or a rename error under race).

- [ ] **Step 3: Implement**

In `handleAdd`: `name = filepath.Base(filepath.Clean(req.Filename))`; if `name` is `"."`, `"/"`, `""` or starts with `".."`, use `filenameFor(req.URL)`. In `Save`: `os.CreateTemp(filepath.Dir(path), "settings-*.tmp")`, write, close, `os.Chmod(0o600)`, rename.

- [ ] **Step 4: Run** `go test -race ./internal/localapi ./internal/settings` Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add internal/localapi internal/settings
git commit -m "localapi: sanitise hand-off filenames; settings: unique temp file on save"
```

---

### Task 6: Structured logging in the core

**Files:**
- Create: `internal/logx/logx.go`
- Modify: `internal/service/service.go`, `internal/job/manager.go`, `internal/localapi/server.go`, `internal/download/manager.go`, `cmd/cascade/main.go`
- Test: `internal/logx/logx_test.go`

**Interfaces:**
- Produces: `func logx.ToFile(path string, maxBytes int64) (*slog.Logger, error)`: opens `path` append-only 0600; if its size exceeds `maxBytes` first renames it to `path + ".1"` (replacing any older `.1`). Returns a text-handler logger at `slog.LevelInfo`.
- Produces: `func logx.Discard() *slog.Logger`.
- Behaviour: `service.StartWith` sets `slog.SetDefault(logx.ToFile(<configDir>/cascade.log, 5<<20))` (falls back to `Discard` on error). The CLI sets `Discard` unless `-v` is given, in which case a stderr text handler at Info. Log points, all via `slog.Default()`:
  - service: `started` (addr, dir, version), `queue restored` (n), `queue load failed` (err), `recurring due` (url), `settings applied`, `stopped`.
  - job: every state transition with id, from, to, and error text when set.
  - localapi: `handoff refused` (url, reason), `handoff accepted` (id, url), `pair` (allowed bool).
  - download: `resume discarded` (reason: size, validator, missing part), `gate closed` (reason), `connections reduced` (n).

- [ ] **Step 1: Write the failing test**

```go
func TestToFileRotatesWhenLarge(t *testing.T) // write 6 MiB file at path; ToFile(path, 5<<20) leaves path small and path+".1" at 6 MiB
```

- [ ] **Step 2: Run** `go test ./internal/logx -v` Expected: FAIL, package missing.

- [ ] **Step 3: Implement** `logx` and add the log calls listed above. Add `-v` to `cmd/cascade/main.go`.

- [ ] **Step 4: Run** `go vet ./... && go test -race ./...` Expected: PASS. Then start the service via `go test ./internal/service -run TestSettingsRulesAndPersistence -v` and confirm `cascade.log` appears beside the test's settings file (add that assertion to the test).

- [ ] **Step 5: Commit**

```bash
git add internal cmd
git commit -m "core: slog to <config>/cascade.log with rotation; -v for the CLI"
```

---

### Task 7: Linux gating provider

**Files:**
- Create: `internal/policy/provider_linux.go`
- Create: `internal/policy/provider_linux_test.go`
- Modify: `internal/policy/provider_other.go` (build tag becomes `!darwin && !linux`)

**Interfaces:**
- Produces: `type linuxConditions struct { sysfs string; run func(name string, args ...string) ([]byte, error) }` with defaults `/sys/class/power_supply` and `exec.Command(...).Output`.
- Produces: `func parseDefaultRouteDev(ipRouteOut string) string` (the `dev` token from `ip route show default`).
- Produces: `func parseWifiDevices(nmcliOut string) map[string]bool` from `nmcli -t -f DEVICE,TYPE device` (TYPE `wifi`).
- Produces: `func readBattery(sysfs string) (percent int, onAC bool, err error)`: `BAT*/capacity`, `AC*/online` or `*/type == Mains` with `online == 1`; no battery directory returns `100, true, nil` (desktop).

- [ ] **Step 1: Write the failing tests** for the three parsers with literal sample outputs, and `readBattery` against a temp sysfs tree (`BAT0/capacity` = `42`, `AC/online` = `0`).

- [ ] **Step 2: Run** `GOOS=linux go test ./internal/policy -v` Expected: FAIL (`GOOS=linux go vet ./internal/policy` compiles the file on macOS; the parser tests have no build tag so they run anywhere: put parsers in `provider_linux_parse.go` without a tag).

- [ ] **Step 3: Implement.** `OnWiFi`: default route dev is in the wifi set. `Battery`: `readBattery`.

- [ ] **Step 4: Run** `go test -race ./internal/policy && GOOS=linux go vet ./internal/policy` Expected: PASS.

- [ ] **Step 5: Update** `docs/delivery.md` parity table (Linux gating: yes) and `README.md` flag help (`-wifi-only`, `-battery-min` say "macOS, Linux").

- [ ] **Step 6: Commit**

```bash
git add internal/policy docs/delivery.md README.md cmd/cascade/main.go
git commit -m "policy: Linux Wi-Fi and battery provider (ip route, nmcli, sysfs)"
```

---

### Task 8: One status schema

**Files:**
- Modify: `internal/job/manager.go` (add `StatusJSON`)
- Modify: `export/cshared/cascade.go`, `mobile/cascade.go`, `internal/localapi/server.go` (use it)
- Modify: `apps/flutter/lib/src/model/job.dart` (doc comment only)
- Test: `internal/job/manager_test.go`

**Interfaces:**
- Produces: `type StatusJSON struct { ID, URL, Out, State string; Priority int; Bytes, Total int64; Retries int; StartAt int64 `json:"startAt,omitempty"`; Error string `json:"error,omitempty"` }` with the same tags the cshared `statusJSON` has today, plus `func (s Status) JSON() StatusJSON` and `func StatusesJSON(sts []Status) []StatusJSON`.
- Behaviour: the three callers delete their local structs. The mobile facade's output therefore gains `url`, `out`, `retries`, `startAt` (add-only).

- [ ] **Step 1: Write the failing test** `TestStatusJSONFieldSet`: marshal a `StatusJSON` and assert the exact key set `id,url,out,state,priority,bytes,total,retries,startAt,error`.

- [ ] **Step 2: Run** `go test ./internal/job -run TestStatusJSONFieldSet -v` Expected: FAIL.

- [ ] **Step 3: Implement** and replace the three local structs.

- [ ] **Step 4: Run** `go vet ./... && go test -race ./... && make lib && (cd apps/flutter && flutter test)` Expected: PASS (Dart model unchanged).

- [ ] **Step 5: Commit**

```bash
git add internal/job export mobile internal/localapi apps/flutter/lib/src/model/job.dart
git commit -m "job: one StatusJSON shared by the C ABI, gomobile and loopback exports"
```

---

### Task 9: Flutter analyze and tests in CI; queue version export

**Files:**
- Modify: `.github/workflows/build.yml` (macos and linux jobs)
- Modify: `export/cshared/cascade.go`, `export/cshared/symbols`, `apps/flutter/lib/src/ffi/cascade_ffi.dart`, `apps/flutter/lib/src/app.dart`

**Interfaces:**
- Produces: `//export CascadeQueueVersion` returning `C.ulonglong` from `Mgr.Version()`.
- Behaviour: `CascadeController._tick` reads `core.queueVersion`; when unchanged since the last tick and no job is running it skips the status call and `notifyListeners` (speed samples still need ticks while running). Tick stays 500 ms.
- CI: after the toolchain steps in `macos` and `linux`: `make lib`, then `cd apps/flutter && flutter pub get && flutter analyze && flutter test`. The macOS step runs before `./build mac`. The Linux job already installs GTK dev packages.

- [ ] **Step 1: Add the export and binding**, and the skip in `_tick`.
- [ ] **Step 2: Run** `scripts/test/exports.test.sh && make lib && (cd apps/flutter && flutter analyze && flutter test)` Expected: PASS.
- [ ] **Step 3: Edit the workflow** and run `yq '.jobs.macos.steps[].name' .github/workflows/build.yml 2>/dev/null || grep -n "flutter test" .github/workflows/build.yml` to confirm both jobs carry the step.
- [ ] **Step 4: Commit**

```bash
git add .github export apps/flutter/lib
git commit -m "ci: flutter analyze and test on macOS and Linux; UI skips idle polls via CascadeQueueVersion"
```

---

### Task 10: Documentation drift

**Files:**
- Modify: `README.md` (Status section lines 37-40; "How resume works" mentions `.part`; new "Logs" line under Organization)
- Modify: `browser/README.md` (Firefox and Safari sections describe the shipped manifests and `scripts/safari-extension.sh`)
- Modify: `docs/delivery.md` (strike the leaks this plan closes; note queue.json, `.part`, `CascadeLastError`, logging; leave the daemon split as the next phase)

- [ ] **Step 1: Edit** the three files.
- [ ] **Step 2: Verify** `grep -n "Not implemented yet" README.md` shows only the `.rar/.7z` and media-button items; `grep -n "follow-up\|Not included yet" browser/README.md` returns nothing.
- [ ] **Step 3: Commit**

```bash
git add README.md browser/README.md docs/delivery.md
git commit -m "docs: status, resume layout, logs, Firefox and Safari sections brought current"
```
