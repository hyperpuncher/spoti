package ui

import "core:container/lru"
import "core:math"
import "core:mem"
import "core:strings"
import native "native_text"
import sdl "vendor:sdl3"

TEXT_CACHE_SLOTS :: 2048
TEXT_TEXTURE_BUDGET :: 16 * 1024 * 1024

Text_Key :: struct {
	value:   string,
	size:    f32,
	font_id: u16,
}

// Measurement, drawing, fitting, and editing share complete layouts. The core
// cache callback needs this owner to stay at a stable address.
Text_Cache :: struct {
	layouts:   lru.Cache(Text_Key, ^Text_Entry),
	retired:   [dynamic]^Text_Entry,
	allocator: mem.Allocator,
}

Text_Entry :: struct {
	using key:                          Text_Key,
	layout:                             ^native.Layout,
	metrics:                            native.Metrics,
	fit_width:                          f32,
	fit_cut:                            int,
	fit_valid:                          bool,
	texture:                            ^sdl.Texture,
	color:                              [3]u8,
	image_x, image_y, image_w, image_h: f32,
	bytes:                              int,
}

cached_text :: proc(state: ^State, value: string, size: f32, font_id: u16 = 0) -> ^Text_Entry {
	if !init_text(state) {return nil}
	cache := state.text_cache
	key := Text_Key{value, size, font_id}
	if entry, ok := lru.get(&cache.layouts, key); ok {return entry}
	entry := new(Text_Entry, cache.allocator)
	entry.key = {strings.clone(value, cache.allocator), size, font_id}
	entry.layout = native.layout(
		state.text_backend,
		raw_data(value),
		i32(len(value)),
		size,
		font_weight(font_id),
	)
	if entry.layout == nil {destroy_text_entry(state, entry); return nil}
	entry.metrics = native.metrics(entry.layout)
	if lru.set(&cache.layouts, entry.key, entry) != nil {
		destroy_text_entry(state, entry)
		return nil
	}
	return entry
}

// Entries remain valid until the frame ends, even if a later lookup evicts
// them. Release textures after SDL has consumed the queued draws.
retire_text_entry :: proc(_: Text_Key, entry: ^Text_Entry, user_data: rawptr) {
	cache := cast(^Text_Cache)user_data
	append(&cache.retired, entry)
}

text_size :: proc(
	state: ^State,
	value: string,
	size: f32,
	font_id: u16 = 0,
) -> (
	width, height: f32,
) {
	if entry := cached_text(state, value, size, font_id); entry != nil {
		return entry.metrics.width, entry.metrics.height
	}
	return
}

label_bounds :: proc(state: ^State, value: string, size: f32, font_id: u16 = 0) -> native.Rect {
	if entry := cached_text(state, value, size, font_id); entry != nil {return entry.metrics.ink}
	return {}
}

// Returns borrowed text if it fits, otherwise an owned string from the supplied
// allocator. Cache the native cut for the last width, not an allocator-owned result.
fit_text :: proc(
	state: ^State,
	value: string,
	width, size: f32,
	font_id: u16 = 0,
	allocator := context.allocator,
) -> string {
	entry := cached_text(state, value, size, font_id)
	if entry == nil {return ""}
	if entry.metrics.width <= width {return value}
	if !entry.fit_valid || entry.fit_width != width {
		entry.fit_cut = int(native.fit(entry.layout, width))
		entry.fit_width, entry.fit_valid = width, true
	}
	cut := entry.fit_cut
	if cut < 0 {return ""}
	if cut >= len(value) {return value}
	return strings.concatenate({value[:editor_boundary(value, cut)], "…"}, allocator)
}

text :: proc(
	state: ^State,
	value: string,
	x, y, size: f32,
	color: sdl.Color,
	font_id: u16 = 0,
	ink_bounds: bool = false,
) {
	if value == "" || state.renderer == nil {return}
	entry := cached_text(state, value, size, font_id)
	if entry == nil {return}
	rgb := [3]u8{color.r, color.g, color.b}
	if entry.texture == nil || entry.color != rgb {
		drop_text_texture(state, entry)
		image := native.render(entry.layout, color.r, color.g, color.b)
		defer native.free_image(image)
		if image.pixels == nil {return}
		texture := sdl.CreateTexture(state.renderer, .ARGB8888, .STATIC, image.width, image.height)
		if texture == nil {return}
		if !sdl.UpdateTexture(texture, nil, image.pixels, image.stride) ||
		   !sdl.SetTextureBlendMode(texture, sdl.BLENDMODE_BLEND_PREMULTIPLIED) {
			sdl.DestroyTexture(texture)
			return
		}
		entry.texture, entry.color = texture, rgb
		entry.image_x, entry.image_y = f32(image.x), f32(image.y)
		entry.image_w, entry.image_h = f32(image.width), f32(image.height)
		entry.bytes = int(image.stride) * int(image.height)
		state.text_texture_bytes += entry.bytes
	}
	pen_x, pen_y := x, y
	if ink_bounds {pen_x -= entry.metrics.ink.x; pen_y -= entry.metrics.ink.y}
	// Premultiplied textures must modulate both RGB and alpha for opacity.
	// Never tint emoji with the label foreground: its RGB is baked by the backend.
	_ = sdl.SetTextureColorMod(entry.texture, color.a, color.a, color.a)
	_ = sdl.SetTextureAlphaMod(entry.texture, color.a)
	rect := sdl.FRect {
		math.round(pen_x + entry.image_x),
		math.round(pen_y + entry.image_y),
		entry.image_w,
		entry.image_h,
	}
	_ = sdl.RenderTexture(state.renderer, entry.texture, nil, &rect)
}

drop_text_texture :: proc(state: ^State, entry: ^Text_Entry) {
	if entry.texture != nil {sdl.DestroyTexture(entry.texture)}
	state.text_texture_bytes -= entry.bytes
	entry.texture, entry.bytes = nil, 0
}

destroy_text_entry :: proc(state: ^State, entry: ^Text_Entry) {
	drop_text_texture(state, entry)
	if entry.layout != nil {native.destroy(entry.layout)}
	delete(entry.value, state.text_cache.allocator)
	free(entry, state.text_cache.allocator)
}

// Call after presentation. Remove the least recently used textures first when
// retained pixel data exceeds its soft budget. Layout count has a fixed bound.
finish_text_frame :: proc(state: ^State, texture_budget: int = TEXT_TEXTURE_BUDGET) {
	cache := state.text_cache
	if cache == nil {return}
	for entry in cache.retired {destroy_text_entry(state, entry)}
	clear(&cache.retired)
	for node := cache.layouts.tail;
	    node != nil && state.text_texture_bytes > texture_budget;
	    node = node.prev {
		drop_text_texture(state, node.value)
	}
}

destroy_text :: proc(state: ^State) {
	if cache := state.text_cache; cache != nil {
		lru.destroy(&cache.layouts, true)
		finish_text_frame(state)
		delete(cache.retired)
		free(cache, cache.allocator)
		state.text_cache = nil
	}
	if state.text_backend != nil {native.close(state.text_backend); state.text_backend = nil}
}
