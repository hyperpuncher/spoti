# spoti

A native Spotify Premium client in Odin: SDL3 interface, real library
browsing, artwork, queues, seeking, encrypted audio cache and persistent
AP transport. Linux, macOS and Windows.

## Dependencies

| Library    | Linux              | macOS          | Windows            |
| ---------- | ------------------ | -------------- | ------------------ |
| SDL3       | system package     | `brew install sdl3` | vcpkg `sdl3`    |
| SDL3_ttf   | system package     | `brew install sdl3_ttf` | vcpkg `sdl3-ttf` |
| libcurl    | system package     | ships with macOS | vcpkg `curl`   |
| vorbisfile | system package     | `brew install libvorbis` | vcpkg `libvorbis` |
| libwebp    | system package     | `brew install webp` | vcpkg `libwebp` |
| credentials | libsecret (Secret Service) | Keychain, no setup | Credential Manager, no setup |
| MPRIS      | libsystemd (optional) | not applicable | not applicable |

Build tools: Odin, `just`, a C compiler, `pkg-config`, `rsvg-convert`
for the icon rasterization. Fonts ship in `assets/fonts`, nothing to
install. On Windows the shell scripts run under the sh bundled with
Git for Windows (or msys2, which also provides cc, pkg-config and
rsvg-convert); the `justfile` already selects it.

macOS also wants the Xcode command line tools for `cc`.

## Build

```sh
just build    # fast dev build into build/spoti
just release  # optimized build, safety checks kept
just test     # full suite, single-threaded for the Clay tests
```

Windows and macOS builds cannot be link-checked from Linux: `odin
check . -target:darwin_arm64` typechecks the macOS target, but the
Windows target needs a Windows SDK. Shared DLLs (SDL3, SDL3_ttf,
curl, vorbis, webp) go next to the binary on Windows.

## Platform notes

- Credentials: GNOME Secret Service on Linux, Keychain on macOS,
  Credential Manager on Windows. Only refresh tokens are stored.
- Now-playing integration (MPRIS) is Linux-only; other platforms
  compile in a no-op stub and everything else works.
- Linux requires native Wayland; other platforms use the SDL default.
- State and cache live in the OS dirs (`~/.local/state`,
  `~/Library`, `%APPDATA%`, …) automatically.
- `SPOTI_FONTS` overrides the font search dir, `SPOTI_THEME`
  forces `light` or `dark`.
