# Shared by the install scripts: version comparison and the installed-version
# probes that let an install refuse a downgrade and say whether it is a fresh
# install, a reinstall or an upgrade. Source it; bash 3.2 compatible.

# vercmp A B: prints -1, 0 or 1 comparing dotted versions numerically.
# Pre-release/build suffixes are ignored and missing components count as 0.
vercmp() {
  local a="${1#v}" b="${2#v}" i x y
  a="${a%%[-+]*}"; b="${b%%[-+]*}"
  local IFS=.
  local -a as=($a) bs=($b)
  for ((i = 0; i < 3; i++)); do
    x="${as[i]:-0}"; y="${bs[i]:-0}"
    if ((10#$x < 10#$y)); then echo -1; return; fi
    if ((10#$x > 10#$y)); then echo 1; return; fi
  done
  echo 0
}

# installed_version_macos: the version of the installed app bundle, or nothing.
# Flutter's template defaults (1.0.0 build 1) mean an unstamped dev build and
# are reported as unknown so they never block an upgrade.
installed_version_macos() {
  local plist v b
  for plist in "$HOME/Applications/Cascade.app/Contents/Info.plist" \
               "$HOME/Library/Application Support/cascade/bin/Cascade.app/Contents/Info.plist"; do
    [ -f "$plist" ] && break
  done
  [ -f "$plist" ] || return 0
  v="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist" 2>/dev/null || true)"
  b="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$plist" 2>/dev/null || true)"
  { [ "$v" = "1.0.0" ] && [ "$b" = "1" ]; } && return 0
  printf '%s' "$v"
}

# installed_version_linux: the marker the Linux installer writes, or nothing.
installed_version_linux() {
  local f="${XDG_DATA_HOME:-$HOME/.local/share}/cascade/VERSION"
  [ -f "$f" ] && tr -d '[:space:]' < "$f"
  return 0
}

# check_install_version INSTALLED NEW: says what this install is and refuses a
# downgrade (exit 1) unless CASCADE_FORCE=1.
check_install_version() {
  local have="$1" want="$2"
  if [ -z "$have" ]; then
    echo "==> installing Cascade $want"
    return 0
  fi
  case "$(vercmp "$have" "$want")" in
    1)
      if [ "${CASCADE_FORCE:-0}" = "1" ]; then
        echo "==> downgrading Cascade $have -> $want (CASCADE_FORCE=1)"
        return 0
      fi
      echo "error: Cascade $have is installed and $want is older; downgrades are not supported." >&2
      echo "       Uninstall first, or run again with CASCADE_FORCE=1." >&2
      return 1 ;;
    0) echo "==> Cascade $have is already installed; reinstalling (settings and downloads are kept)" ;;
    *) echo "==> upgrading Cascade $have -> $want" ;;
  esac
}
