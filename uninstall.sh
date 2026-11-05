#!/bin/bash
# Removes what install.sh set up outside the plugin folder: the Hyprland hook
# symlink, the require line in hyprland.lua (after asking), and the loaded
# native plugin. Remove the plugin itself afterwards with:
#   omarchy plugin remove nov.dock
set -euo pipefail

ASSUME_YES=0
[[ ${1:-} == "--yes" || ${1:-} == "-y" ]] && ASSUME_YES=1

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
hook="$HOME/.config/hypr/nov-floating-dock.lua"
hypr_conf="$HOME/.config/hypr/hyprland.lua"
so="$here/native/nov-floating-snap.so"

step() { printf '\033[1m==> %s\033[0m\n' "$*"; }

step "Unloading the native snap plugin"
if [[ -n ${HYPRLAND_INSTANCE_SIGNATURE:-} ]] && hyprctl plugin list 2>/dev/null | grep -q "nov-floating-snap"; then
  hyprctl plugin unload "$so" >/dev/null || true
fi

step "Removing the Hyprland hook"
if [[ -L $hook && $(readlink "$hook") == "$here/hypr/nov-floating-dock.lua" ]]; then
  rm -- "$hook"
  echo "    removed $hook"
elif [[ -e $hook ]]; then
  echo "    $hook is not nov.dock's link, left in place"
fi

if [[ -f $hypr_conf ]] && grep -q 'require("hypr.nov-floating-dock")' "$hypr_conf"; then
  answer=n
  if (( ASSUME_YES )); then
    answer=y
  elif [[ -t 0 ]]; then
    read -r -p "    Remove require(\"hypr.nov-floating-dock\") from $hypr_conf? [y/N] " answer
  fi
  if [[ $answer =~ ^[Yy] ]]; then
    cp "$hypr_conf" "$hypr_conf.bak-nov-dock-$(date +%s)"
    sed -i '/^-- Floating Dock: animated edge snapping on floating workspaces\.$/d; /^require("hypr\.nov-floating-dock")$/d' "$hypr_conf"
    echo "    removed the require line (backup next to it)"
  else
    echo "    left $hypr_conf unchanged"
  fi
fi

if [[ -n ${HYPRLAND_INSTANCE_SIGNATURE:-} ]]; then
  step "Reloading Hyprland"
  hyprctl reload >/dev/null
fi

step "Done"
echo "    Now remove the plugin itself: omarchy plugin remove nov.dock"
echo "    The borderless setting, if any, is in ~/.local/state/nov-dock/ (safe to delete)."
