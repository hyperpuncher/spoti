package main

import "core:fmt"
import "core:math"
import "core:strings"
import library "spotify/library"
import ui "ui"
import clay "vendor/clay"
import sdl "vendor:sdl3"

Visible_Items :: struct {
	first, last:   int,
	before, after: f32,
}

Frame_Visible :: struct {
	cards, tracks, releases, singles: Visible_Items,
}

// Release cards stop growing past a readable cover; wider windows gain
// columns instead of billboards.
RELEASE_CARD_MAX :: 200
RELEASE_CARD_COLUMNS :: 8

// Clip slots are visible-relative per section, so the singles grid offsets
// its truncation clips past anything the albums grid can hold.
RELEASE_CLIP_STRIDE :: 64

// Keep one extra row on either side. Spacers retain the complete scroll extent.
visible_items :: proc(count, columns: int, stride, offset, height: f32) -> Visible_Items {
	if count == 0 {return {}}
	rows := (count + columns - 1) / columns
	top := clamp(offset, 0, max(0, f32(rows) * stride - height))
	first := max(0, int(math.floor(top / stride)) - 1)
	last := min(rows, int(math.ceil((top + height) / stride)) + 1)
	return {
		first = first * columns,
		last = min(count, last * columns),
		before = f32(first) * stride,
		after = f32(rows - last) * stride,
	}
}

scroll_items :: proc(
	id: string,
	count, columns: int,
	stride, viewport_height: f32,
	leading: f32 = 0,
) -> Visible_Items {
	scroll := clay.GetScrollContainerData(clay.ID(id))
	offset: f32
	height := viewport_height
	if scroll.found && scroll.scrollPosition != nil {
		offset = -scroll.scrollPosition.y - leading
		if scroll.scrollContainerDimensions.height > 0 {
			height = scroll.scrollContainerDimensions.height
		}
	}
	// Sections share one scroll container and each sees the viewport at its
	// own leading offset. A section wholly outside the viewport renders no
	// cards but keeps its full height as spacers: clamping its offset to
	// zero instead would draw a full viewport of off-screen cards and
	// overflow Clay's fixed 100-entry scroll container array.
	if count > 0 && columns > 0 && stride > 0 {
		section := f32((count + columns - 1) / columns) * stride
		if offset + height <= 0 || offset >= section {return {after = section}}
	}
	return visible_items(count, columns, stride, offset, height)
}

// While pages stream in, the list already spans the full total so the
// scrollbar thumb has its final size. Unknown tail rows render as
// placeholders and collapse away if the server over-reported its total.
detail_item_count :: proc(loaded, total: int, loading: bool) -> int {
	if !loading || total <= loaded {return loaded}
	return total
}

// Same stride as a track row: number plus a bar where the title will land.
track_skeleton :: proc(index: int, d: f32) {
	if clay.UI()(
	{
		layout = {
			sizing = {width = clay.SizingGrow({}), height = clay.SizingFixed(44 * d)},
			padding = {left = u16(12 * d), right = u16(92 * d)},
			childAlignment = {y = .Center},
			childGap = u16(18 * d),
		},
	},
	) {
		if clay.UI()(
		{layout = {sizing = {width = clay.SizingFixed(24 * d)}, childAlignment = {x = .Right}}},
		) {
			clay.Text(
				fmt.aprintf("%d", index + 1, allocator = context.temp_allocator),
				clay.TextElementConfig{fontId = 1, fontSize = 15, textColor = MUTED},
			)
		}
		if clay.UI()(
		{
			layout = {sizing = {width = clay.SizingGrow({}), height = clay.SizingFixed(14 * d)}},
			backgroundColor = CARD,
			cornerRadius = clay.CornerRadiusAll(7 * d),
		},
		) {}
		if clay.UI()(
		{
			layout = {sizing = {width = clay.SizingGrow({}), height = clay.SizingFixed(14 * d)}},
			backgroundColor = CARD,
			cornerRadius = clay.CornerRadiusAll(7 * d),
		},
		) {}
	}
}

// Fixed to the card row height so the grid stride never shifts as covers land.
release_skeleton :: proc(card_width, row_height, d: f32) {
	padding := 8 * d
	cover_size := card_width - padding * 2
	if clay.UI()(
	{
		layout = {
			layoutDirection = .TopToBottom,
			sizing = {width = clay.SizingFixed(card_width), height = clay.SizingFixed(row_height)},
			padding = clay.PaddingAll(u16(padding)),
			childGap = u16(7 * d),
		},
	},
	) {
		if clay.UI()(
		{
			layout = {
				sizing = {
					width = clay.SizingFixed(cover_size),
					height = clay.SizingFixed(cover_size),
				},
			},
			backgroundColor = CARD,
			cornerRadius = clay.CornerRadiusAll(8 * d),
		},
		) {}
		if clay.UI()(
		{
			layout = {sizing = {width = clay.SizingGrow({}), height = clay.SizingFixed(13 * d)}},
			backgroundColor = CARD,
			cornerRadius = clay.CornerRadiusAll(6 * d),
		},
		) {}
	}
}

list_spacer :: proc(height: f32) {
	if height <= 0 {return}
	clay.UI()(
	{layout = {sizing = {width = clay.SizingGrow({}), height = clay.SizingFixed(height)}}},
	)
}

// Scroll-edge fades over the library grid while content overflows past
// them. Dithered ramp strips stretched over each zone. Opacity eases in
// and out instead of popping. Only overflowed edges draw.
FADE_HEIGHT :: 16
FADE_RATE :: 12.0

approach_alpha :: proc(current, target, dt: f32) -> f32 {
	next := current + (target - current) * min(1, dt * FADE_RATE)
	if abs(next - target) < 0.01 {return target}
	return next
}

