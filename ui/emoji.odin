package ui

import "base:runtime"
import c "core:c/libc"
import "core:strings"
import "core:sync/chan"
import "core:thread"
import "core:unicode"
import "core:unicode/utf8"
import fontconfig "fontconfig"
import sdl "vendor:sdl3"
import ttf "vendor:sdl3/ttf"

Text_Piece :: struct {
	value: string,
	emoji: bool,
}

// Unicode 17 Emoji_Presentation ranges from emoji-data.txt.
// https://www.unicode.org/Public/17.0.0/ucd/emoji/emoji-data.txt
EMOJI_PRESENTATION_RANGES :: [?][2]rune {
	{0x231A, 0x231B},
	{0x23E9, 0x23EC},
	{0x23F0, 0x23F0},
	{0x23F3, 0x23F3},
	{0x25FD, 0x25FE},
	{0x2614, 0x2615},
	{0x2648, 0x2653},
	{0x267F, 0x267F},
	{0x2693, 0x2693},
	{0x26A1, 0x26A1},
	{0x26AA, 0x26AB},
	{0x26BD, 0x26BE},
	{0x26C4, 0x26C5},
	{0x26CE, 0x26CE},
	{0x26D4, 0x26D4},
	{0x26EA, 0x26EA},
	{0x26F2, 0x26F3},
	{0x26F5, 0x26F5},
	{0x26FA, 0x26FA},
	{0x26FD, 0x26FD},
	{0x2705, 0x2705},
	{0x270A, 0x270B},
	{0x2728, 0x2728},
	{0x274C, 0x274C},
	{0x274E, 0x274E},
	{0x2753, 0x2755},
	{0x2757, 0x2757},
	{0x2795, 0x2797},
	{0x27B0, 0x27B0},
	{0x27BF, 0x27BF},
	{0x2B1B, 0x2B1C},
	{0x2B50, 0x2B50},
	{0x2B55, 0x2B55},
	{0x1F004, 0x1F004},
	{0x1F0CF, 0x1F0CF},
	{0x1F18E, 0x1F18E},
	{0x1F191, 0x1F19A},
	{0x1F1E6, 0x1F1FF},
	{0x1F201, 0x1F201},
	{0x1F21A, 0x1F21A},
	{0x1F22F, 0x1F22F},
	{0x1F232, 0x1F236},
	{0x1F238, 0x1F23A},
	{0x1F250, 0x1F251},
	{0x1F300, 0x1F320},
	{0x1F32D, 0x1F335},
	{0x1F337, 0x1F37C},
	{0x1F37E, 0x1F393},
	{0x1F3A0, 0x1F3CA},
	{0x1F3CF, 0x1F3D3},
	{0x1F3E0, 0x1F3F0},
	{0x1F3F4, 0x1F3F4},
	{0x1F3F8, 0x1F43E},
	{0x1F440, 0x1F440},
	{0x1F442, 0x1F4FC},
	{0x1F4FF, 0x1F53D},
	{0x1F54B, 0x1F54E},
	{0x1F550, 0x1F567},
	{0x1F57A, 0x1F57A},
	{0x1F595, 0x1F596},
	{0x1F5A4, 0x1F5A4},
	{0x1F5FB, 0x1F64F},
	{0x1F680, 0x1F6C5},
	{0x1F6CC, 0x1F6CC},
	{0x1F6D0, 0x1F6D2},
	{0x1F6D5, 0x1F6D8},
	{0x1F6DC, 0x1F6DF},
	{0x1F6EB, 0x1F6EC},
	{0x1F6F4, 0x1F6FC},
	{0x1F7E0, 0x1F7EB},
	{0x1F7F0, 0x1F7F0},
	{0x1F90C, 0x1F93A},
	{0x1F93C, 0x1F945},
	{0x1F947, 0x1F9FF},
	{0x1FA70, 0x1FA7C},
	{0x1FA80, 0x1FA8A},
	{0x1FA8E, 0x1FAC6},
	{0x1FAC8, 0x1FAC8},
	{0x1FACD, 0x1FADC},
	{0x1FADF, 0x1FAEA},
	{0x1FAEF, 0x1FAF8},
}

emoji_cluster :: proc(value: string) -> bool {
	first, _ := utf8.decode_rune_in_string(value)
	presentation := false
	for character in value {
		if character == 0xFE0E {return false}
		if character ==
		   0x20E3 {return first == '#' || first == '*' || (first >= '0' && first <= '9')}
		if character == 0xFE0F ||
		   character == 0x200D ||
		   unicode.is_emoji_modifier(character) {presentation = true}
	}
	if presentation && unicode.is_emoji_extended_pictographic(first) {return true}
	for interval in EMOJI_PRESENTATION_RANGES {
		if first < interval[0] {return false}
		if first <= interval[1] {return true}
	}
	return false
}

