// Each platform owns font fallback, shaping, bidi layout, and rasterization.
// The small C ABI uses SDK headers instead of duplicated COM or framework types.
package native_text

import "core:c"

Engine :: struct {}
Layout :: struct {}
Rect :: struct {
	x, y, width, height: f32,
}
Metrics :: struct {
	width, height, baseline: f32,
	ink:                     Rect,
}
Image :: struct {
	pixels:                      [^]u8,
	width, height, stride, x, y: c.int,
}

when ODIN_OS == .Windows {
	foreign import text_library {"../../build/native_text.lib", "system:dwrite.lib", "system:d2d1.lib", "system:windowscodecs.lib", "system:ole32.lib", "system:uuid.lib"}
} else when ODIN_OS == .Darwin {
	foreign import text_library {"../../build/native_text.a", "system:CoreText.framework", "system:CoreGraphics.framework", "system:CoreFoundation.framework"}
} else when ODIN_OS == .Linux {
	foreign import text_library {"../../build/native_text.a", "system:pangocairo-1.0", "system:pango-1.0", "system:cairo", "system:gobject-2.0", "system:glib-2.0", "system:m"}
}

@(default_calling_convention = "c", link_prefix = "st_")
foreign text_library {
	open :: proc(path: cstring) -> ^Engine ---
	close :: proc(engine: ^Engine) ---
	layout :: proc(engine: ^Engine, text: [^]u8, length: c.int, size: f32, weight: c.int) -> ^Layout ---
	destroy :: proc(layout: ^Layout) ---
	metrics :: proc(layout: ^Layout) -> Metrics ---
	fit :: proc(layout: ^Layout, width: f32) -> c.int ---
	cursor :: proc(layout: ^Layout, index: c.int) -> f32 ---
	hit :: proc(layout: ^Layout, x: f32, nearest: c.int) -> c.int ---
	selection :: proc(layout: ^Layout, start, end: c.int, rects: [^]Rect, capacity: c.int) -> c.int ---
	render :: proc(layout: ^Layout, r, g, b: u8) -> Image ---
	free_image :: proc(image: Image) ---
}
