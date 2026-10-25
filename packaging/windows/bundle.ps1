param([Parameter(Mandatory = $true)][string]$Out)
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
# Windows test archive: binary, DLLs, fontconfig data, plus only the files
# the binary reads at runtime and the files the license texts require.
# The ICO is already embedded in the exe via app.rc. SVG sources, ICNS,
# and markdown docs stay in the repo and are never shipped.
Copy-Item build/deps/SDL3-3.4.18/lib/x64/SDL3.dll build/ -Force
Copy-Item build/deps/SDL3_ttf-3.2.2/lib/x64/SDL3_ttf.dll build/ -Force
Copy-Item "$env:VCPKG_INSTALLATION_ROOT/installed/x64-windows/bin/*.dll" build/ -Force
if (Test-Path build/fontconfig) { Remove-Item build/fontconfig -Recurse -Force }
Copy-Item "$env:VCPKG_INSTALLATION_ROOT/installed/x64-windows/etc/fonts" build/fontconfig -Recurse -Force
$files = @('build/spoti.exe', 'build/fontconfig') + `
  (Get-ChildItem build/*.dll | ForEach-Object { 'build/' + $_.Name }) + `
  (Get-ChildItem assets/icons/*.png | ForEach-Object { 'assets/icons/' + $_.Name }) + `
  @('assets/icons/LICENSE') + `
  (Get-ChildItem assets/fonts/*.ttf | ForEach-Object { 'assets/fonts/' + $_.Name }) + `
  @('assets/fonts/OFL.txt', 'assets/app/icon.png', 'LICENSE', `
    'spotify/shannon/LICENSE', 'vendor/clay/LICENSE.md', 'docs/licenses/unicode.txt', 'docs/licenses/curl.txt', 'docs/licenses/stb_vorbis.txt')
tar --zstd -cf $Out $files
