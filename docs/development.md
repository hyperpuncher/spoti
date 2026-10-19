# development

## dependencies

install Odin `dev-2026-10` or newer, `just`, a C compiler, and `pkg-config`.
the primary Geist fonts are included in `assets/fonts`. on Linux, install
fontconfig and the distribution's Noto script, symbol, and CJK font packages
for broad Unicode coverage (on Ubuntu: `fonts-noto-core`, `fonts-noto-cjk`,
`fonts-noto-extra`). install the color emoji font package for inline
emoji, such as Noto Color Emoji on Linux. see
[font details](../assets/fonts/FONTS.md).

| library | Linux | macOS | Windows |
| --- | --- | --- | --- |
| SDL3 | system package | `brew install sdl3` | official SDL dev bundle |
| SDL3_ttf | system package | `brew install sdl3_ttf` | official SDL dev bundle |
| fontconfig | system package | `brew install fontconfig` | vcpkg `fontconfig` |
| libcurl | system package | `brew install curl` | vcpkg `curl` |
| vorbisfile | system package | `brew install libvorbis` | vcpkg `libvorbis` |
| libwebp | system package | `brew install webp` | vcpkg `libwebp` |
| credential store | libsecret | system Keychain | system Credential Manager |
| MPRIS | libsystemd | not used | not used |

macOS also needs the Xcode command line tools.

on Windows, install Odin and `just` with winget and the C libraries with
vcpkg: `fontconfig`, `curl[websockets]`, `libvorbis`, `libwebp` for
`x64-windows`. SDL3 and SDL3_ttf come from SDL's official pinned `-VC`
dev bundles, fetched automatically by `scripts/prepare-windows.ps1`
alongside the small Vorbis bridge compile; no MSYS2 is needed. point
`FONTCONFIG_FILE` and `FONTCONFIG_PATH` at vcpkg's font configuration,
and extend `SPOTI_LINKER_FLAGS` with `/LIBPATH:<vcpkg>/installed/x64-windows/lib`.

## build and check

```sh
just build    # development binary: build/spoti
just release  # optimized binary with runtime safety checks
just run      # build and start the application
just fmt
just check
just test
```

`just test` runs all 14 test suites. root layout tests run on one thread
because Clay stores its current context in a process-global variable.
Odin memory tracking remains enabled. tests do not contact Spotify or start
browser approval. run live backend probes separately, with explicit permission.

for address-sanitizer checks:

```sh
odin test spotify/library -sanitize:address
odin test spotify/session -sanitize:address
odin test spotify/connect -sanitize:address
odin test ui -define:ODIN_TEST_THREADS=1 -sanitize:address
odin test . -define:ODIN_TEST_THREADS=1 -sanitize:address
```

on macOS, supply the Homebrew curl library path to direct `odin` commands.

Linux can type-check the macOS target:

```sh
odin check . -target:darwin_arm64
```

this does not verify macOS linking or runtime behavior. Windows target
checks require a Windows SDK. verify native builds on their target OS.

## bundled Clay library

