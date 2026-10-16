#!/bin/sh
set -eu
# macOS .app bundle: binary, runtime assets, and every Homebrew library the
# binary links, so the app launches on a machine without Homebrew. SVG
# sources, ICO, and markdown docs stay in the repo and are never shipped.
out=${1:?output .tar.zst path required}
app=build/Spoti.app/Contents
rm -rf build/Spoti.app
mkdir -p "$app/MacOS" "$app/Frameworks" "$app/Resources/app" "$app/Resources/icons" "$app/Resources/fonts"
cp build/spoti "$app/MacOS/"
cp assets/icons/*.png "$app/Resources/icons/"
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
cp docs/licenses/unicode.txt "$app/Resources/licenses/unicode.txt"

# Use the native bundler to resolve absolute, @rpath, and @loader_path
# dependencies from the original libraries before moving them.
dylibbundler -b -x "$app/MacOS/spoti" -d "$app/Frameworks/" \
	-p '@executable_path/../Frameworks/' -s "$(brew --prefix)/lib/" < /dev/null

# Signing alone does not check load paths. Reject any dependency outside
# the OS or this bundle before publishing an artifact.
for binary in "$app/MacOS/spoti" "$app/Frameworks/"*.dylib; do
	dependencies=$(otool -L "$binary")
	for dep in $(printf '%s\n' "$dependencies" | awk 'NR>1 {print $1}'); do
		case "$dep" in
			/usr/lib/*|/System/*) ;;
			@executable_path/../Frameworks/*)
				test -f "$app/Frameworks/${dep##*/}" || exit 1 ;;
			*) echo "Unbundled dependency in $binary: $dep" >&2; exit 1 ;;
		esac
	done
done
otool -L "$app/MacOS/spoti"
codesign --force --deep --sign - build/Spoti.app
codesign --verify --strict build/Spoti.app
tar --zstd -cf "$out" -C build Spoti.app
