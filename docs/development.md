# development

## dependencies

install Odin, `just`, a C compiler, `pkg-config`, and `rsvg-convert`.
fonts are included in `assets/fonts`.

| library | Linux | macOS | Windows |
| --- | --- | --- | --- |
| SDL3 | system package | `brew install sdl3` | vcpkg `sdl3` |
| SDL3_ttf | system package | `brew install sdl3_ttf` | vcpkg `sdl3-ttf` |
| libcurl | system package | `brew install curl` | vcpkg `curl` |
| vorbisfile | system package | `brew install libvorbis` | vcpkg `libvorbis` |
| libwebp | system package | `brew install webp` | vcpkg `libwebp` |
| credential store | libsecret | system Keychain | system Credential Manager |
| MPRIS | libsystemd, optional | not used | not used |

Connect needs libcurl 7.86 or later with `ws` and `wss` support.
check the protocol list with `curl --version`. macOS builds use
Homebrew curl because the system library does not provide this API.
macOS also needs the Xcode command line tools.

on Windows, the build scripts use `sh` from Git for Windows or msys2.
msys2 also provides `cc`, `pkg-config`, and `rsvg-convert`.
put the required shared DLLs beside the application binary.

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
odin test . -define:ODIN_TEST_THREADS=1 -sanitize:address
```

on macOS, supply the Homebrew curl library path to direct `odin` commands.

Linux can type-check the macOS target:

```sh
odin check . -target:darwin_arm64
```

this does not verify macOS linking or runtime behavior. Windows target
checks require a Windows SDK. verify native builds on their target OS.

## runtime settings

- Linux requires native Wayland. there is no XWayland fallback.
- `WEB_CLIENT_ID` selects the personal Spotify Web API app.
- `SPOTI_FONTS` overrides the font search directory.
- `SPOTI_THEME` selects `light` or `dark`.
- credentials use Secret Service, Keychain, or Credential Manager.
- state, cache, and logs use the operating system's application directories.

retain SVG icon sources in `assets/icons`. the build generates PNGs;
these outputs are not committed.

## live verification

use backend-only probes when the protocol needs a live check. report
status, counts, and boolean results, not account IDs or response bodies.
do not open desktop probes or send playback commands without permission.
see [Spotify setup and limits](spotify.md).
