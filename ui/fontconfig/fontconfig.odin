// System font matching shared by all three desktop targets.
package fontconfig

import "core:c"
import "core:strings"

when ODIN_OS == .Windows {
	foreign import lib "fontconfig.lib"
} else {
	foreign import lib "system:fontconfig"
}

WEIGHT_REGULAR :: 80
WEIGHT_MEDIUM :: 100
WEIGHT_EXTRABOLD :: 205

Config :: struct {}
Pattern :: struct {}
Char_Set :: struct {}

@(default_calling_convention = "c", link_prefix = "Fc")
foreign lib {
	InitLoadConfigAndFonts :: proc() -> ^Config ---
	ConfigDestroy :: proc(config: ^Config) ---
	PatternCreate :: proc() -> ^Pattern ---
	PatternDestroy :: proc(pattern: ^Pattern) ---
	CharSetCreate :: proc() -> ^Char_Set ---
	CharSetDestroy :: proc(set: ^Char_Set) ---
	CharSetAddChar :: proc(set: ^Char_Set, codepoint: u32) -> c.int ---
	PatternAddString :: proc(pattern: ^Pattern, key, value: cstring) -> c.int ---
	PatternAddInteger :: proc(pattern: ^Pattern, key: cstring, value: c.int) -> c.int ---
	PatternAddBool :: proc(pattern: ^Pattern, key: cstring, value: c.int) -> c.int ---
	PatternAddCharSet :: proc(pattern: ^Pattern, key: cstring, set: ^Char_Set) -> c.int ---
	ConfigSubstitute :: proc(config: ^Config, pattern: ^Pattern, kind: c.int) -> c.int ---
	DefaultSubstitute :: proc(pattern: ^Pattern) ---
	FontMatch :: proc(config: ^Config, pattern: ^Pattern, result: ^c.int) -> ^Pattern ---
	PatternGetString :: proc(pattern: ^Pattern, key: cstring, index: c.int, value: ^cstring) -> c.int ---
	PatternGetInteger :: proc(pattern: ^Pattern, key: cstring, index: c.int, value: ^c.int) -> c.int ---
}

// The caller owns the returned path. Ordinary fallback checks scalable
// outlines and glyph coverage; the emoji worker handles color images.
match :: proc(
	config: ^Config,
	codepoint: rune,
	weight: int,
	allocator := context.allocator,
	color_emoji: bool = false,
	family: cstring = "sans-serif",
) -> (
	path: string,
	index: int,
) {
	if config == nil {return}
	pattern := PatternCreate()
	if pattern == nil {return}
	defer PatternDestroy(pattern)
	set := CharSetCreate()
	if set == nil {return}
	defer CharSetDestroy(set)
	if codepoint != 0 {
		if CharSetAddChar(set, u32(codepoint)) == 0 ||
		   PatternAddCharSet(pattern, "charset", set) == 0 {return}
	}
	selected_family: cstring = color_emoji ? "emoji" : family
	property: cstring = color_emoji ? "color" : "outline"
	if PatternAddString(pattern, "family", selected_family) == 0 ||
	   PatternAddInteger(pattern, "weight", c.int(weight)) == 0 ||
	   PatternAddBool(pattern, property, 1) == 0 ||
	   ConfigSubstitute(config, pattern, 0) == 0 {return}
	DefaultSubstitute(pattern)
	result: c.int
	font := FontMatch(config, pattern, &result)
	if font == nil {return}
	defer PatternDestroy(font)
	file: cstring
	face: c.int
	if PatternGetString(font, "file", 0, &file) != 0 {return}
	_ = PatternGetInteger(font, "index", 0, &face)
	return strings.clone(string(file), allocator), int(face)
}
