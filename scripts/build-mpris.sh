#!/bin/sh
set -eu

# The Linux backend links this bridge and libsystemd unconditionally.
[ "$(uname -s)" = Linux ] || exit 0
pkg-config --print-errors --exists libsystemd
source=spotify/mpris/mpris_sd_bus.c
archive=build/mpris_sd_bus.a
mkdir -p build
if [ -f "$archive" ] && [ "$archive" -nt "$source" ]; then
	exit 0
fi
"${CC:-cc}" -O2 -fPIC $(pkg-config --cflags libsystemd) -c "$source" -o build/mpris_sd_bus.o
ar rcs "$archive" build/mpris_sd_bus.o
