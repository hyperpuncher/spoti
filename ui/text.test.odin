package ui

import "core:strings"
import "core:testing"
import sdl "vendor:sdl3"
import ttf "vendor:sdl3/ttf"

@(test)
text_pool_reuses_updates_and_releases_visible_frame_slots :: proc(t: ^testing.T) {
	// No video subsystem, window, renderer, or desktop interaction.
	if !testing.expect(t, sdl.Init({})) {return}
	defer sdl.Quit()
	if !testing.expect(t, ttf.Init()) {return}
	defer ttf.Quit()
	path, face, ok := resolve_role(.Regular)
	if !testing.expect(t, ok) {return}
	defer delete(path)
	state := State {
		fonts = make(map[int]^ttf.Font),
	}
	defer {
		for content in state.texts {ttf.DestroyText(content)}
		delete(state.texts)
		if state.text_engine != nil {ttf.DestroySurfaceTextEngine(state.text_engine)}
		for _, font in state.fonts {ttf.CloseFont(font)}
		delete(state.fonts)
	}
	state.font_sources[.Regular] = {path, face}
	state.text_engine = ttf.CreateSurfaceTextEngine()
	if !testing.expect(t, state.text_engine != nil) {return}
	font := font_for_size(&state, 14)
	if !testing.expect(t, font != nil) {return}
	borrowed := strings.clone("héllo library")
	first := cached_text(&state, font, borrowed)
	delete(borrowed)
	if !testing.expect(t, first != nil) {return}
	testing.expect_value(t, string(cstring(first.text)), "héllo library")
	second := cached_text(&state, font, "0:30")
	testing.expect(t, second != nil && first != second)
	finish_text_frame(&state)
	testing.expect_value(t, len(state.texts), 2)
	testing.expect(t, cached_text(&state, font, "héllo library") == first)
	finish_text_frame(&state)
	testing.expect(t, len(state.texts) == 1, "unused slots must not accumulate while browsing")
	large := font_for_size(&state, 28)
	if !testing.expect(t, large != nil) {return}
	testing.expect(t, cached_text(&state, large, "new title") == first)
	testing.expect(t, ttf.GetTextFont(first) == large)
	testing.expect_value(t, string(cstring(first.text)), "new title")
	finish_text_frame(&state)
	finish_text_frame(&state)
	testing.expect_value(t, len(state.texts), 0)
}
