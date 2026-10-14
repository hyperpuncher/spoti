$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true

# Thin libvorbisfile ABI bridge; all network and playback control stays in Odin.
# Uses the compiler and SDK already installed on the runner.
$root = "$env:VCPKG_INSTALLATION_ROOT/installed/x64-windows"
$vswhere = "${env:ProgramFiles(x86)}/Microsoft Visual Studio/Installer/vswhere.exe"
$vs = & $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
& "$vs/Common7/Tools/Launch-VsDevShell.ps1" -Arch amd64 -HostArch amd64 -SkipAutomaticLocation
cl /nologo /MD /O2 /std:c11 /c "/I$root/include" spotify/audio/vorbisfile.c /Fobuild/vorbisfile.obj
lib /nologo /OUT:build/vorbisfile.a build/vorbisfile.obj
