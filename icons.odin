// Icon textures are rasterized from the vendored Lucide SVGs and tinted at
// load time, so drawing an icon costs one texture blit like a cover.
package main

import "core:fmt"
import "core:os"
import artwork "spotify/artwork"
import library "spotify/library"
import ui "ui"

Icon_Tint :: enum {
	White,
	Muted,
	Green,
	Dark,
	Disabled,
}

ICON_NAMES :: []string {
	"house",
	"search",
	"library",
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
	"heart",
	"pin",
	"pin-filled",
	"pin-off",
	"clock",
	"ellipsis",
	"plus",
	"chevron-left",
	"chevron-right",
	"volume-2",
	"music",
	"chevrons-up-down",
	"check",
	"list-sort-descending",
}

icon_tint_color :: proc(tint: Icon_Tint) -> (r, g, b: u8) {
	switch tint {
	case .White:
		return 245, 245, 245
	case .Muted:
		return 165, 165, 165
	case .Green:
		return 30, 215, 96
	case .Dark:
		return 12, 12, 12
	case .Disabled:
		return 90, 90, 90
	}
	return 245, 245, 245
}

icon_key :: proc(name: string, tint: Icon_Tint) -> u64 {
	buffer: [64]u8
	return library.url_key(fmt.bprintf(buffer[:], "icon:%s:%d", name, int(tint)))
}

// The artwork package is the only image decoder in the tree, so icons go
// through the same decode path as covers.
load_icons :: proc(state: ^ui.State, textures: ^Textures) {
	for name in ICON_NAMES {
		path := fmt.aprintf("build/icons/%s.png", name)
		bytes, read_error := os.read_entire_file_from_path(path, context.allocator)
		delete(path)
		if read_error != nil {continue}
		image, decoded := artwork.decode(bytes)
		delete(bytes)
		if !decoded {continue}
		for tint in ([]Icon_Tint{.White, .Muted, .Green, .Dark, .Disabled}) {
			r, g, b := icon_tint_color(tint)
			tinted := make([]u8, len(image.pixels))
			for i := 0; i + 3 < len(image.pixels); i += 4 {
				tinted[i + 0] = u8(u32(image.pixels[i + 0]) * u32(r) / 255)
				tinted[i + 1] = u8(u32(image.pixels[i + 1]) * u32(g) / 255)
				tinted[i + 2] = u8(u32(image.pixels[i + 2]) * u32(b) / 255)
				tinted[i + 3] = image.pixels[i + 3]
			}
			texture := ui.create_texture(state, tinted, image.width, image.height)
			delete(tinted)
			if texture != nil {textures.by_key[icon_key(name, tint)] = texture}
		}
		delete(image.pixels)
	}
}
