# Spate

<p align="center">
  <a href="https://github.com/dlohani/Spate/releases/latest"><img src="https://img.shields.io/github/v/release/dlohani/Spate?color=blue&label=version" alt="GitHub Release"></a>
  <a href="https://github.com/dlohani/Spate/actions/workflows/build.yml"><img src="https://github.com/dlohani/Spate/actions/workflows/build.yml/badge.svg" alt="Build Status"></a>
  <img src="https://img.shields.io/badge/Go-1.22+-00ADD8?logo=go&logoColor=white" alt="Go Version">
  <img src="https://img.shields.io/github/license/dlohani/Spate" alt="License">
</p>

<p align="center">
  <strong>The fast, lightweight download manager for macOS, Linux, and Windows that finishes what your browser starts.</strong><br>
  Multi-connection acceleration, rock-solid resume, and seamless browser hand-off with your session intact.
</p>

<p align="center">
  <img src="docs/ui-light.png" alt="Spate Interface" width="800">
</p>

---

## Highlights

- ⚡ **Accelerated Downloads** &mdash; Up to 32 parallel connections per file with dynamic work-stealing to bypass server rate caps.
- 🔄 **Resilient Resume** &mdash; Seamlessly recovers after sleep, connection drops, or restarts with optional SHA-256 verification.
- 🌐 **Browser Integration** &mdash; Catch downloads from Chrome, Brave, Edge, Firefox, and Safari with cookies and authentication intact.
- 🗂️ **Automated Organization** &mdash; Rule-based folder sorting by domain or file extension, speed limiters, and off-peak scheduling.
- 🪶 **Lightweight Footprint** &mdash; ~20 MB Go engine, native system tray / menu bar integration, and zero bloatware.

---

## Installation

Download the latest release for your platform from the [Releases page](https://github.com/dlohani/Spate/releases/latest):

| Platform | Package | Notes |
|:---|:---|:---|
| **macOS** | [`Spate-1.0.0.pkg`](https://github.com/dlohani/Spate/releases/latest) | Apple Silicon & Intel, per-user install (no admin password needed) |
| **Linux** | [`spate_1.0.0_amd64.deb`](https://github.com/dlohani/Spate/releases/latest) | Debian / Ubuntu (`sudo apt install ./spate_*.deb`) |
| **Windows** | [`Spate-Setup-1.0.0.exe`](https://github.com/dlohani/Spate/releases/latest) | NSIS installer (silent mode: `/S`) |
| **CLI Only** | `go install github.com/dlohani/Spate/cmd/spate@latest` | Requires Go 1.22+ (standard library only) |

### Browser Extension

1. **Chrome / Brave / Edge**: Open `chrome://extensions` &rarr; enable *Developer mode* &rarr; click *Load unpacked* &rarr; select the `extension` folder included with Spate.
2. **Firefox**: Open `about:debugging` &rarr; *This Firefox* &rarr; *Load Temporary Add-on* &rarr; select `manifest.json`.
3. **Safari**: Included in `Spate-for-Safari.pkg` on macOS.

---

## Command Line (CLI)

Spate includes a standalone, dependency-free CLI tool:

```bash
# Basic download
spate https://example.com/archive.iso

# Accelerated download with 16 connections and SHA-256 validation
spate -n 16 -sha256 <expected-hash> -o archive.iso https://example.com/archive.iso

# Resume an interrupted download
spate -resume https://example.com/archive.iso

# Rate limit transfer speed
spate -limit 5M https://example.com/large-dataset.tar.gz
```

---

## Building from Source

Prerequisites: **Go 1.22+** and **Flutter 3.x** (optional, for desktop GUI).

```bash
# Build desktop app and core for current OS
./build mac       # macOS (.pkg and .zip in dist/macos)
./build linux     # Linux (.deb in dist/linux)
./build windows   # Windows (.exe in dist/windows)

# Run test suite
go test -race ./...
```

For architecture notes and protocol specifications, see [docs/architecture.md](docs/architecture.md).

---

## License

Distributed under the [MIT License](LICENSE). Copyright &copy; 2026 Deepak Lohani.

---

## Support

Spate is an independent, open-source project. If it saves you time or bandwidth, consider supporting its development:

[![Buy Me A Coffee](https://img.shields.io/badge/Buy%20Me%20A%20Coffee-Support-yellow?style=for-the-badge&logo=buy-me-a-coffee)](https://buymeacoffee.com/dlohani)
