package main

import "core:fmt"
import "core:strings"
import "core:testing"
import "core:unicode/utf8"
import ui "ui"
import clay "vendor/clay"
import sdl "vendor:sdl3"
import ttf "vendor:sdl3/ttf"

@(test)
text_fitting_preserves_graphemes_and_available_player_space :: proc(t: ^testing.T) {
	// Real font metrics, but no video subsystem or desktop interaction.
	if !testing.expect(t, sdl.Init({})) {return}
	if !testing.expect(t, ttf.Init()) {sdl.Quit(); return}
	state := ui.State {
		fonts   = make(map[int]^ttf.Font),
		density = 1,
	}
	defer ui.close(&state)
	ok: bool
	for role in ([]ui.Font_Role{.Regular, .Numeric, .Bold}) {
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
	// The footer must use spare width, not clip labels at its old fixed slot.
	errors := 0
	memory := layout_test_init(&state.density, &errors, {2000, 92})
	defer {clay.SetCurrentContext(nil); delete(memory)}
	clay.SetMeasureTextFunction(measure_text, &state)
	textures: Textures
	anims := make(map[u32]Button_Fx)
	defer delete(anims)
	fx := Button_Fx_Ctx {
		anims = &anims,
	}
	view := View {
		title   = "Rio's Interlude - feat. Rio Da Yung Og",
		status  = "Joyce Wrice, Rio Da Yung Og, Another Artist, Someone Else",
		elapsed = "0:16",
		total   = "2:11",
	}
	for width in ([]f32{960, 2000}) {
		clay.SetLayoutDimensions({width, 92})
		clay.BeginLayout()
		player_bar(view, &textures, &fx, &state, width, 1)
		commands := clay.EndLayout(0)
		app := App {
			selected = "spotify:track:AAAAAAAAAAAAAAAAAAAAAA",
		}
		app_frame := Frame {
			right_clicked  = true,
			foot_first_uri = "spotify:artist:CCCCCCCCCCCCCCCCCCCCCC",
		}
		for id in ([]string{"footer_title", "footer_artist", "footer_metadata"}) {
			box := clay.GetElementData(clay.ID(id)).boundingBox
			app_frame.mouse_right = {box.x + 1, box.y + 1}
			app_click(&app, &app_frame, {})
			testing.expect(t, app.menu.open)
			testing.expect_value(
				t,
				app.menu.uri,
				id == "footer_artist" ? app_frame.foot_first_uri : app.selected,
			)
			free_context_menu(&app.menu)
		}
		play := clay.GetElementData(clay.ID("footer_play")).boundingBox
		testing.expect_value(t, play.x + play.width / 2, width / 2 + 50)
		labels := 0
		for command in commands.internalArray[:commands.length] {
			if command.commandType != .Text || command.renderData.text.fontId != 0 {continue}
			text := command.renderData.text
			value := string(text.stringContents.chars[:text.stringContents.length])
			if width == 2000 {
				testing.expect_value(t, value, text.fontSize == 15 ? view.title : view.status)
			} else {
				testing.expect(t, strings.has_suffix(value, "…"))
			}
			labels += 1
		}
		testing.expect_value(t, labels, 2)
	}
	testing.expect_value(t, errors, 0)
}
