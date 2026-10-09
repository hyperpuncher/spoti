package ui

import "core:fmt"
import "core:os"
import filepath "core:path/filepath"
import "core:strconv"
import "core:strings"
import sdl "vendor:sdl3"
import ttf "vendor:sdl3/ttf"

// Product typography is the vendored Geist pair in assets/fonts, so every
// platform renders the same faces. The variable font carries the weights
// as named instances; the ids below are properties of that file.
Font_Role :: enum {
	Regular,
	Numeric,
	Bold,
	Medium,
}

GEIST_VAR :: "Geist[wght].ttf"
GEIST_MONO :: "GeistMono-Regular.ttf"
GEIST_FACE_REGULAR :: 0
GEIST_FACE_MEDIUM :: (5 << 16)
GEIST_FACE_BOLD :: (7 << 16)

// First existing file wins: an override dir, the install layout around
// the binary, then the dev checkout. The caller owns the returned path.
resolve_bundled :: proc(file: string) -> (path: string, ok: bool) {
	candidates := make([dynamic]string, context.temp_allocator)
	if override, found := os.lookup_env("SPOTI_FONTS", context.temp_allocator); found {
		append(&candidates, fmt.aprintf("%s/%s", override, file))
	}
	if exe, err := os.get_executable_path(context.temp_allocator); err == nil {
		dir := filepath.dir(string(exe))
		append(&candidates, fmt.aprintf("%s/../share/spoti/fonts/%s", dir, file))
		append(&candidates, fmt.aprintf("%s/fonts/%s", dir, file))
	}
	append(&candidates, fmt.aprintf("assets/fonts/%s", file))
	for candidate in candidates {
		if os.exists(candidate) {return strings.clone(candidate), true}
	}
	return "", false
}

// Bundled faces first; Linux falls back to fontconfig when the checkout
// ships without them. Other platforms have no system fallback: without
// the bundle there is nothing legible to fall back to.
resolve_role :: proc(role: Font_Role) -> (path: string, index: int, ok: bool) {
	file := GEIST_VAR
	face := GEIST_FACE_REGULAR
	pattern := "sans-serif"
	switch role {
	case .Regular:
	case .Numeric:
		file, face, pattern = GEIST_MONO, 0, "monospace"
	case .Bold:
		face, pattern = GEIST_FACE_BOLD, "sans-serif:style=Bold"
	case .Medium:
		face, pattern = GEIST_FACE_MEDIUM, "sans-serif:style=Medium"
	}
	if bundled, found := resolve_bundled(file); found {return bundled, face, true}
	when ODIN_OS == .Linux {
		return resolve_font(pattern)
	} else {
		fmt.eprintln("missing bundled font:", file)
		return "", 0, false
	}
}
resolve_font :: proc(pattern: string) -> (path: string, index: int, ok: bool) {
	state, output, errors, err := os.process_exec(
		{command = {"fc-match", "-f", "%{file}\n%{index}\n", pattern}},
		context.allocator,
	)
	defer delete(output)
	defer delete(errors)
	if err != nil || !state.exited || state.exit_code != 0 {
		fmt.eprintln("could not find a system font with fc-match:", err)
		return
	}
	fields := strings.fields(string(output))
	defer delete(fields)
	if len(fields) < 2 {return}
	face, parsed := strconv.parse_int(fields[1])
	if !parsed {return}
	path = strings.clone(fields[0])
	return path, face, len(path) > 0
}

// Read the desktop's fontconfig hinting so text matches system apps.
// Falls back to normal hinting when fontconfig is unavailable. Subpixel
// (rgba) has no SDL GPU-text equivalent, so system text stays slightly
// darker; shapes and spacing follow the configured hinter.
system_hinting :: proc() -> ttf.Hinting {
	// Only Linux desktops expose fontconfig; elsewhere SDL's default stands.
	when ODIN_OS != .Linux {return .NORMAL}
	state, output, errors, err := os.process_exec(
		{command = {"fc-match", "-f", "%{hinting} %{hintstyle} %{antialias}\n", "sans-serif"}},
		context.allocator,
	)
	defer delete(output)
	defer delete(errors)
	if err != nil || !state.exited || state.exit_code != 0 {return .NORMAL}
	fields := strings.fields(string(output))
	defer delete(fields)
	if len(fields) < 3 {return .NORMAL}
	if !strings.equal_fold(fields[2], "true") && fields[2] != "1" {return .MONO}
	if !strings.equal_fold(fields[0], "true") && fields[0] != "1" {return .NONE}
	style, parsed := strconv.parse_int(fields[1])
	if !parsed || style <= 0 {return .NONE}
	if style == 1 || style == 2 {return .LIGHT}
	return .NORMAL
}

font_for_size :: proc(state: ^State, size: f32, font_id: u16 = 0) -> ^ttf.Font {
	size_key := max(1, int(size * 8 + 0.5))
	key := size_key | int(font_id) << 24
	if font, found := state.fonts[key]; found {return font}
	path, face := state.font_path, state.font_index
	switch font_id {
	case 1:
		path, face = state.numeric_font_path, state.numeric_font_index
	case 2:
		path, face = state.bold_font_path, state.bold_font_index
	case 3:
		path, face = state.medium_font_path, state.medium_font_index
	}
	c_path := strings.clone_to_cstring(path)
	defer delete(c_path)
	props := sdl.CreateProperties()
	if props == 0 {return nil}
	defer sdl.DestroyProperties(props)
	_ = sdl.SetStringProperty(props, ttf.PROP_FONT_CREATE_FILENAME_STRING, c_path)
	_ = sdl.SetFloatProperty(props, ttf.PROP_FONT_CREATE_SIZE_FLOAT, f32(size_key) / 8)
	_ = sdl.SetNumberProperty(props, ttf.PROP_FONT_CREATE_FACE_NUMBER, sdl.Sint64(face))
	font := ttf.OpenFontWithProperties(props)
	if font == nil {
		fmt.eprintln("could not load system font:", path)
		return nil
	}
	ttf.SetFontHinting(font, state.hinting)
	state.fonts[key] = font
	return font
}
