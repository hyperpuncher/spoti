// Decode covers and local icons to owned SDL surfaces.
package artwork

import "core:c"
import sdl "vendor:sdl3"
import img "vendor:sdl3/image"

// Artist header images are 2660 pixels wide; retain a bounded 4096 limit.
MAX_DIMENSION :: 4096

// One owner transfers this surface from the cover worker to the UI.
// RGBA32/sRGB keeps alpha available for rounded covers and direct upload.
// Rows use the SDL pitch.
Image :: ^sdl.Surface

free_image :: proc(image: ^Image) {
	sdl.DestroySurface(image^)
	image^ = nil
}

// A positive svg_size fits a local SVG within that width and height.
decode :: proc(encoded: []u8, svg_size: int = 0) -> (image: Image, ok: bool) {
	if len(encoded) == 0 || svg_size < 0 || svg_size > MAX_DIMENSION {return}
	stream := sdl.IOFromConstMem(raw_data(encoded), uint(len(encoded)))
	if stream == nil {return}
	defer _ = sdl.CloseIO(stream)
	surface :=
		svg_size > 0 ? img.LoadSizedSVG_IO(stream, c.int(svg_size), c.int(svg_size)) : img.Load_IO(stream, false)
	if surface == nil {return}
	if surface.w <= 0 || surface.h <= 0 || surface.w > MAX_DIMENSION || surface.h > MAX_DIMENSION {
		sdl.DestroySurface(surface)
		return
	}
	if surface.format != .RGBA32 || sdl.GetSurfaceColorspace(surface) != .SRGB {
		rgba := sdl.ConvertSurfaceAndColorspace(surface, .RGBA32, nil, .SRGB, 0)
		sdl.DestroySurface(surface)
		surface = rgba
	}
	return surface, surface != nil
}

// A cover URL is a plain https address from Spotify's image hosts, which
// include i.scdn.co, mosaic.scdn.co and image-cdn-*.spotifycdn.com.
valid_cover_url :: proc(url: string) -> bool {
	return len(url) >= 8 && len(url) <= 512 && url[:8] == "https://"
}
