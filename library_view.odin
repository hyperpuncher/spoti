package main

import "core:fmt"
import "core:math"
import "core:strings"
import library "spotify/library"
import clay "vendor/clay"

Visible_Items :: struct {
	first, last:   int,
	before, after: f32,
}

Frame_Visible :: struct {
	cards, tracks, releases: Visible_Items,
}

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
	return visible_items(count, columns, stride, offset, height)
}

list_spacer :: proc(height: f32) {
	if height <= 0 {return}
	clay.UI()(
	{layout = {sizing = {width = clay.SizingGrow({}), height = clay.SizingFixed(height)}}},
	)
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
		if clay.UI()(
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

sidebar :: proc(
	client: ^library.Client,
	filter: library.Kind,
	textures: ^Textures,
	width, viewport_height, card_text_height, d: f32,
) -> (
	visible: Visible_Items,
) {
	if clay.UI()(
	{
		layout = {
			layoutDirection = .TopToBottom,
			sizing = {width = clay.SizingFixed(width * d), height = clay.SizingGrow({})},
			padding = clay.PaddingAll(u16(18 * d)),
			childGap = u16(18 * d),
		},
		backgroundColor = SIDEBAR,
	},
	) {
		if clay.UI()({layout = {childGap = u16(8 * d), childAlignment = {y = .Center}}}) {
			tabs := LIBRARY_TABS
			labels := LIBRARY_TAB_LABELS
			for kind, index in tabs {
				chip(labels[index], u32(index), filter == kind, d)
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
			page := &client.pages[filter]
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
						)
					}
				}
			}
			list_spacer(visible.after)
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

track_table :: proc(
	detail: ^library.Detail,
	textures: ^Textures,
	viewport_height, d: f32,
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
		// Header: # / TITLE on the left, the duration clock on the right.
		if clay.UI()(
		{
			layout = {
				sizing = {width = clay.SizingGrow({}), height = clay.SizingFixed(36 * d)},
				padding = {left = u16(12 * d), right = u16(24 * d)},
				childAlignment = {y = .Center},
				childGap = u16(18 * d),
			},
			border = {color = CARD, width = {bottom = 1}},
		},
		) {
			clay.Text("#", clay.TextElementConfig{fontSize = 13, textColor = MUTED})
			clay.Text("TITLE", clay.TextElementConfig{fontSize = 13, textColor = MUTED})
			if clay.UI()({layout = {sizing = {width = clay.SizingGrow({})}}}) {}
			if clay.UI()(
			{
				layout = {
					sizing = {width = clay.SizingFixed(56 * d)},
					childAlignment = {x = .Right, y = .Center},
				},
			},
			) {
				icon_element(textures, "clock", .Muted, 15 * d)
			}
		}
		gap := f32(u16(2 * d))
		visible = scroll_items(
			"detail_rows",
			len(detail.rows),
			1,
			44 * d + gap,
			viewport_height,
			36 * d + gap,
		)
		list_spacer(visible.before - gap)
		for index in visible.first ..< visible.last {
			row := &detail.rows[index]
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
				if clay.UI()(
				{
					layout = {
						sizing = {width = clay.SizingFixed(24 * d)},
						childAlignment = {x = .Right},
					},
				},
				) {
					clay.Text(
						fmt.aprintf("%d", index + 1, allocator = context.temp_allocator),
						clay.TextElementConfig{fontId = 1, fontSize = 15, textColor = MUTED},
					)
				}
				// The middle column grows so the duration stays at the right edge.
				if clay.UI()(
				{
					layout = {
						sizing = {width = clay.SizingGrow({})},
						childGap = u16(10 * d),
						childAlignment = {y = .Center},
					},
					clip = {horizontal = true},
				},
				) {
					clay.Text(
						row.name,
						clay.TextElementConfig {
							fontId = 3,
							fontSize = 15,
							textColor = WHITE,
							wrapMode = .None,
						},
					)
					clay.Text("•", clay.TextElementConfig{fontSize = 15, textColor = MUTED})
					clay.Text(
						row.artists,
						clay.TextElementConfig{fontSize = 14, textColor = MUTED, wrapMode = .None},
					)
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
		list_spacer(visible.after - gap)
		if detail.has_more {
			if clay.UI_WithId(clay.ID("detail_more"))(
			{
				layout = {
					sizing = {
						width = clay.SizingFixed(150 * d),
						height = clay.SizingFixed(38 * d),
					},
					childAlignment = {x = .Center, y = .Center},
				},
				backgroundColor = CARD,
				cornerRadius = clay.CornerRadiusAll(19 * d),
			},
			) {
				clay.Text("Load more", clay.TextElementConfig{fontSize = 14, textColor = WHITE})
			}
		}
	}
	return
}

artist_discography :: proc(
	detail: ^library.Detail,
	textures: ^Textures,
	available_width, viewport_height, card_text_height, d: f32,
) -> (
	visible: Visible_Items,
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
		if clay.UI_WithId(clay.ID("discography_title"))({}) {
			clay.Text("Discography", clay.TextElementConfig{fontSize = 22, textColor = WHITE})
		}
		gap: f32 = 0
		usable := max(280 * d, available_width - 40 * d)
		columns := clamp(int((usable + gap) / (168 * d + gap)), 2, 4)
		card_width := (usable - f32(columns - 1) * gap) / f32(columns)
		row_height := card_row_height(card_width, card_text_height, d)
		row_gap := f32(u16(8 * d))
		heading := clay.GetElementData(clay.ID("discography_title"))
		visible = scroll_items(
			"detail_rows",
			len(detail.releases),
			columns,
			row_height + row_gap,
			viewport_height,
			heading.boundingBox.height + row_gap,
		)
		list_spacer(visible.before - row_gap)
		for index := visible.first; index < visible.last; index += columns {
			if clay.UI()(
			{layout = {sizing = {height = clay.SizingFixed(row_height)}, childGap = u16(gap)}},
			) {
				for column in 0 ..< columns {
					next := index + column
					if next >= len(detail.releases) {break}
					library_card(
						textures,
						&detail.releases[next],
						u32(next),
						card_width,
						d,
						"release_card",
					)
				}
			}
		}
		list_spacer(visible.after - row_gap)
		if detail.has_more {
			if clay.UI_WithId(clay.ID("detail_more"))(
			{
				layout = {
					sizing = {
						width = clay.SizingFixed(150 * d),
						height = clay.SizingFixed(38 * d),
					},
					childAlignment = {x = .Center, y = .Center},
				},
				backgroundColor = CARD,
				cornerRadius = clay.CornerRadiusAll(19 * d),
			},
			) {
				clay.Text("Load more", clay.TextElementConfig{fontSize = 14, textColor = WHITE})
			}
		}
	}
	return
}

detail_play_enabled :: proc(client: ^library.Client) -> bool {
	return(
		client.detail.ready &&
		!client.detail_loading &&
		client.detail.rows_error == 0 &&
		len(client.detail.rows) > 0 \
	)
}

detail_page :: proc(
	view: View,
	client: ^library.Client,
	textures: ^Textures,
	available_width, viewport_height, card_text_height, d: f32,
	visible: ^Frame_Visible,
) {
	detail := &client.detail
	if clay.UI()(
	{
		layout = {
			layoutDirection = .TopToBottom,
			sizing = {width = clay.SizingGrow({}), height = clay.SizingGrow({})},
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
		hero_cover := clamp(available_width * 0.28, 180 * d, 280 * d)
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
			backgroundColor = PANEL,
			cornerRadius = clay.CornerRadiusAll(10 * d),
		},
		) {
			cover := detail.image
			if textures.by_key[cover_key(cover)] == nil && len(detail.image_preview) > 0 {
				cover = detail.image_preview
			}
			cover_element(textures, cover, hero_cover, 10 * d)
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
					detail.name,
					clay.TextElementConfig{fontId = 2, fontSize = 54, textColor = WHITE},
				)
				count_label := detail.source == .Artist ? "releases" : "songs"
				metadata := fmt.aprintf(
					"%s · %d %s",
					detail.subtitle,
					detail.total,
					count_label,
					allocator = context.temp_allocator,
				)
				if detail.source == .Playlist && detail.rows_error != 0 {
					metadata = fmt.aprintf(
						"%s · tracks unavailable",
						detail.subtitle,
						allocator = context.temp_allocator,
					)
				}
				clay.Text(metadata, clay.TextElementConfig{fontSize = 14, textColor = MUTED})
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
			if detail.source != .Artist {
				if clay.UI_WithId(clay.ID("hero_play"))(
				{
					layout = {
						sizing = {
							width = clay.SizingFixed(56 * d),
							height = clay.SizingFixed(56 * d),
						},
						childAlignment = {x = .Center, y = .Center},
					},
					backgroundColor = play_enabled ? GREEN : CARD,
					cornerRadius = clay.CornerRadiusAll(28 * d),
				},
				) {
					icon_element(textures, "play-filled", play_enabled ? .Dark : .Disabled, 22 * d)
				}
				player_control(
					"hero_shuffle",
					"shuffle",
					!play_enabled ? .Disabled : view.shuffle ? .Green : .Muted,
					textures,
					d,
				)
			}
			icon_element(textures, "heart", client.detail_loading ? .Disabled : .Muted, 22 * d)
			if clay.UI_WithId(clay.ID("spotify_link"))(
			{
				layout = {
					sizing = {width = clay.SizingFit({}), height = clay.SizingFixed(36 * d)},
					padding = {left = u16(14 * d), right = u16(14 * d)},
					childAlignment = {x = .Center, y = .Center},
				},
				backgroundColor = CARD,
				cornerRadius = clay.CornerRadiusAll(18 * d),
			},
			) {
				clay.Text(
					"Open in Spotify",
					clay.TextElementConfig {
						fontSize = 13,
						textColor = client.detail_loading ? MUTED : WHITE,
					},
				)
			}
		}
		if client.detail_loading {
			loading_track_table(d)
		} else if detail.source == .Artist {
			visible.releases = artist_discography(
				detail,
				textures,
				available_width,
				viewport_height,
				card_text_height,
				d,
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
			visible.tracks = track_table(detail, textures, viewport_height, d)
		}
	}
}
