package main

import "core:fmt"
import "core:math"
import "core:strings"
import "core:time"
import "core:unicode/utf8"
import library "spotify/library"
import ui "ui"
import clay "vendor/clay"
import sdl "vendor:sdl3"

Visible_Items :: struct {
	first, last:   int,
	before, after: f32,
}

Frame_Visible :: struct {
	cards, tracks, releases, singles, feed: Visible_Items,
}

// Release cards stop growing past a readable cover; wider windows gain
// columns instead of billboards.
RELEASE_CARD_MAX :: 200
RELEASE_CARD_COLUMNS :: 8

// A playlist card under a dragged track lights green.
DROP_TARGET :: clay.Color{30, 215, 96, 80}

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
			sizing = {width = clay.SizingGrow({}), height = clay.SizingFixed(ROW_HEIGHT * d)},
			padding = {left = u16(ROW_PAD_LEFT * d), right = u16(ROW_PAD_RIGHT * d)},
			childAlignment = {y = .Center},
			childGap = u16(ROW_GAP * d),
		},
	},
	) {
		if clay.UI()(
		{
			layout = {
				sizing = {width = clay.SizingFixed(ROW_NUM_WIDTH * d)},
				childAlignment = {x = .Right},
			},
		},
		) {
			clay.Text(
				fmt.aprintf("%d", index + 1, allocator = context.temp_allocator),
				{fontId = 1, fontSize = 15, textColor = theme.muted},
			)
		}
		if clay.UI()(
		{
			layout = {sizing = {width = clay.SizingGrow({}), height = clay.SizingFixed(14 * d)}},
			backgroundColor = theme.card,
			cornerRadius = clay.CornerRadiusAll(7 * d),
		},
		) {}
		if clay.UI()(
		{
			layout = {sizing = {width = clay.SizingGrow({}), height = clay.SizingFixed(14 * d)}},
			backgroundColor = theme.card,
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
			backgroundColor = theme.card,
			cornerRadius = clay.CornerRadiusAll(8 * d),
		},
		) {}
		if clay.UI()(
		{
			layout = {sizing = {width = clay.SizingGrow({}), height = clay.SizingFixed(13 * d)}},
			backgroundColor = theme.card,
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
			sizing = {
				width = clay.SizingFixed(ROW_NUM_WIDTH * d),
				height = clay.SizingFixed(16 * d),
			},
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
				backgroundColor = theme.green,
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
	ui_state: ^ui.State,
	entry: ^library.Entry,
	index: u32,
	card_width, d: f32,
	id: string = "card",
	selected: bool = false,
	pinned: bool = false,
	drop_target: bool = false,
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
		backgroundColor = hovered ? theme.hover : drop_target ? DROP_TARGET : selected ? theme.selected : clay.Color{},
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
					offset = {padding + 4 * d, padding + 4 * d},
					zIndex = 2,
					attachTo = .Parent,
					attachment = {element = .LeftTop, parent = .LeftTop},
					pointerCaptureMode = .Passthrough,
					clipTo = .AttachedParent,
				},
				backgroundColor = theme.player,
				cornerRadius = clay.CornerRadiusAll(11 * d),
			},
			) {
				icon_element(textures, "pin-filled", .White, 13 * d)
			}
		}
		// Text is fitted to the card width; the grid owns clipping.
		if clay.UI()(
		{
			layout = {
				layoutDirection = .TopToBottom,
				sizing = {width = clay.SizingGrow({})},
				childGap = u16(3 * d),
			},
		},
		) {
			text_width := card_width - padding * 2
			fitted_text(
				ui_state,
				entry.name,
				text_width,
				{fontSize = 14, textColor = theme.text, wrapMode = .None},
			)
			if len(entry.subtitle) > 0 {
				fitted_text(
					ui_state,
					entry.subtitle,
					text_width,
					{fontSize = 12, textColor = theme.muted, wrapMode = .None},
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
			clay.Text(sort_name(app_state.sort[active]), {fontSize = 13, textColor = theme.muted})
		}
	}
}

