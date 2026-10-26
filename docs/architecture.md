# cascade architecture: one core, five platforms

Goal: a single shared codebase that exports to Android, iOS, Windows, Linux, and
macOS. The download engine is written once in Go and exposed through a stable
binding boundary; each platform adds only a thin native shell for its UI and its
OS-specific services.

## Layers

```
+-------------------------------------------------------------+
| UI shell (per platform, thin)                               |
|   Flutter (recommended, one UI for all 5) OR native         |
+-------------------------------------------------------------+
| Platform services (thin, native, NOT unified)               |
|   Android: share intent, WorkManager gating, foreground svc |
|   iOS: share extension, background URLSession policy, BGTask |
|   Desktop: system tray, browser extension host, GateFunc    |
+-------------------------------------------------------------+
| Binding boundary (stable, generated)                        |
|   C ABI  (export/cshared)  -> Flutter dart:ffi, native C    |
|   gomobile (mobile/)       -> Android .aar, iOS .xcframework |
+-------------------------------------------------------------+
| Core engine (Go, unified, ~all the logic)                   |
|   internal/download  segmented + work-stealing + resume      |
|   internal/job       queue, priority, scheduler, pause       |
|   internal/httpc     tuned client (auth, proxy, TLS)         |
|   internal/policy    Wi-Fi/battery gate (desktop provider)   |
+-------------------------------------------------------------+
```

Everything below the binding boundary is shared. Everything above is small and
per-platform. The engine holds all the hard logic; shells wire it to the OS.

## Binding boundary

Two exports over the same core, sharing one JSON status schema:

- **C ABI** (`export/cshared`, `buildmode=c-shared`): `libcascade.{dylib,so}` /
  `cascade.dll` + header. Consumed by Flutter via `dart:ffi` and by any native C
  code. Handle-based API; structured data crosses as JSON strings.
- **gomobile** (`mobile/`): `cascade.aar` (Android) and `Cascade.xcframework`
  (iOS) for native Kotlin/Swift shells. Same JSON schema.

Status schema (both exports): `[{"id","state","priority","bytes","total","error"}]`.

## Recommended UI: Flutter + FFI

Flutter is the one framework that renders a single UI on all five targets. It
calls the Go core through `dart:ffi` against the C ABI. This keeps both the core
*and* the UI unified; only the OS-service shims differ per platform.


## Per-platform gating (Wi-Fi-only / battery)

Do not reuse one implementation; use each OS's idiom:

- **Android (11+):** WorkManager constraints, not polling:
  `setRequiredNetworkType(UNMETERED)` (Wi-Fi-only), `setRequiresCharging`,
  `setRequiresBatteryNotLow`; `ConnectivityManager`/`NetworkCapabilities` for
  live checks; a foreground service (type `dataSync`) for an active download.
- **iOS:** background `URLSession` with `allowsCellularAccess=false` and
  `BGTaskScheduler`; the OS enforces network/power policy.
- **Desktop:** the engine's `download.GateFunc` with the `internal/policy`
  provider (macOS via `pmset`/`route`/`networksetup`; Linux via `ip route`,
  `nmcli` and `/sys/class/power_supply`; Windows provider is TODO).

The engine already treats a closed gate as resumable (returns `*GateError`; the
job manager re-queues), so native gating just needs to open/close the gate.

## Media capture (TikTok / Instagram / Shorts / YouTube)

Screen analysis is the wrong primitive on every platform: it yields pixels or UI
text, never the source media URL, and the screen-reading APIs are either policy-
prohibited or DRM-blocked. Findings:

| Mechanism | Result | Verdict |
|---|---|---|
| Share intent / share extension | The post URL | Viable, supported, no scraping |
| VpnService / local proxy | Metadata; URLs only via TLS-MITM | Blocked by cert pinning on these apps |
| AccessibilityService | UI text | Play-policy prohibited for this use |
| MediaProjection / screen capture | Re-encoded pixels | DRM surfaces blocked; wrong output |

Chosen approach: **user shares the post to the app (mobile) or a browser
extension reads the page (desktop); a resolver turns that into a media URL; the
cascade engine downloads it.** No screen analysis, no mobile "extension."

## Boundary (non-negotiable)

The engine downloads what the user is authorized to fetch. No DRM circumvention;
protected streams are out of scope. Resolving/downloading third-party platform
content may violate those platforms' Terms of Service and is the operator's
responsibility.

## Build / export matrix

| Target | Artifact | Command | Prereqs |
|---|---|---|---|
| Desktop CLI | `dist/cascade` | `make cli` | Go 1.22+ |
| Desktop/Flutter FFI | `libcascade.{dylib,so}` / `cascade.dll` + header | `make lib` | CGO + host C toolchain |
| Android | `cascade.aar` | `make android` | gomobile + Android SDK/NDK |
| iOS | `Cascade.xcframework` | `make ios` | gomobile + Xcode (macOS) |

### Verified in this environment (macOS/arm64)
- `go build ./...`, `go vet ./...`, `go test -race ./...` (all pass).
- `make lib` produces `libcascade.dylib` + header; a C program linked against it
  ran a real download end to end with byte-identical output.

### Not verifiable here (needs external SDKs)
- `make android` / `make ios`: require Android NDK / Xcode. The `mobile/` package
  is written to gomobile's type rules and compiles as ordinary Go; the bind step
  must run on a machine with those SDKs.
