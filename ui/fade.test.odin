package ui

import "core:math"
import "core:testing"
import sdl "vendor:sdl3"

// The procedural Bayer must match the reference 8x8 ordered matrix:
// each level adds its quadrant offset below the finer bits.
@(test)
fade_bayer_matches_reference :: proc(t: ^testing.T) {
	reference := [8][8]u8 {
		{0, 32, 8, 40, 2, 34, 10, 42},
		{48, 16, 56, 24, 50, 18, 58, 26},
		{12, 44, 4, 36, 14, 46, 6, 38},
		{60, 28, 52, 20, 62, 30, 54, 22},
		{3, 35, 11, 43, 1, 33, 9, 41},
		{51, 19, 59, 27, 49, 17, 57, 25},
		{15, 47, 7, 39, 13, 45, 5, 37},
		{63, 31, 55, 23, 61, 29, 53, 21},
	}
	for y in 0 ..< 8 {
		for x in 0 ..< 8 {
			testing.expect(t, bayer_value(x, y) == reference[y][x], "bayer drift")
		}
	}
	// Tiling repeats every 8 texels in both axes.
	testing.expect(t, bayer_value(8, 0) == bayer_value(0, 0))
	testing.expect(t, bayer_value(3, 71) == bayer_value(3, 7))
}

@(test)
banner_crop_fills_the_header_without_stretching :: proc(t: ^testing.T) {
	for size in ([][4]f32{{2660, 1496, 1600, 360}, {600, 1200, 900, 400}}) {
		crop := crop_source_rect(size[0], size[1], size[2], size[3])
		testing.expect(t, crop.x >= 0 && crop.y >= 0)
		testing.expect(t, crop.x + crop.w <= size[0] && crop.y + crop.h <= size[1])
		testing.expect(t, math.abs(crop.w / crop.h - size[2] / size[3]) < 0.001)
		testing.expect_value(t, crop.x * 2 + crop.w, size[0])
		testing.expect_value(t, crop.y * 2 + crop.h, size[1])
	}
}

@(test)
rounded_controls_have_level_edges_and_symmetric_corners :: proc(t: ^testing.T) {
	surface := sdl.CreateSurface(800, 200, .RGBA32)
	if !testing.expect(t, surface != nil) {return}
	defer sdl.DestroySurface(surface)
	renderer := sdl.CreateSoftwareRenderer(surface)
	if !testing.expect(t, renderer != nil) {return}
	defer sdl.DestroyRenderer(renderer)
	state := State {
		renderer = renderer,
		masks    = make(map[u64]Rounded_Mask),
	}
	defer {
		for _, mask in state.masks {sdl.DestroyTexture(mask.texture)}
		delete(state.masks)
	}
	// This wide button previously had a step in its bottom edge.
	W, H, R :: 744, 60, 30
	_ = sdl.SetRenderDrawColor(renderer, 0, 0, 0, 255)
	_ = sdl.RenderClear(renderer)
	fill_rounded(&state, {10.25, 10.25, W, H}, {R, R, R, R}, {255, 255, 255, 255})
	_ = sdl.RenderPresent(renderer)
	pixels := ([^]u8)(surface.pixels)
	for x in R ..< W - R {
		for y in ([]int{0, H - 1}) {
			testing.expect_value(t, pixels[(10 + y) * int(surface.pitch) + (10 + x) * 4], 255)
		}
	}
	partial := false
	for y in 0 ..< R {
		for x in 0 ..< R {
			value := pixels[(10 + y) * int(surface.pitch) + (10 + x) * 4]
			partial ||= value > 0 && value < 255
			testing.expect_value(
				t,
				value,
				pixels[(10 + y) * int(surface.pitch) + (10 + W - 1 - x) * 4],
			)
			testing.expect_value(
				t,
				value,
				pixels[(10 + H - 1 - y) * int(surface.pitch) + (10 + x) * 4],
			)
		}
	}
	testing.expect(t, partial, "curves must have antialiased pixels")
}

@(test)
cropped_banner_rounds_only_the_displayed_top_corners :: proc(t: ^testing.T) {
	surface := sdl.CreateSurface(24, 24, .RGBA32)
	if !testing.expect(t, surface != nil) {return}
	defer sdl.DestroySurface(surface)
	renderer := sdl.CreateSoftwareRenderer(surface)
	if !testing.expect(t, renderer != nil) {return}
	defer sdl.DestroyRenderer(renderer)
	state := State {
		renderer = renderer,
		masks    = make(map[u64]Rounded_Mask),
	}
	defer {
		for _, mask in state.masks {sdl.DestroyTexture(mask.texture)}
		delete(state.masks)
	}
	_ = sdl.SetRenderDrawColor(renderer, 255, 255, 255, 255)
	_ = sdl.RenderClear(renderer)
	mask_top_corners(&state, {0, 0, 24, 24}, 8, {0, 0, 0, 255})
	_ = sdl.RenderPresent(renderer)
	pixels := ([^]u8)(surface.pixels)
	testing.expect_value(t, pixels[0], 0)
	testing.expect_value(t, pixels[23 * 4], 0)
	testing.expect_value(t, pixels[12 * 4], 255)
	testing.expect_value(t, pixels[23 * int(surface.pitch)], 255)
}
