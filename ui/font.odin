package ui

import "core:fmt"
import "core:os"
import filepath "core:path/filepath"
import "core:strconv"
import "core:strings"
import "core:unicode"
import fontconfig "fontconfig"
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
GEIST_FACE_EXTRA_BOLD :: (8 << 16)

FONT_ROLE_COUNT :: u16(len([Font_Role]Font_Source{}))

Font_Source :: struct {
	path:  string,
	index: int,
}

// SDL_ttf appends duplicate fallback entries. Track attached pairs so one
// primary font is never given the same fallback twice.
Font_Pair :: struct {
	primary, fallback: ^ttf.Font,
}

resolve_fallbacks :: proc(state: ^State) {
	state.font_config = fontconfig.InitLoadConfigAndFonts()
	state.fallback_sources = make([dynamic]Font_Source)
	state.fallback_matches = make(map[u64]int)
	state.fallback_added = make(map[Font_Pair]bool)
}

// Assets resolve around the executable before the development checkout.
// The returned path is owned; candidate strings use the frame allocator.
asset_path :: proc(relative: string) -> (path: string, ok: bool) {
	if exe, err := os.get_executable_path(context.temp_allocator); err == nil {
		dir := filepath.dir(string(exe))
		for root in ([]string{"../Resources", "../share/spoti", ".", "assets", "../assets"}) {
			candidate := fmt.aprintf(
				"%s/%s/%s",
				dir,
				root,
				relative,
				allocator = context.temp_allocator,
			)
			if os.exists(candidate) {return strings.clone(candidate), true}
		}
	}
	candidate := fmt.aprintf("assets/%s", relative, allocator = context.temp_allocator)
	if os.exists(candidate) {return strings.clone(candidate), true}
	return "", false
}

// An existing override wins; all other font paths use the asset lookup.
resolve_bundled :: proc(file: string) -> (path: string, ok: bool) {
	if override, found := os.lookup_env("SPOTI_FONTS", context.temp_allocator); found {
		candidate := fmt.aprintf("%s/%s", override, file, allocator = context.temp_allocator)
		if os.exists(candidate) {return strings.clone(candidate), true}
	}
	return asset_path(fmt.aprintf("fonts/%s", file, allocator = context.temp_allocator))
}

// Bundled faces first; Linux falls back to fontconfig when the checkout
// ships without them. Other platforms have no system fallback: without
// the bundle there is nothing legible to fall back to.
resolve_role :: proc(role: Font_Role) -> (path: string, index: int, ok: bool) {
	file := GEIST_VAR
	face := GEIST_FACE_REGULAR
	family: cstring = "sans-serif"
	weight := fontconfig.WEIGHT_REGULAR
	switch role {
	case .Regular:
	case .Numeric:
		file, face, family = GEIST_MONO, 0, "monospace"
	case .Bold:
		face, weight = GEIST_FACE_EXTRA_BOLD, fontconfig.WEIGHT_EXTRABOLD
	case .Medium:
		face, weight = GEIST_FACE_MEDIUM, fontconfig.WEIGHT_MEDIUM
	}
	if bundled, found := resolve_bundled(file); found {return bundled, face, true}
	when ODIN_OS == .Linux {
		config := fontconfig.InitLoadConfigAndFonts()
		if config == nil {return}
		defer fontconfig.ConfigDestroy(config)
		path, index = fontconfig.match(config, 0, weight, family = family)
		return path, index, path != ""
	} else {
		fmt.eprintln("missing bundled font:", file)
		return "", 0, false
	}
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
	source: Font_Source
	if font_id < FONT_ROLE_COUNT {
		source = state.font_sources[Font_Role(font_id)]
	} else {
		index := int(font_id - FONT_ROLE_COUNT)
		if index >= len(state.fallback_sources) {return nil}
		source = state.fallback_sources[index]
	}
	font := open_font(source, f32(size_key) / 8, state.hinting)
	if font != nil {state.fonts[key] = font}
	return font
}

// The caller owns the font. The source path is only borrowed while opening.
open_font :: proc(source: Font_Source, size: f32, hinting: ttf.Hinting = .NORMAL) -> ^ttf.Font {
	if source.path == "" {return nil}
	c_path := strings.clone_to_cstring(source.path)
	defer delete(c_path)
	props := sdl.CreateProperties()
	if props == 0 {return nil}
	defer sdl.DestroyProperties(props)
	_ = sdl.SetStringProperty(props, ttf.PROP_FONT_CREATE_FILENAME_STRING, c_path)
	_ = sdl.SetFloatProperty(props, ttf.PROP_FONT_CREATE_SIZE_FLOAT, size)
	_ = sdl.SetNumberProperty(props, ttf.PROP_FONT_CREATE_FACE_NUMBER, sdl.Sint64(source.index))
	font := ttf.OpenFontWithProperties(props)
	if font == nil {fmt.eprintln("could not load font:", source.path); return nil}
	ttf.SetFontHinting(font, hinting)
	return font
}

// Resolve only characters the primary font and its attached fallbacks lack.
// Sources are shared across sizes; failed matches are cached as well.
font_for_text :: proc(state: ^State, value: string, size: f32, font_id: u16 = 0) -> ^ttf.Font {
	font := font_for_size(state, size, font_id)
	if font == nil {return nil}
	for character in value {
		if character < ' ' || ttf.FontHasGlyph(font, u32(character)) {continue}
		key := u64(u32(character)) << 16 | u64(font_id)
		index, found := state.fallback_matches[key]
		if !found {
			weight := fontconfig.WEIGHT_REGULAR
			// Fallback symbols keep their designed outline instead of taking
			// the title's bold weight. Script letters still follow the role.
			if !unicode.is_symbol(character) {
				if font_id == u16(Font_Role.Bold) {weight = fontconfig.WEIGHT_EXTRABOLD}
				if font_id == u16(Font_Role.Medium) {weight = fontconfig.WEIGHT_MEDIUM}
			}
			path, face := fontconfig.match(
				state.font_config,
				character,
				weight,
				state.fallback_sources.allocator,
			)
			index = -1
			if path != "" {
				for source, candidate in state.fallback_sources {
					if source.path == path && source.index == face {index = candidate; break}
				}
				if index < 0 {
					index = len(state.fallback_sources)
					append(&state.fallback_sources, Font_Source{path, face})
				} else {delete(path, state.fallback_sources.allocator)}
			}
			state.fallback_matches[key] = index
		}
		if index < 0 {continue}
		fallback := font_for_size(state, size, FONT_ROLE_COUNT + u16(index))
		if fallback == nil ||
		   !ttf.FontIsScalable(fallback) ||
		   !ttf.FontHasGlyph(fallback, u32(character)) {
			state.fallback_matches[key] = -1
			continue
		}
		pair := Font_Pair{font, fallback}
		if state.fallback_added[pair] {continue}
		if ttf.AddFallbackFont(font, fallback) {
			state.fallback_added[pair] = true
		} else {fmt.eprintln("could not add font fallback:", sdl.GetError())}
	}
	return font
}
