package ui

import "core:testing"
import sdl "vendor:sdl3"

@(test)
rounded_cover_upload_preserves_pixels_and_row_padding :: proc(t: ^testing.T) {
	W, H, PITCH :: 48, 32, 48 * 4 + 16
	pixels: [H * PITCH]u8 = 77
	for y in 0 ..< H {
		for x in 0 ..< W {
			copy(pixels[y * PITCH + x * 4:][:4], ([]u8{240, 120, 60, 255}))
		}
	}
	target := sdl.CreateSurface(W, H, .RGBA32)
	if !testing.expect(t, target != nil) {return}
	defer sdl.DestroySurface(target)
	renderer := sdl.CreateSoftwareRenderer(target)
	if !testing.expect(t, renderer != nil) {return}
	defer sdl.DestroyRenderer(renderer)
	state := State {
		renderer = renderer,
	}
	texture: ^sdl.Texture
	{
		surface := sdl.CreateSurfaceFrom(W, H, .RGBA32, raw_data(pixels[:]), PITCH)
		if !testing.expect(t, surface != nil) {return}
		defer sdl.DestroySurface(surface)
		// Rounding needs alpha blending even if the source used NONE.
		if !testing.expect(t, sdl.SetSurfaceBlendMode(surface, sdl.BLENDMODE_NONE)) {return}
		round_image_corners(surface)
		for y in 0 ..< H {
			for value in pixels[y * PITCH + W * 4:(y + 1) * PITCH] {testing.expect_value(t, value, u8(77))}
		}
		texture = create_texture(&state, surface)
	}
	if !testing.expect(t, texture != nil) {return}
	defer sdl.DestroyTexture(texture)
	// The uploaded texture must not borrow the released surface's pixels.
	for &value in pixels {value = 0}
	_ = sdl.SetRenderDrawColor(renderer, 0, 0, 0, 255)
	_ = sdl.RenderClear(renderer)
	testing.expect(t, sdl.RenderTexture(renderer, texture, nil, nil))
	_ = sdl.RenderPresent(renderer)
	rgba: [4]u8
	testing.expect(
		t,
		sdl.ReadSurfacePixel(target, W / 2, H / 2, &rgba[0], &rgba[1], &rgba[2], &rgba[3]),
	)
	testing.expect_value(t, rgba, ([4]u8{240, 120, 60, 255}))
	testing.expect(t, sdl.ReadSurfacePixel(target, 0, 0, &rgba[0], &rgba[1], &rgba[2], &rgba[3]))
	testing.expect(t, rgba[0] < 240, "rounded corners must blend with the background")
}
