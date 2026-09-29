#!/bin/sh
set -eu

# Build Odin's bundled public-domain stb_vorbis decoder locally. No Rust or
# system-wide installation; only the decoder, not a Spotify playback helper.
source="$(odin root)/vendor/stb/src/stb_vorbis.c"
archive=build/stb_vorbis.a
if [ ! -f "$source" ]; then
	echo "missing stb_vorbis.c in the installed Odin toolchain" >&2
	exit 1
fi
if [ "$source" -nt "$archive" ]; then
	mkdir -p build
	"${CC:-cc}" -O2 -fPIC -DSTB_VORBIS_NO_STDIO -c "$source" -o build/stb_vorbis.o
	ar rcs "$archive" build/stb_vorbis.o
fi
