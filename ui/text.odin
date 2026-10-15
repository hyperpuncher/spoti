package ui

import c "core:c/libc"
import "core:strings"
import "core:unicode/utf8"
import sdl "vendor:sdl3"
import ttf "vendor:sdl3/ttf"

// Each pool retains one frame's text objects in call order. SDL_ttf owns the
// copied strings and updates cached layouts when their font or text changes.
Text_Pool :: struct {
	text_engine: ^ttf.TextEngine,
	texts:       [dynamic]^ttf.Text,
	text_count:  int,
}

cached_text :: proc(
	state: ^State,
	pool: ^Text_Pool,
	value: string,
	size: f32,
	font_id: u16 = 0,
) -> ^ttf.Text {
	font := font_for_size(state, size, font_id)
	if font == nil {return nil}
	content: ^ttf.Text
	if pool.text_count < len(pool.texts) {
		content = pool.texts[pool.text_count]
		if ttf.GetTextFont(content) == font && string(cstring(content.text)) == value {
			pool.text_count += 1
			return content
		}
	}
	// An unchanged slot already has its fallbacks. SDL_ttf updates existing
	// text objects when another string adds a fallback to the shared font.
	_ = font_for_text(state, value, size, font_id)
	if content == nil {
		content = ttf.CreateText(pool.text_engine, font, raw_data(value), len(value))
		if content == nil {return nil}
		append(&pool.texts, content)
	} else {
		if ttf.GetTextFont(content) != font && !ttf.SetTextFont(content, font) {return nil}
		if string(cstring(content.text)) != value &&
		   !ttf.SetTextString(content, raw_data(value), len(value)) {return nil}
	}
	pool.text_count += 1
	return content
}

// Emoji contributes one fixed cell to measurement, independent of image
// availability. Plain spans keep SDL_ttf shaping and their existing advances.
text_size :: proc(
	state: ^State,
	value: string,
	size: f32,
	font_id: u16 = 0,
) -> (
	width, height: f32,
) {
	font := font_for_size(state, size, font_id)
	if font == nil {return}
	height = f32(ttf.GetFontHeight(font))
	for piece in text_pieces(value) {
		if piece.emoji {width += emoji_side(font); continue}
		w, h: c.int
		measured := false
		if strings.contains_any(piece.value, "\r\n") {
			span_font := font_for_text(state, piece.value, size, font_id)
			if span_font == nil {continue}
			// Text objects lay out hard line breaks; string sizing does not.
			measured = ttf.GetStringSize(
				span_font,
				raw_data(piece.value),
				uint(len(piece.value)),
				&w,
				&h,
			)
		} else {
			content := cached_text(state, &state.measured_texts, piece.value, size, font_id)
			measured = content != nil && ttf.GetTextSize(content, &w, &h)
		}
		if measured {
			width += f32(w)
			height = max(height, f32(h))
		}
	}
	return
}

// Draw text and inline emoji on the renderer thread.
text :: proc(
	state: ^State,
	value: string,
	x, y, font_size: f32,
	color: sdl.Color,
	font_id: u16 = 0,
) {
	if value == "" {return}
	font := font_for_size(state, font_size, font_id)
	if font == nil {return}
	cursor := x
	for piece in text_pieces(value) {
		if piece.emoji {
			rect := emoji_rect(font, cursor, y)
			if texture := emoji_texture(state, piece.value); texture != nil {
				_ = sdl.SetTextureAlphaMod(texture, color.a)
				draw_texture(state, texture, rect)
			} else {
				_ = sdl.SetRenderDrawColor(state.renderer, color.r, color.g, color.b, color.a)
				_ = sdl.RenderRect(state.renderer, &rect)
			}
			cursor += rect.w
			continue
		}
		content := cached_text(state, &state.drawn_texts, piece.value, font_size, font_id)
		if content == nil {continue}
		_ = ttf.SetTextColor(content, color.r, color.g, color.b, color.a)
		pen := cursor
		if cursor == x {pen -= glyph_left_bearing(font, piece.value)}
		_ = ttf.DrawRendererText(content, f32(int(pen + 0.5)), f32(int(y + 0.5)))
		width: c.int
		if ttf.GetTextSize(content, &width, nil) {cursor += f32(width)}
	}
}

// Offset the first pen position so visible ink starts at the layout edge.
glyph_left_bearing :: proc(font: ^ttf.Font, value: string) -> f32 {
	r, _ := utf8.decode_rune_in_string(value)
	min_x: c.int
	if !ttf.GetGlyphMetrics(font, u32(r), &min_x, nil, nil, nil, nil) {return 0}
	return f32(min_x)
}

finish_text_frame :: proc(state: ^State) {
	for pool in ([]^Text_Pool{&state.drawn_texts, &state.measured_texts}) {
		for len(pool.texts) > pool.text_count {ttf.DestroyText(pop(&pool.texts))}
		pool.text_count = 0
	}
}
