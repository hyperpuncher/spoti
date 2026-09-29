package ui

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import sdl "vendor:sdl3"
import ttf "vendor:sdl3/ttf"

// Fontconfig returns both the file and FreeType face index. Variable-font named
// instances share one file, so dropping the index silently opens regular.
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
	state.fonts[key] = font
	return font
}