the Linux arm64 archive uses Clay revision
[`e6cc36941ab2af5d81107617039d6f527a1c660b`](https://github.com/nicbarker/clay/tree/e6cc36941ab2af5d81107617039d6f527a1c660b),
which supplies our existing Odin bindings and platform archives.
rebuild it on Linux with clang and llvm-ar:

```sh
curl -fsSL https://raw.githubusercontent.com/nicbarker/clay/e6cc36941ab2af5d81107617039d6f527a1c660b/clay.h -o /tmp/spoti-clay.h
clang -x c -c -DCLAY_IMPLEMENTATION -ffreestanding -static -target aarch64-unknown-linux-gnu -fPIC -O3 /tmp/spoti-clay.h -o /tmp/spoti-clay-linux-arm64.o
mkdir -p vendor/clay/linux-arm64
llvm-ar rcsD vendor/clay/linux-arm64/clay.a /tmp/spoti-clay-linux-arm64.o
```

## CI

GitHub Actions runs four native builds: Ubuntu 26.04 x64 and arm64,
macOS arm64, and Windows x64. Linux and macOS use official Odin release
archives. both Linux jobs run `just check` and `just test` on pushes to
`main` and pull requests. release builds run on manual dispatch and version
tags; macOS and Windows wait for both Linux jobs. actions use major-version
tags. no Spotify credentials are needed. macOS checks credential queries
without Keychain access.

download the `.tar.zst` artifact from a successful manual run. Linux and
Windows include the binary and assets. Windows also includes DLLs and a
fontconfig directory beside the exe; point `FONTCONFIG_FILE` and
`FONTCONFIG_PATH` at it before running. macOS includes an ad-hoc signed
`Spoti.app`, with its icons, fonts, and Homebrew libraries in
`Contents/Resources` and `Contents/Frameworks`, so it launches without
Homebrew installed. it is not notarized.

macOS packaging requires `brew install dylibbundler`. the bundler resolves
absolute paths, `@rpath`, and `@loader_path` references, copies the required
libraries, and updates their load paths. the package script checks every
binary for unresolved dependencies before signing and uploading.
see [Apple\'s run-path guide](https://developer.apple.com/library/archive/documentation/DeveloperTools/Conceptual/DynamicLibraries/100-Articles/RunpathDependentLibraries.html)
and [dylibbundler usage](https://github.com/auriamg/macdylibbundler#using-dylibbundler-on-the-terminal).

## homebrew

the cask installs `Spoti.app` on Apple Silicon with macOS 26 or newer.
the macOS CI runner stays on version 26 to match that minimum.
tagged releases generate the cask from the macOS archive checksum and push
it to `hyperpuncher/homebrew-tap`. this needs a `GH_PAT` repository secret
with contents write access to that tap. the app remains ad-hoc signed,
not notarized; the cask does not bypass Gatekeeper.

## curl and linker flags

Connect's Dealer socket uses libcurl's WebSocket API, which needs curl
7.86 or newer with `ws`/`wss` support. check the protocol list with
`curl --version`. Linux links the system curl.
macOS links Homebrew curl because the system library lacks that API; the
`justfile` adds its library path by default. Windows has no system curl
development files, so CI builds curl with the `websockets` feature via
vcpkg and passes its library path through `SPOTI_LINKER_FLAGS`.
`SPOTI_LINKER_FLAGS` is the single knob for native library paths: empty on
Linux, Homebrew paths on macOS, `/LIBPATH:` on Windows.

## keyboard input

text entry uses SDL UTF-8 text-input events. shortcuts use logical keycodes,
so they follow the keyboard layout. `ctrl` and macOS `cmd` support `a` to
select all, `c` to copy, `x` to cut, and `v` to paste. copy and cut require
a selection. typing and paste replace the selected range or insert at the
caret. click to place the caret, drag to select, double-click to select a word,
and triple-click to select the line. Shift-click and Shift with arrow keys or
Home/End extend the selection. Ctrl-arrow moves by word; macOS Command-arrow
moves to a line edge. long text scrolls horizontally to keep the caret visible.
editing preserves spaces, including trailing spaces. the caret blinks while
idle and becomes visible again after typing or movement; blinking does not
require continuous redraw.
`escape` leaves the text field; it does not quit the app. `s` has no playback
shortcut. `space` toggles playback only when the text field is not active.

## runtime settings

- Linux requires native Wayland. there is no XWayland fallback.
- macOS draws app content behind a transparent native title bar. the
  traffic-light controls stay native; empty header space moves the window.
  the search field and toolbar buttons keep their normal click behavior.
- Windows extends the DWM frame into the header while keeping native
  minimise, maximise, and close buttons. native resize borders stay in
  place. caption-button bounds determine the reserved header space.
  see [Microsoft's custom-frame guide](https://learn.microsoft.com/windows/win32/dwm/customframe).
- the first-run setup screen stores the personal Spotify Web API app ID
  in the system keyring; `WEB_CLIENT_ID` overrides it for headless use.
- `SPOTI_FONTS` overrides the font search directory.
- `SPOTI_THEME` selects `light` or `dark`.
- `SPOTI_DEBUG` shows the on-screen fps counter in release builds;
  dev `just build` and `just run` always show it.
- credentials use Secret Service, Keychain, or Credential Manager.
- state, cache, and logs use the operating system's application directories.

icon PNGs in `assets/icons` are committed and loaded directly. the Lucide
SVG sources sit beside them; `scripts/build-icons.sh` regenerates the PNGs
when an icon changes.

## app icon and Linux desktop entry

[app icon source and generation](../assets/app/README.md) describes the
shared SVG, PNG, and ICO assets. Windows embeds the ICO; macOS uses an
ICNS in its app bundle. SDL sets the running icon on the main thread.
Wayland compositors without the window-icon protocol use the desktop
entry matched by SDL's `app.spoti` application ID.

install a local Linux build and its desktop entry:

```sh
install -Dm755 build/spoti "$HOME/.local/bin/spoti"
mkdir -p "$HOME/.local/share/spoti"
cp -R assets/icons assets/fonts assets/app "$HOME/.local/share/spoti/"
install -Dm644 packaging/linux/app.spoti.desktop "$HOME/.local/share/applications/app.spoti.desktop"
install -Dm644 assets/app/icon.svg "$HOME/.local/share/icons/hicolor/scalable/apps/app.spoti.svg"
```

## live verification

use backend-only probes when the protocol needs a live check. report
status, counts, and boolean results, not account IDs or response bodies.
do not open desktop probes or send playback commands without permission.
see [Spotify setup and limits](spotify.md).
