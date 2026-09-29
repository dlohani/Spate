package main

import _ "embed"

// appIconPNG is the app icon (generated from assets/brand by scripts/icons.sh).
//
//go:embed icon.png
var appIconPNG []byte
