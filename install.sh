#!/bin/bash
# Sets up the parts of nov.dock that the Omarchy shell does not install on its
# own: the native Hyprland snap plugin (built from source for this machine's
# Hyprland), the Hyprland Lua hook, and the shell plugin itself.
#
# Run it after `omarchy plugin add`, and again after every update
# (`omarchy plugin update nov.dock`), since the native plugin must match the
# running Hyprland version. Safe to run repeatedly.
set -euo pipefail

# --yes accepts the one change to your own config (a require line in
# hyprland.lua) without asking.
ASSUME_YES=0
[[ ${1:-} == "--yes" || ${1:-} == "-y" ]] && ASSUME_YES=1

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
hypr_dir="$HOME/.config/hypr"
hook="$hypr_dir/nov-floating-dock.lua"
hypr_conf="$hypr_dir/hyprland.lua"
so="$here/native/nov-floating-snap.so"

step() { printf '\033[1m==> %s\033[0m\n' "$*"; }
fail() { printf 'install.sh: %s\n' "$*" >&2; exit 1; }

expected="$HOME/.config/omarchy/plugins/nov.dock"
[[ $here == "$expected" ]] || fail "expected the plugin at $expected (found $here); install it with: omarchy plugin add <repo-url>"

step "Checking build tools"
missing=()
for tool in make g++ pkg-config hyprctl python3; do
  command -v "$tool" >/dev/null || missing+=("$tool")
done
pkg-config --exists hyprland 2>/dev/null || missing+=("hyprland headers (pkg-config hyprland)")
if (( ${#missing[@]} )); then
  fail "missing: ${missing[*]} (install the base-devel, pkgconf and hyprland packages)"
fi

step "Building the native snap plugin"
# Built into a temporary folder and moved into place, so a running Hyprland
# that has the old file mapped is never handed a half-written one.
build=$(mktemp -d)
trap 'rm -rf "$build"' EXIT
make -s -C "$here/native" BUILD_DIR="$build" all test
mv -f "$build/nov-floating-snap.so" "$so"

step "Linking the Hyprland hook"
mkdir -p "$hypr_dir"
if [[ -e $hook && ! -L $hook ]]; then
  backup="$hook.bak-$(date +%s)"
  mv "$hook" "$backup"
  echo "    kept the previous file as $backup"
fi
ln -sfn "$here/hypr/nov-floating-dock.lua" "$hook"

if [[ -f $hypr_conf ]]; then
  if ! grep -q 'require("hypr.nov-floating-dock")' "$hypr_conf"; then
    answer=n
    if (( ASSUME_YES )); then
      answer=y
    elif [[ -t 0 ]]; then
      read -r -p "    Add require(\"hypr.nov-floating-dock\") to $hypr_conf? [y/N] " answer
    fi
    if [[ $answer =~ ^[Yy] ]]; then
      cp "$hypr_conf" "$hypr_conf.bak-nov-dock-$(date +%s)"
      printf '\n-- Floating Dock: animated edge snapping on floating workspaces.\nrequire("hypr.nov-floating-dock")\n' >>"$hypr_conf"
      echo "    added the require line to $hypr_conf (backup next to it)"
    else
      echo "    left $hypr_conf unchanged: add require(\"hypr.nov-floating-dock\") yourself to load the native part"
    fi
  fi
else
  echo "    $hypr_conf not found: add require(\"hypr.nov-floating-dock\") to your Hyprland Lua config yourself"
fi

if [[ -n ${HYPRLAND_INSTANCE_SIGNATURE:-} ]]; then
  step "Reloading Hyprland"
  # Unloading first makes Hyprland pick up the freshly built file.
  if hyprctl plugin list 2>/dev/null | grep -q "nov-floating-snap"; then
    hyprctl plugin unload "$so" >/dev/null || true
  fi
  hyprctl reload >/dev/null
  hyprctl plugin list 2>/dev/null | grep -q "nov-floating-snap" || hyprctl plugin load "$so" >/dev/null
fi

step "Enabling the shell plugin"
if command -v omarchy-plugin-enable >/dev/null; then
  if jq -e '(.plugins // []) | any(.id == "nov.dock")' "$HOME/.config/omarchy/shell.json" >/dev/null 2>&1; then
    echo "    already enabled"
  else
    omarchy-plugin-enable nov.dock
  fi
  omarchy-restart-shell >/dev/null 2>&1 || true
else
  echo "    omarchy-plugin-enable not found: enable nov.dock in the Omarchy shell settings"
fi

step "Done"
