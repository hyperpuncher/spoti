// Right-click menu for library cards and track rows.
package main

import "core:fmt"
import "core:strings"
import library "spotify/library"
import clay "vendor/clay"
import sdl "vendor:sdl3"

MENU_ITEMS_MAX :: 5

Menu_Item :: enum {
	Pin,
	Copy_Link,
	Open_In_Spotify,
	Play,
	Add_To_Queue,
	Save_Album,
	Pick_Sort,
	Add_To_Playlist,
	Remove_From_Playlist,
}

Context_Menu :: struct {
	open:         bool,
	point:        sdl.FPoint,
	track:        int, // detail row index, or -1 for cards
	uri:          string, // owned clone of the target
	items:        [MENU_ITEMS_MAX]Menu_Item,
	labels:       [MENU_ITEMS_MAX]string,
	count:        int,
	selected:     int, // check-marked row, or -1
	sorts:        [4]Sort, // sort payload per row for Pick_Sort
	picker_open:  bool, // the nested add-to-playlist submenu is showing
	picker_items: [dynamic]library.Entry, // reused, owned; the editable playlists
}

free_context_menu :: proc(menu: ^Context_Menu) {
	delete(menu.uri)
	delete(menu.picker_items)
	menu^ = {}
	// Only the sort picker marks a row; the others must not draw a check.
	menu.selected = -1
}

// Row index of the add-to-playlist action, or -1 when the menu has none.
menu_add_index :: proc(menu: ^Context_Menu) -> int {
	for index in 0 ..< menu.count {
		if menu.items[index] == .Add_To_Playlist {return index}
	}
	return -1
}

open_context_menu :: proc(
	menu: ^Context_Menu,
	point: sdl.FPoint,
	uri: string = "",
	track: int = -1,
) {
	free_context_menu(menu)
	menu.open = true
	menu.point = point
	menu.track = track
	menu.uri = strings.clone(uri)
}

open_card_menu :: proc(menu: ^Context_Menu, point: sdl.FPoint, uri: string, pinned: bool) {
	open_context_menu(menu, point, uri)
	menu.items[0] = .Pin
	menu.labels[0] = pinned ? "Unpin" : "Pin"
	menu.items[1] = .Copy_Link
	menu.labels[1] = "Copy link"
	menu.items[2] = .Open_In_Spotify
	menu.labels[2] = "Open in Spotify"
	menu.count = 3
}

open_track_menu :: proc(
	menu: ^Context_Menu,
	point: sdl.FPoint,
	track: int,
	uri: string,
	removable: bool = false,
) {
	open_context_menu(menu, point, uri, track)
	menu.items = {
		.Play,
		.Add_To_Queue,
		removable ? .Remove_From_Playlist : .Add_To_Playlist,
		.Copy_Link,
		.Open_In_Spotify,
	}
	menu.labels = {
		"Play",
		"Add to queue",
		removable ? "Remove from playlist" : "Add to playlist",
		"Copy link",
		"Open in Spotify",
	}
	menu.count = 5
}

// Search and queue tracks can be queued or opened without a network lookup.
open_link_menu :: proc(menu: ^Context_Menu, point: sdl.FPoint, uri: string) {
	open_context_menu(menu, point, uri)
	if strings.has_prefix(uri, "spotify:track:") {
		menu.items[0], menu.labels[0] = .Add_To_Queue, "Add to queue"
		menu.count = 1
	}
	index := menu.count
	menu.items[index], menu.labels[index] = .Copy_Link, "Copy link"
	menu.items[index + 1], menu.labels[index + 1] = .Open_In_Spotify, "Open in Spotify"
	menu.count += 2
}

open_release_menu :: proc(menu: ^Context_Menu, point: sdl.FPoint, uri: string, saved: bool) {
	open_context_menu(menu, point, uri)
	menu.items = {.Play, .Save_Album, .Add_To_Playlist, .Copy_Link, .Open_In_Spotify}
	menu.labels = {
		"Play",
		saved ? "Remove from library" : "Save to library",
		"Add to playlist",
		"Copy link",
		"Open in Spotify",
	}
	menu.count = 5
}

