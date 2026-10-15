package ui

import c "core:c/libc"
import "core:testing"
import sdl "vendor:sdl3"
import ttf "vendor:sdl3/ttf"

@(test)
text_fallbacks_cover_scripts_and_symbols_without_replacing_geist :: proc(t: ^testing.T) {
	// Font operations only: no window or desktop interaction.
	if !testing.expect(t, sdl.Init({})) {return}
	if !testing.expect(t, ttf.Init()) {sdl.Quit(); return}
	state := State {
		fonts = make(map[int]^ttf.Font),
	}
	defer close(&state)
	for &source, role in state.font_sources {
		ok: bool
		source.path, source.index, ok = resolve_role(role)
		if !testing.expect(t, ok) {return}
	}
	resolve_fallbacks(&state)
	if !testing.expect(t, state.font_config != nil) {return}
	for size in ([]f32{14, 28, 84}) {
		for role in ([]Font_Role{.Regular, .Numeric, .Bold, .Medium}) {
			font := font_for_size(&state, size, u16(role))
			if !testing.expect(t, font != nil) {continue}
			latin := "Rally House"
			before, after: c.int
			testing.expect(
				t,
				ttf.GetStringSize(font, raw_data(latin), uint(len(latin)), &before, nil),
			)
			for value in ([]string{"千葉雄喜", "ethereal breaks ⟡ ✧", "ethereal breaks *:･ﾟ✧", "العربية", "עברית", "हिन्दी", "ไทย"}) {
				font = font_for_text(&state, value, size, u16(role))
				for character in value {
					testing.expect(
						t,
						ttf.FontHasGlyph(font, u32(character)),
						"installed script and symbol fonts must be available through fallback",
					)
				}
			}
			testing.expect(
				t,
				ttf.GetStringSize(font, raw_data(latin), uint(len(latin)), &after, nil),
			)
			testing.expect_value(t, after, before)
		}
	}
	// The installed fonts must keep a symbol's normal outline even in a
	// bold title, without removing bold from its Japanese letters.
	when ODIN_OS == .Linux {
		for character in ([]rune{'⟡', '千'}) {
			key := u64(u32(character)) << 16 | u64(Font_Role.Bold)
			index, found := state.fallback_matches[key]
			if !testing.expect(t, found && index >= 0) {continue}
			face := font_for_size(&state, 84, FONT_ROLE_COUNT + u16(index))
			if !testing.expect(t, face != nil) {continue}
			if character == '⟡' {
				testing.expect(t, ttf.GetFontWeight(face) <= ttf.FONT_WEIGHT_NORMAL)
			} else {
				testing.expect(t, ttf.GetFontWeight(face) >= ttf.FONT_WEIGHT_BOLD)
			}
		}
	}
	for _, font in state.fonts {
		testing.expect(
			t,
			ttf.FontIsScalable(font),
			"fixed-size bitmap emoji must not change ordinary text metrics",
		)
	}
	count := len(state.fallback_sources)
	_ = font_for_text(
		&state,
		"千葉雄喜 ⟡ ✧ العربية עברית हिन्दी ไทย",
		14,
	)
	testing.expect_value(t, len(state.fallback_sources), count)
	// A code point with no installed glyph must not repeatedly grow the cache.
	_ = font_for_text(&state, "\U0010ffff", 14)
	count = len(state.fallback_sources)
	_ = font_for_text(&state, "\U0010ffff", 14)
	testing.expect_value(t, len(state.fallback_sources), count)
}
