#!/bin/sh
set -eu
# macOS .app bundle: binary and runtime assets. The cask installs libraries.
# UI SVGs are runtime assets; app icon sources and markdown stay in the repo.
out=${1:?output .tar.zst path required}
app=build/spoti.app/Contents
rm -rf build/spoti.app
mkdir -p "$app/MacOS" "$app/Resources/app" "$app/Resources/icons" "$app/Resources/fonts"
cp build/spoti "$app/MacOS/"
cp assets/icons/*.svg "$app/Resources/icons/"
cp assets/icons/LICENSE "$app/Resources/icons/"
cp assets/fonts/*.ttf assets/fonts/OFL.txt "$app/Resources/fonts/"
cp assets/app/icon.png "$app/Resources/app/"
cp assets/app/icon.icns "$app/Resources/AppIcon.icns"
cp packaging/macos/Info.plist "$app/"
case "${GITHUB_REF:-}" in
	refs/tags/v*)
		version=${GITHUB_REF_NAME#v}
		/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $version" "$app/Info.plist"
		/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $version" "$app/Info.plist"
		;;
esac
mkdir -p "$app/Resources/licenses"
cp LICENSE "$app/Resources/licenses/LICENSE"
cp spotify/shannon/LICENSE "$app/Resources/licenses/shannon.txt"
cp vendor/clay/LICENSE.md "$app/Resources/licenses/clay.txt"
cp docs/licenses/*.txt "$app/Resources/licenses/"

otool -L "$app/MacOS/spoti"
codesign --force --sign - build/spoti.app
codesign --verify --strict build/spoti.app
tar --zstd -cf "$out" -C build spoti.app
