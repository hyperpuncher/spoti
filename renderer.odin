package main

import "base:runtime"
import libc "core:c/libc"
import "core:fmt"
import "core:strings"
import diagnostic "diagnostic"
import library "spotify/library"
import ui "ui"
import clay "vendor/clay"
import sdl "vendor:sdl3"

COVER_TEXTURE_BUDGET :: 128 * 1024 * 1024

Cover_Request_State :: struct {
	pending:  bool,
	attempts: u8,
	bytes:    int,
	used:     u64,
}

Textures :: struct {
	by_key:                   map[u64]^sdl.Texture,
	requested:                map[u64]Cover_Request_State,
	icon_colors:              [Icon_Tint]sdl.Color,
	cover_bytes:              int,
	cover_frame:              u64,
	fade_top:                 u64,
	fade_bottom:              u64,
	hero_fade:                u64,
	fade_top_alpha:           f32,
	fade_bottom_alpha:        f32,
	// The detail list scrolls independently of the sidebar grid, so it
	// eases its own pair instead of fighting over the shared one.
	fade_detail_top_alpha:    f32,
	fade_detail_bottom_alpha: f32,
	// The detail page sits on theme.bg, not the sidebar, so its strips are
	// baked with the page tint instead of reusing the sidebar pair.
	fade_detail_top:          u64,
	fade_detail_bottom:       u64,
}

// Scroll-edge fades baked once as dithered ramp strips, keyed by texture
// address like covers and freed with them. Tinted per surface at upload:
// the sidebar pair follows theme.sidebar, the detail pair follows theme.bg.
load_fades :: proc(state: ^ui.State, textures: ^Textures) {
	textures.fade_top = load_fade(state, textures, false)
	textures.fade_bottom = load_fade(state, textures, true)
	textures.hero_fade = load_fade(state, textures, true, smooth = true)
	textures.fade_detail_top = load_fade(state, textures, false)
	textures.fade_detail_bottom = load_fade(state, textures, true)
	retint_fades(textures)
}

load_fade :: proc(state: ^ui.State, textures: ^Textures, flip: bool, smooth: bool = false) -> u64 {
	texture := ui.make_fade_texture(state, flip, smooth)
	if texture == nil {return 0}
	key := u64(uintptr(texture))
	textures.by_key[key] = texture
	return key
}

// Recolors the baked fade strips after a theme switch; the ramp pixels
// stay white and only the mods follow their surfaces.
retint_fades :: proc(textures: ^Textures) {
	for key in ([2]u64{textures.fade_top, textures.fade_bottom}) {
		texture := textures.by_key[key]
		if texture == nil {continue}
		_ = sdl.SetTextureColorMod(
			texture,
			u8(theme.sidebar.r),
			u8(theme.sidebar.g),
			u8(theme.sidebar.b),
		)
	}
	for key in ([]u64{textures.fade_detail_top, textures.fade_detail_bottom, textures.hero_fade}) {
		texture := textures.by_key[key]
		if texture == nil {continue}
		_ = sdl.SetTextureColorMod(texture, u8(theme.bg.r), u8(theme.bg.g), u8(theme.bg.b))
	}
}

// Keep the previous artwork visible until the requested replacement is uploaded.
retain_player_cover :: proc(displayed: ^string, desired: string, textures: ^Textures) {
	if desired == displayed^ || textures.by_key[cover_key(desired)] == nil {return}
	next := strings.clone(desired)
	delete(displayed^)
	displayed^ = next
}

retry_failed_covers :: proc(textures: ^Textures) {
	for _, &request in textures.requested {
		if !request.pending {request.attempts = 0}
	}
}

// Evict old covers only after presentation. Keep this frame's images and both
// player covers, even when the visible working set exceeds the soft budget.
trim_cover_textures :: proc(
	textures: ^Textures,
	displayed, desired: string,
	budget: int = COVER_TEXTURE_BUDGET,
) {
	if textures.cover_bytes <= budget {return}
	displayed_key, desired_key := cover_key(displayed), cover_key(desired)
	for textures.cover_bytes > budget {
		oldest_key: u64
		oldest_frame := max(u64)
		found := false
		for key, request in textures.requested {
			if request.bytes == 0 ||
			   request.pending ||
			   request.used >= textures.cover_frame ||
			   key == displayed_key ||
			   key == desired_key {continue}
			if request.used < oldest_frame {
				oldest_key, oldest_frame, found = key, request.used, true
			}
		}
		if !found {break}
		sdl.DestroyTexture(textures.by_key[oldest_key])
		textures.cover_bytes -= textures.requested[oldest_key].bytes
		delete_key(&textures.by_key, oldest_key)
		// An evicted cover can be requested again; failures keep their retry cap.
		delete_key(&textures.requested, oldest_key)
	}
}

// A backtrace on InternalError is the only way to identify which Clay
// array overflowed, so it stays even in non-verbose runs. Errors are rare.
clay_error :: proc "c" (data: clay.ErrorData) {
	context = runtime.default_context()
	message := string(data.errorText.chars[:data.errorText.length])
	fmt.eprintln("clay:", data.errorType, message)
	diagnostic.write(message)
	if data.errorType == .InternalError {
		frames: [32]rawptr
		depth := backtrace(raw_data(frames[:]), len(frames))
		if depth > 0 {
			symbols := backtrace_symbols(raw_data(frames[:]), depth)
			if symbols != nil {
				defer libc.free(symbols)
				for i in 0 ..< depth {
					line := fmt.aprintf("clay trace: %s", symbols[i])
					diagnostic.write(line)
					delete(line)
				}
			}
		}
	}
}