scroll_fades :: proc(
	id: string,
	textures: ^Textures,
	top_key, bottom_key: u64,
	top_alpha, bottom_alpha: ^f32,
	x, width, dt, d: f32,
) {
	top_target, bottom_target: f32
	data := clay.GetScrollContainerData(clay.ID(id))
	if data.found && data.scrollPosition != nil {
		pos := data.scrollPosition.y
		height := data.scrollContainerDimensions.height
		if pos < -1 {top_target = 1}
		if data.contentDimensions.height + pos > height + 1 {bottom_target = 1}
		fade_height := FADE_HEIGHT * d
		fade_image(textures, top_key, top_alpha^, x, width, fade_height, 0)
		fade_image(
			textures,
			bottom_key,
			bottom_alpha^,
			x,
			width,
			fade_height,
			height - fade_height,
		)
	}
	top_alpha^ = approach_alpha(top_alpha^, top_target, dt)
	bottom_alpha^ = approach_alpha(bottom_alpha^, bottom_target, dt)
}

fade_image :: proc(textures: ^Textures, key: u64, alpha, x, width, height, y: f32) {
	texture := textures.by_key[key]
	if texture == nil || alpha <= 0.005 {return}
	sdl.SetTextureAlphaMod(texture, u8(alpha * 255))
	if clay.UI()(
	{
		layout = {sizing = {width = clay.SizingFixed(width), height = clay.SizingFixed(height)}},
		image = {imageData = rawptr(uintptr(key))},
		floating = {
			offset = {x, y},
			zIndex = 1,
			pointerCaptureMode = .Passthrough,
			attachTo = .Parent,
		},
	},
	) {}
}

// Three green bars replace the track number on the current row. Heights
// oscillate while audio plays and rest at fixed steps when paused.
playing_bars :: proc(playing: bool, d: f32) {
	if clay.UI()(
	{
		layout = {
			sizing = {width = clay.SizingFixed(24 * d), height = clay.SizingFixed(16 * d)},
			childAlignment = {x = .Center, y = .Bottom},
			childGap = u16(3 * d),
		},
	},
	) {
		phase := f32(sdl.GetTicksNS()) / 1e9 * 7
		for i in 0 ..< 3 {
			height := 7 * d
			if i == 1 {height = 11 * d}
			if playing {
				height = (4 + 9 * (0.5 + 0.5 * math.sin(phase + f32(i) * 2.1))) * d
			}; if clay.UI()(
			{
				layout = {
					sizing = {width = clay.SizingFixed(4 * d), height = clay.SizingFixed(height)},
				},
				backgroundColor = GREEN,
				cornerRadius = clay.CornerRadiusAll(2 * d),
			},
			) {
			}
		}
	}
}

card_row_height :: proc(card_width, text_height, d: f32) -> f32 {
	return(
		card_width -
		16 * d +
		2 * f32(u16(8 * d)) +
		f32(u16(7 * d)) +
		f32(u16(3 * d)) +
		text_height \
	)
}

card_selected :: proc(entry: ^library.Entry, detail: ^library.Detail) -> bool {
	if !detail.ready {return false}
	prefix: string
	switch detail.source {
	case .Album:
		prefix = "spotify:album:"
	case .Playlist:
		prefix = "spotify:playlist:"
	case .Artist:
		prefix = "spotify:artist:"
	case .Liked:
		return false
	}
	return strings.has_prefix(entry.uri, prefix) && entry.uri[len(prefix):] == detail.id
}

library_card :: proc(
	textures: ^Textures,
	entry: ^library.Entry,
	index: u32,
	card_width, d: f32,
	id: string = "card",
	selected: bool = false,
	pinned: bool = false,
	// Visible slot, not the absolute index: truncation clips register a
	// persistent Clay scroll entry each, so slot keys keep the entries
	// stable while scrolling instead of churning one per row per frame.
	clip_slot: u32 = 0,
) {
	hovered := clay.PointerOver(clay.ID(id, index))
	padding := 8 * d
	cover_size := card_width - padding * 2
	if clay.UI_WithId(clay.ID(id, index))(
	{
		layout = {
			layoutDirection = .TopToBottom,
			sizing = {width = clay.SizingFixed(card_width), height = clay.SizingFit({})},
			padding = clay.PaddingAll(u16(padding)),
			childGap = u16(7 * d),
		},
		backgroundColor = hovered ? HOVER : selected ? SELECTED : clay.Color{},
		cornerRadius = clay.CornerRadiusAll(10 * d),
	},
	) {
		cover_element(textures, entry.image, cover_size, 8 * d)
		if pinned {
			if clay.UI_WithId(clay.ID("card_pin", index))(
			{
				layout = {
					sizing = {width = clay.SizingFixed(22 * d), height = clay.SizingFixed(22 * d)},
					childAlignment = {x = .Center, y = .Center},
				},
				floating = {
					offset = {padding, padding},
					zIndex = 2,
					attachTo = .Parent,
					attachment = {element = .LeftTop, parent = .LeftTop},
					pointerCaptureMode = .Passthrough,
					clipTo = .AttachedParent,
				},
				backgroundColor = clay.Color{12, 12, 12, 200},
				cornerRadius = clay.CornerRadiusAll(11 * d),
			},
			) {
				icon_element(textures, "pin-filled", .White, 13 * d)
			}
		}
		clip_id :=
			id == "card" ? clay.ID("card_clip", clip_slot) : clay.ID("release_clip", clip_slot)
		if clay.UI_WithId(clip_id)(
		{
			layout = {
				layoutDirection = .TopToBottom,
				sizing = {width = clay.SizingGrow({})},
				childGap = u16(3 * d),
			},
			clip = {horizontal = true},
		},
		) {
			clay.Text(
				entry.name,
				clay.TextElementConfig{fontSize = 14, textColor = WHITE, wrapMode = .None},
			)
			if len(entry.subtitle) > 0 {
				clay.Text(
					entry.subtitle,
					clay.TextElementConfig{fontSize = 12, textColor = MUTED, wrapMode = .None},
				)
			}
		}
	}
}