sidebar :: proc(
	client: ^library.Client,
	app_state: ^State,
	ui_state: ^ui.State,
	page: ^library.Page,
	tabs: []library.Kind,
	labels: []string,
	active: library.Kind,
	searching: bool,
	textures: ^Textures,
	width, viewport_height, card_text_height, d, dt: f32,
	drop_target: int,
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
		backgroundColor = theme.sidebar,
		cornerRadius = clay.CornerRadius{topRight = 12 * d, bottomRight = 12 * d},
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
				clay.Text(status, {fontSize = 13, textColor = theme.muted})
			}
		}
		if clay.UI_WithId(clay.ID("library_grid"))(
		{
			layout = {
				layoutDirection = .TopToBottom,
				sizing = {width = clay.SizingGrow({}), height = clay.SizingGrow({})},
				childGap = 0,
			},
			clip = {horizontal = true, vertical = true, childOffset = clay.GetScrollOffset()},
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
							ui_state,
							&page.items[next],
							u32(next),
							card_width,
							d,
							selected = !client.release_feed.open &&
							card_selected(&page.items[next], &client.detail),
							pinned = state_is_pinned(app_state, page.items[next].uri),
							drop_target = next == drop_target,
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
		clay.Text("Loading tracks...", {fontSize = 15, textColor = theme.muted})
	}
}

// Row text budget where the track table switches from flowing rows to
// header-aligned columns.
ROW_COLUMN_BREAK :: 600

// One track row's geometry, shared by rows, skeletons, the header labels
// and the scroll strides so the columns never drift apart.
ROW_HEIGHT :: 44
ROW_PAD_LEFT :: 12
ROW_PAD_RIGHT :: 92
ROW_NUM_WIDTH :: 24
ROW_DUR_WIDTH :: 56
ROW_GAP :: 18

