package main

import "core:fmt"
import "core:os"
import "core:testing"
import artwork "spotify/artwork"
import sdl "vendor:sdl3"

@(test)
svg_icons_decode_to_white_tint_masks :: proc(t: ^testing.T) {
	for name in ICON_NAMES {
		path := fmt.aprintf("assets/icons/%s.svg", name)
		defer delete(path)
		encoded, err := os.read_entire_file(path, context.allocator)
		if !testing.expect(t, err == nil, path) {return}
		defer delete(encoded)
		image, decoded := artwork.decode(encoded, svg_size = ICON_SIZE)
		if !testing.expect(t, decoded, path) {return}
		defer artwork.free_image(&image)
		testing.expect_value(t, int(image.w), ICON_SIZE)
		testing.expect_value(t, int(image.h), ICON_SIZE)
		visible, transparent := false, false
		for y in 0 ..< image.h {
			for x in 0 ..< image.w {
				rgba: [4]u8
				if !testing.expect(
					t,
					sdl.ReadSurfacePixel(image, x, y, &rgba[0], &rgba[1], &rgba[2], &rgba[3]),
				) {return}
				if rgba[3] == 0 {transparent = true; continue}
				visible = true
				for channel in rgba[:3] {testing.expect_value(t, channel, u8(255))}
			}
		}
		testing.expect(t, visible && transparent, path)
	}
}
