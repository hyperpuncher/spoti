#!/usr/bin/env bash
set -euo pipefail
version=${1:?release version required}
archive=${2:?Linux archive required}
out=${3:?output directory required}
[[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "expected a stable release version" >&2; exit 1; }
checksum=$(sha256sum "$archive")
checksum=${checksum%% *}
mkdir -p "$out/spoti-bin" "$out/spoti-git"
sed -e "s/@VERSION@/$version/g" -e "s/@SHA256@/$checksum/g" \
	packaging/aur/spoti-bin/PKGBUILD.in > "$out/spoti-bin/PKGBUILD"
cp packaging/aur/spoti-git/PKGBUILD "$out/spoti-git/PKGBUILD"
for package in spoti-bin spoti-git; do
	(cd "$out/$package" && makepkg --printsrcinfo > .SRCINFO)
done
