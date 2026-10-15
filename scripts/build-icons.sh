#!/bin/sh
set -eu

# Rasterize the vendored Lucide SVGs into white PNGs at 2x the largest size we
# draw, so they stay crisp when scaled down on the HiDPI desktop. The app
# applies its own tints, so one PNG per icon is enough. Lucide is ISC licensed;
# see assets/icons/LICENSE.
target_size=48
if ! command -v rsvg-convert >/dev/null; then
	echo "build-icons.sh needs rsvg-convert (librsvg)" >&2
	exit 1
fi
for svg in assets/icons/*.svg; do
	png=${svg%.svg}.png
	if [ -f "$png" ] && [ "$png" -nt "$svg" ]; then continue; fi
	sed 's/currentColor/#ffffff/g' "$svg" | rsvg-convert -w "$target_size" -h "$target_size" -o "$png"
done