// Full sort labels fit beside the tabs past this sidebar width;
// narrower sidebars show the sort icon alone on the same line.
SORT_LABEL_MIN_WIDTH :: 420

sort_button :: proc(
	textures: ^Textures,
	app_state: ^State,
	active: library.Kind,
	label: bool,
	d: f32,
) {
	if clay.UI_WithId(clay.ID("sort_button"))(
	{layout = {childGap = u16(6 * d), childAlignment = {y = .Center}}},
	) {
		icon_element(textures, "list-sort-descending", .Muted, 14 * d)
		if label {
			clay.Text(
				sort_name(app_state.sort[active]),
				clay.TextElementConfig{fontSize = 13, textColor = MUTED},
			)
		}
	}
}

sidebar :: proc(
	client: ^library.Client,
	app_state: ^State,
	page: ^library.Page,
	tabs: []library.Kind,
	labels: []string,
	active: library.Kind,
	searching: bool,
	textures: ^Textures,
	width, viewport_height, card_text_height, d, dt: f32,
) -> (
	visible: Visible_Items,
) {
	if clay.UI()(
	{
		layout = {
			layoutDirection = .TopToBottom,
			sizing = {width = clay.SizingFixed(width * d), height = clay.SizingGrow({})},
			padding = {left = u16(18 * d), right = u16(18 * d), top = u16(18 * d)},
			childGap = u16(18 * d),
		},
		backgroundColor = SIDEBAR,
		cornerRadius = clay.CornerRadius{topRight = 12 * d},
	},
	) {
		if clay.UI()(
		{
			layout = {
				sizing = {width = clay.SizingGrow({})},
				childGap = u16(8 * d),
				childAlignment = {y = .Center},
			},
		},
		) {
			for kind, index in tabs {
				chip(labels[index], u32(index), active == kind, d)
			}
			if !searching {
				if clay.UI()({layout = {sizing = {width = clay.SizingGrow({})}}}) {}
				sort_button(textures, app_state, active, width >= SORT_LABEL_MIN_WIDTH, d)
			}
		}
		if searching {
			status := ""
			if client.search_loading {
				status = "Searching..."
			} else if client.search_error != 0 {
				if client.search_error > 0 {
					status = fmt.aprintf(
						"Search failed (HTTP %d). Press Enter to retry.",
						client.search_error,
						allocator = context.temp_allocator,
					)
				} else {
					status = "Search failed. Press Enter to retry."
				}
			} else if len(page.items) == 0 {
				status = "No results."
			}
			if len(status) > 0 {
				clay.Text(status, clay.TextElementConfig{fontSize = 13, textColor = MUTED})
			}
		}
		if clay.UI_WithId(clay.ID("library_grid"))(
		{
			layout = {
				layoutDirection = .TopToBottom,
				sizing = {width = clay.SizingGrow({}), height = clay.SizingGrow({})},
				childGap = 0,
			},
			clip = {vertical = true, childOffset = clay.GetScrollOffset()},
		},
		) {
			// Cards own their padding, so rows do not add a second outer gap.
			usable := max(180 * d, width * d - 36 * d)
			columns := clamp(int(usable / (140 * d)), 2, 4)
			card_width := usable / f32(columns)
			row_height := card_row_height(card_width, card_text_height, d)
			visible = scroll_items(
				"library_grid",
				len(page.items),
				columns,
				row_height,
				viewport_height,
			)
			list_spacer(visible.before)
			for index := visible.first; index < visible.last; index += columns {
				if clay.UI()({layout = {sizing = {height = clay.SizingFixed(row_height)}}}) {
					for column in 0 ..< columns {
						next := index + column
						if next >= len(page.items) {break}
						library_card(
							textures,
							&page.items[next],
							u32(next),
							card_width,
							d,
							selected = card_selected(&page.items[next], &client.detail),
							pinned = state_is_pinned(app_state, page.items[next].uri),
							clip_slot = u32(next - visible.first),
						)
					}
				}
			}
			list_spacer(visible.after)
			scroll_fades(
				"library_grid",
				textures,
				textures.fade_top,
				textures.fade_bottom,
				&textures.fade_top_alpha,
				&textures.fade_bottom_alpha,
				0,
				(width - 36) * d,
				dt,
				d,
			)
		}
	}
	return
}

loading_track_table :: proc(d: f32) {
	if clay.UI_WithId(clay.ID("detail_rows"))(
	{
		layout = {
			layoutDirection = .TopToBottom,
			sizing = {width = clay.SizingGrow({}), height = clay.SizingGrow({})},
			padding = {left = u16(28 * d), top = u16(22 * d)},
			childGap = u16(8 * d),
		},
	},
	) {
		clay.Text("Loading tracks...", clay.TextElementConfig{fontSize = 15, textColor = MUTED})
	}
}

// Row text budget where the track table switches from flowing rows to
// header-aligned columns.
ROW_COLUMN_BREAK :: 600

