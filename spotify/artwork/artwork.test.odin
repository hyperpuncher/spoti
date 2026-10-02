package artwork

import "core:testing"

@(test)
webp_cover_preserves_dimensions_pixels_and_alpha :: proc(t: ^testing.T) {
	// Lossless 2x2 synthetic RGBA image, generated with libwebp.
	encoded := []u8 {
		0x52,
		0x49,
		0x46,
		0x46,
		0x30,
		0,
		0,
		0,
		0x57,
		0x45,
		0x42,
		0x50,
		0x56,
		0x50,
		0x38,
		0x4c,
		0x23,
		0,
		0,
		0,
		0x2f,
		0x01,
		0x40,
		0,
		0x10,
		0x1f,
		0x20,
		0x10,
		0x48,
		0xde,
		0x1f,
		0x3a,
		0x8d,
		0xf9,
		0x17,
		0x10,
		0x14,
		0xfc,
		0x1f,
		0x9d,
		0x80,
		0xa0,
		0x68,
		0xba,
		0xe7,
		0x22,
		0x66,
		0x0f,
		0xc2,
		0x0d,
		0x18,
		0x22,
		0xfa,
		0x1f,
		0x02,
		0,
	}
	image, ok := decode(encoded)
	defer free_image(&image)
	testing.expect(t, ok)
	testing.expect_value(t, image.width, 2)
	testing.expect_value(t, image.height, 2)
	expected := []u8{255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255, 255, 255, 255, 127}
	testing.expect_value(t, len(image.pixels), len(expected))
	for pixel, i in image.pixels {testing.expect_value(t, pixel, expected[i])}
	for length in ([]int{0, 12, 24, len(encoded) - 4}) {
		invalid, valid := decode(encoded[:length])
		defer free_image(&invalid)
		testing.expect(
			t,
			!valid && len(invalid.pixels) == 0,
			"truncated WebP must not leak partial images",
		)
	}
}
