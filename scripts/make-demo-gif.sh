#!/bin/zsh
# Renders the scripted walkthrough and encodes docs/demo.gif (needs ffmpeg).
set -euo pipefail
cd "$(dirname "$0")/.."
./build.sh >/dev/null
frames=$(mktemp -d)
trap 'rm -rf "$frames"' EXIT
build/SonosPanel.app/Contents/MacOS/SonosPanel --demo-frames "$frames"
mkdir -p docs
ffmpeg -loglevel error -y -framerate 12 -i "$frames/frame_%04d.png" \
  -vf "scale=480:-1:flags=lanczos,split[a][b];[a]palettegen=max_colors=192:stats_mode=diff[p];[b][p]paletteuse=dither=sierra2_4a:diff_mode=rectangle" \
  docs/demo.gif
ls -lh docs/demo.gif