measure_text :: proc "c" (
	text: clay.StringSlice,
	config: ^clay.TextElementConfig,
	user_data: rawptr,
) -> clay.Dimensions {
	context = runtime.default_context()
	state := (^ui.State)(user_data)
	value := string(text.chars[:text.length])
	state.text_measures += 1
	width, height := ui.text_size(
		state,
		value,
		f32(config.fontSize) * ui.scale(state),
		config.fontId,
	)
	return {width, height}
}

render :: proc(
	commands: ^clay.ClayArray(clay.RenderCommand),
	state: ^ui.State,
	textures: ^Textures,
) {
	ui.poll_emoji(state)
	textures.cover_frame += 1
	clip_stack: [64]sdl.Rect
	clip_depth := 0
	for i in 0 ..< commands.length {
		command := clay.RenderCommandArray_Get(commands, i)
		box := command.boundingBox
		#partial switch command.commandType {
		case .Rectangle:
			color := command.renderData.rectangle.backgroundColor
			radius := command.renderData.rectangle.cornerRadius
			ui.fill_rounded(
				state,
				{box.x, box.y, box.width, box.height},
				{radius.topLeft, radius.topRight, radius.bottomRight, radius.bottomLeft},
				{u8(color.r), u8(color.g), u8(color.b), u8(color.a)},
			)
		case .Image:
			key := u64(uintptr(command.renderData.image.imageData))
			banner := command.id == clay.ID("hero_banner_image").id
			texture := textures.by_key[key]
			if request, found := &textures.requested[key]; found {
				request.used = textures.cover_frame
			}
			color := (^sdl.Color)(command.userData)
			// Icons always carry their next tint; covers and fades use other textures.
			if texture != nil && color != nil {
				_ = sdl.SetTextureColorMod(texture, color.r, color.g, color.b)
			}
			ui.draw_texture(state, texture, {box.x, box.y, box.width, box.height}, crop = banner)
			if banner {
				ui.mask_top_corners(
					state,
					{box.x, box.y, box.width, box.height},
					12 * ui.scale(state),
					{u8(theme.bg.r), u8(theme.bg.g), u8(theme.bg.b), 255},
				)
			}
		case .Text:
			text := command.renderData.text
			color := text.textColor
			ui.text(
				state,
				string(text.stringContents.chars[:text.stringContents.length]),
				box.x,
				box.y,
				f32(text.fontSize) * ui.scale(state),
				{u8(color.r), u8(color.g), u8(color.b), u8(color.a)},
				text.fontId,
			)
		case .Custom:
			if command.id == clay.ID("input_content").id {
				ui.editor_draw(
					state,
					(^ui.Editor)(command.renderData.custom.customData),
					{box.x, box.y, box.width, box.height},
					{u8(theme.text.r), u8(theme.text.g), u8(theme.text.b), 255},
					{u8(theme.muted.r), u8(theme.muted.g), u8(theme.muted.b), 255},
					{u8(theme.bg.r), u8(theme.bg.g), u8(theme.bg.b), 255},
				)
			}
		case .ScissorStart:
			clip := sdl.Rect{i32(box.x), i32(box.y), i32(box.width), i32(box.height)}
			if clip_depth > 0 {
				parent := clip_stack[clip_depth - 1]
				left := max(clip.x, parent.x)
				top := max(clip.y, parent.y)
				right := min(clip.x + clip.w, parent.x + parent.w)
				bottom := min(clip.y + clip.h, parent.y + parent.h)
				clip = {left, top, max(0, right - left), max(0, bottom - top)}
			}
			if clip_depth < len(clip_stack) {
				clip_stack[clip_depth] = clip
				clip_depth += 1
			}
			_ = sdl.SetRenderClipRect(state.renderer, &clip)
		case .ScissorEnd:
			if clip_depth > 0 {clip_depth -= 1}
			if clip_depth > 0 {
				_ = sdl.SetRenderClipRect(state.renderer, &clip_stack[clip_depth - 1])
			} else {
				_ = sdl.SetRenderClipRect(state.renderer, nil)
			}
		}
	}
}

cover_key :: proc(url: string) -> u64 {
	return library.url_key(url)
}

// Covers and icons both draw as Clay image elements keyed by a u64.
// The optional tint borrows the UI-owned icon palette through presentation.
image_element :: proc(key: u64, size: f32, tint: ^sdl.Color = nil) {
	clay.UI()(
	{
		layout = {sizing = {width = clay.SizingFixed(size), height = clay.SizingFixed(size)}},
		image = {imageData = rawptr(uintptr(key))},
		userData = tint,
	},
	)
}

cover_element :: proc(textures: ^Textures, url: string, size, radius: f32) {
	if len(url) == 0 || textures.by_key[cover_key(url)] == nil {
		clay.UI()(
		{
			layout = {sizing = {width = clay.SizingFixed(size), height = clay.SizingFixed(size)}},
			backgroundColor = theme.card,
			cornerRadius = clay.CornerRadiusAll(radius),
		},
		)
		return
	}
	// Cover pixels already contain a supersampled rounded alpha edge.
	image_element(cover_key(url), size)
}

icon_element :: proc(textures: ^Textures, name: string, tint: Icon_Tint, size: f32) {
	key := icon_key(name)
	if textures.by_key[key] == nil {return}
	image_element(key, size, &textures.icon_colors[tint])
}
