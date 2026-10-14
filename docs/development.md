# development

## dependencies

install Odin, `just`, a C compiler, and `pkg-config`.
the primary Geist fonts are included in `assets/fonts`. on Linux, install
fontconfig and the distribution's Noto script, symbol, and CJK font packages
for broad Unicode coverage (on Ubuntu: `fonts-noto-core`, `fonts-noto-cjk`,
`fonts-noto-extra`). install the color emoji font package for inline
emoji, such as Noto Color Emoji on Linux. see
[font details](../assets/fonts/FONTS.md).

| library | Linux | macOS | Windows |
| --- | --- | --- | --- |
| SDL3 | system package | `brew install sdl3` | vcpkg `sdl3` |
| SDL3_ttf | system package | `brew install sdl3_ttf` | vcpkg `sdl3-ttf` |
| fontconfig | system package | `brew install fontconfig` | vcpkg `fontconfig` |
| libcurl | system package | `brew install curl` | vcpkg `curl` |
| vorbisfile | system package | `brew install libvorbis` | vcpkg `libvorbis` |
| libwebp | system package | `brew install webp` | vcpkg `libwebp` |
| credential store | libsecret | system Keychain | system Credential Manager |
| MPRIS | libsystemd, optional | not used | not used |

Connect needs libcurl 7.86 or later with `ws` and `wss` support.
check the protocol list with `curl --version`. macOS builds use
Homebrew curl because the system library does not provide this API.
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

`just test` runs all 13 test suites. root layout tests run on one thread
because Clay stores its current context in a process-global variable.
Odin memory tracking remains enabled.

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

## CI

GitHub Actions runs three native builds: Ubuntu 26.04 x64, macOS arm64, and
Windows x64. Linux and macOS pin the same Odin release tarball so the
compiler never drifts between platforms. Windows caches vcpkg binaries
between runs; the first build is slow, later ones reuse them.
the Linux job runs `just check` and `just test` on every push and pull request. release builds run only on
manual dispatch; macOS and Windows wait for Linux. each build archives its
binary, icons, and fonts into a `.tar.zst` test artifact. pull requests run only the
check job; the three builds run on pushes to `main` and manual dispatches.
actions use major-version tags. download the artifact from a successful run;
no Spotify credentials are needed. the Windows artifact bundles its DLLs and a fontconfig
directory beside the exe; point `FONTCONFIG_FILE` and `FONTCONFIG_PATH`
at it before running.

## curl and linker flags

Connect's Dealer socket uses libcurl's WebSocket API, which needs curl
7.86 or newer with `ws`/`wss` support. Linux links the system curl.
macOS links Homebrew curl because the system library lacks that API; the
`justfile` adds its library path by default. Windows has no system curl
development files, so CI builds curl with the `websockets` feature via
vcpkg and passes its library path through `SPOTI_LINKER_FLAGS`.
`SPOTI_LINKER_FLAGS` is the single knob for native library paths: empty on
Linux, Homebrew paths on macOS, `/LIBPATH:` on Windows.

## runtime settings

- Linux requires native Wayland. there is no XWayland fallback.
- `WEB_CLIENT_ID` selects the personal Spotify Web API app.
- `SPOTI_FONTS` overrides the font search directory.
- `SPOTI_THEME` selects `light` or `dark`.
- credentials use Secret Service, Keychain, or Credential Manager.
- state, cache, and logs use the operating system's application directories.

icon PNGs in `assets/icons` are committed and loaded directly. the Lucide
SVG sources sit beside them; `scripts/build-icons.sh` regenerates the PNGs
when an icon changes.

## live verification

use backend-only probes when the protocol needs a live check. report
status, counts, and boolean results, not account IDs or response bodies.
do not open desktop probes or send playback commands without permission.
see [Spotify setup and limits](spotify.md).