// One track row: number, hover play icon, or playing bars, pre-shortened title,
// linked artists and duration. Shared by track tables and Popular.
track_list_row :: proc(
	row: ^library.Track_Row,
	index: int,
	slot: u32,
	view: View,
	textures: ^Textures,
	ui_state: ^ui.State,
	columns: bool,
	row_text, title_max, column_box: f32,
	d: f32,
	playlist: bool = false,
) {
	// Each line is pre-shortened to its box: clay clips pixels but
	// never draws an ellipsis itself. With no fonts (layout tests)
	// everything below is the identity.
	album_width, date_width, title_fraction := f32(0), f32(0), f32(0.5)
	if playlist {album_width, date_width, title_fraction = playlist_columns(row_text, d)}
	title_box := column_box * title_fraction / 0.5
	if !columns {
		title_box = min(hero_text_width(ui_state, row.name, 15, 3), title_max)
	}
	title_text := hero_fit_text(ui_state, row.name, title_box, 15, 3, context.temp_allocator)
	// Boundary-fitted segments: whole artists that fit, then an
	// ellipsis. A first artist that alone overflows truncates with
	// one like before. Sources that omit URIs render plain text.
	count_width := row.play_count > 0 && row_text >= 380 * d ? 100 * d : 0
	extra := album_width + date_width + count_width
	for width in ([]f32{album_width, date_width, count_width}) {if width > 0 {extra += ROW_GAP * d}}
	artist_box := max(0, row_text - title_box - extra)
	hovered := clay.PointerOver(clay.ID("track_row", u32(index)))
	if clay.UI_WithId(clay.ID("track_row", u32(index)))(
	{
		layout = {
			sizing = {width = clay.SizingGrow({}), height = clay.SizingFixed(ROW_HEIGHT * d)},
			padding = {left = u16(ROW_PAD_LEFT * d), right = u16(ROW_PAD_RIGHT * d)},
			childAlignment = {y = .Center},
			childGap = u16(ROW_GAP * d),
		},
		backgroundColor = hovered ? theme.hover : clay.Color{},
		cornerRadius = clay.CornerRadiusAll(4 * d),
	},
	) {
		current := row.uri == view.current_uri && view.button != "play"
		if current {
			playing_bars(view.playing, d)
		} else if clay.UI()(
		{
			layout = {
				sizing = {width = clay.SizingFixed(ROW_NUM_WIDTH * d)},
				childAlignment = {x = .Right, y = .Center},
			},
		},
		) {
			if hovered {
				icon_element(textures, "play-filled", .White, 12 * d)
			} else {
				clay.Text(
					fmt.aprintf("%d", index + 1, allocator = context.temp_allocator),
					{fontId = 1, fontSize = 15, textColor = theme.muted},
				)
			}
		}
		// Wide rows give the title a fixed column under the header;
		// narrow rows hug the text so the artist follows at exactly
		// one gap, with the cap keeping a runaway title from eating
		// the artist. Text fits its column; the table owns clipping.
		if clay.UI()(
		{
			layout = {
				sizing = {
					width = columns ? clay.SizingPercent(title_fraction) : clay.SizingFit({max = title_max}),
				},
				childAlignment = {y = .Center},
			},
		},
		) {
			clay.Text(
				title_text,
				{
					fontId = 3,
					fontSize = 15,
					textColor = current ? theme.green : theme.text,
					wrapMode = .None,
				},
			)
		}
		if clay.UI()(
		{layout = {sizing = {width = clay.SizingGrow({})}, childAlignment = {y = .Center}}},
		) {
			artist_links_row(
				ui_state,
				row.artist_links,
				artist_box,
				"artist_link",
				artist_link_id(slot, 0),
			)
		}
		for width, i in ([]f32{album_width, date_width}) {
			if width <= 0 {continue}
			id := i == 0 ? "track_album" : "track_added"
			if clay.UI_WithId(clay.ID(id, u32(index)))(
			{layout = {sizing = {width = clay.SizingFixed(width)}}},
			) {
				if i == 0 {
					name := hero_fit_text(
						ui_state,
						row.album,
						max(0, width - 24 * d),
						14,
						0,
						context.temp_allocator,
					)
					metadata_link("album_link", u32(index), name, row.album_uri != "")
				} else {
					fitted_text(
						ui_state,
						added_at_text(row.added_at),
						width,
						{fontId = 1, fontSize = 14, textColor = theme.muted, wrapMode = .None},
					)
				}
			}
		}
		if count_width > 0 {
			if clay.UI()(
			{
				layout = {
					sizing = {width = clay.SizingFixed(count_width)},
					childAlignment = {x = .Right},
				},
			},
			) {
				clay.Text(
					count_text(row.play_count),
					{fontId = 1, fontSize = 14, textColor = theme.muted, wrapMode = .None},
				)
			}
		}
		if clay.UI()(
		{
			layout = {
				sizing = {width = clay.SizingFixed(ROW_DUR_WIDTH * d)},
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
				{fontId = 1, fontSize = 14, textColor = theme.muted},
			)
		}
	}
}

// Shared by playlist headers and rows. Narrow panes hide date, then album.
playlist_columns :: proc(row_text, d: f32) -> (album_width, date_width, title_fraction: f32) {
	album_width = row_text >= 700 * d ? row_text * 0.26 : 0
	date_width = row_text >= 1000 * d ? 140 * d : 0
	title_fraction = album_width > 0 ? 0.35 : 0.5
	return
}

added_at_text :: proc(milliseconds: i64) -> string {
	if milliseconds <= 0 {return ""}
	at := time.unix(milliseconds / 1000, milliseconds % 1000 * 1_000_000)
	year, month, day := time.date(at)
	name, _ := fmt.enum_value_to_string(month)
	return fmt.aprintf("%s %d, %d", name[:3], day, year, allocator = context.temp_allocator)
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

// One virtualized run of track rows into the shared scroll container.
// Skeletons cover the not-yet-loaded tail when the total outruns the rows.
track_row_list :: proc(
	detail: ^library.Detail,
	view: View,
	textures: ^Textures,
	ui_state: ^ui.State,
	visible: Visible_Items,
	columns: bool,
	row_text, title_max, column_box, gap: f32,
	d: f32,
) {
	list_spacer(visible.before - gap)
	for index in visible.first ..< visible.last {
		if index >= len(detail.rows) {
			track_skeleton(index, d)
			continue
		}
		row := &detail.rows[index]
		track_list_row(
			row,
			index,
			u32(index - visible.first),
			view,
			textures,
			ui_state,
			columns,
			row_text,
			title_max,
			column_box,
			d,
			playlist = detail.source == .Playlist,
		)
	}
	list_spacer(visible.after - gap)
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
	row_text, title_max, column_box, gap, columns := track_row_boxes(available_width, d)
	album_width, date_width, title_fraction := f32(0), f32(0), f32(0.5)
	if detail.source ==
	   .Playlist {album_width, date_width, title_fraction = playlist_columns(row_text, d)}
	if clay.UI_WithId(clay.ID("detail_rows"))(
	{
		layout = {
			layoutDirection = .TopToBottom,
			sizing = {width = clay.SizingGrow({}), height = clay.SizingGrow({})},
			childGap = u16(2 * d),
		},
		clip = {horizontal = true, vertical = true, childOffset = clay.GetScrollOffset()},
	},
	) {
		// Header labels sit over the number and duration slots, and over the
		// artist column on wide rows; narrow rows flow instead.
		if clay.UI()(
		{
			layout = {
				sizing = {width = clay.SizingGrow({}), height = clay.SizingFixed(36 * d)},
				padding = {left = u16(ROW_PAD_LEFT * d), right = u16(ROW_PAD_RIGHT * d)},
				childAlignment = {y = .Center},
				childGap = u16(ROW_GAP * d),
			},
			border = {color = theme.card, width = {bottom = 1}},
		},
		) {
			if clay.UI()(
			{
				layout = {
					sizing = {width = clay.SizingFixed(ROW_NUM_WIDTH * d)},
					childAlignment = {x = .Right},
				},
			},
			) {
				clay.Text("#", {fontSize = 13, textColor = theme.muted})
			}
			// Same percent column as the rows below, so the artist label
			// sits exactly over the artist column: Grow pairs would split
			// their joint share instead of the whole base.
			if clay.UI()({layout = {sizing = {width = clay.SizingPercent(title_fraction)}}}) {
				clay.Text("TITLE", {fontSize = 13, textColor = theme.muted})
			}
			if clay.UI()({layout = {sizing = {width = clay.SizingGrow({})}}}) {
				clay.Text("ARTIST", {fontSize = 13, textColor = theme.muted})
			}
			for width, i in ([]f32{album_width, date_width}) {
				if width <= 0 {continue}
				id := i == 0 ? "album_header" : "added_header"
				if clay.UI_WithId(clay.ID(id))(
				{layout = {sizing = {width = clay.SizingFixed(width)}}},
				) {
					clay.Text(
						i == 0 ? "ALBUM" : "DATE ADDED",
						{fontSize = 13, textColor = theme.muted},
					)
				}
			}
			if clay.UI()(
			{
				layout = {
					sizing = {width = clay.SizingFixed(ROW_DUR_WIDTH * d)},
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
		visible = scroll_items(
			"detail_rows",
			detail_item_count(len(detail.rows), detail.total, detail.has_more),
			1,
			ROW_HEIGHT * d + gap,
			viewport_height,
			36 * d + gap,
		)
		track_row_list(
			detail,
			view,
			textures,
			ui_state,
			visible,
			columns,
			row_text,
			title_max,
			column_box,
			gap,
			d,
		)
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
		clip = {horizontal = true, vertical = true, childOffset = clay.GetScrollOffset()},
	},
	) {
		usable := max(280 * d, available_width - (40 + SCROLLBAR_OUTSET) * d)
		columns := clamp(int(usable / (168 * d)), 2, RELEASE_CARD_COLUMNS)
		card_width := min(usable / f32(columns), RELEASE_CARD_MAX * d)
		row_height := card_row_height(card_width, card_text_height, d)
		row_gap := f32(u16(8 * d))
		leading: f32
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
					clay.Text("Popular", {fontSize = 22, textColor = theme.text})
				}
				row_text, title_max, column_box, track_gap, row_columns := track_row_boxes(
					available_width,
					d,
				)
				popular_leading :=
					leading +
					clay.GetElementData(clay.ID("popular_title")).boundingBox.height +
					track_gap
				visible.tracks = scroll_items(
					"detail_rows",
					len(detail.rows),
					1,
					ROW_HEIGHT * d + track_gap,
					viewport_height,
					popular_leading,
				)
				track_row_list(
					detail,
					view,
					textures,
					ui_state,
					visible.tracks,
					row_columns,
					row_text,
					title_max,
					column_box,
					track_gap,
					d,
				)
				leading +=
					clay.GetElementData(clay.ID("popular_title")).boundingBox.height +
					track_gap +
					f32(len(detail.rows)) * ROW_HEIGHT * d +
					f32(max(len(detail.rows) - 1, 0)) * track_gap +
					row_gap
			}
		}
		leading = release_section(
			&detail.albums,
			"Albums",
			"albums_title",
			"release_card",
			textures,
			ui_state,
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
			textures,
			ui_state,
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
	textures: ^Textures,
	ui_state: ^ui.State,
	columns: int,
	card_width, row_height, row_gap, usable, viewport_height, leading, dt, d: f32,
	visible: ^Visible_Items,
) -> (
	next_leading: f32,
) {
	next_leading = leading
	if len(group.items) == 0 && group.total == 0 && !group.has_more && group.error == 0 {return}
	if clay.UI_WithId(clay.ID(title_id))({layout = {layoutDirection = .TopToBottom}}) {
		clay.Text(title, {fontSize = 22, textColor = theme.text})
		if group.error != 0 {
			clay.Text(page_error_text(group.error), {fontSize = 14, textColor = theme.muted})
		}
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
						ui_state,
						&group.items[next],
						u32(next),
						card_width,
						d,
						card_id,
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

// Shared single-line titles shrink before text is shortened.
HERO_TITLE_SIZES := [?]u16{96, 80, 64, 54, 44, 36, 30}
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

hero_max_title_size :: proc(viewport_height, d: f32) -> u16 {
	return u16(clamp(54 + max(0, viewport_height / d - 900) * 0.08, 54, 96))
}

// Both cover and banner headers use the same font, fitting, and wrapping rules.
hero_title :: proc(
	state: ^ui.State,
	name: string,
	width: f32,
	max_size: u16,
) -> (
	string,
	clay.TextElementConfig,
) {
	size := max_size
	if state != nil && name != "" {
		size = HERO_TITLE_SIZES[len(HERO_TITLE_SIZES) - 1]
		for candidate in HERO_TITLE_SIZES {
			if candidate <= max_size &&
			   hero_text_width(state, name, candidate, HERO_TITLE_FONT) <= width {
				size = candidate
				break
			}
		}
	}
	return hero_fit_text(
		state,
		name,
		width,
		size,
		HERO_TITLE_FONT,
		context.temp_allocator,
	), {fontId = HERO_TITLE_FONT, fontSize = size, textColor = theme.text, wrapMode = .None}
}

// Shortens one line at a grapheme boundary. Returns borrowed text when it fits,
// otherwise a copy from the supplied allocator.
hero_fit_text :: proc(
	state: ^ui.State,
	text: string,
	width: f32,
	size, font: u16,
	allocator := context.allocator,
) -> string {
	if state == nil || len(text) == 0 {return text}
	if hero_text_width(state, text, size, font) <= width {return text}
	scratch := make([]u8, len(text) + len("…"), allocator)
	// ASCII bytes are grapheme boundaries, except for the CRLF pair.
	ascii := true
	for ch in transmute([]u8)text {
		if ch >= 0x80 || ch == '\r' {ascii = false; break}
	}
	boundaries: [dynamic]int
	lo, hi := 0, len(text)
	if !ascii {
		boundaries = make([dynamic]int, 0, len(text) + 1, context.temp_allocator)
		it := utf8.decode_grapheme_iterator_make(text)
		for _, grapheme in utf8.decode_grapheme_iterate(&it) {append(&boundaries, grapheme.byte_index)}
		append(&boundaries, len(text))
		hi = len(boundaries) - 1
	}
	for lo < hi {
		mid := (lo + hi + 1) / 2
		end := ascii ? mid : boundaries[mid]
		copy(scratch, text[:end])
		copy(scratch[end:], "…")
		probe := string(scratch[:end + len("…")])
		if hero_text_width(state, probe, size, font) <= width {
			lo = mid
		} else {
			hi = mid - 1
		}
	}
	end := ascii ? lo : boundaries[lo]
	copy(scratch, text[:end])
	copy(scratch[end:], "…")
	return string(scratch[:end + len("…")])
}

// Compound Clay index for one artist segment: the row slot owns the high
// bits, the artist offset the low six. main.odin hits the same IDs.
artist_link_id :: proc(slot: u32, ai: int) -> u32 {
	return slot * 64 + u32(ai)
}

// Artist and album links hug the fitted text, not the whole column.
// Missing URIs remain plain text. The caller owns truncation.
metadata_link :: proc(id: string, index: u32, name: string, linked: bool) {
	if !linked {
		clay.Text(name, {fontSize = 14, textColor = theme.muted, wrapMode = .None})
		return
	}
	over := clay.PointerOver(clay.ID(id, index))
	if clay.UI_WithId(clay.ID(id, index))({layout = {sizing = {width = clay.SizingFit({})}}}) {
		clay.Text(
			name,
			{fontSize = 14, textColor = over ? theme.text : theme.muted, wrapMode = .None},
		)
	}
}

// Whole artist links that fit the box, then an ellipsis. A lone overlong
// first artist is shortened to fit. Shared by track rows and the detail hero,
// which owns the text that follows.
artist_links_row :: proc(
	ui_state: ^ui.State,
	links: []library.Artist_Link,
	box: f32,
	id: string,
	base: u32,
) {
	comma_w: f32
	if len(links) > 1 {comma_w = hero_text_width(ui_state, ", ", 14, 0)}
	used := f32(0)
	for ai in 0 ..< min(len(links), 64) {
		link := links[ai]
		linked := len(link.uri) > 0
		separator := ai + 1 < len(links) ? ", " : ""
		need := hero_text_width(ui_state, link.name, 14, 0)
		if separator != "" {need += comma_w}
		if used + need > box {
			if ai == 0 {
				fit := hero_fit_text(ui_state, link.name, box, 14, 0, context.temp_allocator)
				metadata_link(id, base + u32(ai), fit, linked)
			} else {
				clay.Text("…", {fontSize = 14, textColor = theme.muted, wrapMode = .None})
			}
			return
		}
		metadata_link(id, base + u32(ai), link.name, linked)
		if separator != "" {
			clay.Text(separator, {fontSize = 14, textColor = theme.muted, wrapMode = .None})
		}
		used += need
	}
}

fitted_text :: proc(state: ^ui.State, text: string, width: f32, style: clay.TextElementConfig) {
	clay.Text(
		hero_fit_text(state, text, width, style.fontSize, style.fontId, context.temp_allocator),
		style,
	)
}

detail_play_enabled :: proc(client: ^library.Client) -> bool {
	return !client.release_feed.open && detail_rows_ready(client)
}

detail_rows_ready :: proc(client: ^library.Client) -> bool {
	return client.detail.ready && client.detail.rows_error == 0 && len(client.detail.rows) > 0
}

// Counts share one grouped format; numeric rows use the monospace face.
count_text :: proc(value: i64) -> string {
	digits := fmt.aprintf("%d", max(0, value), allocator = context.temp_allocator)
	out := make([]u8, len(digits) + (len(digits) - 1) / 3, context.temp_allocator)
	at := 0
	for ch, i in transmute([]u8)digits {
		if i > 0 && (len(digits) - i) % 3 == 0 {out[at] = ','; at += 1}
		out[at] = ch
		at += 1
	}
	return string(out)
}

hero_metadata :: proc(detail: ^library.Detail) -> string {
	count_label := detail.source == .Artist ? "releases" : "songs"
	parts := make([dynamic]string, 0, 3, context.temp_allocator)
	// Album artists render as their own clickable segments, so the
	// joined subtitle only serves sources that carry no links.
	if len(detail.subtitle) > 0 && len(detail.artist_links) == 0 {
		append(&parts, detail.subtitle)
	}
	if len(detail.year) >= 4 {append(&parts, detail.year)}
	if detail.source == .Artist && detail.monthly_listeners > 0 {
		append(
			&parts,
			fmt.aprintf(
				"%s monthly listeners",
				count_text(detail.monthly_listeners),
				allocator = context.temp_allocator,
			),
		)
	} else if detail.source == .Playlist && detail.rows_error != 0 {
		append(&parts, "tracks unavailable")
	} else {
		append(
			&parts,
			fmt.aprintf("%d %s", detail.total, count_label, allocator = context.temp_allocator),
		)
	}
	return strings.join(parts[:], " • ", context.temp_allocator)
}

// Dedicated banners fill a bounded header; SDL crops without stretching.
hero_banner :: proc(
	detail: ^library.Detail,
	textures: ^Textures,
	ui_state: ^ui.State,
	width, viewport_height, d: f32,
) -> bool {
	if detail.banner == "" {return false}
	texture := textures.by_key[cover_key(detail.banner)]
	w, h: f32
	if texture == nil || !sdl.GetTextureSize(texture, &w, &h) || w <= h || h <= 0 {return false}
	available := max(0, width - SCROLLBAR_OUTSET * d)
	// Keep small windows unchanged; let larger windows grow up to 40%.
	height_limit := min(
		viewport_height * 0.40,
		viewport_height * 0.35 + max(0, viewport_height - 900 * d) * 0.15,
	)
	height := min(available * h / w, height_limit)
	title_width := max(0, available - 48 * d)
	title, title_style := hero_title(
		ui_state,
		detail.name,
		title_width,
		hero_max_title_size(viewport_height, d),
	)
	metadata := hero_metadata(detail)
	if clay.UI_WithId(clay.ID("hero_banner"))(
	{layout = {sizing = {width = clay.SizingFixed(available), height = clay.SizingFixed(height)}}},
	) {
		clay.UI_WithId(clay.ID("hero_banner_image"))(
		{
			layout = {
				sizing = {width = clay.SizingFixed(available), height = clay.SizingFixed(height)},
			},
			image = {imageData = rawptr(uintptr(cover_key(detail.banner)))},
		},
		)
		fade_height := min(height, max(320 * d, f32(title_style.fontSize) * 4 * d))
		fade_image(
			textures,
			textures.hero_fade,
			1,
			0,
			available,
			fade_height,
			height - fade_height,
		)
		if clay.UI_WithId(clay.ID("hero_caption"))(
		{
			layout = {
				layoutDirection = .TopToBottom,
				sizing = {width = clay.SizingFixed(title_width)},
				childGap = u16(8 * d),
			},
			floating = {
				offset = {24 * d, -24 * d},
				zIndex = 2,
				attachTo = .Parent,
				attachment = {element = .LeftBottom, parent = .LeftBottom},
				pointerCaptureMode = .Passthrough,
			},
		},
		) {
			clay.Text(detail.label, {fontSize = 13, textColor = theme.text})
			clay.Text(title, title_style)
			fitted_text(
				ui_state,
				metadata,
				title_width,
				{fontSize = 14, textColor = theme.text, wrapMode = .None},
			)
		}
	}
	return true
}

detail_hero :: proc(
	detail: ^library.Detail,
	textures: ^Textures,
	ui_state: ^ui.State,
	available_width, viewport_height, d: f32,
) {
	// Spotify-style hero: substantial artwork and a strong, bold title.
	// No panel behind it; the cover floats on the page with a soft shadow.
	if hero_banner(detail, textures, ui_state, available_width, viewport_height, d) {return}
	hero_cover := clamp(available_width * 0.28, 180 * d, 280 * d)
	// Keep a density unit of slack at the text boundary.
	title_width := max(0, available_width - hero_cover - (SCROLLBAR_OUTSET + 72) * d - d)
	title, title_style := hero_title(
		ui_state,
		detail.name,
		title_width,
		hero_max_title_size(viewport_height, d),
	)
	if clay.UI()(
	{
		layout = {
			sizing = {width = clay.SizingGrow({}), height = clay.SizingFixed(hero_cover + 48 * d)},
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
			clay.Text(detail.label, {fontSize = 13, textColor = theme.text})
			clay.Text(title, title_style)
			metadata := hero_metadata(detail)
			if len(detail.artist_links) > 0 {
				tail := fmt.aprintf(" • %s", metadata, allocator = context.temp_allocator)
				tail_width := hero_text_width(ui_state, tail, 14, 0)
				if clay.UI()(
				{
					layout = {
						sizing = {width = clay.SizingGrow({})},
						childAlignment = {y = .Center},
					},
					clip = {horizontal = true},
				},
				) {
					artist_links_row(
						ui_state,
						detail.artist_links,
						max(0, title_width - tail_width),
						"hero_artist_link",
						0,
					)
					clay.Text(tail, {fontSize = 14, textColor = theme.muted, wrapMode = .None})
				}
			} else {
				metadata_text := hero_fit_text(
					ui_state,
					metadata,
					title_width,
					14,
					0,
					context.temp_allocator,
				)
				clay.Text(metadata_text, {fontSize = 14, textColor = theme.muted})
			}
		}
	}
}

page_error_text :: proc(status: int) -> string {
	if status == 429 {return "Spotify is limiting requests. Please try again later."}
	if status > 0 {
		return fmt.aprintf(
			"Spotify returned HTTP %d. Please try again.",
			status,
			allocator = context.temp_allocator,
		)
	}
	return "Could not reach Spotify. Please try again."
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
	if client.release_feed.open {
		release_feed_page(
			client,
			textures,
			fx,
			available_width,
			viewport_height,
			dt,
			d,
			ui_state,
			&visible.feed,
		)
		return
	}
	detail := &client.detail
	if clay.UI()(
	{
		layout = {
			layoutDirection = .TopToBottom,
			sizing = {width = clay.SizingGrow({}), height = clay.SizingGrow({})},
			padding = {right = u16(SCROLLBAR_OUTSET * d)},
		},
		backgroundColor = theme.bg,
	},
	) {
		if !detail.ready || client.detail_error != 0 {
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
					detail_line = page_error_text(client.detail_error)
				}
				clay.Text(title, {fontSize = 26, textColor = theme.text})
				clay.Text(detail_line, {fontSize = 14, textColor = theme.muted})
				if client.detail_error != 0 &&
				   client.state == .Ready &&
				   time.since(client.page_at) >= 0 {
					sign_in_button("detail_retry", "Try again", d)
				}
			}
			return
		}
		detail_hero(detail, textures, ui_state, available_width, viewport_height, d)
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
				round_play_button(
					"hero_play",
					"play-filled",
					textures,
					fx,
					d,
					56,
					22,
					theme.green,
					theme.hero_hover,
					play_enabled,
				)
				icon_button(
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
				icon_button(
					"hero_like",
					client.detail.liked ? "circle-check" : "circle-plus",
					like_disabled ? .Disabled : client.detail.liked ? .Green : .Muted,
					textures,
					fx,
					d,
				)
			}
			if client.detail.source == .Playlist {
				icon_button(
					"hero_pin",
					view.pinned ? "pin-filled" : "pin-off",
					library.detail_loading_visible(client) ? .Disabled : view.pinned ? .Green : .Muted,
					textures,
					fx,
					d,
				)
			}
			if client.detail.source != .Liked {
				icon_button(
					"hero_copy_link",
					"link",
					library.detail_loading_visible(client) ? .Disabled : .Muted,
					textures,
					fx,
					d,
				)
			}
			icon_button(
				"spotify_link",
				"external-link",
				library.detail_loading_visible(client) ? .Disabled : .Muted,
				textures,
				fx,
				d,
			)
		}
		// All collection pages share the same space below their controls.
		list_spacer(24 * d)
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
					{fontId = 2, fontSize = 18, textColor = theme.text},
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
				clay.Text(message, {fontSize = 14, textColor = theme.muted})
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
