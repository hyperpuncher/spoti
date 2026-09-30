package ui

import c "core:c/libc"
import "core:fmt"
import "core:math"
import sdl "vendor:sdl3"
import ttf "vendor:sdl3/ttf"

Cursor_Kind :: enum {
	Default,
	Pointer,
	Text,
	Resize,
}

State :: struct {
	window:             ^sdl.Window,
	renderer:           ^sdl.Renderer,
	font_path:          string,
	font_index:         int,
	numeric_font_path:  string,
	numeric_font_index: int,
	bold_font_path:     string,
	bold_font_index:    int,
	medium_font_path:   string,
	medium_font_index:  int,
	fonts:              map[int]^ttf.Font,
	text_engine:        ^ttf.TextEngine,
	masks:              map[u64]^sdl.Texture,
	cursors:            [Cursor_Kind]^sdl.Cursor,
	cursor:             Cursor_Kind,
	vsync:              bool,
	fps_started:        u64,
	fps_frames:         u32,
	fps:                u32,
}

open :: proc(title: cstring, width, height: int) -> (state: State, ok: bool) {
	when ODIN_OS == .Linux {
		// Override wayland,x11 in the environment: XWayland is not a fallback.
		if !sdl.SetHintWithPriority(sdl.HINT_VIDEO_DRIVER, "wayland", .OVERRIDE) {
			fmt.eprintln("could not require the SDL3 Wayland driver")
			return
		}
	}
	if !sdl.Init(sdl.INIT_VIDEO) {
		fmt.eprintln("could not initialize SDL3 video:", sdl.GetError())
		return
	}
	when ODIN_OS == .Linux {
		if string(sdl.GetCurrentVideoDriver()) != "wayland" {
			fmt.eprintln("native Wayland is required; refusing the SDL3 video fallback")
			sdl.Quit()
			return
		}
	}
	if !ttf.Init() {
		fmt.eprintln("could not initialize SDL3_ttf:", sdl.GetError())
		sdl.Quit()
		return
	}
	if !sdl.CreateWindowAndRenderer(
		title,
		c.int(width),
		c.int(height),
		{.RESIZABLE, .HIGH_PIXEL_DENSITY},
		&state.window,
		&state.renderer,
	) {
		fmt.eprintln("could not create SDL3 window:", sdl.GetError())
		close(&state)
		return
	}
	state.vsync = sdl.SetRenderVSync(state.renderer, 1)
	_ = sdl.SetRenderDrawBlendMode(state.renderer, sdl.BLENDMODE_BLEND)
	if !state.vsync {fmt.eprintln("SDL3 vsync unavailable; limiting frames to about 60 fps")}
	state.fps_started = sdl.GetTicks()
	state.font_path, state.font_index, ok = resolve_font("sans-serif")
	if !ok {close(&state); return}
	state.numeric_font_path, state.numeric_font_index, ok = resolve_font("monospace")
	if !ok {close(&state); return}
	state.bold_font_path, state.bold_font_index, ok = resolve_font("sans-serif:style=Bold")
	if !ok {close(&state); return}
	state.medium_font_path, state.medium_font_index, ok = resolve_font("sans-serif:style=Medium")
	if !ok {close(&state); return}
	state.fonts = make(map[int]^ttf.Font)
	state.masks = make(map[u64]^sdl.Texture)
	state.cursors[.Default] = sdl.GetDefaultCursor()
	state.cursors[.Pointer] = sdl.CreateSystemCursor(.POINTER)
	state.cursors[.Text] = sdl.CreateSystemCursor(.TEXT)
	state.cursors[.Resize] = sdl.CreateSystemCursor(.EW_RESIZE)
	state.text_engine = ttf.CreateRendererTextEngine(state.renderer)
	if state.text_engine == nil {
		fmt.eprintln("could not initialize SDL3 text rendering:", sdl.GetError())
		close(&state)
		return
	}
	return state, true
}

close :: proc(state: ^State) {
	if state.text_engine != nil {ttf.DestroyRendererTextEngine(state.text_engine)}
	for _, font in state.fonts {ttf.CloseFont(font)}
	delete(state.fonts)
	delete(state.font_path)
	delete(state.numeric_font_path)
	delete(state.bold_font_path)
	delete(state.medium_font_path)
	for _, texture in state.masks {sdl.DestroyTexture(texture)}
	delete(state.masks)
	if state.cursors[.Default] != nil {_ = sdl.SetCursor(state.cursors[.Default])}
	for kind := Cursor_Kind.Pointer; kind <= .Resize; kind = Cursor_Kind(int(kind) + 1) {
		if state.cursors[kind] != nil {sdl.DestroyCursor(state.cursors[kind])}
	}
	if state.renderer != nil {sdl.DestroyRenderer(state.renderer)}
	if state.window != nil {sdl.DestroyWindow(state.window)}
	ttf.Quit()
	sdl.Quit()
}

