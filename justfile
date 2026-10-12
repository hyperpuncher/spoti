# The prepare scripts are POSIX shell. On Windows they run under the sh
# that ships with Git for Windows (or msys2).
set windows-shell := ["sh", "-cu"]

vet_flags := "-vet -vet-cast -vet-style -vet-semicolon -vet-tabs"
# macOS system curl has no WebSocket API. Use the Homebrew library.
curl_flags := if os() == "macos" { '-extra-linker-flags:"-L$(brew --prefix curl)/lib"' } else { "" }
project_packages := "main,ap,artwork,audio,connect,credential,diagnostic,http,library,mpris,oauth,player,session,shannon,track,ui"

default: run

_prepare:
	./scripts/build-vorbis.sh
	./scripts/build-icons.sh
	./scripts/build-mpris.sh

# Fast dev build with default optimization.
build: _prepare
	odin build . -out:build/spoti {{curl_flags}}

# Optimized portable release build. Keep runtime safety checks enabled.
release: _prepare
	odin build . -out:build/spoti -o:speed {{curl_flags}}

run *args: _prepare
	odin run . {{curl_flags}} -- {{args}}

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
	odin test spotify/session {{curl_flags}}
	odin test spotify/connect {{curl_flags}}
	odin test spotify/library {{curl_flags}}
	odin test spotify/track {{curl_flags}}
	odin test spotify/audio {{curl_flags}}
	odin test spotify/artwork {{curl_flags}}
	odin test spotify/http {{curl_flags}}
	odin test ui {{curl_flags}}

# Network diagnostic: connects to a Spotify AP without signing in.
probe:
	odin run cmd/ap_probe {{curl_flags}}

# Browser approval, AP login, audio key and first CDN range diagnostics.
login:
	./scripts/build-vorbis.sh
	odin run cmd/ap_login {{curl_flags}}

# Remove the saved refresh credential from the desktop keyring.
logout:
	odin run cmd/logout {{curl_flags}}
