#!/bin/sh
set -eu

# Thin libvorbisfile ABI bridge; all network and playback control stays in Odin.
source=spotify/audio/vorbisfile.c
archive=build/vorbisfile.a
if [ "$source" -nt "$archive" ]; then
	mkdir -p build
	"${CC:-cc}" -O2 -fPIC $(pkg-config --cflags vorbisfile) -c "$source" -o build/vorbisfile.o
	ar rcs "$archive" build/vorbisfile.o
fi
