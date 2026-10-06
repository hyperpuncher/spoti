package main

import "core:testing"
import library "spotify/library"

@(test)
library_order_places_pins_then_recent_and_keeps_spotify_order :: proc(t: ^testing.T) {
	settings := Settings{}
	defer free_settings(&settings)
	settings.sort[.Playlists] = .Played
	settings_toggle_pin(&settings, "spotify:playlist:pinned")
	settings_note_recent(&settings, "spotify:playlist:played")

	page := library.Page {
		items = make([dynamic]library.Entry, 0, 4),
	}
	defer delete(page.items)
	append(
		&page.items,
		library.Entry{uri = "spotify:playlist:plain-a"},
		library.Entry{uri = "spotify:playlist:played"},
		library.Entry{uri = "spotify:playlist:plain-b"},
		library.Entry{uri = "spotify:playlist:pinned"},
	)
	sort_library_page(&page, .Playlists, &settings)
	testing.expect_value(t, page.items[0].uri, "spotify:playlist:pinned")
	testing.expect_value(t, page.items[1].uri, "spotify:playlist:played")
	testing.expect_value(t, page.items[2].uri, "spotify:playlist:plain-a")
	testing.expect_value(t, page.items[3].uri, "spotify:playlist:plain-b")
}

@(test)
library_order_added_sorts_albums_newest_first_missing_last :: proc(t: ^testing.T) {
	settings := Settings{}
	defer free_settings(&settings)
	settings.sort[.Albums] = .Added
	settings_toggle_pin(&settings, "spotify:album:pinned")

	page := library.Page {
		items = make([dynamic]library.Entry, 0, 4),
	}
	defer delete(page.items)
	append(
		&page.items,
		library.Entry{uri = "spotify:album:old", added_at = "2023-05-01T00:00:00Z"},
		library.Entry{uri = "spotify:album:nodate"},
		library.Entry{uri = "spotify:album:new", added_at = "2024-02-01T00:00:00Z"},
		library.Entry{uri = "spotify:album:pinned", added_at = "2020-01-01T00:00:00Z"},
	)
	sort_library_page(&page, .Albums, &settings)
	testing.expect_value(t, page.items[0].uri, "spotify:album:pinned")
	testing.expect_value(t, page.items[1].uri, "spotify:album:new")
	testing.expect_value(t, page.items[2].uri, "spotify:album:old")
	testing.expect_value(t, page.items[3].uri, "spotify:album:nodate")
}

@(test)
library_order_name_sorts_case_insensitive :: proc(t: ^testing.T) {
	settings := Settings{}
	defer free_settings(&settings)
	settings.sort[.Playlists] = .Name

	page := library.Page {
		items = make([dynamic]library.Entry, 0, 3),
	}
	defer delete(page.items)
	append(
		&page.items,
		library.Entry{uri = "spotify:playlist:c", name = "charlie"},
		library.Entry{uri = "spotify:playlist:a", name = "Alpha"},
		library.Entry{uri = "spotify:playlist:b", name = "Bravo"},
	)
	sort_library_page(&page, .Playlists, &settings)
	testing.expect_value(t, page.items[0].uri, "spotify:playlist:a")
	testing.expect_value(t, page.items[1].uri, "spotify:playlist:b")
	testing.expect_value(t, page.items[2].uri, "spotify:playlist:c")
}
