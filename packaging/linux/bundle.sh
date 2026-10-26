#!/bin/sh
set -eu
# Linux test archive: binary plus only the files the binary reads at runtime
# and the files the license texts require. UI SVGs are runtime assets;
# app icon sources, ICO/ICNS, and markdown docs stay in the repo.
out=${1:?output .tar.zst path required}
tar --zstd -cf "$out" \
	build/spoti \
	assets/icons/*.svg \
	assets/icons/LICENSE \
	assets/fonts/*.ttf \
	assets/fonts/OFL.txt \
	assets/app/icon.png \
	packaging/linux/app.spoti.desktop \
	packaging/linux/install.sh \
	LICENSE \
	spotify/shannon/LICENSE \
	vendor/clay/LICENSE.md \
	docs/licenses/*.txt