// One track row: number or playing bars, pre-shortened title, linked
// artists and duration. Shared by track tables and Popular.
track_list_row :: proc(
	row: ^library.Track_Row,
	index: int,
	slot: u32,
	view: View,
	ui_state: ^ui.State,
	columns: bool,
	row_text, title_max, column_box: f32,
	d: f32,
) {
	// Each line is pre-shortened to its box: clay clips pixels but
	// never draws an ellipsis itself. With no fonts (layout tests)
	// everything below is the identity.
	title_box := column_box
	if !columns {
		title_box = min(hero_text_width(ui_state, row.name, 15, 3), title_max)
	}
	title_text := hero_fit_text(ui_state, row.name, title_box, 15, 3, 1, context.temp_allocator)
	// Boundary-fitted segments: whole artists that fit, then an
	// ellipsis. A first artist that alone overflows truncates with
	// one like before. Sources that omit URIs render plain text.
	artist_box := max(0, row_text - title_box)
	comma_w := hero_text_width(ui_state, ", ", 14, 0)
	hovered := clay.PointerOver(clay.ID("track_row", u32(index)))
	if clay.UI_WithId(clay.ID("track_row", u32(index)))(
	{
		layout = {
			sizing = {width = clay.SizingGrow({}), height = clay.SizingFixed(44 * d)},
			padding = {left = u16(12 * d), right = u16(92 * d)},
			childAlignment = {y = .Center},
			childGap = u16(18 * d),
		},
		backgroundColor = hovered ? HOVER : clay.Color{},
		cornerRadius = clay.CornerRadiusAll(4 * d),
	},
	) {
		current := row.uri == view.current_uri && view.button != "play"
		if current {
			playing_bars(view.playing, d)
		} else if clay.UI()(
		{layout = {sizing = {width = clay.SizingFixed(24 * d)}, childAlignment = {x = .Right}}},
		) {
			clay.Text(
				fmt.aprintf("%d", index + 1, allocator = context.temp_allocator),
				clay.TextElementConfig{fontId = 1, fontSize = 15, textColor = MUTED},
			)
		}
		// Wide rows give the title a fixed column under the header;
		// narrow rows hug the text so the artist follows at exactly
		// one gap, with the cap keeping a runaway title from eating
		// the artist. Slot-keyed like card clips: one stable scroll
		// entry per visible row instead of one per absolute index.
		if clay.UI_WithId(clay.ID("row_clip", slot))(
		{
			layout = {
				sizing = {
					width = columns ? clay.SizingPercent(0.5) : clay.SizingFit({max = title_max}),
				},
				childAlignment = {y = .Center},
			},
			clip = {horizontal = true},
		},
		) {
			clay.Text(
				title_text,
				clay.TextElementConfig {
					fontId = 3,
					fontSize = 15,
					textColor = current ? GREEN : WHITE,
					wrapMode = .None,
				},
			)
		}
		if clay.UI_WithId(clay.ID("artist_clip", slot))(
		{
			layout = {sizing = {width = clay.SizingGrow({})}, childAlignment = {y = .Center}},
			clip = {horizontal = true},
		},
		) {
			used := f32(0)
			for ai in 0 ..< min(len(row.artist_links), 64) {
				link := row.artist_links[ai]
				linked := len(link.uri) > 0
				separator := ai + 1 < len(row.artist_links) ? ", " : ""
				need := hero_text_width(ui_state, link.name, 14, 0)
				if separator != "" {need += comma_w}
				if used + need > artist_box {
					if ai == 0 {
						fit := hero_fit_text(
							ui_state,
							link.name,
							artist_box,
							14,
							0,
							1,
							context.temp_allocator,
						)
						artist_segment(slot, ai, fit, linked)
					} else {
						clay.Text(
							"…",
							clay.TextElementConfig {
								fontSize = 14,
								textColor = MUTED,
								wrapMode = .None,
							},
						)
					}
					break
				}
				artist_segment(slot, ai, link.name, linked)
				if separator != "" {
					clay.Text(
						separator,
						clay.TextElementConfig{fontSize = 14, textColor = MUTED, wrapMode = .None},
					)
				}
				used += need
			}
		}
		if clay.UI()(
		{
			layout = {
				sizing = {width = clay.SizingFixed(56 * d)},
				childAlignment = {x = .Right, y = .Center},
			},
			floating = {
				offset = {-24 * d, 0},
				zIndex = 1,
				attachment = {element = .RightCenter, parent = .RightCenter},
				pointerCaptureMode = .Passthrough,
				attachTo = .Parent,
				clipTo = .AttachedParent,
			},
		},
		) {
			clay.Text(
				duration_text_alloc(row.duration_ms),
				clay.TextElementConfig{fontId = 1, fontSize = 14, textColor = MUTED},
			)
		}
	}
}

// Track-row text budgets for one container width: the flowing title cap,
// the wide fixed column, the row gap and the wide/narrow switch.
track_row_boxes :: proc(
	available_width, d: f32,
) -> (
	row_text, title_max, column_box, gap: f32,
	columns: bool,
) {
	row_text = max(0, available_width - (SCROLLBAR_OUTSET + 182) * d)
	columns = row_text >= ROW_COLUMN_BREAK * d
	title_max = row_text * 0.6
	column_box = max(0, available_width - (SCROLLBAR_OUTSET + 158) * d) * 0.5
	gap = f32(u16(2 * d))
	return
}

