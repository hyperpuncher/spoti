$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true

# Thin libvorbisfile ABI bridge; all network and playback control stays in Odin.
# Uses the compiler and SDK already installed on the runner.
# SDL's official MSVC dev bundles. Pinned; vcpkg only supplies the ports
# with no upstream Windows bundle (fontconfig, curl, vorbis, webp).
$deps = @{
	'SDL3-3.4.18'     = 'https://github.com/libsdl-org/SDL/releases/download/release-3.4.18/SDL3-devel-3.4.18-VC.zip'
	'SDL3_ttf-3.2.2' = 'https://github.com/libsdl-org/SDL_ttf/releases/download/release-3.2.2/SDL3_ttf-devel-3.2.2-VC.zip'
}
New-Item -ItemType Directory -Force build/deps | Out-Null
foreach ($dir in $deps.Keys) {
	if (Test-Path "build/deps/$dir") { continue }
	$zip = Join-Path $env:TEMP "spoti-$dir.zip"
	curl.exe -sSL --retry 3 -o $zip $deps[$dir]
	tar -xf $zip -C build/deps
}

$root = "$env:VCPKG_INSTALLATION_ROOT/installed/x64-windows"
$vswhere = "${env:ProgramFiles(x86)}/Microsoft Visual Studio/Installer/vswhere.exe"
$vs = & $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
& "$vs/Common7/Tools/Launch-VsDevShell.ps1" -Arch amd64 -HostArch amd64 -SkipAutomaticLocation
cl /nologo /MD /O2 /std:c11 /c "/I$root/include" spotify/audio/vorbisfile.c /Fobuild/vorbisfile.obj
lib /nologo /OUT:build/vorbisfile.a build/vorbisfile.obj

# Compile the app icon resource. Odin's -resource: flag takes the compiled
# .res output, not the .rc source. Rebuild when the script or icon changes.
$rcChanged = !(Test-Path build/app.res) `
	-or (Get-Item packaging/windows/app.rc).LastWriteTime -gt (Get-Item build/app.res).LastWriteTime `
	-or (Get-Item assets/app/icon.ico).LastWriteTime -gt (Get-Item build/app.res).LastWriteTime
if ($rcChanged) { rc /nologo /fo build/app.res packaging/windows/app.rc }