// Library sort picker for a tab. The current sort carries a check; the tab
// itself comes from the sidebar filter when an item is picked.
open_sort_menu :: proc(menu: ^Context_Menu, point: sdl.FPoint, current: Sort) {
	options := [2]Sort{.Default, .Played}
	open_context_menu(menu, point)
	for option in options {
		index := menu.count
		menu.items[index] = .Pick_Sort
		menu.sorts[index] = option
		menu.labels[index] = sort_name(option)
		if option == current {menu.selected = index}
		menu.count += 1
	}
}

context_menu :: proc(menu: ^Context_Menu, textures: ^Textures, d: f32) {
	if menu == nil || !menu.open {return}
	if clay.UI_WithId(clay.ID("context_menu"))(
	{
		layout = {
			layoutDirection = .TopToBottom,
			sizing = {width = clay.SizingFit({}), height = clay.SizingFit({})},
			padding = clay.PaddingAll(u16(6 * d)),
			childGap = u16(2 * d),
		},
		floating = {offset = {menu.point.x, menu.point.y}, zIndex = 10, attachTo = .Root},
		backgroundColor = theme.panel,
		cornerRadius = clay.CornerRadiusAll(8 * d),
	},
	) {
		// Only the sort picker marks a row, so only it reserves the gutter;
		// every other menu fits its labels exactly.
		reserve := menu.selected >= 0 && menu.selected < menu.count
		for index in 0 ..< menu.count {
			hovered := clay.PointerOver(clay.ID("menu_item", u32(index)))
			if clay.UI_WithId(clay.ID("menu_item", u32(index)))(
			{
				layout = {
					sizing = {width = clay.SizingGrow({}), height = clay.SizingFixed(32 * d)},
					padding = {left = u16(10 * d), right = u16(10 * d)},
					childGap = u16(8 * d),
					childAlignment = {y = .Center},
				},
				backgroundColor = hovered ? theme.hover : clay.Color{},
				cornerRadius = clay.CornerRadiusAll(5 * d),
			},
			) {
				if index == menu.selected {
					icon_element(textures, "check", .White, 14 * d)
				} else if reserve {
					if clay.UI()({layout = {sizing = {width = clay.SizingFixed(14 * d)}}}) {}
				}
				clay.Text(menu.labels[index], {fontSize = 14, textColor = theme.text})
			}
		}
	}
	if menu.picker_open {playlist_picker(menu, d)}
}

PICKER_WIDTH :: 260
PICKER_ROW :: 30
PICKER_MAX_HEIGHT :: 360

// The playlists the account can add items to: owned or collaborative. Before
// the account id arrives every loaded playlist is offered, and a pick that
// turns out non-editable simply answers 403.
rebuild_picker_items :: proc(menu: ^Context_Menu, client: ^library.Client) {
	clear(&menu.picker_items)
	for entry in client.pages[.Playlists].items {
		editable := len(client.me_id) == 0 || entry.owner_id == client.me_id || entry.collaborative
		if editable {append(&menu.picker_items, entry)}
	}
}

