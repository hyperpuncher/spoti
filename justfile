default: run

_prepare:
	./scripts/build-vorbis.sh
	./scripts/build-icons.sh

# Optimized portable release build. Keep runtime safety checks enabled.
build: _prepare
	odin build . -out:build/spoti -o:speed

run: _prepare
	odin run .

# Format every Odin file in the project, including vendored bindings.
fmt:
	odinfmt . -w

check: _prepare
	odin check . -vet-unused-imports -vet-unused-variables
	odin check cmd/ap_probe -vet-unused-imports -vet-unused-variables
	odin check cmd/ap_login -vet-unused-imports -vet-unused-variables
	odin check cmd/logout -vet-unused-imports -vet-unused-variables

test:
	./scripts/build-vorbis.sh
	odin test .
	odin test spotify/ap
	odin test spotify/shannon
	odin test spotify/oauth
	odin test spotify/session
	odin test spotify/library
	odin test spotify/track
	odin test spotify/audio
	odin test spotify/artwork
	odin test spotify/http
	odin test ui

# Network diagnostic: connects to a Spotify AP without signing in.
probe:
	odin run cmd/ap_probe

# Browser approval, AP login, audio key and first CDN range diagnostics.
login:
	./scripts/build-vorbis.sh
	odin run cmd/ap_login

# Explicitly allow saving the browser grant in the desktop keyring.
remember:
	SPOTI_REMEMBER_LOGIN=1 just run

# Remove the saved refresh credential from the desktop keyring.
logout:
	odin run cmd/logout
