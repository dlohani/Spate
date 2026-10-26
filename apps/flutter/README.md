# Spate desktop app

The Flutter shell over the Go core (`../../export/cshared`, loaded through
`dart:ffi` from `lib/src/ffi/spate_ffi.dart`). One UI for macOS, Windows and
Linux; the core owns every download, queue, settings and capture decision,
the shell renders and forwards.

- Build the core first: `make lib` at the repository root (produces
  `dist/libspate.*`), then `flutter run` here, or `scripts/flutter-macos.sh
  run` / `build` for the bundled macOS app.
- `flutter test` runs `test/ffi_test.dart` against the real library.
- Icons come from `assets/brand/*.svg` through `scripts/icons.sh`; do not
  edit the generated platform icon sets by hand.

See the repository README and `docs/help.md` for the product itself.
