#!/usr/bin/env bash
set -euo pipefail
version=${1:?release version required}
archives=${2:?Linux archive directory required}
out=${3:?output directory required}
[[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "expected a stable release version" >&2; exit 1; }
checksum_x86_64=$(sha256sum "$archives/spoti-linux-x64.tar.zst")
checksum_aarch64=$(sha256sum "$archives/spoti-linux-arm64.tar.zst")
mkdir -p "$out/spoti-bin" "$out/spoti-git"
sed -e "s/@VERSION@/$version/g" \
	-e "s/@SHA256_X86_64@/${checksum_x86_64%% *}/g" \
	-e "s/@SHA256_AARCH64@/${checksum_aarch64%% *}/g" \
	packaging/aur/spoti-bin/PKGBUILD.in > "$out/spoti-bin/PKGBUILD"
cp packaging/aur/spoti-git/PKGBUILD "$out/spoti-git/PKGBUILD"
for package in spoti-bin spoti-git; do
	(cd "$out/$package" && makepkg --printsrcinfo > .SRCINFO)
done
