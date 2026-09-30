package artwork

import "core:c"

foreign import libwebp "system:webp"

@(private, default_calling_convention = "c")
foreign libwebp {
	WebPGetInfo :: proc(data: [^]u8, size: c.size_t, width, height: ^c.int) -> c.int ---
	WebPDecodeRGBAInto :: proc(data: [^]u8, size: c.size_t, output: [^]u8, output_size: c.size_t, stride: c.int) -> [^]u8 ---
}

decode_webp :: proc(encoded: []u8) -> (image: Image, ok: bool) {
	width, height: c.int
	if WebPGetInfo(raw_data(encoded), c.size_t(len(encoded)), &width, &height) == 0 {return}
	if width <= 0 || height <= 0 || width > MAX_DIMENSION || height > MAX_DIMENSION {return}
	pixels := make([]u8, int(width) * int(height) * 4)
	if WebPDecodeRGBAInto(
		   raw_data(encoded),
		   c.size_t(len(encoded)),
		   raw_data(pixels),
		   c.size_t(len(pixels)),
		   width * 4,
	   ) ==
	   nil {
		delete(pixels)
		return
	}
	return Image{pixels = pixels, width = int(width), height = int(height)}, true
}
