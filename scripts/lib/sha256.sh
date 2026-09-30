# sha256_file FILE: prints "<hex>  <file>" like `shasum -a 256`, using whichever
# tool the host has (macOS and Linux ship shasum; Git Bash on Windows has only
# GNU sha256sum). Source it; bash 3.2 compatible.
sha256_file() {
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$@"; else sha256sum "$@"; fi
}