track_table :: proc(
	detail: ^library.Detail,
	view: View,
	textures: ^Textures,
	available_width, viewport_height, dt, d: f32,
	ui_state: ^ui.State,
) -> (
	visible: Visible_Items,
) {
	if clay.UI_WithId(clay.ID("detail_rows"))(
	{
		layout = {
			layoutDirection = .TopToBottom,
			sizing = {width = clay.SizingGrow({}), height = clay.SizingGrow({})},
			childGap = u16(2 * d),
		},
		clip = {vertical = true, childOffset = clay.GetScrollOffset()},
	},
	) {
		// Header labels sit over the number and duration slots, and over the
		// artist column on wide rows; narrow rows flow instead.
		if clay.UI()(
		{
			layout = {
				sizing = {width = clay.SizingGrow({}), height = clay.SizingFixed(36 * d)},
				padding = {left = u16(12 * d), right = u16(92 * d)},
				childAlignment = {y = .Center},
				childGap = u16(18 * d),
			},
			border = {color = CARD, width = {bottom = 1}},
		},
		) {
			if clay.UI()(
			{
				layout = {
					sizing = {width = clay.SizingFixed(24 * d)},
					childAlignment = {x = .Right},
				},
			},
			) {
				clay.Text("#", clay.TextElementConfig{fontSize = 13, textColor = MUTED})
			}
			// Same percent column as the rows below, so the artist label
			// sits exactly over the artist column: Grow pairs would split
			// their joint share instead of the whole base.
			if clay.UI()({layout = {sizing = {width = clay.SizingPercent(0.5)}}}) {
				clay.Text("TITLE", clay.TextElementConfig{fontSize = 13, textColor = MUTED})
			}
			if clay.UI()({layout = {sizing = {width = clay.SizingGrow({})}}}) {
				clay.Text("ARTIST", clay.TextElementConfig{fontSize = 13, textColor = MUTED})
			}
			if clay.UI()(
			{
				layout = {
					sizing = {width = clay.SizingFixed(56 * d)},
					childAlignment = {x = .Right, y = .Center},
				},
				floating = {
					offset = {-24 * d, 0},
					zIndex = 1,
					attachment = {element = .RightCenter, parent = .RightCenter},
					pointerCaptureMode = .Passthrough,
					attachTo = .Parent,
					clipTo = .AttachedParent,
				},
			},
			) {
				icon_element(textures, "clock", .Muted, 15 * d)
			}
		}
		// Row padding (12/92), the number slot and the gaps come off the top.
		// Wide rows columnate under the header labels; narrow rows flow with
		// the title taking most of what is left and the artist the rest.
		row_text, title_max, column_box, gap, columns := track_row_boxes(available_width, d)
		visible = scroll_items(
			"detail_rows",
			detail_item_count(len(detail.rows), detail.total, detail.has_more),
			1,
			44 * d + gap,
			viewport_height,
			36 * d + gap,
		)
		list_spacer(visible.before - gap)
		for index in visible.first ..< visible.last {
			if index >= len(detail.rows) {
				track_skeleton(index, d)
				continue
			}
			row := &detail.rows[index]
			slot := u32(index - visible.first)
			track_list_row(
				row,
				index,
				slot,
				view,
				ui_state,
				columns,
				row_text,
				title_max,
				column_box,
				d,
			)
		}
		list_spacer(visible.after - gap)
		scroll_fades(
			"detail_rows",
			textures,
			textures.fade_detail_top,
			textures.fade_detail_bottom,
			&textures.fade_detail_top_alpha,
			&textures.fade_detail_bottom_alpha,
			0,
			available_width - SCROLLBAR_OUTSET * d,
			dt,
			d,
		)
	}
	return
}

artist_page :: proc(
	detail: ^library.Detail,
	view: View,
	textures: ^Textures,
	available_width, viewport_height, card_text_height, dt, d: f32,
	ui_state: ^ui.State,
	visible: ^Frame_Visible,
) {
	if clay.UI_WithId(clay.ID("detail_rows"))(
	{
		layout = {
			layoutDirection = .TopToBottom,
			sizing = {width = clay.SizingGrow({}), height = clay.SizingGrow({})},
			padding = {left = u16(20 * d), right = u16(20 * d)},
			childGap = u16(8 * d),
		},
		clip = {vertical = true, childOffset = clay.GetScrollOffset()},
	},
	) {
		usable := max(280 * d, available_width - (40 + SCROLLBAR_OUTSET) * d)
		columns := clamp(int(usable / (168 * d)), 2, RELEASE_CARD_COLUMNS)
		card_width := min(usable / f32(columns), RELEASE_CARD_MAX * d)
		row_height := card_row_height(card_width, card_text_height, d)
		row_gap := f32(u16(8 * d))
		leading: f32 = 0
		// Popular keeps the track table's tighter row gap inside its own
		// wrapper, so the container gap never enters the row stride.
		if len(detail.rows) > 0 {
			if clay.UI()(
			{
				layout = {
					layoutDirection = .TopToBottom,
					sizing = {width = clay.SizingGrow({})},
					childGap = u16(2 * d),
				},
			},
			) {
				if clay.UI_WithId(clay.ID("popular_title"))({}) {
					clay.Text("Popular", clay.TextElementConfig{fontSize = 22, textColor = WHITE})
				}
				row_text, title_max, column_box, track_gap, row_columns := track_row_boxes(
					available_width,
					d,
				)
				popular_leading :=
					clay.GetElementData(clay.ID("popular_title")).boundingBox.height + track_gap
				visible.tracks = scroll_items(
					"detail_rows",
					len(detail.rows),
					1,
					44 * d + track_gap,
					viewport_height,
					popular_leading,
				)
				list_spacer(visible.tracks.before - track_gap)
				for index in visible.tracks.first ..< visible.tracks.last {
					row := &detail.rows[index]
					track_list_row(
						row,
						index,
						u32(index - visible.tracks.first),
						view,
						ui_state,
						row_columns,
						row_text,
						title_max,
						column_box,
						d,
					)
				}
				list_spacer(visible.tracks.after - track_gap)
				leading =
					clay.GetElementData(clay.ID("popular_title")).boundingBox.height +
					track_gap +
					f32(len(detail.rows)) * 44 * d +
					f32(max(len(detail.rows) - 1, 0)) * track_gap +
					row_gap
			}
		}
		leading = release_section(
			&detail.albums,
			"Albums",
			"albums_title",
			"release_card",
			0,
			textures,
			columns,
			card_width,
			row_height,
			row_gap,
			usable,
			viewport_height,
			leading,
			dt,
			d,
			&visible.releases,
		)
		leading = release_section(
			&detail.singles,
			"Singles and EPs",
			"singles_title",
			"single_card",
			RELEASE_CLIP_STRIDE,
			textures,
			columns,
			card_width,
			row_height,
			row_gap,
			usable,
			viewport_height,
			leading,
			dt,
			d,
			&visible.singles,
		)
		scroll_fades(
			"detail_rows",
			textures,
			textures.fade_detail_top,
			textures.fade_detail_bottom,
			&textures.fade_detail_top_alpha,
			&textures.fade_detail_bottom_alpha,
			20 * d,
			usable,
			dt,
			d,
		)
	}
}

