package ui

import "core:testing"
import edit "core:text/edit"

@(test)
editor_blink_waits_only_for_visible_caret :: proc(t: ^testing.T) {
	e := Editor {
		input_active  = true,
		blink_started = 1000,
		caret_painted = true,
	}
	testing.expect(t, editor_caret_visible(&e, 1000))
	testing.expect(t, editor_caret_visible(&e, 1499))
	testing.expect_value(t, editor_blink_delay(&e, 1499), i32(1))
	testing.expect(t, !editor_caret_visible(&e, 1500))
	testing.expect_value(t, editor_blink_delay(&e, 1500), i32(0))
	e.caret_painted = false
	testing.expect_value(t, editor_blink_delay(&e, 1500), i32(500))
	testing.expect(t, editor_caret_visible(&e, 2000))
	e.editing.selection[1] = 1
	testing.expect_value(t, editor_blink_delay(&e, 2000), i32(-1))
	e.editing.selection[1] = 0
	e.input_active = false
	testing.expect_value(t, editor_blink_delay(&e, 2000), i32(-1))
}

@(test)
editor_replaces_only_selected_text :: proc(t: ^testing.T) {
	e: Editor
	editor_init(&e)
	defer editor_destroy(&e)
	editor_set_text(&e, "hello Кино world")
	editor_move(&e, 6)
	editor_move(&e, 14, true)
	testing.expect(t, editor_insert(&e, "🎵", 64))
	testing.expect_value(t, e.input, "hello 🎵 world")
	testing.expect_value(t, e.editing.selection[0], 10)
	editor_move(&e, 6, true)
	testing.expect(t, editor_delete(&e, .Left))
	testing.expect_value(t, e.input, "hello  world")
	testing.expect_value(t, e.editing.selection[1], e.editing.selection[0])
	editor_move(&e, 0)
	testing.expect(t, !editor_insert(&e, "too long", 4))
	testing.expect_value(t, e.input, "hello  world")
	editor_select_all(&e)
	testing.expect(t, editor_insert(&e, "new", 4))
	testing.expect_value(t, e.input, "new")
	testing.expect(t, !editor_undo(&e, false, 4))
	editor_set_text(&e, "👩💻")
	editor_move(&e, len("👩"))
	testing.expect(t, editor_insert(&e, "\u200d", 64))
	testing.expect_value(t, e.input, "👩‍💻")
	testing.expect_value(t, e.editing.selection[0], len(e.input))
	testing.expect(t, editor_undo(&e, false, 64))
	testing.expect_value(t, e.input, "👩💻")
	editor_move(&e, 0)
	testing.expect(t, !editor_delete(&e, .Left))
	testing.expect(t, editor_undo(&e, true, 64))
	testing.expect_value(t, e.editing.selection[0], len("👩‍💻"))
	testing.expect(t, editor_delete(&e, .Left))
	testing.expect_value(t, e.input, "")
	editor_set_text(&e, "🇺x🇦")
	editor_move(&e, len("🇺"))
	editor_move(&e, len("🇺x"), true)
	testing.expect(t, editor_delete(&e, .Left))
	testing.expect_value(t, e.input, "🇺🇦")
	testing.expect_value(t, e.editing.selection[0], len(e.input))
}

@(test)
editor_selects_unicode_graphemes_and_words :: proc(t: ^testing.T) {
	e: Editor
	editor_init(&e)
	defer editor_destroy(&e)
	editor_set_text(&e, "a👩‍💻b")
	editor_move(&e, 1)
	editor_translate(&e, .Right, true)
	low, high := edit.sorted_selection(&e.editing)
	testing.expect_value(t, e.input[low:high], "👩‍💻")
	for example in ([]struct {
			text: string,
			at:   int,
			word: string,
		}{{"hello Кино world", 9, "Кино"}, {"one   two", 4, "   "}, {"word,word", 4, ","}, {"Pi’erre Bourne", 4, "Pi’erre"}, {"'don't'", 4, "don't"}, {"hi 👩‍💻!", 5, "👩‍💻"}}) {
		low, high = editor_word(example.text, example.at)
		testing.expect_value(t, example.text[low:high], example.word)
	}
	editor_set_text(&e, "one\u00a0Кино 👩‍💻")
	editor_move(&e, 0)
	editor_translate(&e, .Word_Right, true)
	editor_translate(&e, .Word_Right, true)
	low, high = edit.sorted_selection(&e.editing)
	testing.expect_value(t, e.input[low:high], "one\u00a0Кино ")
	editor_translate(&e, .Left)
	testing.expect_value(t, e.editing.selection, [2]int{0, 0})
	editor_translate(&e, .End)
	testing.expect(t, editor_delete(&e, .Word_Left))
	testing.expect_value(t, e.input, "one\u00a0Кино ")
}

@(test)
editor_history_is_bounded_and_cleared_on_navigation :: proc(t: ^testing.T) {
	e: Editor
	editor_init(&e)
	defer editor_destroy(&e)
	for _ in 0 ..< EDITOR_UNDO_LIMIT + 4 {
		editor_move(&e, len(e.input))
		testing.expect(t, editor_insert(&e, "x", 64))
	}
	for _ in 0 ..< EDITOR_UNDO_LIMIT {testing.expect(t, editor_undo(&e, false, 64))}
	testing.expect(t, !editor_undo(&e, false, 64))
	testing.expect_value(t, e.input, "xxxx")
	editor_set_text(&e, "restored search")
	testing.expect(t, !editor_undo(&e, true, 64))
	testing.expect(t, !editor_undo(&e, false, 64))
	testing.expect_value(t, e.input, "restored search")
}
