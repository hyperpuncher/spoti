package main

import "core:testing"
import library "spotify/library"

@(test)
detail_uri_matches_source_and_id_without_building_a_string :: proc(t: ^testing.T) {
	album := library.Detail {
		source = .Album,
		id     = "album-1",
	}
	playlist := library.Detail {
		source = .Playlist,
		id     = "playlist-1",
	}
	testing.expect(t, detail_matches_uri(album, "spotify:album:album-1"))
	testing.expect(t, !detail_matches_uri(album, "spotify:playlist:album-1"))
	testing.expect(t, !detail_matches_uri(album, "spotify:album:album-10"))
	testing.expect(t, detail_matches_uri(playlist, "spotify:playlist:playlist-1"))
	testing.expect(t, detail_matches_uri(library.Detail{source = .Liked}, ""))
}

@(test)
library_order_places_pins_then_recent_and_keeps_spotify_order :: proc(t: ^testing.T) {
	app_state := State{}
	defer free_state(&app_state)
	state_toggle_pin(&app_state, "spotify:playlist:pinned")
	state_note_recent(&app_state, "spotify:playlist:played")

	page := library.Page {
		items = make([dynamic]library.Entry, 0, 4),
	}
	defer delete(page.items)
	for sort in Sort {
		clear(&page.items)
		append(
			&page.items,
			library.Entry{uri = "spotify:playlist:plain-a"},
			library.Entry{uri = "spotify:playlist:played"},
			library.Entry{uri = "spotify:playlist:plain-b"},
			library.Entry{uri = "spotify:playlist:pinned"},
		)
		app_state.sort[.Playlists] = sort
		sort_library_page(&page, .Playlists, &app_state)
		testing.expect_value(t, page.items[0].uri, "spotify:playlist:pinned")
		testing.expect_value(
			t,
			page.items[1].uri,
			sort == .Played ? "spotify:playlist:played" : "spotify:playlist:plain-a",
		)
		testing.expect_value(
			t,
			page.items[2].uri,
			sort == .Played ? "spotify:playlist:plain-a" : "spotify:playlist:played",
		)
		testing.expect_value(t, page.items[3].uri, "spotify:playlist:plain-b")
	}
}
