#!/bin/sh
set -eu
out=${1:?usage: bundle.sh output.tar.zst}

cp build/deps/SDL3-3.4.18/lib/x64/SDL3.dll build/
cp build/deps/SDL3_image-3.4.8/lib/x64/SDL3_image.dll build/
# SDL_image loads WebP at runtime. Keep these codecs even though import scans
# do not find them. An explicit list excludes stale DLLs from older builds.
set -- build/spoti.exe build/SDL3.dll build/SDL3_image.dll
for codec in build/deps/SDL3_image-3.4.8/lib/x64/optional/libwebp*.dll; do
	cp "$codec" build/
	set -- "$@" "build/$(basename "$codec")"
done
tar --zstd -cf "$out" "$@" assets/icons/*.svg assets/icons/LICENSE \
	assets/fonts/*.ttf assets/fonts/OFL.txt assets/app/icon.png \
	LICENSE spotify/shannon/LICENSE vendor/clay/LICENSE.md docs/licenses/*.txt
