package ui

import "core:strings"
import "core:testing"
import native "native_text"
import sdl "vendor:sdl3"

@(test)
text_cache_owns_text_reuses_reordered_labels_and_defers_eviction :: proc(t: ^testing.T) {
	state := State {
		density = 1,
	}
	if !testing.expect(t, init_text(&state)) {return}
	defer close(&state)
	state.text_cache.layouts.capacity = 2
	borrowed := strings.clone("héllo library")
	first := cached_text(&state, borrowed, 14)
	delete(borrowed)
	if !testing.expect(t, first != nil) {return}
	testing.expect_value(t, first.value, "héllo library")
	layout := first.layout
	second := cached_text(&state, "0:30", 14)
	if !testing.expect(t, second != nil && first != second) {return}
	finish_text_frame(&state)
	// Scrolling changes call order. Measurement must reuse the draw layout too.
	testing.expect(t, cached_text(&state, "0:30", 14) == second)
	width, height := text_size(&state, "héllo library", 14)
	testing.expect(t, width == first.metrics.width && height == first.metrics.height)
	testing.expect(t, cached_text(&state, "héllo library", 14) == first && first.layout == layout)
	larger := cached_text(&state, "héllo library", 28)
	if !testing.expect(t, larger != nil && larger != first) {return}
	testing.expect(t, larger.metrics.height > height)
	testing.expect_value(t, state.text_cache.layouts.count, 2)
	// The evicted entry can still be in use by this frame.
	testing.expect_value(t, second.value, "0:30")
	testing.expect_value(t, len(state.text_cache.retired), 1)
	finish_text_frame(&state)
	testing.expect_value(t, len(state.text_cache.retired), 0)
	_, line := text_size(&state, "new title", 28)
	_, multiline := text_size(&state, "new\ntitle", 28)
	_, trailing_line := text_size(&state, "new title\n", 28)
	testing.expect(t, multiline > line && trailing_line > line)
	finish_text_frame(&state)
	testing.expect_value(t, state.text_cache.layouts.count, 2)
}

@(test)
text_fit_reuses_native_cut_without_borrowing_owned_results :: proc(t: ^testing.T) {
	state := State {
		density = 1,
	}
	if !testing.expect(t, init_text(&state)) {return}
	defer close(&state)
	source := "A👍🏽 extended title"
	expected := "A👍🏽…"
	width, _ := text_size(&state, expected, 14)
	first := fit_text(&state, source, width, 14)
	if !testing.expect_value(t, first, expected) {return}
	delete(first)
	second := fit_text(&state, source, width, 14)
	defer delete(second)
	whole := fit_text(&state, source, 10000, 14)
	testing.expect(t, raw_data(whole) == raw_data(source), "unmodified text stays borrowed")
	destroy_text(&state)
	testing.expect(t, second == expected, "the caller owns fitted text after cache destruction")
}

@(test)
native_editor_geometry_preserves_clusters_spaces_and_bidi_selection :: proc(t: ^testing.T) {
	state := State {
		density = 1,
	}
	if !testing.expect(t, init_text(&state)) {return}
	defer close(&state)
	e: Editor
	editor_init(&e)
	defer editor_destroy(&e)
	for value in ([]string{"A👨‍👩‍👧B", "A👍🏽B", "AéB", "A🇯🇵B"}) {
		editor_set_text(&e, value)
		e.box = {0, 0, 1000, 30}
		for at in ([]int{0, 1, len(value) - 1, len(value)}) {
			x := editor_x(&state, value, at)
			testing.expect_value(t, editor_hit(&state, &e, x), at)
		}
	}
	testing.expect(t, editor_x(&state, "hello   ", 8) > editor_x(&state, "hello", 5))
	ranges := editor_ranges(&state, "abאב12αβ", 1, 6)
	testing.expect(t, len(ranges) >= 2, "mixed bidi selection must not include unselected text")
	for rect in ranges {testing.expect(t, rect.width > 0 && rect.height > 0)}
}

