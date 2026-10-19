package ui

import "core:strings"
import "core:testing"

@(test)
editor_blink_waits_only_for_visible_caret :: proc(t: ^testing.T) {
	e := Editor {
		input         = strings.clone("x"),
		input_active  = true,
		blink_started = 1000,
		caret_painted = true,
	}
	defer delete(e.input)
	testing.expect(t, editor_caret_visible(&e, 1000))
	testing.expect(t, editor_caret_visible(&e, 1499))
	testing.expect_value(t, editor_blink_delay(&e, 1499), i32(1))
	testing.expect(t, !editor_caret_visible(&e, 1500))
	testing.expect_value(t, editor_blink_delay(&e, 1500), i32(0))
	e.caret_painted = false
	testing.expect_value(t, editor_blink_delay(&e, 1500), i32(500))
	testing.expect(t, editor_caret_visible(&e, 2000))
	e.anchor = 1
	testing.expect_value(t, editor_blink_delay(&e, 2000), i32(-1))
	e.anchor = 0
	e.input_active = false
	testing.expect_value(t, editor_blink_delay(&e, 2000), i32(-1))
}

@(test)
editor_replaces_only_selected_text :: proc(t: ^testing.T) {
	e := Editor {
		input  = strings.clone("hello Кино world"),
		anchor = 6,
		caret  = 14,
	}
	defer delete(e.input)
	testing.expect(t, editor_insert(&e, "🎵", 64))
	testing.expect_value(t, e.input, "hello 🎵 world")
	testing.expect_value(t, e.caret, 10)
	editor_move(&e, 6, true)
	testing.expect(t, editor_insert(&e, "", 64))
	testing.expect_value(t, e.input, "hello  world")
	testing.expect_value(t, e.anchor, e.caret)
	editor_move(&e, 0)
	testing.expect(t, !editor_insert(&e, "too long", 4))
	testing.expect_value(t, e.input, "hello  world")
	editor_select_all(&e)
	testing.expect(t, editor_insert(&e, "new", 4))
	testing.expect_value(t, e.input, "new")
	delete(e.input)
	e.input = strings.clone("👩💻")
	editor_move(&e, len("👩"))
	testing.expect(t, editor_insert(&e, "\u200d", 64))
	testing.expect_value(t, e.input, "👩‍💻")
	testing.expect_value(t, e.caret, len(e.input))
}

@(test)
editor_moves_and_selects_complete_graphemes :: proc(t: ^testing.T) {
	value := "a🇺🇦é👩‍💻b"
	position := 0
	for cluster in ([]string{"a", "🇺🇦", "é", "👩‍💻", "b"}) {
		next := editor_step(value, position, false)
		testing.expect_value(t, value[position:next], cluster)
		testing.expect_value(t, editor_step(value, next, true), position)
		position = next
	}
	for example in ([]struct {
			text: string,
			at:   int,
			word: string,
		}{{"hello Кино world", 9, "Кино"}, {"one   two", 4, "   "}, {"word,word", 4, ","}, {"Pi’erre Bourne", 4, "Pi’erre"}, {"'don't'", 4, "don't"}, {"hi 👩‍💻!", 5, "👩‍💻"}}) {
		low, high := editor_word(example.text, example.at)
		testing.expect_value(t, example.text[low:high], example.word)
	}
	testing.expect_value(t, editor_word_step("one  two", 0, false), 5)
	testing.expect_value(t, editor_word_step("one  two", 5, true), 0)
}
