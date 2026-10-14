package main

import "core:fmt"
import "core:time"
import library "spotify/library"
import ui "ui"
import clay "vendor/clay"

FEED_COVER_SIZE :: 168
FEED_ROW_HEIGHT :: FEED_COVER_SIZE + 24

release_feed_action :: proc(action: string, index: int) -> string {
	return fmt.aprintf("feed_%s_%d", action, index, allocator = context.temp_allocator)
}

release_age_label :: proc(released_at, now: time.Time) -> string {
	age := time.diff(released_at, now)
	if age < time.Minute {return "just now"}
	unit, step := "minute", time.Minute
	if age >= 24 * time.Hour {
		unit, step = "day", 24 * time.Hour
	} else if age >= time.Hour {
		unit, step = "hour", time.Hour
	}
	count := int(age / step)
	return fmt.aprintf(
		"%d %s%s ago",
		count,
		unit,
		count == 1 ? "" : "s",
		allocator = context.temp_allocator,
	)
}

// Load the existing album queue without changing the visible feed or history.
release_feed_load_playback :: proc(client: ^library.Client, entry: library.Entry) -> bool {
	source, id, valid := parse_card_uri(entry.uri)
	if !valid || source != .Album {return false}
	was_open := client.release_feed.open
	defer client.release_feed.open = was_open
	return library.open_detail(client, source, id, entry)
}

release_feed_find :: proc(client: ^library.Client, uri: string) -> ^library.New_Release {
	for &release in client.release_feed.items {
		if release.entry.uri == uri {return &release}
	}
	return nil
}

release_feed_saved :: proc(client: ^library.Client, release: ^library.New_Release) -> bool {
	if release.entry.saved {return true}
	for entry in client.pages[.Albums].items {if entry.uri == release.entry.uri {return true}}
	return false
}

release_feed_page :: proc(
	client: ^library.Client,
	textures: ^Textures,
	fx: ^Button_Fx_Ctx,
	width, height, dt, d: f32,
	ui_state: ^ui.State,
	visible: ^Visible_Items,
) {
	feed := &client.release_feed
	now := time.now()
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
		if clay.UI()(
		{
			layout = {
				layoutDirection = .TopToBottom,
				sizing = {width = clay.SizingGrow({})},
				padding = clay.PaddingAll(u16(24 * d)),
				childGap = u16(8 * d),
			},
		},
		) {
			clay.Text(
				"What's New",
				clay.TextElementConfig{fontId = 2, fontSize = 28, textColor = WHITE},
			)
			clay.Text(
				"Music from artists you follow • Last seven days",
				clay.TextElementConfig{fontSize = 14, textColor = MUTED},
			)
			status := fmt.aprintf(
				"%d releases",
				len(feed.items),
				allocator = context.temp_allocator,
			)
			if client.state == .Idle || client.state == .Authorizing {
				status = "Waiting for Spotify..."
			} else if client.state == .Missing_Client_ID || client.state == .Sign_In_Failed {
				status = "Library sign-in is required."
			} else if feed.error == library.PLAYLIST_AUTH_REQUIRED {
				status = "Play a track locally to approve streaming, then reopen this view."
			} else if feed.error == 429 {
				status = "Spotify rate limit. Reopen this view after the wait period."
			} else if feed.error != 0 {
				status = "Could not load the feed. Select the bell to retry."
			} else if !feed.done {
				status = "Loading recent music..."
			} else if len(feed.items) == 0 {
				status = "No music releases in the last seven days."
			}
			clay.Text(status, clay.TextElementConfig{fontSize = 13, textColor = MUTED})
		}
		if clay.UI_WithId(clay.ID("detail_rows"))(
		{
			layout = {
				layoutDirection = .TopToBottom,
				sizing = {width = clay.SizingGrow({}), height = clay.SizingGrow({})},
				padding = {left = u16(24 * d), right = u16(24 * d)},
			},
			clip = {vertical = true, childOffset = clay.GetScrollOffset()},
		},
		) {
			visible^ = scroll_items("detail_rows", len(feed.items), 1, FEED_ROW_HEIGHT * d, height)
			list_spacer(visible.before)
			text_width := max(0, width - (FEED_COVER_SIZE + 80 + SCROLLBAR_OUTSET) * d)
			for index in visible.first ..< visible.last {
				release := &feed.items[index]
				entry := &release.entry
				if clay.UI_WithId(clay.ID("feed_row", u32(index)))(
				{
					layout = {
						sizing = {
							width = clay.SizingGrow({}),
							height = clay.SizingFixed(FEED_ROW_HEIGHT * d),
						},
						padding = {top = u16(12 * d), bottom = u16(12 * d)},
						childGap = u16(24 * d),
						childAlignment = {y = .Center},
					},
					border = {color = CARD, width = {bottom = 1}},
				},
				) {
					cover_element(textures, entry.image, FEED_COVER_SIZE * d, 8 * d)
					if clay.UI()(
					{
						layout = {
							layoutDirection = .TopToBottom,
							sizing = {width = clay.SizingGrow({})},
							childGap = u16(8 * d),
						},
					},
					) {
						fitted_text(
							ui_state,
							entry.name,
							text_width,
							{fontId = 2, fontSize = 20, textColor = WHITE, wrapMode = .None},
						)
						fitted_text(
							ui_state,
							entry.subtitle,
							text_width,
							{fontSize = 14, textColor = MUTED, wrapMode = .None},
						)
						if clay.UI()(
						{layout = {childGap = u16(6 * d), childAlignment = {y = .Center}}},
						) {
							clay.Text(
								release.kind,
								clay.TextElementConfig{fontSize = 13, textColor = MUTED},
							)
							clay.Text(
								"•",
								clay.TextElementConfig{fontSize = 13, textColor = MUTED},
							)
							clay.Text(
								release_age_label(release.released_at, now),
								clay.TextElementConfig{fontSize = 13, textColor = MUTED},
							)
						}
						if clay.UI()(
						{layout = {childGap = u16(12 * d), childAlignment = {y = .Center}}},
						) {
							round_play_button(
								release_feed_action("play", index),
								"play-filled",
								textures,
								fx,
								d,
								36,
								15,
								WHITE,
								FOOTER_HOVER,
							)
							saved := release_feed_saved(client, release)
							icon_button(
								release_feed_action("save", index),
								saved ? "circle-check" : "circle-plus",
								client.like_pending ? .Disabled : saved ? .Green : .Muted,
								textures,
								fx,
								d,
							)
						}
					}
				}
			}
			list_spacer(visible.after)
			scroll_fades(
				"detail_rows",
				textures,
				textures.fade_detail_top,
				textures.fade_detail_bottom,
				&textures.fade_detail_top_alpha,
				&textures.fade_detail_bottom_alpha,
				0,
				width - (48 + SCROLLBAR_OUTSET) * d,
				dt,
				d,
			)
		}
	}
}
