package main

import "core:fmt"
import "core:os"
import "core:testing"
import artwork "spotify/artwork"
import ui "ui"
import sdl "vendor:sdl3"

@(test)
pressed_icons_keep_their_center_when_dimensions_round :: proc(t: ^testing.T) {
	// Cross the even/odd pixel boundary with a fractional center.
	for size in ([]f32{20.4, 20.6}) {
		rect := icon_rect({101.25 - size / 2, 81.5 - size / 2, size, size})
		testing.expect_value(t, rect.x + rect.w / 2, f32(101.25))
		testing.expect_value(t, rect.y + rect.h / 2, f32(81.5))
	}
}

@(test)
svg_icons_decode_to_white_tint_masks :: proc(t: ^testing.T) {
	surface := sdl.CreateSurface(1, 1, .RGBA32)
	if !testing.expect(t, surface != nil) {return}
	defer sdl.DestroySurface(surface)
	renderer := sdl.CreateSoftwareRenderer(surface)
	if !testing.expect(t, renderer != nil) {return}
	defer sdl.DestroyRenderer(renderer)
	state := ui.State {
		renderer = renderer,
	}
	textures := Textures {
		by_key = make(map[u64]^sdl.Texture),
	}
	defer {
		for _, texture in textures.by_key {sdl.DestroyTexture(texture)}
		delete(textures.by_key)
	}
	for density in ([]f32{1, 3, 1}) {
		state.density = density
		load_icons(&state, &textures)
		for name in ICON_NAMES {
			width, height: f32
			if !testing.expect(
				t,
				sdl.GetTextureSize(textures.by_key[icon_key(name)], &width, &height),
				name,
			) {return}
			testing.expect_value(t, width, density == 3 ? f32(72) : f32(48))
			testing.expect_value(t, height, width)
		}
	}
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