// One artist section: a title plus its virtualized card grid. Sections show
// while they hold cards, report a total, or keep paging; a group still on
// its first fetch renders one skeleton row so the title never sits alone.
// Returns the content height above the next section's first row, so each
// grid virtualizes against its own offset inside the shared container.
release_section :: proc(
	group: ^library.Release_Group,
	title, title_id, card_id: string,
	slot_base: u32,
	textures: ^Textures,
	columns: int,
	card_width, row_height, row_gap, usable, viewport_height, leading, dt, d: f32,
	visible: ^Visible_Items,
) -> (
	next_leading: f32,
) {
	next_leading = leading
	if len(group.items) == 0 && group.total == 0 && !group.has_more {return}
	if clay.UI_WithId(clay.ID(title_id))({}) {
		clay.Text(title, clay.TextElementConfig{fontSize = 22, textColor = WHITE})
	}
	// Title heights come from the previous frame, like the old discography
	// heading did; the window settles after one layout.
	title_height := clay.GetElementData(clay.ID(title_id)).boundingBox.height
	next_leading += title_height + row_gap
	count := detail_item_count(len(group.items), group.total, group.has_more)
	if count == 0 && group.has_more {count = columns}
	visible^ = scroll_items(
		"detail_rows",
		count,
		columns,
		row_height + row_gap,
		viewport_height,
		next_leading,
	)
	list_spacer(visible.before - row_gap)
	for index := visible.first; index < visible.last; index += columns {
		if clay.UI()(
		{layout = {sizing = {height = clay.SizingFixed(row_height)}, childGap = u16(0)}},
		) {
			for column in 0 ..< columns {
				next := index + column
				if next >= count {break}
				if next < len(group.items) {
					library_card(
						textures,
						&group.items[next],
						u32(next),
						card_width,
						d,
						card_id,
						clip_slot = slot_base + u32(next - visible.first),
					)
				} else {
					release_skeleton(card_width, row_height, d)
				}
			}
		}
	}
	list_spacer(visible.after - row_gap)
	rows := count == 0 ? 0 : (count + columns - 1) / columns
	next_leading += f32(rows) * row_height + f32(max(rows - 1, 0)) * row_gap + row_gap
	return
}

// Hero title sizes, largest first. The title wraps onto two lines, steps
// down until it fits them, and finally ellipsizes; the metadata line below
// it is a single ellipsized line. Clay only wraps on whitespace and offers
// no max-lines, so sizes and cuts have to be picked up front by replaying
// its greedy word wrap with the same measurer the layout itself uses.
HERO_TITLE_SIZES := [?]u16{54, 44, 36, 30}
HERO_TITLE_LINES :: 2
HERO_TITLE_FONT :: 2

hero_text_width :: proc(state: ^ui.State, text: string, size, font: u16) -> f32 {
	// Layout tests run without fonts; text keeps its full length there.
	if state == nil || len(text) == 0 {return 0}
	config := clay.TextElementConfig {
		fontId   = font,
		fontSize = size,
	}
	slice := clay.StringSlice {
		length = i32(len(text)),
		chars  = raw_data(text),
	}
	return measure_text(slice, &config, state).width
}

// How many lines Clay's greedy wrap produces for the text in a column of
// the given width: words break on spaces, every non-final word carries its
// trailing space, and a lone overlong word takes its own overflowing line.
hero_wrapped_lines :: proc(state: ^ui.State, text: string, size, font: u16, width: f32) -> int {
	if len(text) == 0 {return 1}
	space := hero_text_width(state, " ", size, font)
	lines := 0
	line := f32(0)
	start := 0
	for start < len(text) {
		end := start
		for end < len(text) && text[end] != ' ' {end += 1}
		w := hero_text_width(state, text[start:end], size, font)
		if end < len(text) {w += space}
		if line == 0 && line + w > width {
			lines += 1
			start = end + 1
			continue
		}
		if line + w > width {
			lines += 1
			line = 0
			continue
		}
		line += w
		start = end + 1
	}
	if line > 0 {lines += 1}
	return lines
}

hero_title_size :: proc(state: ^ui.State, name: string, width: f32) -> u16 {
	// Layout tests run without fonts; they keep the default size.
	if state == nil || len(name) == 0 {return HERO_TITLE_SIZES[0]}
	for size in HERO_TITLE_SIZES {
		if hero_wrapped_lines(state, name, size, HERO_TITLE_FONT, width) <= HERO_TITLE_LINES {
			return size
		}
	}
	return HERO_TITLE_SIZES[len(HERO_TITLE_SIZES) - 1]
}

// Shortens the text with an ellipsis so it fits the width: a single line
// when lines is 1, that many wrapped lines otherwise. Returns the text
// itself when it already fits, otherwise a copy from the allocator, which
// the caller must not free.
hero_fit_text :: proc(
	state: ^ui.State,
	text: string,
	width: f32,
	size, font: u16,
	lines: int,
	allocator := context.allocator,
) -> string {
	if state == nil || len(text) == 0 {return text}
	// A single line needs one measure, not a per-word walk.
	if lines <= 1 {
		if hero_text_width(state, text, size, font) <= width {return text}
	} else if hero_wrapped_lines(state, text, size, font, width) <= lines {return text}
	scratch := make([]u8, len(text) + len("…"), allocator)
	lo, hi := 0, len(text)
	for lo < hi {
		mid := (lo + hi + 1) / 2
		copy(scratch, text[:mid])
		copy(scratch[mid:], "…")
		probe := string(scratch[:mid + len("…")])
		ok :=
			lines <= 1 ? hero_text_width(state, probe, size, font) <= width : hero_wrapped_lines(state, probe, size, font, width) <= lines
		if ok {
			lo = mid
		} else {
			hi = mid - 1
		}
	}
	// Never split a multi-byte rune; shrinking only ever keeps the fit.
	for lo > 0 && (text[lo - 1] & 0xC0) == 0x80 {lo -= 1}
	if lo == 0 {return "…"}
	copy(scratch, text[:lo])
	copy(scratch[lo:], "…")
	return string(scratch[:lo + len("…")])
}

