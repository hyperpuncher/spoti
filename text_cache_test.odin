package main

import "core:strings"
import "core:testing"
import ui "ui"
import sdl "vendor:sdl3"
import ttf "vendor:sdl3/ttf"

@(test)
text_pool_reuses_updates_and_releases_visible_frame_slots :: proc(t: ^testing.T) {
	// No video subsystem, window, renderer, or desktop interaction.
	if !testing.expect(t, sdl.Init({})) {return}
	defer sdl.Quit()
	if !testing.expect(t, ttf.Init()) {return}
	defer ttf.Quit()
	path, face, ok := ui.resolve_font("sans-serif")
	if !testing.expect(t, ok) {return}
	defer delete(path)
	state := ui.State {
		font_path  = path,
		font_index = face,
		fonts      = make(map[int]^ttf.Font),
	}
	defer {
		for content in state.texts {ttf.DestroyText(content)}
		delete(state.texts)
		if state.text_engine != nil {ttf.DestroySurfaceTextEngine(state.text_engine)}
		for _, font in state.fonts {ttf.CloseFont(font)}
		delete(state.fonts)
	}
	state.text_engine = ttf.CreateSurfaceTextEngine()
	if !testing.expect(t, state.text_engine != nil) {return}
	font := ui.font_for_size(&state, 14)
	if !testing.expect(t, font != nil) {return}
	borrowed := strings.clone("héllo library")
	first := ui.cached_text(&state, font, borrowed)
	delete(borrowed)
	if !testing.expect(t, first != nil) {return}
	testing.expect_value(t, string(cstring(first.text)), "héllo library")
	second := ui.cached_text(&state, font, "0:30")
	testing.expect(t, second != nil && first != second)
	ui.finish_text_frame(&state)
	testing.expect_value(t, len(state.texts), 2)
	testing.expect(t, ui.cached_text(&state, font, "héllo library") == first)
	ui.finish_text_frame(&state)
	testing.expect(t, len(state.texts) == 1, "unused slots must not accumulate while browsing")
	large := ui.font_for_size(&state, 28)
	if !testing.expect(t, large != nil) {return}
	testing.expect(t, ui.cached_text(&state, large, "new title") == first)
	testing.expect(t, ttf.GetTextFont(first) == large)
	testing.expect_value(t, string(cstring(first.text)), "new title")
	ui.finish_text_frame(&state)
	ui.finish_text_frame(&state)
	testing.expect_value(t, len(state.texts), 0)
}
