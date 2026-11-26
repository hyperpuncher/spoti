package main

import "core:testing"
import library "spotify/library"

@(test)
detail_uri_matches_source_and_exact_id :: proc(t: ^testing.T) {
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
recently_added_sorts_saved_albums_by_timestamp_across_pages :: proc(t: ^testing.T) {
	client: library.Client
	page := &client.pages[.Albums]
	defer library.free_page(page)
	app_state: State
	for body in ([]string{`{"total":5,"offset":0,"next":"more","items":[
			{"added_at":"2026-11-20T12:34:31Z","album":{"name":"Roll N' Rock","uri":"spotify:album:roll"}},
			{"added_at":"2026-11-21T06:45:25Z","album":{"name":"Only 1","uri":"spotify:album:only"}},
			{"album":{"name":"No date","uri":"spotify:album:unknown"}}
		]}`, `{"total":5,"offset":3,"items":[
			{"added_at":"2026-11-21T10:42:06Z","album":{"name":"Hawsâ","uri":"spotify:album:hawsa"}},
			{"added_at":"2026-11-21T06:45:25Z","album":{"name":"Same save time","uri":"spotify:album:tied"}}
		]}`}) {
		incoming, ok := library.parse_index(transmute([]u8)body, .Albums)
		if !testing.expect(t, ok) {return}
		library.apply(&client, {kind = .Index, list = .Albums, page = incoming, ok = true})
		sort_library_pages(&client, &app_state, false)
	}
	want := []string{"Hawsâ", "Only 1", "Same save time", "Roll N' Rock", "No date"}
	if !testing.expect_value(t, len(page.items), len(want)) {return}
	for name, index in want {testing.expect_value(t, page.items[index].name, name)}
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
	append(
		&page.items,
		library.Entry{uri = "spotify:playlist:plain-a", library_order = 0},
		library.Entry{uri = "spotify:playlist:played", library_order = 1},
		library.Entry{uri = "spotify:playlist:plain-b", library_order = 2},
		library.Entry{uri = "spotify:playlist:pinned", library_order = 3},
	)
	app_state.sort[.Playlists] = .Played
	sort_library_page(&page, .Playlists, &app_state)
	testing.expect_value(t, page.items[0].uri, "spotify:playlist:pinned")
	testing.expect_value(t, page.items[1].uri, "spotify:playlist:played")

	app_state.sort[.Playlists] = .Default
	sort_library_page(&page, .Playlists, &app_state)
	testing.expect_value(t, page.items[0].uri, "spotify:playlist:pinned")
	testing.expect_value(t, page.items[1].uri, "spotify:playlist:plain-a")
	testing.expect_value(t, page.items[2].uri, "spotify:playlist:played")
	testing.expect_value(t, page.items[3].uri, "spotify:playlist:plain-b")
}