set_cursor :: proc(state: ^State, kind: Cursor_Kind) {
	if state.cursor == kind || state.cursors[kind] == nil {return}
	if sdl.SetCursor(state.cursors[kind]) {state.cursor = kind}
}

// SDL window/input coordinates are logical; the renderer is in drawable pixels.
// SDL's own conversion also handles fractional Wayland scaling and resizes.
mouse_position :: proc(state: ^State, x, y: f32) -> (point: sdl.FPoint) {
	_ = sdl.RenderCoordinatesFromWindow(state.renderer, x, y, &point.x, &point.y)
	return
}

size :: proc(state: ^State) -> (width, height: c.int) {
	_ = sdl.GetRenderOutputSize(state.renderer, &width, &height)
	return
}

scale :: proc(state: ^State) -> f32 {
	pixels, _ := size(state)
	logical: c.int
	_ = sdl.GetWindowSize(state.window, &logical, nil)
	if logical == 0 {return 1}
	return f32(pixels) / f32(logical)
}

// Large rounded panels use an indexed triangle fan around their centre.
// SDL3 has no rounded-rect call; Clay's own SDL3 renderer does the same.
ROUND_SEGMENTS :: 24

draw_rounded :: proc(state: ^State, rect: sdl.FRect, radius: f32, color: sdl.Color) {
	if rect.w <= 0 || rect.h <= 0 {return}
	corners := clamp(radius, 0, min(rect.w, rect.h) / 2)
	if corners <= 0.5 {fill(state, rect, color); return}
	fill_color := sdl.FColor {
		f32(color.r) / 255,
		f32(color.g) / 255,
		f32(color.b) / 255,
		f32(color.a) / 255,
	}
	vertices: [1 + 4 * ROUND_SEGMENTS]sdl.Vertex
	indices: [3 * 4 * ROUND_SEGMENTS]c.int
	vertices[0] = {
		position = {rect.x + rect.w / 2, rect.y + rect.h / 2},
		color    = fill_color,
	}
	arcs := [4][3]f32 {
		{rect.x + corners, rect.y + corners, 180},
		{rect.x + rect.w - corners, rect.y + corners, 270},
		{rect.x + rect.w - corners, rect.y + rect.h - corners, 0},
		{rect.x + corners, rect.y + rect.h - corners, 90},
	}
	perimeter := 0
	for arc in arcs {
		for step in 0 ..< ROUND_SEGMENTS {
			angle := (arc[2] + f32(step) * 90 / ROUND_SEGMENTS) * math.PI / 180
			x := arc[0] + corners * f32(math.cos(f64(angle)))
			y := arc[1] + corners * f32(math.sin(f64(angle)))
			perimeter += 1
			vertices[perimeter] = {
				position = {x, y},
				color    = fill_color,
			}
		}
	}
	index_count := 0
	for i in 1 ..= perimeter {
		next := i == perimeter ? 1 : i + 1
		indices[index_count + 0] = 0
		indices[index_count + 1] = c.int(i)
		indices[index_count + 2] = c.int(next)
		index_count += 3
	}
	_ = sdl.RenderGeometry(
		state.renderer,
		nil,
		&vertices[0],
		c.int(perimeter + 1),
		&indices[0],
		c.int(index_count),
	)
}

fill :: proc(state: ^State, rect: sdl.FRect, color: sdl.Color) {
	_ = sdl.SetRenderDrawColor(state.renderer, color.r, color.g, color.b, color.a)
	area := rect
	_ = sdl.RenderFillRect(state.renderer, &area)
}

// Apply a small antialiased rounded alpha edge once at the source image's
// native resolution. This avoids SDL_RenderGeometry's non-antialiased edge and
// remains smooth at every destination size.
round_image_pixels :: proc(pixels: []u8, width, height: int) {
	if len(pixels) < width * height * 4 || width <= 0 || height <= 0 {return}
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
			alpha := &pixels[(y * width + x) * 4 + 3]
			alpha^ = u8(u32(alpha^) * u32(covered) / u32(samples * samples))
		}
	}
}

// Upload straight RGBA pixels (as decoded covers) into a reusable texture.
create_texture :: proc(state: ^State, pixels: []u8, width, height: int) -> ^sdl.Texture {
	if len(pixels) < width * height * 4 || width <= 0 || height <= 0 {return nil}
	texture := sdl.CreateTexture(state.renderer, .RGBA32, .STATIC, c.int(width), c.int(height))
	if texture == nil {return nil}
	if !sdl.UpdateTexture(texture, nil, raw_data(pixels), c.int(width * 4)) {
		sdl.DestroyTexture(texture)
		return nil
	}
	_ = sdl.SetTextureScaleMode(texture, .LINEAR)
	_ = sdl.SetTextureBlendMode(texture, sdl.BLENDMODE_BLEND)
	return texture
}

draw_texture :: proc(state: ^State, texture: ^sdl.Texture, rect: sdl.FRect) {
	if texture == nil {return}
	area := rect
	_ = sdl.RenderTexture(state.renderer, texture, nil, &area)
}

