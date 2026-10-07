package main

import "core:slice"
import "core:testing"
import library "spotify/library"

@(test)
state_round_trip_preserves_order_and_clamps_input :: proc(t: ^testing.T) {
	loaded := parse_state(
		`{"sidebar_width":99999,"tab":"Artists","pinned":["spotify:playlist:a","spotify:playlist:b"],"recent":["spotify:playlist:c"]}`,
	)
	defer free_state(&loaded)
	testing.expect_value(t, loaded.sidebar_width, f32(SIDEBAR_MAX))
	testing.expect_value(t, loaded.tab, library.Kind.Artists)
	testing.expect_value(t, len(loaded.pinned), 2)
	testing.expect_value(t, loaded.pinned[0], "spotify:playlist:a")
	testing.expect_value(t, loaded.pinned[1], "spotify:playlist:b")
	testing.expect_value(t, loaded.recent[0], "spotify:playlist:c")

	encoded := format_state(&loaded)
	defer delete(encoded)
	decoded := parse_state(encoded)
	defer free_state(&decoded)
	testing.expect_value(t, decoded.sidebar_width, loaded.sidebar_width)
	testing.expect_value(t, decoded.tab, loaded.tab)
	testing.expect(t, slice.equal(decoded.pinned[:], loaded.pinned[:]))
	testing.expect(t, slice.equal(decoded.recent[:], loaded.recent[:]))

	// A corrupt file must still open the app with defaults.
	fallback := parse_state(`{"sidebar_width":"abc","tab":"unexpected"}`)
	defer free_state(&fallback)
	testing.expect_value(t, fallback.sidebar_width, DEFAULT_SIDEBAR_WIDTH)
	testing.expect_value(t, fallback.tab, library.Kind.Playlists)
}

@(test)
state_sorts_default_then_round_trips :: proc(t: ^testing.T) {
	fresh := parse_state("{}")
	defer free_state(&fresh)
	testing.expect_value(t, fresh.sort[.Albums], Sort.Default)
	testing.expect_value(t, fresh.sort[.Playlists], Sort.Default)
	testing.expect_value(t, fresh.sort[.Artists], Sort.Default)

	loaded := parse_state(`{"sort":{"Albums":"Played","Playlists":"Default","Artists":"Played"}}`)
	defer free_state(&loaded)
	testing.expect_value(t, loaded.sort[.Albums], Sort.Played)
	testing.expect_value(t, loaded.sort[.Playlists], Sort.Default)
	testing.expect_value(t, loaded.sort[.Artists], Sort.Played)

	encoded := format_state(&loaded)
	defer delete(encoded)
	decoded := parse_state(encoded)
	defer free_state(&decoded)
	testing.expect_value(t, decoded.sort[.Albums], Sort.Played)
	testing.expect_value(t, decoded.sort[.Playlists], Sort.Default)
	testing.expect_value(t, decoded.sort[.Artists], Sort.Played)

	// A retired name from an older file falls back to the default.
	retired := parse_state(`{"sort":{"Albums":"Added"}}`)
	defer free_state(&retired)
	testing.expect_value(t, retired.sort[.Albums], Sort.Default)
}

@(test)
state_volume_round_trips_and_clamps :: proc(t: ^testing.T) {
	fresh := parse_state("{}")
	defer free_state(&fresh)
	testing.expect_value(t, fresh.volume, DEFAULT_VOLUME)

	loaded := parse_state(`{"volume":0.8}`)
	defer free_state(&loaded)
	testing.expect_value(t, loaded.volume, f32(0.8))

	clamped := parse_state(`{"volume":7}`)
	defer free_state(&clamped)
	testing.expect_value(t, clamped.volume, f32(1))

	encoded := format_state(&loaded)
	defer delete(encoded)
	decoded := parse_state(encoded)
	defer free_state(&decoded)
	testing.expect_value(t, decoded.volume, f32(0.8))
}

@(test)
state_toggle_pin_and_recent_keep_most_recent_first :: proc(t: ^testing.T) {
	app_state := State{}
	defer free_state(&app_state)
	testing.expect(t, state_toggle_pin(&app_state, "u1"))
	testing.expect(t, state_toggle_pin(&app_state, "u2"))
	testing.expect(t, state_is_pinned(&app_state, "u1"))
	testing.expect(t, !state_toggle_pin(&app_state, "u1"))
	testing.expect(t, !state_is_pinned(&app_state, "u1"))
	testing.expect_value(t, app_state.pinned[0], "u2")

	state_note_recent(&app_state, "r1")
	state_note_recent(&app_state, "r2")
	state_note_recent(&app_state, "r1")
	state_note_recent(&app_state, "")
	testing.expect_value(t, len(app_state.recent), 2)
	testing.expect_value(t, app_state.recent[0], "r1")
	testing.expect_value(t, app_state.recent[1], "r2")
}

@(test)
state_last_played_round_trips_and_rejects_bad_values :: proc(t: ^testing.T) {
	loaded := parse_state(
		`{"last_played":{"track":"spotify:track:abc","title":"Song = Live","artist":"X, Y","cover":"https://i.scdn.co/image/c","album":"An Album","album_uri":"spotify:album:abc","first_artist":"X","artist_uri":"spotify:artist:xyz"},"last_collection":"spotify:album:abc","last_name":"An Album"}`,
	)
	defer free_state(&loaded)
	testing.expect_value(t, loaded.last_played.track, "spotify:track:abc")
	testing.expect_value(t, loaded.last_played.title, "Song = Live")
	testing.expect_value(t, loaded.last_played.artist, "X, Y")
	testing.expect_value(t, loaded.last_played.cover, "https://i.scdn.co/image/c")
	testing.expect_value(t, loaded.last_played.album, "An Album")
	testing.expect_value(t, loaded.last_played.album_uri, "spotify:album:abc")
	testing.expect_value(t, loaded.last_played.first_artist, "X")
	testing.expect_value(t, loaded.last_played.artist_uri, "spotify:artist:xyz")
	testing.expect_value(t, loaded.last_collection, "spotify:album:abc")
	testing.expect_value(t, loaded.last_name, "An Album")

	encoded := format_state(&loaded)
	defer delete(encoded)
	decoded := parse_state(encoded)
	defer free_state(&decoded)
	testing.expect_value(t, decoded.last_played.track, loaded.last_played.track)
	testing.expect_value(t, decoded.last_played.title, loaded.last_played.title)
	testing.expect_value(t, decoded.last_played.artist, loaded.last_played.artist)
	testing.expect_value(t, decoded.last_played.cover, loaded.last_played.cover)
	testing.expect_value(t, decoded.last_played.album, loaded.last_played.album)
	testing.expect_value(t, decoded.last_played.album_uri, loaded.last_played.album_uri)
	testing.expect_value(t, decoded.last_played.first_artist, loaded.last_played.first_artist)
	testing.expect_value(t, decoded.last_played.artist_uri, loaded.last_played.artist_uri)
	testing.expect_value(t, decoded.last_collection, loaded.last_collection)
	testing.expect_value(t, decoded.last_name, loaded.last_name)

	bad := parse_state(
		`{"last_played":{"track":"spotify:album:abc","cover":"http://insecure"},"last_collection":"spotify:track:abc"}`,
	)
	defer free_state(&bad)
	testing.expect_value(t, bad.last_played.track, "")
	testing.expect_value(t, bad.last_played.cover, "")
	testing.expect_value(t, bad.last_collection, "")
}
