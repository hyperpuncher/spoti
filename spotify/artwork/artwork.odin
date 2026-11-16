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

// Apply a small antialiased rounded alpha edge once at the source image's
// native resolution. This avoids SDL_RenderGeometry's non-antialiased edge and
// remains smooth at every destination size.
// Runs on the cover worker, so uploads only copy pixels.
round_corners :: proc(surface: ^sdl.Surface) {
	if surface == nil || surface.format != .RGBA32 || !sdl.LockSurface(surface) {return}
	defer sdl.UnlockSurface(surface)
	width, height, pitch := int(surface.w), int(surface.h), int(surface.pitch)
	pixels := ([^]u8)(surface.pixels)[:pitch * height]
	radius := max(2, int(f32(min(width, height)) * 0.045 + 0.5))
	samples: int = 4
	for y in 0 ..< height {
		corner_y := y < radius || y >= height - radius
		if !corner_y {continue}
		for x in 0 ..< width {
			if x >= radius && x < width - radius {continue}
			covered := 0
			for sy in 0 ..< samples {
				for sx in 0 ..< samples {
					px := f32(x) + (f32(sx) + 0.5) / f32(samples)
					py := f32(y) + (f32(sy) + 0.5) / f32(samples)
					cx := px < f32(radius) ? f32(radius) : f32(width - radius)
					cy := py < f32(radius) ? f32(radius) : f32(height - radius)
					dx, dy := px - cx, py - cy
					if dx * dx + dy * dy <= f32(radius * radius) {covered += 1}
				}
			}
			alpha := &pixels[y * pitch + x * 4 + 3]
			alpha^ = u8(u32(alpha^) * u32(covered) / u32(samples * samples))
		}
	}
}
