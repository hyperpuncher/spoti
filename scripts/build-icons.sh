#!/bin/sh
set -eu

# Rasterize the vendored Lucide SVGs into white PNGs at 2x the largest size we
# draw, so they stay crisp when scaled down on the HiDPI desktop. The app tints
# them per use, so only one texture per icon is needed. Lucide is ISC licensed;
# see assets/icons/LICENSE.
source_dir=assets/icons
output_dir=build/icons
target_size=48
mkdir -p "$output_dir"
if ! command -v rsvg-convert >/dev/null; then
	echo "build-icons.sh needs rsvg-convert (librsvg)" >&2
	exit 1
fi
for svg in "$source_dir"/*.svg; do
	name=${svg##*/}
	png="$output_dir/${name%.svg}.png"
	if [ -f "$png" ] && [ "$png" -nt "$svg" ]; then continue; fi
	sed 's/currentColor/#ffffff/g' "$svg" | rsvg-convert -w "$target_size" -h "$target_size" -o "$png"
done
