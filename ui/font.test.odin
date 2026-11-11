package ui

import "core:testing"
import native "native_text"

when ODIN_OS == .Linux {
	foreign import text_test_library "../build/native_text.a"
	foreign text_test_library {
		st_missing :: proc(layout: ^native.Layout) -> i32 ---
		st_color_glyphs :: proc(layout: ^native.Layout) -> i32 ---
	}
}

@(test)
native_fallbacks_cover_scripts_and_join_color_emoji :: proc(t: ^testing.T) {
	state := State {
		density = 1,
	}
	if !testing.expect(t, init_text(&state)) {return}
	defer close(&state)
	for sample in ([]struct {
			size: f32,
			role: Font_Role,
		}{{14, .Regular}, {17.5, .Numeric}, {28, .Medium}, {84, .Bold}}) {
		size, role := sample.size, sample.role
		advance: f32
		for digit in '0' ..= '9' {
			width, _ := text_size(&state, string([]u8{u8(digit)}), size, u16(role))
			if digit == '0' {advance = width}
			testing.expect_value(t, width, advance)
		}
		for value in ([]string{"千葉雄喜", "⟡ ✧ *:･ﾟ✧", "Українська · Кино", "Ελληνικά", "العربية", "עברית", "हिन्दी", "ไทย"}) {
			entry := cached_text(&state, value, size, u16(role))
			if !testing.expect(t, entry != nil) {continue}
			testing.expect(t, entry.metrics.width > 0 && entry.metrics.height > 0)
			when ODIN_OS == .Linux {testing.expect_value(t, st_missing(entry.layout), i32(0))}
		}
		finish_text_frame(&state)
	}
	for value in ([]string{"🚘", "💨", "👍🏽", "🇯🇵", "👨‍👩‍👧", "1️⃣", "#️⃣", "*️⃣", "❤️", "©️"}) {
		entry := cached_text(&state, value, 28)
		if !testing.expect(t, entry != nil) {continue}
		when ODIN_OS == .Linux {
			testing.expect_value(t, st_missing(entry.layout), i32(0))
			testing.expect_value(t, st_color_glyphs(entry.layout), i32(1))
		}
		image := native.render(entry.layout, 255, 255, 255)
		if testing.expect(t, image.pixels != nil) {native.free_image(image)}
	}
}
