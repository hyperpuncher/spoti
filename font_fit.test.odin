package main

import "core:fmt"
import "core:testing"
import "core:unicode/utf8"
import ui "ui"
import sdl "vendor:sdl3"
import ttf "vendor:sdl3/ttf"

@(test)
card_title_truncation_keeps_complete_unicode_characters :: proc(t: ^testing.T) {
	// Real font metrics, but no video subsystem or desktop interaction.
	if !testing.expect(t, sdl.Init({})) {return}
	if !testing.expect(t, ttf.Init()) {sdl.Quit(); return}
	state := ui.State {
		fonts   = make(map[int]^ttf.Font),
		density = 1,
	}
	defer ui.close(&state)
	ok: bool
	for role in ([]ui.Font_Role{.Regular, .Bold}) {
		source := &state.font_sources[role]
		source.path, source.index, ok = ui.resolve_role(role)
		if !testing.expect(t, ok) {return}
	}
	ui.resolve_fallbacks(&state)
	for name in ([]string{"Release Radar", "Victory Music"}) {
		_, large := hero_title(&state, name, 900, 96)
		text, small := hero_title(&state, name, 270, 96)
		testing.expect(t, small.fontSize < large.fontSize && small.wrapMode == .None)
		testing.expect_value(t, text, name)
	}
	for text in ([]string{"Rally House🚘💨", "千葉雄喜 チーム友達", "Квартирный Вопрос"}) {
		for _, offset in text {
			if offset == 0 {continue}
			prefix := fmt.aprintf("%s…", text[:offset])
			width := hero_text_width(&state, prefix, 14, 0)
			delete(prefix)
			fit := hero_fit_text(&state, text, width, 14, 0, context.temp_allocator)
			testing.expect(
				t,
				utf8.valid_string(fit),
				"truncation must not produce a missing-glyph box from partial UTF-8",
			)
			testing.expect(t, hero_text_width(&state, fit, 14, 0) <= width + 0.01)
		}
	}
	for cluster in ([]string{"👍🏽", "🇯🇵", "👨‍👩‍👧", "1️⃣", "❤️", "é"}) {
		probe := fmt.aprintf("A%s extended title", cluster)
		expected := fmt.aprintf("A%s…", cluster)
		cut_width := hero_text_width(&state, expected, 14, 0)
		cut := hero_fit_text(&state, probe, cut_width, 14, 0, context.temp_allocator)
		testing.expect_value(t, cut, expected)
		delete(expected)
		delete(probe)
	}
}
