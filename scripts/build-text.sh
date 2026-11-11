#!/bin/sh
set -eu

flags=
archive=build/native_text.a
case "$(uname -s)" in
	Linux)
		pkg-config --print-errors --atleast-version=1.56 pango
		flags=$(pkg-config --cflags pangocairo)
		source=ui/native_text/text_linux.c
		;;
	Darwin) source=ui/native_text/text_darwin.c ;;
	MINGW*|MSYS*)
		export MSYS_NO_PATHCONV=1
		source=ui/native_text/text_windows.cpp
		archive=build/native_text.lib
		;;
	*) exit 1 ;;
esac
header=ui/native_text/text.h
common=ui/native_text/text_common.c
config="${CC:-cc}|${CFLAGS:-}|$flags|$source"
mkdir -p build
if [ -f "$archive" ] && [ "$archive" -nt "$source" ] && [ "$archive" -nt "$header" ] &&
	[ "$archive" -nt "$common" ] && [ "$archive" -nt "$0" ] &&
	printf '%s\n' "$config" | cmp -s - build/native_text.flags; then
	exit 0
fi
if [ "$archive" = build/native_text.lib ]; then
	cl.exe /nologo /O2 /MT /W4 /EHs-c- /GR- /std:c++17 /c "$source" /Fobuild/native_text.obj
	cl.exe /nologo /O2 /MT /W4 /c "$common" /Fobuild/native_text_common.obj
	lib.exe /nologo /OUT:build/native_text.lib build/native_text.obj build/native_text_common.obj
else
	# CFLAGS and pkg-config output are compiler argument lists.
	# shellcheck disable=SC2086
	"${CC:-cc}" -std=c11 -O2 -Wall -Wextra -Werror -fPIC ${CFLAGS:-} $flags -c "$source" -o build/native_text.o
	# shellcheck disable=SC2086
	"${CC:-cc}" -std=c11 -O2 -Wall -Wextra -Werror -fPIC ${CFLAGS:-} -c "$common" -o build/native_text_common.o
	ar rcs "$archive" build/native_text.o build/native_text_common.o
fi
printf '%s\n' "$config" > build/native_text.flags
