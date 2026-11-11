package ui

import "core:strings"
import edit "core:text/edit"
import "core:unicode"
import "core:unicode/utf8"
import native "native_text"
import sdl "vendor:sdl3"

// One single-line input. Byte offsets always lie on grapheme boundaries.
Editor :: struct {
	input:                string, // borrowed from buffer; refreshed after edits
	buffer:               strings.Builder,
	editing:              edit.State,
	input_active:         bool,
	selecting:            bool,
	clicks:               u8,
	word_start, word_end: int,
	scroll:               f32, // logical pixels
	box:                  sdl.FRect, // last rendered text viewport, in drawable pixels
	placeholder:          string, // borrowed for the current frame
	blink_started:        u64,
	caret_painted:        bool,
}

EDITOR_CARET_MS :: 500
EDITOR_UNDO_LIMIT :: 32

// Initialize in the final owner: editing borrows the buffer's address.
editor_init :: proc(e: ^Editor) {
	e.buffer = strings.builder_make()
	edit.init(&e.editing, context.allocator, context.allocator)
	edit.setup_once(&e.editing, &e.buffer)
	e.editing.translate_by_grapheme = true
}

editor_destroy :: proc(e: ^Editor) {
	edit.destroy(&e.editing)
	strings.builder_destroy(&e.buffer)
	e^ = {}
}

editor_set_text :: proc(e: ^Editor, value: string) {
	edit.clear_all(&e.editing)
	strings.write_string(&e.buffer, value)
	e.input = strings.to_string(e.buffer)
	editor_move(e, len(e.input))
}

editor_caret_visible :: proc(e: ^Editor, now: u64) -> bool {
	return(
		e.input_active &&
		e.editing.selection[0] == e.editing.selection[1] &&
		(e.selecting || (now - e.blink_started) / EDITOR_CARET_MS % 2 == 0) \
	)
}

// Wake only at the next blink edge, not at the display refresh rate.
editor_blink_delay :: proc(e: ^Editor, now: u64) -> i32 {
	if !e.input_active ||
	   e.editing.selection[0] != e.editing.selection[1] ||
	   e.selecting {return -1}
	if editor_caret_visible(e, now) != e.caret_painted {return 0}
	return i32(EDITOR_CARET_MS - (now - e.blink_started) % EDITOR_CARET_MS)
}

editor_boundary :: proc(value: string, position: int) -> int {
	at := clamp(position, 0, len(value))
	if at == len(value) {return at}
	it := utf8.decode_grapheme_iterator_make(value)
	for part, g in utf8.decode_grapheme_iterate(&it) {
		if at < g.byte_index + len(part) {return g.byte_index}
	}
	return len(value)
}

editor_step :: proc(value: string, at: int, backward: bool) -> int {
	previous := 0
	it := utf8.decode_grapheme_iterator_make(value)
	for part, g in utf8.decode_grapheme_iterate(&it) {
		end := g.byte_index + len(part)
		if backward && end >= at {return g.byte_index}
		if !backward && end > at {return end}
		previous = end
	}
	return previous
}

// Whitespace, word characters, or one punctuation/emoji grapheme.
editor_word_class :: proc(value: string) -> int {
	r, _ := utf8.decode_rune_in_string(value)
	if unicode.is_space(r) {return 0}
	if unicode.is_letter(r) ||
	   unicode.is_number(r) ||
	   unicode.is_nonspacing_mark(r) ||
	   r == '_' {return 1}
	return 2
}

editor_word :: proc(value: string, position: int) -> (low, high: int) {
	if value == "" {return}
	at := clamp(position, 0, len(value) - 1)
	start, previous, target := 0, -1, -1
	it := utf8.decode_grapheme_iterator_make(value)
	for part, g in utf8.decode_grapheme_iterate(&it) {
		kind := editor_word_class(part)
		if (part == "'" || part == "’") &&
		   g.byte_index > 0 &&
		   g.byte_index + len(part) < len(value) {
			before, _ := utf8.decode_last_rune(value[:g.byte_index])
			after, _ := utf8.decode_rune_in_string(value[g.byte_index + len(part):])
			if (unicode.is_letter(before) || unicode.is_nonspacing_mark(before)) &&
			   unicode.is_letter(after) {kind = 1}
		}
		if target >= 0 && (kind != target || kind == 2) {return low, g.byte_index}
		if kind != previous || kind == 2 {start = g.byte_index}
		if at < g.byte_index + len(part) {low, target = start, kind}
		previous = kind
	}
	return low, len(value)
}

