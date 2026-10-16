#!/bin/sh
set -eu
# Run from the source tree or extracted Linux archive.
dest=${1:?package root required}
package=${2:-spoti}
install -Dm755 build/spoti "$dest/usr/bin/spoti"
install -Dm644 assets/icons/*.png -t "$dest/usr/share/spoti/icons"
install -Dm644 assets/fonts/*.ttf -t "$dest/usr/share/spoti/fonts"
install -Dm644 assets/app/icon.png "$dest/usr/share/spoti/app/icon.png"
install -Dm644 assets/app/icon.png "$dest/usr/share/icons/hicolor/1024x1024/apps/app.spoti.png"
install -Dm644 packaging/linux/app.spoti.desktop "$dest/usr/share/applications/app.spoti.desktop"
licenses="$dest/usr/share/licenses/$package"
install -Dm644 LICENSE "$licenses/LICENSE"
install -Dm644 assets/icons/LICENSE "$licenses/icons.txt"
install -Dm644 assets/fonts/OFL.txt "$licenses/fonts.txt"
install -Dm644 spotify/shannon/LICENSE "$licenses/shannon.txt"
install -Dm644 vendor/clay/LICENSE.md "$licenses/clay.txt"
install -Dm644 docs/licenses/unicode.txt "$licenses/unicode.txt"
