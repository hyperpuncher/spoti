#!/bin/sh
set -eu
export MSYS_NO_PATHCONV=1

# Run Git Bash from a Visual Studio developer terminal. CI loads this environment
# once with Microsoft's setup script. Odin, the SDK resource compiler, and cl share it.
command -v cl.exe >/dev/null || {
	printf '%s\n' 'start Git Bash from a Visual Studio developer terminal' >&2
	exit 1
}
mkdir -p build/deps
fetch_sdl() (
	[ ! -d "build/deps/$1" ] || return 0
	zip=$(mktemp)
	trap 'rm -f "$zip"' EXIT
	curl -fsSL --retry 3 "$2" -o "$zip"
	tar -xf "$zip" -C build/deps
)
fetch_sdl SDL3-3.4.18 https://github.com/libsdl-org/SDL/releases/download/release-3.4.18/SDL3-devel-3.4.18-VC.zip
fetch_sdl SDL3_image-3.4.8 https://github.com/libsdl-org/SDL_image/releases/download/release-3.4.8/SDL3_image-devel-3.4.8-VC.zip

if [ ! -f build/app.res ] || [ packaging/windows/app.rc -nt build/app.res ] ||
	[ assets/app/icon.ico -nt build/app.res ]; then
	rc.exe /nologo /fo build/app.res packaging/windows/app.rc
fi
