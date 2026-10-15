package main

import "core:testing"
import library "spotify/library"

@(test)
restored_collection_preview_never_uses_track_artwork :: proc(t: ^testing.T) {
	app_state := State {
		last_collection = "spotify:playlist:radar",
		last_name = "Release Radar",
		last_saved = true,
		last_played = {
			title = "Lifestyle",
			cover = "https://i.scdn.co/image/track",
			collection = "spotify:playlist:radar",
		},
	}
	client: library.Client
	client.pages[.Albums].items = make([dynamic]library.Entry)
	defer delete(client.pages[.Albums].items)
	append(
		&client.pages[.Albums].items,
		library.Entry{uri = "spotify:album:radar", image = "https://i.scdn.co/image/unrelated"},
	)
	preview := state_collection_preview(&app_state, &client)
	testing.expect_value(t, preview.uri, app_state.last_collection)
	testing.expect_value(t, preview.name, "Release Radar")
	testing.expect_value(t, preview.image, "")
	testing.expect(t, preview.saved)
	// Missing collection metadata must not become the footer's track title.
	app_state.last_name = ""
	preview = state_collection_preview(&app_state, &client)
	testing.expect_value(t, preview.name, "")
	client.pages[.Playlists].items = make([dynamic]library.Entry)
	defer delete(client.pages[.Playlists].items)
	append(
		&client.pages[.Playlists].items,
		library.Entry{uri = "spotify:playlist:other", image = "https://i.scdn.co/image/other"},
		library.Entry {
			uri = app_state.last_collection,
			name = "Release Radar",
			image = "https://i.scdn.co/image/collection",
			subtitle = "spotify",
			total = 200,
			saved = true,
		},
	)
	preview = state_collection_preview(&app_state, &client)
	testing.expect_value(t, preview.image, "https://i.scdn.co/image/collection")
	testing.expect_value(t, preview.name, "Release Radar")
	testing.expect_value(t, preview.subtitle, "spotify")
	testing.expect_value(t, preview.total, 200)
	testing.expect_value(t, app_state.last_played.cover, "https://i.scdn.co/image/track")
}
