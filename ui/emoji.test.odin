package ui

import "core:fmt"
import "core:math"
import "core:sync/chan"
import "core:testing"
import fontconfig "fontconfig"
import sdl "vendor:sdl3"
import ttf "vendor:sdl3/ttf"

@(test)
emoji_pieces_preserve_sequences_and_text_presentation :: proc(t: ^testing.T) {
	for value in ([]string{"🚘", "💨", "👍🏽", "🇯🇵", "👨‍👩‍👧", "1️⃣", "❤️", "©️"}) {
		pieces := text_pieces(value, context.allocator)
		defer delete(pieces)
		if !testing.expect_value(t, len(pieces), 1) {continue}
		testing.expect(t, pieces[0].emoji)
		testing.expect_value(t, pieces[0].value, value)
	}
	for value in ([]string{"©", "❤", "⟡", "✧", "1", "🚘︎", "🖥", "🜁", "🂡", "العربية", "র‍্য"}) {
		pieces := text_pieces(value, context.allocator)
		defer delete(pieces)
		for piece in pieces {testing.expect(t, !piece.emoji)}
	}
	pieces := text_pieces("Rally House🚘💨", context.allocator)
	defer delete(pieces)
	if !testing.expect_value(t, len(pieces), 3) {return}
	testing.expect_value(t, pieces[0].value, "Rally House")
	testing.expect(t, !pieces[0].emoji && pieces[1].emoji && pieces[2].emoji)
}

@(test)
system_emoji_images_join_and_scale_without_changing_text_metrics :: proc(t: ^testing.T) {
	// Real system fonts and surfaces, no video subsystem or desktop access.
	if !testing.expect(t, sdl.Init({})) {return}
	if !testing.expect(t, ttf.Init()) {sdl.Quit(); return}
	state := State {
		fonts = make(map[int]^ttf.Font),
	}
	defer close(&state)
	ok: bool
	state.font_sources[.Regular].path, state.font_sources[.Regular].index, ok = resolve_role(
		.Regular,
	)
	if !testing.expect(t, ok) {return}
	config := fontconfig.InitLoadConfigAndFonts()
	if !testing.expect(t, config != nil) {return}
	defer fontconfig.ConfigDestroy(config)
	path, index := fontconfig.match(config, 0, 80, color_emoji = true)
	defer delete(path)
	image_font := open_font({path, index}, EMOJI_IMAGE_SIDE)
	defer ttf.CloseFont(image_font)
	if !testing.expect(t, image_font != nil) {return}
	for value in ([]string{"🚘", "💨", "👍🏽", "❤️", "1️⃣", "👨‍👩‍👧", "🇯🇵"}) {
		surface := emoji_surface(image_font, value)
		// Native fonts differ. Linux's installed Noto must cover these cases;
		// an unsupported sequence elsewhere must retain one placeholder cell.
		when ODIN_OS == .Linux {testing.expect(t, surface != nil)}
		if surface != nil {
			testing.expect_value(t, surface.w, EMOJI_IMAGE_SIDE)
			testing.expect_value(t, surface.h, EMOJI_IMAGE_SIDE)
			colored := false
			for y in 0 ..< surface.h {
				for x in 0 ..< surface.w {
					r, g, b, a: u8
					if sdl.ReadSurfacePixel(surface, x, y, &r, &g, &b, &a) &&
					   a > 0 &&
					   (r != g || g != b) {colored = true}
				}
			}
			if value == "🚘" || value == "❤️" {testing.expect(t, colored, value)}
			sdl.DestroySurface(surface)
		}
	}
	for size in ([]f32{14, 28, 84}) {
		font := font_for_size(&state, size)
		// Compare against real rendered capital ink, not only font metrics.
		capital := "H"
		ink := ttf.RenderText_Blended(
			font,
			raw_data(capital),
			uint(len(capital)),
			{255, 255, 255, 255},
		)
		if testing.expect(t, ink != nil) {
			top, bottom := int(ink.h), -1
			for y in 0 ..< ink.h {
				for x in 0 ..< ink.w {
					alpha: u8
					if sdl.ReadSurfacePixel(ink, x, y, nil, nil, nil, &alpha) && alpha > 0 {
						top = min(top, int(y))
						bottom = max(bottom, int(y))
					}
				}
			}
			rect := emoji_rect(font, 20, 30)
			testing.expect(
				t,
				math.abs(rect.y + rect.h / 2 - (30 + f32(top + bottom + 1) / 2)) < 0.51,
				"emoji and capital ink must have the same vertical center",
			)
			testing.expect_value(t, rect.w, emoji_side(font))
			sdl.DestroySurface(ink)
		}
		width, height := text_size(&state, "👨‍👩‍👧", size)
		testing.expect_value(t, width, emoji_side(font))
		testing.expect_value(t, height, f32(ttf.GetFontHeight(font)))
		base_width, base_height := text_size(&state, "Rally House", size)
		mixed_width, mixed_height := text_size(&state, "Rally House🚘💨", size)
		testing.expect_value(t, mixed_width, base_width + 2 * emoji_side(font))
		testing.expect_value(t, mixed_height, base_height)
	}
	if !testing.expect(t, start_emoji(&state, nil)) {return}
	testing.expect(t, !emoji_pending(&state))
	_ = emoji_texture(&state, "🚘")
	testing.expect(t, emoji_pending(&state))
	result, received := chan.recv(state.emoji.results)
	if testing.expect(t, received) {
		testing.expect_value(t, result.value, "🚘")
		testing.expect(t, result.surface != nil)
		if result.surface != nil {sdl.DestroySurface(result.surface)}
		delete(result.value, state.emoji.allocator)
		state.emoji.records["🚘"] = {
			ready = true,
		}
	}
	testing.expect(t, !emoji_pending(&state))
	before_width, before_height := text_size(&state, "Rally House🚘💨", 14)
	_ = emoji_texture(&state, "🚘")
	after_width, after_height := text_size(&state, "Rally House🚘💨", 14)
	testing.expect_value(t, after_width, before_width)
	testing.expect_value(t, after_height, before_height)
	// A full cache evicts completed entries, never pending worker results.
	for slot in 1 ..< EMOJI_CACHE_LIMIT {
		key := fmt.aprintf("cached-%d", slot, allocator = state.emoji.allocator)
		state.emoji.records[key] = {
			ready = true,
			used  = u64(slot + 10),
		}
	}
	_ = emoji_texture(&state, "💨")
	testing.expect_value(t, len(state.emoji.records), EMOJI_CACHE_LIMIT)
	_, old_found := state.emoji.records["🚘"]
	testing.expect(t, !old_found)
	// Pending results must not deadlock shutdown or leak their surfaces.
	_ = emoji_texture(&state, "👍🏽")
	stop_emoji(&state)
	testing.expect(t, state.emoji == nil)
}
