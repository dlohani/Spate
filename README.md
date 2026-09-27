# cascade

A segmented, resumable HTTP download engine in Go. It fetches a file over
multiple parallel byte-range connections, writing each range at its offset in a
single preallocated file, and persists per-segment progress so an interrupted
transfer resumes cleanly.

## What it does (and does not) do

cascade makes full use of the bandwidth your connection provides and defeats
**per-connection / server-side** throttling (a server that caps each TCP
connection): N connections aggregate up to what your link allows.

It does **not** evade an ISP's aggregate rate shaping or data cap. If your line
is shaped to X Mbps total, N connections still sum to X. There is no DPI evasion,
packet crafting, or tunneling here, by design.

## Status

Implemented (headless engine + CLI):

- Multi-connection segmented downloads with dynamic work-stealing.
- Resume, broken-download recovery (retry/backoff, `If-Range` revalidation).
- Speed limiter; SHA-256 verification; automatic filename + file-type detection.
- Auth (basic), custom headers, cookies, explicit/authenticated proxy, TLS-skip.
- URL expiry/refresh via a caller hook.
- Job manager: queue, priority, scheduled start, multiple downloads in parallel,
  per-job pause/resume.
- Post-download `.zip` extraction (with zip-slip protection).
- Wi-Fi-only and battery-aware gating (macOS provider; other OSes report
  unsupported).

Not implemented yet: desktop GUI; the browser extension with a floating download
button for non-DRM streaming media; native `.rar`/`.7z` extraction.

## Build

    go build -o cascade ./cmd/cascade

Requires Go 1.22+. No external dependencies (standard library only).

## Use

    cascade [flags] <url> [url...]

Flags:

    -o <path>          output file (default: derived from URL; single URL only)
    -n <int>           parallel connections (default 8)
    -resume            resume from an existing .cascade sidecar if present
    -limit <size>      aggregate rate limit, e.g. 2M or 500K (default: unlimited)
    -sha256 <hex>      expected SHA-256 to verify on completion
    -retries <int>     per-segment retry attempts (default 5)
    -H "Key: Value"    extra request header (repeatable)
    -cookie <value>    Cookie header value
    -user user:pass    HTTP basic auth
    -proxy <url>       proxy URL, e.g. http://user:pass@host:port
    -insecure          skip TLS certificate verification
    -extract <dir>     after download, extract a .zip into <dir>
    -max-concurrent N  simultaneous downloads when several URLs are given (default 2)
    -wifi-only         only download while on Wi-Fi (macOS)
    -battery-min N     only download when battery >= N%% or on AC power (macOS)

Examples:

    cascade https://example.com/file.bin -o file.bin -n 8 -sha256 <hex>
    # interrupt with Ctrl-C, then resume:
    cascade https://example.com/file.bin -o file.bin -resume
    # download several files, two at a time:
    cascade -max-concurrent 2 https://host/a.bin https://host/b.bin https://host/c.bin

Exit codes: 0 success, 1 error, 2 usage, 130 interrupted (resumable).

## How resume works

Progress is tracked in a sidecar `<output>.cascade` (JSON) holding the URL, total
size, a validator (ETag or Last-Modified), and each segment's byte offset. On
resume, cascade re-probes and sends `If-Range`; if the validator changed (the
upstream file changed), it discards the partial data and restarts rather than
producing a corrupt merge.

## Test

    go test ./...

Tests use `net/http/httptest` and need no network: segmentation math, multi-
connection happy path with checksum, resume-after-failure, validator-changed
restart, no-range single-connection fallback, and cancellation leaving
resumable state.
