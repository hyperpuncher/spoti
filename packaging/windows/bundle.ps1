param([Parameter(Mandatory = $true)][string]$Out)
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
# Windows test archive: binary, DLLs, fontconfig data, plus only the files
# the binary reads at runtime and the files the license texts require.
# The ICO is embedded in the exe via app.rc. UI SVGs are runtime assets;
# app icon sources, ICNS, and markdown docs stay in the repo.
Copy-Item build/deps/SDL3-3.4.18/lib/x64/SDL3.dll build/ -Force
Copy-Item build/deps/SDL3_ttf-3.2.2/lib/x64/SDL3_ttf.dll build/ -Force
Copy-Item build/deps/SDL3_image-3.4.8/lib/x64/SDL3_image.dll build/ -Force
# SDL_image loads its WebP codecs at runtime, so DLL import scans miss them.
Copy-Item build/deps/SDL3_image-3.4.8/lib/x64/optional/libwebp*.dll build/ -Force
Copy-Item "$env:VCPKG_INSTALLATION_ROOT/installed/x64-windows/bin/*.dll" build/ -Force
if (Test-Path build/fontconfig) { Remove-Item build/fontconfig -Recurse -Force }
Copy-Item "$env:VCPKG_INSTALLATION_ROOT/installed/x64-windows/etc/fonts" build/fontconfig -Recurse -Force
$files = @('build/spoti.exe', 'build/fontconfig') + `
  (Get-ChildItem build/*.dll | ForEach-Object { 'build/' + $_.Name }) + `
  (Get-ChildItem assets/icons/*.svg | ForEach-Object { 'assets/icons/' + $_.Name }) + `
  @('assets/icons/LICENSE') + `
  (Get-ChildItem assets/fonts/*.ttf | ForEach-Object { 'assets/fonts/' + $_.Name }) + `
  @('assets/fonts/OFL.txt', 'assets/app/icon.png', 'LICENSE', `
    'spotify/shannon/LICENSE', 'vendor/clay/LICENSE.md') + `
  (Get-ChildItem docs/licenses/*.txt | ForEach-Object { 'docs/licenses/' + $_.Name })
tar --zstd -cf $Out $files