// Compound Clay index for one artist segment: the row slot owns the high
// bits, the artist offset the low six. main.odin hits the same IDs.
artist_link_id :: proc(slot: u32, ai: int) -> u32 {
	return slot * 64 + u32(ai)
}

// One artist segment: a hug box when linked (hover brightens, clicks open
// the page), plain text otherwise. The caller owns truncation.
artist_segment :: proc(slot: u32, ai: int, name: string, linked: bool) {
	if !linked {
		clay.Text(name, clay.TextElementConfig{fontSize = 14, textColor = MUTED, wrapMode = .None})
		return
	}
	over := clay.PointerOver(clay.ID("artist_link", artist_link_id(slot, ai)))
	if clay.UI_WithId(clay.ID("artist_link", artist_link_id(slot, ai)))(
	{layout = {sizing = {width = clay.SizingFit({})}}},
	) {
		clay.Text(
			name,
			clay.TextElementConfig {
				fontSize = 14,
				textColor = over ? WHITE : MUTED,
				wrapMode = .None,
			},
		)
	}
}

detail_play_enabled :: proc(client: ^library.Client) -> bool {
	return client.detail.ready && client.detail.rows_error == 0 && len(client.detail.rows) > 0
}

detail_page :: proc(
	view: View,
	client: ^library.Client,
	textures: ^Textures,
	fx: ^Button_Fx_Ctx,
	available_width, viewport_height, card_text_height, dt, d: f32,
	ui_state: ^ui.State,
	visible: ^Frame_Visible,
) {
	detail := &client.detail
	if clay.UI()(
	{
		layout = {
			layoutDirection = .TopToBottom,
			sizing = {width = clay.SizingGrow({}), height = clay.SizingGrow({})},
			padding = {right = u16(SCROLLBAR_OUTSET * d)},
		},
		backgroundColor = BG,
	},
	) {
		if !detail.ready {
			if clay.UI()(
			{
				layout = {
					layoutDirection = .TopToBottom,
					sizing = {width = clay.SizingGrow({}), height = clay.SizingGrow({})},
					padding = clay.PaddingAll(u16(32 * d)),
					childGap = u16(12 * d),
				},
			},
			) {
				title := "Pick a playlist, album or artist"
				detail_line := "Covers and track lists load from your own Spotify account."
				if client.detail_loading {
					title = "Loading..."
					detail_line = "Fetching this page from Spotify."
				} else if client.detail_error != 0 {
					title = "Could not open this page"
					detail_line = fmt.aprintf(
						"Spotify answered HTTP %d for it.",
						client.detail_error,
						allocator = context.temp_allocator,
					)
				}
				clay.Text(title, clay.TextElementConfig{fontSize = 26, textColor = WHITE})
				clay.Text(detail_line, clay.TextElementConfig{fontSize = 14, textColor = MUTED})
			}
			return
		}
		// Spotify-style hero: substantial artwork and a strong, bold title.
		// No panel behind it; the cover floats on the page with a soft shadow.
		hero_cover := clamp(available_width * 0.28, 180 * d, 280 * d)
		// A density unit of slack keeps knife-edge words from spilling a third
		// line over floating-point summation order.
		title_width := max(0, available_width - hero_cover - (SCROLLBAR_OUTSET + 72) * d - d)
		title_size := hero_title_size(ui_state, detail.name, title_width)
		title_text := hero_fit_text(
			ui_state,
			detail.name,
			title_width,
			title_size,
			HERO_TITLE_FONT,
			HERO_TITLE_LINES,
			context.temp_allocator,
		)
		if clay.UI()(
		{
			layout = {
				sizing = {
					width = clay.SizingGrow({}),
					height = clay.SizingFixed(hero_cover + 48 * d),
				},
				padding = clay.PaddingAll(u16(24 * d)),
				childGap = u16(24 * d),
				childAlignment = {y = .Center},
			},
		},
		) {
			cover := detail.image
			if textures.by_key[cover_key(cover)] == nil && len(detail.image_preview) > 0 {
				cover = detail.image_preview
			}
			if clay.UI()(
			{
				layout = {
					sizing = {
						width = clay.SizingFixed(hero_cover),
						height = clay.SizingFixed(hero_cover),
					},
				},
			},
			) {
				if clay.UI()(
				{
					layout = {
						sizing = {
							width = clay.SizingFixed(hero_cover + 28 * d),
							height = clay.SizingFixed(hero_cover + 28 * d),
						},
					},
					backgroundColor = {0, 0, 0, 60},
					cornerRadius = clay.CornerRadiusAll(18 * d),
					floating = {
						offset = {-14 * d, -6 * d},
						zIndex = -1,
						pointerCaptureMode = .Passthrough,
						attachTo = .Parent,
					},
				},
				) {}
				if clay.UI()(
				{
					layout = {
						sizing = {
							width = clay.SizingFixed(hero_cover + 12 * d),
							height = clay.SizingFixed(hero_cover + 12 * d),
						},
					},
					backgroundColor = {0, 0, 0, 120},
					cornerRadius = clay.CornerRadiusAll(14 * d),
					floating = {
						offset = {-6 * d, 0},
						zIndex = -1,
						pointerCaptureMode = .Passthrough,
						attachTo = .Parent,
					},
				},
				) {}
				cover_element(textures, cover, hero_cover, 10 * d)
			}
			if clay.UI()(
			{
				layout = {
					layoutDirection = .TopToBottom,
					sizing = {width = clay.SizingGrow({}), height = clay.SizingGrow({})},
					childGap = u16(8 * d),
					childAlignment = {y = .Center},
				},
			},
			) {
				clay.Text(detail.label, clay.TextElementConfig{fontSize = 13, textColor = WHITE})
				clay.Text(
					title_text,
					clay.TextElementConfig{fontId = 2, fontSize = title_size, textColor = WHITE},
				)
				count_label := detail.source == .Artist ? "releases" : "songs"
				base := detail.subtitle
				if len(detail.year) >= 4 {
					base = fmt.aprintf(
						"%s · %s",
						base,
						detail.year,
						allocator = context.temp_allocator,
					)
				}
				metadata := fmt.aprintf(
					"%s · %d %s",
					base,
					detail.total,
					count_label,
					allocator = context.temp_allocator,
				)
				if detail.source == .Playlist && detail.rows_error != 0 {
					metadata = fmt.aprintf(
						"%s · tracks unavailable",
						base,
						allocator = context.temp_allocator,
					)
				}
				metadata_text := hero_fit_text(
					ui_state,
					metadata,
					title_width,
					14,
					0,
					1,
					context.temp_allocator,
				)
				clay.Text(metadata_text, clay.TextElementConfig{fontSize = 14, textColor = MUTED})
			}
		}
		if clay.UI()(
		{
			layout = {
				sizing = {width = clay.SizingGrow({}), height = clay.SizingFixed(72 * d)},
				padding = {left = u16(28 * d), right = u16(28 * d)},
				childGap = u16(20 * d),
				childAlignment = {y = .Center},
			},
		},
		) {
			play_enabled := detail_play_enabled(client)
			// Artists play their Popular tracks; the queue builds from
			// the same rows as every other collection.
			{
				hero_scale, hero_over := button_fx(fx, "hero_play", play_enabled)
				if clay.UI_WithId(clay.ID("hero_play"))(
				{
					layout = {
						sizing = {
							width = clay.SizingFixed(56 * d),
							height = clay.SizingFixed(56 * d),
						},
						childAlignment = {x = .Center, y = .Center},
					},
				},
				) {
					if clay.UI()(
					{
						layout = {
							sizing = {
								width = clay.SizingFixed(56 * d * hero_scale),
								height = clay.SizingFixed(56 * d * hero_scale),
							},
							childAlignment = {x = .Center, y = .Center},
						},
						backgroundColor = play_enabled ? (hero_over ? HERO_HOVER : GREEN) : CARD,
						cornerRadius = clay.CornerRadiusAll(28 * d * hero_scale),
					},
					) {
						icon_element(
							textures,
							"play-filled",
							play_enabled ? .Dark : .Disabled,
							22 * d * hero_scale,
						)
					}
				}
				hero_icon(
					"hero_shuffle",
					"shuffle",
					!play_enabled ? .Disabled : view.shuffle ? .Green : .Muted,
					textures,
					fx,
					d,
				)
			}
			if client.detail.source != .Liked {
				like_disabled := library.detail_loading_visible(client) || client.like_pending
				hero_icon(
					"hero_like",
					client.detail.liked ? "circle-check" : "circle-plus",
					like_disabled ? .Disabled : client.detail.liked ? .Green : .Muted,
					textures,
					fx,
					d,
				)
			}
			if client.detail.source == .Playlist {
				hero_icon(
					"hero_pin",
					view.pinned ? "pin-filled" : "pin-off",
					library.detail_loading_visible(client) ? .Disabled : view.pinned ? .Green : .Muted,
					textures,
					fx,
					d,
				)
			}
			if client.detail.source != .Liked {
				hero_icon(
					"hero_copy_link",
					"link",
					library.detail_loading_visible(client) ? .Disabled : .Muted,
					textures,
					fx,
					d,
				)
			}
			hero_icon(
				"spotify_link",
				"external-link",
				library.detail_loading_visible(client) ? .Disabled : .Muted,
				textures,
				fx,
				d,
			)
		}
		if library.detail_loading_visible(client) {
			loading_track_table(d)
		} else if detail.source == .Artist {
			artist_page(
				detail,
				view,
				textures,
				available_width,
				viewport_height,
				card_text_height,
				dt,
				d,
				ui_state,
				visible,
			)
		} else if detail.source == .Playlist && detail.rows_error != 0 {
			if clay.UI()(
			{
				layout = {
					layoutDirection = .TopToBottom,
					sizing = {width = clay.SizingGrow({})},
					padding = clay.PaddingAll(u16(28 * d)),
					childGap = u16(8 * d),
				},
			},
			) {
				clay.Text(
					"Couldn't load playlist tracks",
					clay.TextElementConfig{fontId = 2, fontSize = 18, textColor = WHITE},
				)
				message := "The request failed. Select the playlist again to retry."
				if detail.rows_error == library.PLAYLIST_AUTH_REQUIRED {
					message = "Streaming approval did not complete. Select the playlist again to retry."
				} else if detail.rows_error == library.PLAYLIST_INVALID_RESPONSE {
					message = "Spotify returned incomplete or invalid playlist data. Please try again."
				} else if detail.rows_error > 0 {
					message = fmt.aprintf(
						"Spotify returned HTTP %d. Please try again.",
						detail.rows_error,
						allocator = context.temp_allocator,
					)
				}
				clay.Text(message, clay.TextElementConfig{fontSize = 14, textColor = MUTED})
			}
		} else {
			visible.tracks = track_table(
				detail,
				view,
				textures,
				available_width,
				viewport_height,
				dt,
				d,
				ui_state,
			)
		}
	}
}