editor_word_step :: proc(value: string, position: int, backward: bool) -> int {
	at := position
	if backward {
		for at > 0 {
			at = editor_step(value, at, true)
			low, high := editor_word(value, at)
			if editor_word_class(value[low:high]) != 0 {return low}
			at = low
		}
		return 0
	}
	if at >= len(value) {return len(value)}
	_, at = editor_word(value, at)
	for at < len(value) {
		low, high := editor_word(value, at)
		if editor_word_class(value[low:high]) != 0 {break}
		at = high
	}
	return at
}

editor_move :: proc(e: ^Editor, at: int, extend: bool = false) {
	e.editing.selection[0] = editor_boundary(e.input, at)
	if !extend {e.editing.selection[1] = e.editing.selection[0]}
	e.editing.last_edit_time = {}
	e.blink_started = sdl.GetTicks()
}

editor_translate :: proc(e: ^Editor, direction: edit.Translation, extend: bool = false) {
	if direction == .Word_Left || direction == .Word_Right {
		editor_move(
			e,
			editor_word_step(e.input, e.editing.selection[0], direction == .Word_Left),
			extend,
		)
		return
	}
	if extend {edit.select_to(&e.editing, direction)} else {edit.move_to(&e.editing, direction)}
	e.editing.last_edit_time = {}
	e.blink_started = sdl.GetTicks()
}

editor_select_all :: proc(e: ^Editor) {
	edit.perform_command(&e.editing, .Select_All)
	e.editing.last_edit_time = {}
}

editor_insert :: proc(e: ^Editor, value: string, limit: int) -> bool {
	if value == "" {return false}
	low, high := edit.sorted_selection(&e.editing)
	if len(e.input) - (high - low) + len(value) > limit {return false}
	edit.update_time(&e.editing)
	edit.input_text(&e.editing, value)
	editor_changed(e)
	return true
}

editor_changed :: proc(e: ^Editor) {
	e.input = strings.to_string(e.buffer)
	position := e.editing.selection[0]
	// Inserting or deleting text can join graphemes across the edit.
	if !edit.has_selection(&e.editing) && editor_boundary(e.input, position) < position {
		position = editor_step(e.input, position, false)
		e.editing.selection = {position, position}
	}
	e.blink_started = sdl.GetTicks()
	for stack in ([]^[dynamic]^edit.Undo_State{&e.editing.undo, &e.editing.redo}) {
		if len(stack^) > EDITOR_UNDO_LIMIT {free(pop_front(stack), e.editing.undo_text_allocator)}
	}
}

editor_delete :: proc(e: ^Editor, direction: edit.Translation) -> bool {
	before := len(e.input)
	if !edit.has_selection(&e.editing) && (direction == .Word_Left || direction == .Word_Right) {
		editor_translate(e, direction, true)
	}
	if !edit.has_selection(&e.editing) &&
	   edit.translate_position(&e.editing, direction) == e.editing.selection[0] {return false}
	edit.update_time(&e.editing)
	edit.delete_to(&e.editing, direction)
	editor_changed(e)
	return len(e.input) != before
}

editor_undo :: proc(e: ^Editor, redo: bool, limit: int) -> bool {
	from, to := &e.editing.undo, &e.editing.redo
	if redo {from, to = to, from}
	if len(from^) == 0 || from^[len(from^) - 1].len > limit {return false}
	edit.undo(&e.editing, from, to)
	e.editing.last_edit_time = {}
	editor_changed(e)
	return true
}

// Layout, caret geometry, and hit testing use the same complete native line.
editor_x :: proc(state: ^State, value: string, at: int) -> f32 {
	entry := cached_text(state, value, 14 * scale(state))
	if entry == nil {return 0}
	return native.cursor(entry.layout, i32(editor_boundary(value, at)))
}

editor_hit :: proc(state: ^State, e: ^Editor, x: f32, nearest: bool = true) -> int {
	entry := cached_text(state, e.input, 14 * scale(state))
	if entry == nil {return 0}
	point := x - e.box.x + e.scroll * scale(state)
	return editor_boundary(e.input, int(native.hit(entry.layout, point, nearest ? 1 : 0)))
}