text_pieces :: proc(value: string, allocator := context.temp_allocator) -> [dynamic]Text_Piece {
	pieces := make([dynamic]Text_Piece, allocator)
	start := 0
	it := utf8.decode_grapheme_iterator_make(value)
	for cluster, grapheme in utf8.decode_grapheme_iterate(&it) {
		if !emoji_cluster(cluster) {continue}
		if grapheme.byte_index >
		   start {append(&pieces, Text_Piece{value[start:grapheme.byte_index], false})}
		append(&pieces, Text_Piece{cluster, true})
		start = grapheme.byte_index + len(cluster)
	}
	if start < len(value) {append(&pieces, Text_Piece{value[start:], false})}
	return pieces
}

emoji_side :: proc(font: ^ttf.Font) -> f32 {
	min_y, max_y: c.int
	if !ttf.GetGlyphMetrics(
		font,
		u32('H'),
		nil,
		nil,
		&min_y,
		&max_y,
		nil,
	) {return f32(ttf.GetFontHeight(font)) * 0.75}
	return max(1, f32(max_y - min_y) * 1.15)
}

// Center emoji ink on the visible capitals, not on the bitmap's bottom.
emoji_rect :: proc(font: ^ttf.Font, x, y: f32) -> sdl.FRect {
	side := emoji_side(font)
	center := f32(ttf.GetFontHeight(font)) / 2
	min_y, max_y: c.int
	if ttf.GetGlyphMetrics(font, u32('H'), nil, nil, &min_y, &max_y, nil) {
		center = f32(ttf.GetFontAscent(font)) - f32(min_y + max_y) / 2
	}
	return {x, y + center - side / 2, side, side}
}

// SDL_textengine.h's public draw-operation ABI. Only the prefix of TextData
// needed to inspect glyph copies is used; no private TextLayout is accessed.
Emoji_Copy_Operation :: struct {
	command, text_offset: c.int,
	font:                 ^ttf.Font,
	glyph_index:          u32,
	src, dst:             sdl.Rect,
	reserved:             rawptr,
}
Emoji_Draw_Operation :: struct #raw_union {
	command: c.int,
	copy:    Emoji_Copy_Operation,
}
Emoji_Text_Data :: struct {
	font:                         ^ttf.Font,
	color:                        sdl.FColor,
	needs_layout_update:          bool,
	layout:                       rawptr,
	x, y, width, height, num_ops: c.int,
	ops:                          [^]Emoji_Draw_Operation,
}

EMOJI_IMAGE_SIDE :: 96
EMOJI_CACHE_LIMIT :: 256

// Reject unjoined sequences and missing glyphs instead of squeezing several
// separate pictures into a single emoji cell. All work here is worker-only.
emoji_surface :: proc(font: ^ttf.Font, value: string) -> ^sdl.Surface {
	if font == nil {return nil}
	text := ttf.CreateText(nil, font, raw_data(value), uint(len(value)))
	if text == nil {return nil}
	defer ttf.DestroyText(text)
	if !ttf.UpdateText(text) {return nil}
	data := cast(^Emoji_Text_Data)text.internal
	copies := 0
	for op in data.ops[:data.num_ops] {
		if op.command == 2 {
			if op.copy.glyph_index == 0 {return nil}
			copies += 1
		}
	}
	if copies == 0 {return nil}
	if copies > 1 {
		// Some system fonts compose one emoji from overlapping glyph layers.
		// Accept one advancing cell, but reject unjoined side-by-side parts.
		cell, width: c.int
		if !ttf.GetGlyphMetrics(font, 0x1F600, nil, nil, nil, nil, &cell) ||
		   !ttf.GetTextSize(text, &width, nil) ||
		   cell <= 0 ||
		   f32(width) > f32(cell) * 1.1 {return nil}
	}
	source := ttf.RenderText_Blended(font, raw_data(value), uint(len(value)), {255, 255, 255, 255})
	if source == nil {return nil}
	defer sdl.DestroySurface(source)
	left, top, right, bottom := source.w, source.h, c.int(-1), c.int(-1)
	for y in 0 ..< source.h {
		for x in 0 ..< source.w {
			a: u8
			if sdl.ReadSurfacePixel(source, x, y, nil, nil, nil, &a) && a > 0 {
				left, top = min(left, x), min(top, y)
				right, bottom = max(right, x), max(bottom, y)
			}
		}
	}
	if right < left {return nil}
	crop := sdl.Rect{left, top, right - left + 1, bottom - top + 1}
	scale := f32(EMOJI_IMAGE_SIDE) / f32(max(crop.w, crop.h))
	width, height := max(1, c.int(f32(crop.w) * scale)), max(1, c.int(f32(crop.h) * scale))
	dest := sdl.Rect {
		(EMOJI_IMAGE_SIDE - width) / 2,
		(EMOJI_IMAGE_SIDE - height) / 2,
		width,
		height,
	}
	result := sdl.CreateSurface(EMOJI_IMAGE_SIDE, EMOJI_IMAGE_SIDE, .RGBA32)
	if result == nil {return nil}
	_ = sdl.SetSurfaceBlendMode(source, sdl.BLENDMODE_NONE)
	if !sdl.BlitSurfaceScaled(
		source,
		&crop,
		result,
		&dest,
		.LINEAR,
	) {sdl.DestroySurface(result); return nil}
	return result
}