@(test)
native_text_upload_preserves_color_emoji_and_premultiplied_opacity :: proc(t: ^testing.T) {
	if !testing.expect(t, sdl.Init({})) {return}
	state := State {
		density = 1,
	}
	surface: ^sdl.Surface
	defer {close(&state); if surface != nil {sdl.DestroySurface(surface)}}
	if !testing.expect(t, init_text(&state)) {return}
	entry := cached_text(&state, "Ab · 🚘 · ⟡", 17.5)
	if !testing.expect(t, entry != nil) {return}
	image := native.render(entry.layout, 235, 235, 235)
	defer native.free_image(image)
	if !testing.expect(t, image.pixels != nil) {return}
	surface = sdl.CreateSurface(image.width, image.height, .ARGB8888)
	if !testing.expect(t, surface != nil) {return}
	state.renderer = sdl.CreateSoftwareRenderer(surface)
	if !testing.expect(t, state.renderer != nil) {return}
	colored := false
	for opacity in ([]u8{255, 128}) {
		_ = sdl.SetRenderDrawColor(state.renderer, 102, 102, 102, 255)
		_ = sdl.RenderClear(state.renderer)
		text(&state, entry.value, f32(-image.x), f32(-image.y), 17.5, {235, 235, 235, opacity})
		_ = sdl.RenderPresent(state.renderer)
		max_error := 0
		if !testing.expect(t, sdl.LockSurface(surface)) {return}
		for y in 0 ..< int(image.height) {
			for x in 0 ..< int(image.width) {
				src := image.pixels[y * int(image.stride) + x * 4:][:4]
				dst := ([^]u8)(surface.pixels)[y * int(surface.pitch) + x * 4:][:4]
				if src[0] != src[1] || src[1] != src[2] {colored = true}
				alpha := f32(src[3]) / 255 * f32(opacity) / 255
				for channel in 0 ..< 3 {
					expected := f32(src[channel]) * f32(opacity) / 255 + 102 * (1 - alpha)
					max_error = max(max_error, abs(int(dst[channel]) - int(expected + 0.5)))
				}
			}
		}
		sdl.UnlockSurface(surface)
		testing.expect(t, max_error <= 2)
	}
	testing.expect(t, colored, "the complete native line must contain color emoji")
	// Quartz has a bottom-left origin. A top-heavy F must remain upright in
	// the uploaded top-down buffer, not just pass a self-comparison of pixels.
	letter := cached_text(&state, "F", 84)
	if !testing.expect(t, letter != nil) {return}
	upright := native.render(letter.layout, 255, 255, 255)
	defer native.free_image(upright)
	if !testing.expect(t, upright.pixels != nil) {return}
	halves: [2]u64
	for y in 0 ..< int(upright.height) {
		for x in 0 ..< int(upright.width) {
			halves[y < int(upright.height) / 2 ? 0 : 1] += u64(
				upright.pixels[y * int(upright.stride) + x * 4 + 3],
			)
		}
	}
	testing.expect(t, halves[0] > halves[1], "native raster rows must be top-down")
	text(&state, "F", 0, 0, 84, {255, 255, 255, 255})
	text(&state, entry.value, 0, 0, 17.5, {235, 235, 235, 255})
	_ = sdl.RenderPresent(state.renderer)
	if !testing.expect(t, entry.texture != nil && letter.texture != nil) {return}
	// A measurement and draw share one layout. Keep the recently drawn texture
	// when the budget only permits one; retain both layouts for later use.
	finish_text_frame(&state, entry.bytes)
	testing.expect(t, entry.texture != nil && letter.texture == nil)
	testing.expect_value(t, state.text_texture_bytes, entry.bytes)
	finish_text_frame(&state, 0)
	testing.expect(t, entry.texture == nil)
	testing.expect_value(t, state.text_texture_bytes, 0)
}
