#!/bin/sh
set -eu

# Thin MPRIS sd-bus bridge; the C vtable glue cannot live in Odin.
if ! pkg-config --exists libsystemd; then
	echo "build-mpris.sh: libsystemd not found; skipping MPRIS bridge" >&2
	exit 0
fi
source=spotify/mpris/mpris_sd_bus.c
archive=build/mpris_sd_bus.a
mkdir -p build
if [ -f "$archive" ] && [ "$archive" -nt "$source" ]; then
	exit 0
fi
"${CC:-cc}" -O2 -fPIC $(pkg-config --cflags libsystemd) -c "$source" -o build/mpris_sd_bus.o
ar rcs "$archive" build/mpris_sd_bus.o
