set windows-shell := ["pwsh", "-NoLogo", "-NoProfile", "-Command"]

vet_flags := "-vet -vet-cast -vet-style -vet-semicolon -vet-tabs"
# Native library paths. macOS uses Homebrew curl for WebSockets; Windows
# links SDL's dev bundles from build/deps plus the vcpkg libraries, whose
# install root varies per machine and arrives via SPOTI_LINKER_FLAGS.
linker_flags := env_var_or_default("SPOTI_LINKER_FLAGS", if os() == "macos" { "-L$(brew --prefix curl)/lib -L$(brew --prefix)/lib" } else if os() == "windows" { "/LIBPATH:build/deps/SDL3-3.4.18/lib/x64 /LIBPATH:build/deps/SDL3_ttf-3.2.2/lib/x64 /LIBPATH:build/deps/SDL3_image-3.4.8/lib/x64" } else { "" })
curl_flags := if linker_flags == "" { "" } else { '-extra-linker-flags:"' + linker_flags + '"' }
binary := if os() == "windows" { "build/spoti.exe" } else { "build/spoti" }
# Dev-only affordances such as the on-screen fps counter. Release builds
# stay clean unless SPOTI_DEBUG is set in the environment at runtime.
debug_flags := "-define:SPOTI_DEBUG=true"
platform_flags := if os() == "windows" { "-linker:msvc -resource:build/app.res" } else { "" }
project_packages := "main,ap,artwork,audio,connect,credential,diagnostic,http,library,mpris,oauth,player,session,shannon,track,ui,fontconfig"

default: run

_prepare:
	{{if os() == "windows" { "pwsh -NoProfile -File scripts/prepare-windows.ps1" } else { "./scripts/build-mpris.sh" }}}

# Fast dev build with default optimization.
build: _prepare
	odin build . -out:{{binary}} {{curl_flags}} {{platform_flags}} {{debug_flags}}

# Optimized portable release build. Keep runtime safety checks enabled.
release: _prepare
	odin build . -out:{{binary}} -o:speed {{curl_flags}} {{platform_flags}}

run *args: _prepare
	odin run . {{curl_flags}} {{platform_flags}} {{debug_flags}} -- {{args}}

# Format every Odin file in the project, including vendored bindings.
fmt:
	odinfmt . -w

check: _prepare
	odin check . {{vet_flags}} -vet-packages={{project_packages}}
	odin check cmd/ap_probe {{vet_flags}}
	odin check cmd/ap_login {{vet_flags}}
	odin check cmd/logout {{vet_flags}}

# Clay keeps its current context in a process-global, so layout tests
# must not run concurrently with each other. One test thread for all.
test: _prepare
	odin test . -define:ODIN_TEST_THREADS=1 {{curl_flags}}
	odin test spotify/ap {{curl_flags}}
	odin test spotify/shannon {{curl_flags}}
	odin test spotify/oauth {{curl_flags}}
	odin test spotify/credential {{curl_flags}}
	odin test spotify/session {{curl_flags}}
	odin test spotify/connect {{curl_flags}}
	odin test spotify/library {{curl_flags}}
	odin test spotify/track {{curl_flags}}
	odin test spotify/audio {{curl_flags}}
	odin test spotify/artwork {{curl_flags}}
	odin test spotify/http {{curl_flags}}
	# Font tests share SDL initialization and shutdown, so run them serially.
	odin test ui -define:ODIN_TEST_THREADS=1 {{curl_flags}}
	odin test diagnostic {{curl_flags}}

# Network diagnostic: connects to a Spotify AP without signing in.
probe:
	odin run cmd/ap_probe {{curl_flags}}

# Browser approval, AP login, audio key and first CDN range diagnostics.
login: _prepare
	odin run cmd/ap_login {{curl_flags}}

# Remove the saved refresh credential from the desktop keyring.
logout:
	odin run cmd/logout {{curl_flags}}