// Nested submenu of the track menu: the playlists the account can add items
// to. It opens beside the add-to-playlist row and scrolls when the list is
// taller than the panel.
playlist_picker :: proc(menu: ^Context_Menu, d: f32) {
	add_index := menu_add_index(menu)
	if add_index < 0 {return}
	menu_box := clay.GetElementData(clay.ID("context_menu")).boundingBox
	add_box := clay.GetElementData(clay.ID("menu_item", u32(add_index))).boundingBox
	picker_x := menu_box.x + menu_box.width + 4 * d
	picker_y := add_box.y
	rows := f32(len(menu.picker_items))
	panel_height := rows == 0 ? 44 * d : min(rows * PICKER_ROW * d + 12 * d, PICKER_MAX_HEIGHT * d)
	if clay.UI_WithId(clay.ID("playlist_picker_panel"))(
	{
		layout = {
			layoutDirection = .TopToBottom,
			sizing = {
				width = clay.SizingFixed(PICKER_WIDTH * d),
				height = clay.SizingFixed(panel_height),
			},
			padding = clay.PaddingAll(u16(6 * d)),
		},
		floating = {offset = {picker_x, picker_y}, zIndex = 11, attachTo = .Root},
		backgroundColor = theme.panel,
		cornerRadius = clay.CornerRadiusAll(8 * d),
	},
	) {
		if rows == 0 {
			clay.Text("No playlists you can edit", {fontSize = 13, textColor = theme.muted})
			return
		}
		if clay.UI_WithId(clay.ID("playlist_picker"))(
		{
			layout = {
				layoutDirection = .TopToBottom,
				sizing = {width = clay.SizingGrow({}), height = clay.SizingGrow({})},
				childGap = u16(2 * d),
			},
			clip = {vertical = true, childOffset = clay.GetScrollOffset()},
		},
		) {
			gap := f32(u16(2 * d))
			visible := scroll_items(
				"playlist_picker",
				len(menu.picker_items),
				1,
				(PICKER_ROW - 2) * d + gap,
				panel_height,
			)
			list_spacer(visible.before - gap)
			for index in visible.first ..< visible.last {
				entry := menu.picker_items[index]
				hovered := clay.PointerOver(clay.ID("picker_item", u32(index)))
				if clay.UI_WithId(clay.ID("picker_item", u32(index)))(
				{
					layout = {
						sizing = {
							width = clay.SizingGrow({}),
							height = clay.SizingFixed((PICKER_ROW - 2) * d),
						},
						padding = {left = u16(8 * d), right = u16(8 * d)},
						childGap = u16(8 * d),
						childAlignment = {y = .Center},
					},
					backgroundColor = hovered ? theme.hover : clay.Color{},
					cornerRadius = clay.CornerRadiusAll(5 * d),
				},
				) {
					if clay.UI()(
					{
						layout = {
							sizing = {width = clay.SizingGrow({})},
							childGap = u16(8 * d),
							childAlignment = {y = .Center},
						},
						clip = {horizontal = true},
					},
					) {
						clay.Text(
							entry.name,
							{fontSize = 14, textColor = theme.text, wrapMode = .None},
						)
						if len(entry.subtitle) > 0 {
							clay.Text(
								entry.subtitle,
								{fontSize = 12, textColor = theme.muted, wrapMode = .None},
							)
						}
					}
				}
			}
			list_spacer(visible.after - gap)
		}
	}
}

DEVICE_ROW :: 54

// Connect device panel: the fetched devices with the active one checked.
// It floats above the footer speaker button; a pick transfers playback.
// Boxes are one frame old, like every other floating panel.
device_panel :: proc(view: View, textures: ^Textures, d: f32) {
	if !view.device_open {return}
	rows := view.device_rows
	panel_height :=
		len(rows) == 0 ? 64 * d : min(f32(len(rows)) * DEVICE_ROW * d + 12 * d, PICKER_MAX_HEIGHT * d)
	anchor := clay.GetElementData(clay.ID("footer_devices")).boundingBox
	panel_x := anchor.x + anchor.width - PICKER_WIDTH * d
	panel_y := anchor.y - panel_height - 8 * d
	if clay.UI_WithId(clay.ID("device_panel"))(
	{
		layout = {
			layoutDirection = .TopToBottom,
			sizing = {
				width = clay.SizingFixed(PICKER_WIDTH * d),
				height = clay.SizingFixed(panel_height),
			},
			padding = clay.PaddingAll(u16(6 * d)),
		},
		floating = {offset = {panel_x, panel_y}, zIndex = 11, attachTo = .Root},
		backgroundColor = theme.panel,
		cornerRadius = clay.CornerRadiusAll(8 * d),
	},
	) {
		if len(rows) == 0 {
			label :=
				view.device_loading ? "Finding devices..." : view.device_error ? "Could not load devices" : "No devices found"
			if clay.UI()(
			{
				layout = {
					sizing = {width = clay.SizingGrow({}), height = clay.SizingGrow({})},
					padding = {left = u16(10 * d), right = u16(10 * d)},
					childAlignment = {y = .Center},
				},
			},
			) {
				clay.Text(label, {fontSize = 13, textColor = theme.muted})
			}
			return
		}
		if clay.UI_WithId(clay.ID("device_picker"))(
		{
			layout = {
				layoutDirection = .TopToBottom,
				sizing = {width = clay.SizingGrow({}), height = clay.SizingGrow({})},
				childGap = u16(2 * d),
			},
			clip = {vertical = true, childOffset = clay.GetScrollOffset()},
		},
		) {
			for device, index in rows {
				hovered :=
					!device.restricted && clay.PointerOver(clay.ID("device_item", u32(index)))
				if clay.UI_WithId(clay.ID("device_item", u32(index)))(
				{
					layout = {
						sizing = {
							width = clay.SizingGrow({}),
							height = clay.SizingFixed((DEVICE_ROW - 2) * d),
						},
						padding = {left = u16(10 * d), right = u16(10 * d)},
						childGap = u16(10 * d),
						childAlignment = {y = .Center},
					},
					backgroundColor = hovered ? theme.hover : clay.Color{},
					cornerRadius = clay.CornerRadiusAll(5 * d),
				},
				) {
					if device.active {
						icon_element(textures, "check", .White, 14 * d)
					} else if clay.UI()({layout = {sizing = {width = clay.SizingFixed(14 * d)}}}) {
					}
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
							device.name,
							{fontSize = 14, textColor = theme.text, wrapMode = .None},
						)
						subtitle := device.restricted ? "restricted" : device.type
						clay.Text(
							subtitle,
							{fontSize = 12, textColor = theme.muted, wrapMode = .None},
						)
					}
				}
			}
		}
	}
}

