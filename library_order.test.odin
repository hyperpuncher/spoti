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
