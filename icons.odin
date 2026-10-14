// Icon textures are rasterized from the vendored Lucide SVGs and tinted at
// load time, so drawing an icon costs one texture blit like a cover.
package main

import c "core:c"
import "core:fmt"
import "core:os"
import filepath "core:path/filepath"
import "core:strings"
import artwork "spotify/artwork"
import library "spotify/library"
import ui "ui"
import sdl "vendor:sdl3"

Icon_Tint :: enum {
	White,
	Muted,
	Green,
	Dark,
	Disabled,
	Hover,
}

ICON_NAMES :: []string {
	"house",
	"bell",
	"search",
	"layout-grid",
	"list",
	"play",
	"play-filled",
	"pause",
	"pause-filled",
	"shuffle",
	"repeat",
	"skip-back",
	"skip-forward",
	"skip-back-filled",
	"skip-forward-filled",
	"pin",
	"pin-filled",
	"pin-off",
	"clock",
	"ellipsis",
	"plus",
	"chevron-left",
	"chevron-right",
	"volume-2",
	"speaker",
	"music",
	"chevrons-up-down",
	"check",
	"list-sort-descending",
	"circle-plus",
	"circle-check",
	"link",
	"external-link",
}

// Tint lives in the texture color mod, not the pixels, so a theme switch
// recolors every icon without redecoding. White and Dark swap sides;
// Muted deepens for contrast on white; the rest read on both.
icon_tint_color :: proc(tint: Icon_Tint, dark: bool) -> (r, g, b: u8) {
	switch tint {
	case .White:
		if dark {return 245, 245, 245}
		return 32, 32, 32
	case .Muted:
		if dark {return 165, 165, 165}
		return 120, 120, 120
	case .Green:
		return 30, 215, 96
	case .Dark:
		if dark {return 12, 12, 12}
		return 245, 245, 245
	case .Disabled:
		return 90, 90, 90
	case .Hover:
		color := dark ? DARK_THEME.footer_hover : LIGHT_THEME.footer_hover
		return u8(color.r), u8(color.g), u8(color.b)
	}
	return 245, 245, 245
}

ICON_TINTS :: [?]Icon_Tint{.White, .Muted, .Green, .Dark, .Disabled, .Hover}

retint_icons :: proc(textures: ^Textures, dark: bool) {
	for name in ICON_NAMES {
		for tint in ICON_TINTS {
			texture := textures.by_key[icon_key(name, tint)]
			if texture == nil {continue}
			r, g, b := icon_tint_color(tint, dark)
			_ = sdl.SetTextureColorMod(texture, r, g, b)
		}
	}
}

icon_key :: proc(name: string, tint: Icon_Tint) -> u64 {
	buffer: [64]u8
	return library.url_key(fmt.bprintf(buffer[:], "icon:%s:%d", name, int(tint)))
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

load_app_icon :: proc(state: ^ui.State) {
	path, found := asset_path("app/icon.png")
	if !found {return}
	defer delete(path)
	encoded, err := os.read_entire_file_from_path(path, context.allocator)
	if err != nil {return}
	defer delete(encoded)
	image, decoded := artwork.decode(encoded)
	if !decoded {return}
	defer artwork.free_image(&image)
	surface := sdl.CreateSurfaceFrom(
		c.int(image.width),
		c.int(image.height),
		.RGBA32,
		raw_data(image.pixels),
		c.int(image.width * 4),
	)
	if surface == nil {return}
	defer sdl.DestroySurface(surface)
	// Wayland compositors without the icon protocol use the desktop entry.
	_ = sdl.SetWindowIcon(state.window, surface)
}

// The artwork package is the only image decoder in the tree, so icons go
// through the same decode path as covers.
load_icons :: proc(state: ^ui.State, textures: ^Textures, dark: bool) {
	load_app_icon(state)
	for name in ICON_NAMES {
		relative := fmt.aprintf("icons/%s.png", name, allocator = context.temp_allocator)
		path, found := asset_path(relative)
		if !found {continue}
		bytes, read_error := os.read_entire_file_from_path(path, context.allocator)
		delete(path)
		if read_error != nil {continue}
		image, decoded := artwork.decode(bytes)
		delete(bytes)
		if !decoded {continue}
		for tint in ICON_TINTS {
			texture := ui.create_texture(state, image.pixels, image.width, image.height)
			if texture != nil {
				r, g, b := icon_tint_color(tint, dark)
				_ = sdl.SetTextureColorMod(texture, r, g, b)
				textures.by_key[icon_key(name, tint)] = texture
			}
		}
		delete(image.pixels)
	}
}
