package ui

import "core:testing"

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
