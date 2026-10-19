package ui

import "core:strings"
import "core:unicode"
import "core:unicode/utf8"
import sdl "vendor:sdl3"
import ttf "vendor:sdl3/ttf"

// One single-line input. Byte offsets always lie on grapheme boundaries.
Editor :: struct {
	input:                string, // owned; replaced through context.allocator
	input_active:         bool,
	caret, anchor:        int,
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

editor_caret_visible :: proc(e: ^Editor, now: u64) -> bool {
	return(
		e.input_active &&
		e.caret == e.anchor &&
		(e.selecting || (now - e.blink_started) / EDITOR_CARET_MS % 2 == 0) \
	)
}

// Wake only at the next blink edge, not at the display refresh rate.
editor_blink_delay :: proc(e: ^Editor, now: u64) -> i32 {
	if !e.input_active || e.caret != e.anchor || e.selecting {return -1}
	if editor_caret_visible(e, now) != e.caret_painted {return 0}
	return i32(EDITOR_CARET_MS - (now - e.blink_started) % EDITOR_CARET_MS)
}

editor_bounds :: proc(e: ^Editor) -> (int, int) {
	e.caret = editor_boundary(e.input, e.caret)
	e.anchor = editor_boundary(e.input, e.anchor)
	return min(e.caret, e.anchor), max(e.caret, e.anchor)
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
	e.caret = editor_boundary(e.input, at)
	e.blink_started = sdl.GetTicks()
	if !extend {e.anchor = e.caret}
}

editor_select_all :: proc(e: ^Editor) {
	e.anchor, e.caret = 0, len(e.input)
}

editor_insert :: proc(e: ^Editor, value: string, limit: int) -> bool {
	low, high := editor_bounds(e)
	if len(e.input) - (high - low) + len(value) > limit {return false}
	if low == high && value == "" {return false}
	parts := [3]string{e.input[:low], value, e.input[high:]}
	next := strings.join(parts[:], "")
	delete(e.input)
	e.input = next
	position := low + len(value)
	if editor_boundary(e.input, position) < position {
		position = editor_step(e.input, position, false)
	}
	editor_move(e, position)
	return true
}

// SDL_ttf supplies shaped glyph positions; emoji uses the same cells as text().
editor_x :: proc(state: ^State, value: string, at: int) -> f32 {
	font := font_for_size(state, 14 * scale(state))
	if font == nil {return 0}
	pen: f32
	base := 0
	for piece in text_pieces(value) {
		if piece.emoji {
			if at < base + len(piece.value) {return pen}
			pen += emoji_side(font)
		} else {
			content := cached_text(
				state,
				&state.measured_texts,
				piece.value,
				14 * scale(state),
				preserve_spaces = true,
			)
			if content != nil {
				if at <= base + len(piece.value) {
					sub: ttf.SubString
					if ttf.GetTextSubString(content, i32(at - base), &sub) {
						bearing := base == 0 ? glyph_left_bearing(font, piece.value) : 0
						edge := sub.rect.x
						if sub.flags.direction == u8(ttf.Direction.RTL) {edge += sub.rect.w}
						return max(0, pen + f32(edge) - bearing)
					}
				}
				width: i32
				_ = ttf.GetTextSize(content, &width, nil)
				pen += f32(width)
			}
		}
		base += len(piece.value)
	}
	return pen
}

editor_hit :: proc(state: ^State, e: ^Editor, x: f32, nearest: bool = true) -> int {
	font := font_for_size(state, 14 * scale(state))
	if font == nil {return 0}
	point := x - e.box.x + e.scroll * scale(state)
	pen: f32
	base := 0
	for piece in text_pieces(e.input) {
		width: f32
		if piece.emoji {
			width = emoji_side(font)
			if point <
			   pen +
				   width {return base + (nearest && point >= pen + width / 2 ? len(piece.value) : 0)}
		} else {
			content := cached_text(
				state,
				&state.measured_texts,
				piece.value,
				14 * scale(state),
				preserve_spaces = true,
			)
			if content != nil {
				w: i32
				_ = ttf.GetTextSize(content, &w, nil)
				width = f32(w)
				if point < pen + width || base + len(piece.value) == len(e.input) {
					bearing := base == 0 ? glyph_left_bearing(font, piece.value) : 0
					sub: ttf.SubString
					if ttf.GetTextSubStringForPoint(content, i32(point - pen + bearing), 0, &sub) {
						at := base + int(sub.offset)
						trailing := point - pen + bearing >= f32(sub.rect.x) + f32(sub.rect.w) / 2
						if sub.flags.direction == u8(ttf.Direction.RTL) {trailing = !trailing}
						if nearest && trailing {at += int(sub.length)}
						return editor_boundary(e.input, at)
					}
				}
			}
		}
		pen += width
		base += len(piece.value)
	}
	return len(e.input)
}

editor_press :: proc(state: ^State, e: ^Editor, x: f32, clicks: u8, extend: bool) {
	e.selecting = true
	e.clicks = clamp(clicks, 1, 3)
	if e.clicks == 3 {editor_select_all(e)} else if e.clicks == 2 {
		e.anchor, e.caret = editor_word(e.input, editor_hit(state, e, x, false))
	} else {editor_move(e, editor_hit(state, e, x), extend)}
	e.word_start, e.word_end = editor_bounds(e)
}

editor_drag :: proc(state: ^State, e: ^Editor, x: f32) {
	if e.clicks == 3 {return}
	at := editor_hit(state, e, x, e.clicks != 2)
	if e.clicks == 2 {
		low, high := editor_word(e.input, at)
		if at < e.word_start {e.anchor, e.caret = e.word_end, low} else if at >= e.word_end {
			e.anchor, e.caret = e.word_start, high
		} else {e.anchor, e.caret = e.word_start, e.word_end}
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
	low, high := editor_bounds(e)
	d := scale(state)
	caret: f32
	if e.input_active {caret = editor_x(state, e.input, e.caret)}
	width, height := text_size(state, e.input, 14 * d, preserve_spaces = true)
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
	anchor := caret
	if selected {anchor = editor_x(state, e.input, e.anchor)}
	left, right := min(caret, anchor), max(caret, anchor)
	if selected {fill(state, {x + left, y - 2 * d, right - left, height + 4 * d}, foreground)}
	value := e.input
	if !e.input_active && value == "" {value = e.placeholder}
	text(state, value, x, y, 14 * d, e.input_active ? foreground : muted, preserve_spaces = true)
	e.caret_painted = editor_caret_visible(e, sdl.GetTicks())
	if selected {
		selection := sdl.Rect{i32(x + left), clip.y, i32(right - left), clip.h}
		_ = sdl.GetRectIntersection(clip, selection, &selection)
		_ = sdl.SetRenderClipRect(state.renderer, &selection)
		text(state, e.input, x, y, 14 * d, background, preserve_spaces = true)
	} else if e.caret_painted {
		fill(state, {x + caret, y, max(1, d), height}, foreground)
	}
}
