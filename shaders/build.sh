#!/bin/bash
# Recompiles the genie shaders into the portable .qsb files the dock loads.
# Only needed after editing genie.vert or genie.frag; the .qsb files are
# committed, so installing the plugin does not need Qt's shader tools.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
QSB=${QSB:-/usr/lib/qt6/bin/qsb}
for shader in genie.vert genie.frag; do
  "$QSB" --glsl "300 es,330" --hlsl 50 --msl 12 -o "$shader.qsb" "$shader"
done
echo "built genie.vert.qsb and genie.frag.qsb"
