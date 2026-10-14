#!/bin/sh
set -eu
# macOS .app bundle: only runtime rasters, fonts, and required licenses.
# SVG sources, ICO, and markdown docs stay in the repo.
out=${1:?output .tar.zst path required}
app=build/Spoti.app/Contents
rm -rf build/Spoti.app
mkdir -p "$app/MacOS" "$app/Resources/app" "$app/Resources/icons" "$app/Resources/fonts"
cp build/spoti "$app/MacOS/"
cp assets/icons/*.png "$app/Resources/icons/"
cp assets/icons/LICENSE "$app/Resources/icons/"
cp assets/fonts/*.ttf assets/fonts/OFL.txt "$app/Resources/fonts/"
cp assets/app/icon.png "$app/Resources/app/"
cp assets/app/icon.icns "$app/Resources/AppIcon.icns"
cp packaging/macos/Info.plist "$app/"
codesign --force --deep --sign - build/Spoti.app
codesign --verify --strict build/Spoti.app
tar --zstd -cf "$out" -C build Spoti.app
