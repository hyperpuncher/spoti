// Right-click menu for library cards and track rows.
package main

import "core:fmt"
import "core:strings"
import library "spotify/library"
import clay "vendor/clay"
import sdl "vendor:sdl3"

Menu_Item :: enum {
	Pin,
	Open_In_Spotify,
	Play,
	Pick_Sort,
}

Context_Menu :: struct {
	open:     bool,
	point:    sdl.FPoint,
	track:    int, // detail row index, or -1 for cards
	uri:      string, // owned clone of the target
	items:    [4]Menu_Item,
	labels:   [4]string,
	count:    int,
	selected: int, // check-marked row, or -1
	sorts:    [4]Sort, // sort payload per row for Pick_Sort
}

free_context_menu :: proc(menu: ^Context_Menu) {
	delete(menu.uri)
	menu^ = {}
}

open_card_menu :: proc(menu: ^Context_Menu, point: sdl.FPoint, uri: string, pinned: bool) {
	free_context_menu(menu)
	menu.open = true
	menu.point = point
	menu.track = -1
	menu.uri = strings.clone(uri)
	menu.items[0] = .Pin
	menu.labels[0] = pinned ? "Unpin" : "Pin"
	menu.items[1] = .Open_In_Spotify
	menu.labels[1] = "Open in Spotify"
	menu.count = 2
}

open_track_menu :: proc(menu: ^Context_Menu, point: sdl.FPoint, track: int, uri: string) {
	free_context_menu(menu)
	menu.open = true
	menu.point = point
	menu.track = track
	menu.uri = strings.clone(uri)
	menu.items[0] = .Play
	menu.labels[0] = "Play"
	menu.items[1] = .Open_In_Spotify
	menu.labels[1] = "Open in Spotify"
	menu.count = 2
}

// Search tracks play with a left click; the menu only links out.
open_link_menu :: proc(menu: ^Context_Menu, point: sdl.FPoint, uri: string) {
	free_context_menu(menu)
	menu.open = true
	menu.point = point
	menu.track = -1
	menu.uri = strings.clone(uri)
	menu.items[0] = .Open_In_Spotify
	menu.labels[0] = "Open in Spotify"
	menu.count = 1
}

// Library sort picker for a tab. The current sort carries a check; the tab
// itself comes from the sidebar filter when an item is picked.
open_sort_menu :: proc(menu: ^Context_Menu, point: sdl.FPoint, current: Sort) {
	options := [2]Sort{.Default, .Played}
	free_context_menu(menu)
	menu.open = true
	menu.point = point
	menu.track = -1
	menu.selected = -1
	for option in options {
		index := menu.count
		menu.items[index] = .Pick_Sort
		menu.sorts[index] = option
		menu.labels[index] = sort_name(option)
		if option == current {menu.selected = index}
		menu.count += 1
	}
}

context_menu :: proc(view: View, textures: ^Textures, d: f32) {
	if !view.menu_open {return}
	if clay.UI_WithId(clay.ID("context_menu"))(
	{
		layout = {
			layoutDirection = .TopToBottom,
			sizing = {width = clay.SizingFixed(190 * d), height = clay.SizingFit({})},
			padding = clay.PaddingAll(u16(6 * d)),
			childGap = u16(2 * d),
		},
		floating = {offset = {view.menu_x, view.menu_y}, zIndex = 10, attachTo = .Root},
		backgroundColor = PANEL,
		cornerRadius = clay.CornerRadiusAll(8 * d),
	},
	) {
		for index in 0 ..< view.menu_count {
			hovered := clay.PointerOver(clay.ID("menu_item", u32(index)))
			if clay.UI_WithId(clay.ID("menu_item", u32(index)))(
			{
				layout = {
					sizing = {width = clay.SizingGrow({}), height = clay.SizingFixed(32 * d)},
					padding = {left = u16(10 * d), right = u16(10 * d)},
					childGap = u16(8 * d),
					childAlignment = {y = .Center},
				},
				backgroundColor = hovered ? HOVER : clay.Color{},
				cornerRadius = clay.CornerRadiusAll(5 * d),
			},
			) {
				if index == view.menu_selected {
					icon_element(textures, "check", .White, 14 * d)
				} else if clay.UI()({layout = {sizing = {width = clay.SizingFixed(14 * d)}}}) {}
				clay.Text(
					view.menu_labels[index],
					clay.TextElementConfig{fontSize = 14, textColor = WHITE},
				)
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
	for index in visible.tracks.first ..< visible.tracks.last {
		if !hit_clipped("track_row", "detail_rows", point, u32(index)) {continue}
		open_track_menu(menu, point, index, client.detail.rows[index].uri)
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

// Maps a Spotify URI to its web URL without ever logging it.
open_spotify_uri :: proc(uri: string) {
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
		return
	}
	address := fmt.aprintf("https://open.spotify.com/%s/%s", kind, id)
	defer delete(address)
	c_address := strings.clone_to_cstring(address)
	defer delete(c_address)
	_ = sdl.OpenURL(c_address)
}