// Picks the card or track under a right-click and opens its menu.
open_menu_at :: proc(
	menu: ^Context_Menu,
	client: ^library.Client,
	page: ^library.Page,
	kind: library.Kind,
	visible: Frame_Visible,
	point: sdl.FPoint,
	app_state: ^State,
) {
	if client.release_feed.open {
		for index in visible.feed.first ..< visible.feed.last {
			if !hit_clipped("feed_row", "detail_rows", point, u32(index)) {continue}
			release := &client.release_feed.items[index]
			open_release_menu(menu, point, release.entry.uri, release_feed_saved(client, release))
			return
		}
	}
	for index in visible.tracks.first ..< visible.tracks.last {
		if !hit_clipped("track_row", "detail_rows", point, u32(index)) {continue}
		removable :=
			client.detail.source == .Playlist &&
			(len(client.detail.owner_id) > 0 && client.detail.owner_id == client.me_id ||
					client.detail.collaborative)
		open_track_menu(menu, point, index, client.detail.rows[index].uri, removable)
		return
	}
	for index in visible.cards.first ..< visible.cards.last {
		if !hit_clipped("card", "library_grid", point, u32(index)) {continue}
		entry := page.items[index]
		if kind == .Tracks {
			open_link_menu(menu, point, entry.uri)
		} else {
			open_card_menu(menu, point, entry.uri, state_is_pinned(app_state, entry.uri))
		}
		return
	}
	menu.open = false
}

// Maps a Spotify URI to its web URL without ever logging it. Empty for a URI
// that has no open.spotify.com page, like the Liked Songs collection.
spotify_web_url :: proc(uri: string, allocator := context.allocator) -> string {
	kind, id: string
	switch {
	case strings.has_prefix(uri, "spotify:playlist:"):
		kind, id = "playlist", uri[len("spotify:playlist:"):]
	case strings.has_prefix(uri, "spotify:album:"):
		kind, id = "album", uri[len("spotify:album:"):]
	case strings.has_prefix(uri, "spotify:artist:"):
		kind, id = "artist", uri[len("spotify:artist:"):]
	case strings.has_prefix(uri, "spotify:track:"):
		kind, id = "track", uri[len("spotify:track:"):]
	case:
		return ""
	}
	if len(id) == 0 {return ""}
	return fmt.aprintf("https://open.spotify.com/%s/%s", kind, id, allocator = allocator)
}

open_spotify_uri :: proc(uri: string) {
	address := spotify_web_url(uri)
	if len(address) == 0 {return}
	defer delete(address)
	c_address := strings.clone_to_cstring(address)
	defer delete(c_address)
	_ = sdl.OpenURL(c_address)
}

// The link lives only in the clipboard; it is never written to the log.
copy_spotify_uri :: proc(uri: string) -> bool {
	address := spotify_web_url(uri)
	if len(address) == 0 {return false}
	defer delete(address)
	c_address := strings.clone_to_cstring(address)
	defer delete(c_address)
	return sdl.SetClipboardText(c_address)
}
