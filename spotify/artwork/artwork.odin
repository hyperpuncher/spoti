// Decode album and playlist covers to RGBA for SDL3 textures.
package artwork

import "core:c"
import stb "vendor:stb/image"

MAX_DIMENSION :: 2048

Image :: struct {
	pixels: []u8,
	width:  int,
	height: int,
}

free_image :: proc(image: ^Image) {
	delete(image.pixels)
	image^ = {}
}

decode :: proc(encoded: []u8) -> (image: Image, ok: bool) {
	if len(encoded) == 0 {return}
	width, height, channels: c.int
	data := stb.load_from_memory(
		raw_data(encoded),
		c.int(len(encoded)),
		&width,
		&height,
		&channels,
		4,
	)
	if data == nil {return}
	defer stb.image_free(data)
	if width <= 0 || height <= 0 || width > MAX_DIMENSION || height > MAX_DIMENSION {return}
	size := int(width) * int(height) * 4
	pixels := make([]u8, size)
	copy(pixels, data[:size])
	return Image{pixels = pixels, width = int(width), height = int(height)}, true
}

// A cover URL is a plain https address from Spotify's image hosts, which
// include i.scdn.co, mosaic.scdn.co and image-cdn-*.spotifycdn.com.
valid_cover_url :: proc(url: string) -> bool {
	return len(url) >= 8 && len(url) <= 512 && url[:8] == "https://"
}