Emoji_Result :: struct {
	value:   string,
	surface: ^sdl.Surface,
}
Emoji_Record :: struct {
	texture: ^sdl.Texture,
	ready:   bool,
	used:    u64,
}
Emoji_Cache :: struct {
	requests:  chan.Chan(string),
	results:   chan.Chan(Emoji_Result),
	worker:    ^thread.Thread,
	records:   map[string]Emoji_Record,
	clock:     u64,
	wake:      proc "c" (_: rawptr),
	allocator: runtime.Allocator,
}

emoji_worker :: proc(pointer: rawptr) {
	cache := cast(^Emoji_Cache)pointer
	config := fontconfig.InitLoadConfigAndFonts()
	defer {if config != nil {fontconfig.ConfigDestroy(config)}}
	path, index := fontconfig.match(config, 0, fontconfig.WEIGHT_REGULAR, color_emoji = true)
	defer delete(path)
	font := open_font({path, index}, EMOJI_IMAGE_SIDE)
	defer ttf.CloseFont(font)
	for value in chan.recv(cache.requests) {
		surface := emoji_surface(font, value)
		chan.send(cache.results, Emoji_Result{value, surface})
		if cache.wake != nil {cache.wake(nil)}
	}
}

start_emoji :: proc(state: ^State, wake: proc "c" (_: rawptr)) -> bool {
	cache := new(Emoji_Cache)
	cache.allocator = context.allocator
	cache.wake = wake
	cache.records = make(map[string]Emoji_Record)
	err: runtime.Allocator_Error
	cache.requests, err = chan.create_buffered(chan.Chan(string), 32, cache.allocator)
	if err != nil {delete(cache.records); free(cache); return false}
	cache.results, err = chan.create_buffered(
		chan.Chan(Emoji_Result),
		EMOJI_CACHE_LIMIT,
		cache.allocator,
	)
	if err != nil {chan.destroy(cache.requests); delete(cache.records); free(cache); return false}
	cache.worker = thread.create_and_start_with_data(cache, emoji_worker)
	if cache.worker ==
	   nil {chan.destroy(cache.requests); chan.destroy(cache.results); delete(cache.records); free(cache); return false}
	state.emoji = cache
	return true
}

stop_emoji :: proc(state: ^State) {
	cache := state.emoji
	if cache == nil {return}
	// At most CACHE_LIMIT records can be pending, so the result channel can
	// hold every remaining result while shutdown joins the worker.
	chan.close(cache.requests)
	thread.destroy(cache.worker)
	for result in chan.try_recv(cache.results) {
		if result.surface != nil {sdl.DestroySurface(result.surface)}
		delete(result.value, cache.allocator)
	}
	chan.destroy(cache.requests)
	chan.destroy(cache.results)
	for value, record in cache.records {
		if record.texture != nil {sdl.DestroyTexture(record.texture)}
		delete(value, cache.allocator)
	}
	delete(cache.records)
	free(cache, cache.allocator)
	state.emoji = nil
}

emoji_texture :: proc(state: ^State, value: string) -> ^sdl.Texture {
	cache := state.emoji
	if cache == nil {return nil}
	cache.clock += 1
	if record, found := cache.records[value]; found {
		record.used = cache.clock
		cache.records[value] = record
		return record.texture
	}
	if len(cache.records) >= EMOJI_CACHE_LIMIT {
		oldest: string
		stamp := max(u64)
		for key, record in cache.records {
			if record.ready && record.used < stamp {oldest, stamp = key, record.used}
		}
		if oldest == "" {return nil}
		record := cache.records[oldest]
		if record.texture != nil {sdl.DestroyTexture(record.texture)}
		delete_key(&cache.records, oldest)
		delete(oldest, cache.allocator)
	}
	request := strings.clone(value, cache.allocator)
	if !chan.try_send(cache.requests, request) {delete(request, cache.allocator); return nil}
	key := strings.clone(value, cache.allocator)
	cache.records[key] = {
		used = cache.clock,
	}
	return nil
}

emoji_pending :: proc(state: ^State) -> bool {
	if state.emoji == nil {return false}
	for _, record in state.emoji.records {if !record.ready {return true}}
	return false
}

poll_emoji :: proc(state: ^State) {
	cache := state.emoji
	if cache == nil {return}
	// Keep texture uploads bounded even after a busy worker catches up.
	uploaded := 0
	for uploaded < 6 {
		result, ok := chan.try_recv(cache.results)
		if !ok {break}
		uploaded += 1
		record := cache.records[result.value]
		record.ready = true
		if result.surface != nil {
			record.texture = sdl.CreateTextureFromSurface(state.renderer, result.surface)
			if record.texture != nil {
				_ = sdl.SetTextureScaleMode(record.texture, .LINEAR)
				_ = sdl.SetTextureBlendMode(record.texture, sdl.BLENDMODE_BLEND)
			}
			sdl.DestroySurface(result.surface)
		}
		cache.records[result.value] = record
		delete(result.value, cache.allocator)
	}
	if uploaded == 6 && cache.wake != nil {cache.wake(nil)}
}