// Rounded variants used by the Clay renderer, which carries a radius per box.
// A solid rounded box is drawn from a supersampled alpha mask, so its curved
// edges are antialiased; SDL3's renderer has no multisampling of its own.
mask_key :: proc(width, height, radius: int) -> u64 {
	return u64(width) << 32 | u64(height) << 16 | u64(radius)
}

rounded_mask :: proc(state: ^State, width, height, radius: int) -> ^sdl.Texture {
	key := mask_key(width, height, radius)
	if texture, found := state.masks[key]; found {return texture}
	// Compute coverage at the final texture size. SDL's linear minification only
	// interpolates nearby texels; it does not average an entire supersampled
	// source image, which is why the previous 8x masks still looked jagged.
	SAMPLES :: 8
	pixels := make([]u8, width * height * 4)
	defer delete(pixels)
	half_width := f32(width) / 2
	half_height := f32(height) / 2
	inset: f32 = 0.25
	shape_half_width := half_width - inset
	shape_half_height := half_height - inset
	shape_radius := min(f32(radius) - inset, min(shape_half_width, shape_half_height))
	for y in 0 ..< height {
		for x in 0 ..< width {
			covered := 0
			for sy in 0 ..< SAMPLES {
				for sx in 0 ..< SAMPLES {
					px := f32(x) + (f32(sx) + 0.5) / f32(SAMPLES)
					py := f32(y) + (f32(sy) + 0.5) / f32(SAMPLES)
					qx := abs(px - half_width) - (shape_half_width - shape_radius)
					qy := abs(py - half_height) - (shape_half_height - shape_radius)
					dx := max(qx, 0)
					dy := max(qy, 0)
					if dx * dx + dy * dy <= shape_radius * shape_radius {covered += 1}
				}
			}
			index := (y * width + x) * 4
			pixels[index + 0] = 255
			pixels[index + 1] = 255
			pixels[index + 2] = 255
			pixels[index + 3] = u8(covered * 255 / (SAMPLES * SAMPLES))
		}
	}
	texture := create_texture(state, pixels, width, height)
	if texture != nil {state.masks[key] = texture}
	return texture
}

fill_rounded :: proc(state: ^State, rect: sdl.FRect, radius: f32, color: sdl.Color) {
	if rect.w <= 0 || rect.h <= 0 {return}
	corners := int(clamp(radius, 0, min(rect.w, rect.h) / 2) + 0.5)
	width := int(rect.w + 0.5)
	height := int(rect.h + 0.5)
	// Supersampled masks are reserved for controls. Large panels and cards keep
	// the cheaper geometry path, where their shallow radius is less noticeable.
	if corners <= 0 || height > 128 || width > height * 8 {
		draw_rounded(state, rect, radius, color)
		return
	}
	texture := rounded_mask(state, width, height, min(corners, min(width, height) / 2))
	if texture == nil {
		draw_rounded(state, rect, radius, color)
		return
	}
	_ = sdl.SetTextureColorMod(texture, color.r, color.g, color.b)
	_ = sdl.SetTextureAlphaMod(texture, color.a)
	area := rect
	_ = sdl.RenderTexture(state.renderer, texture, nil, &area)
	_ = sdl.SetTextureColorMod(texture, 255, 255, 255)
	_ = sdl.SetTextureAlphaMod(texture, 255)
}

frame_done :: proc(state: ^State) {
	state.fps_frames += 1
	now := sdl.GetTicks()
	if now - state.fps_started >= 1000 {
		state.fps = u32(u64(state.fps_frames) * 1000 / (now - state.fps_started))
		state.fps_frames = 0
		state.fps_started = now
	}
	width, _ := size(state)
	density := scale(state)
	label := fmt.aprintf("%d", state.fps, allocator = context.temp_allocator)
	font := font_for_size(state, 14 * density, 1)
	label_width, label_height: c.int
	if font != nil &&
	   ttf.GetStringSize(
		   font,
		   cstring(raw_data(label)),
		   uint(len(label)),
		   &label_width,
		   &label_height,
	   ) {
		text(
			state,
			label,
			f32(width) - f32(label_width) - 8 * density,
			8 * density,
			14 * density,
			{190, 190, 190, 255},
			font_id = 1,
		)
	}
	_ = sdl.RenderPresent(state.renderer)
	if !state.vsync {sdl.Delay(16)}
}

text :: proc(
	state: ^State,
	value: string,
	x, y, font_size: f32,
	color: sdl.Color,
	font_id: u16 = 0,
) {
	if len(value) == 0 {return}
	font := font_for_size(state, font_size, font_id)
	if font == nil {return}
	content := ttf.CreateText(state.text_engine, font, cstring(raw_data(value)), len(value))
	if content == nil {return}
	defer ttf.DestroyText(content)
	_ = ttf.SetTextColor(content, color.r, color.g, color.b, color.a)
	// Whole-pixel positions keep glyph rasterization identical between frames.
	_ = ttf.DrawRendererText(content, f32(int(x + 0.5)), f32(int(y + 0.5)))
}