editor_ranges :: proc(state: ^State, value: string, low, high: int) -> []native.Rect {
	entry := cached_text(state, value, 14 * scale(state))
	if entry == nil {return nil}
	count := native.selection(entry.layout, i32(low), i32(high), nil, 0)
	if count <= 0 {return nil}
	rects := make([]native.Rect, count, context.temp_allocator)
	_ = native.selection(entry.layout, i32(low), i32(high), raw_data(rects), count)
	return rects
}

editor_press :: proc(state: ^State, e: ^Editor, x: f32, clicks: u8, extend: bool) {
	e.selecting = true
	e.clicks = clamp(clicks, 1, 3)
	if e.clicks == 3 {editor_select_all(e)} else if e.clicks == 2 {
		e.editing.selection[1], e.editing.selection[0] = editor_word(
			e.input,
			editor_hit(state, e, x, false),
		)
		e.editing.last_edit_time = {}
	} else {editor_move(e, editor_hit(state, e, x), extend)}
	e.word_start, e.word_end = edit.sorted_selection(&e.editing)
}

editor_drag :: proc(state: ^State, e: ^Editor, x: f32) {
	if e.clicks == 3 {return}
	at := editor_hit(state, e, x, e.clicks != 2)
	if e.clicks == 2 {
		low, high := editor_word(e.input, at)
		if at < e.word_start {e.editing.selection = {low, e.word_end}} else if at >= e.word_end {
			e.editing.selection = {high, e.word_start}
		} else {e.editing.selection = {e.word_end, e.word_start}}
	} else {editor_move(e, at, true)}
}

// Draw the full shaped line twice when selected, clipping the second pass.
// Splitting it into three text objects would change kerning and ligatures.
editor_draw :: proc(
	state: ^State,
	e: ^Editor,
	box: sdl.FRect,
	foreground, muted, background: sdl.Color,
) {
	e.box = box
	low, high := edit.sorted_selection(&e.editing)
	d := scale(state)
	caret: f32
	if e.input_active {caret = editor_x(state, e.input, e.editing.selection[0])}
	width, height := text_size(state, e.input, 14 * d)
	if e.input_active {
		e.scroll = clamp(e.scroll, 0, max(0, (width + 2 * d - box.w) / d))
		if caret < e.scroll * d {e.scroll = caret / d}
		if caret > e.scroll * d + box.w - 2 * d {e.scroll = max(0, (caret - box.w + 2 * d) / d)}
	} else {e.scroll = 0}
	clip := sdl.Rect{i32(box.x), i32(box.y), i32(box.w), i32(box.h)}
	previous: sdl.Rect
	had_clip := sdl.RenderClipEnabled(state.renderer)
	if had_clip {
		_ = sdl.GetRenderClipRect(state.renderer, &previous)
		_ = sdl.GetRectIntersection(clip, previous, &clip)
	}
	_ = sdl.SetRenderClipRect(state.renderer, &clip)
	defer {
		if had_clip {_ = sdl.SetRenderClipRect(state.renderer, &previous)} else {_ = sdl.SetRenderClipRect(state.renderer, nil)}
	}
	x := box.x - e.scroll * d
	y := box.y + (box.h - height) / 2
	selected := e.input_active && low != high
	ranges: []native.Rect
	if selected {
		ranges = editor_ranges(state, e.input, low, high)
		for rect in ranges {fill(state, {x + rect.x, y + rect.y - 2 * d, rect.width, rect.height + 4 * d}, foreground)}
	}
	value := e.input
	if !e.input_active && value == "" {value = e.placeholder}
	text(state, value, x, y, 14 * d, e.input_active ? foreground : muted)
	e.caret_painted = editor_caret_visible(e, sdl.GetTicks())
	if selected {
		for rect in ranges {
			selection := sdl.Rect{i32(x + rect.x), clip.y, i32(rect.width + 1), clip.h}
			_ = sdl.GetRectIntersection(clip, selection, &selection)
			_ = sdl.SetRenderClipRect(state.renderer, &selection)
			text(state, e.input, x, y, 14 * d, background)
		}
	} else if e.caret_painted {
		fill(state, {x + caret, y, max(1, d), height}, foreground)
	}
}
