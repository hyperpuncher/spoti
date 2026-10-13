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
reopened_queue_continues_after_the_same_duplicate_track :: proc(t: ^testing.T) {
	loaded := parse_state(
		`{"last_collection":"spotify:album:browsed","last_played":{"track":"spotify:track:duplicate","collection":"spotify:playlist:playing","queue_index":2,"shuffle":true,"queue":[{"uri":"spotify:track:duplicate","order":2},{"uri":"spotify:track:other","order":3},{"uri":"spotify:track:duplicate","order":0,"album":"Album","album_uri":"spotify:album:original","artist_links":[{"name":"Artist","uri":"spotify:artist:original"}]},{"uri":"spotify:track:next","order":1}]}}`,
	)
	defer free_state(&loaded)
	encoded := format_state(&loaded)
	defer delete(encoded)
	app := App {
		app_state  = parse_state(encoded),
		play_index = -1,
	}
	defer {
		free_state(&app.app_state)
		free_play_queue(&app.play_queue)
		delete(app.queue_detail)
	}
	app_restore_play_queue(&app)
	if !testing.expect_value(t, len(app.play_queue), 4) {return}
	testing.expect_value(t, app.play_index, 2)
	testing.expect_value(t, app.play_queue[app.play_index].order, 0)
	testing.expect_value(t, app.queue_detail, "spotify:playlist:playing")
	testing.expect_value(t, app.app_state.last_collection, "spotify:album:browsed")
	testing.expect(t, app.shuffle && app.queue_restore_pending)
	// Live playback and the saved record must have independent ownership.
	free_play_queue(&app.app_state.last_played.queue)
	testing.expect_value(t, app.play_queue[2].album_uri, "spotify:album:original")
	testing.expect_value(t, app.play_queue[2].artist_links[0].uri, "spotify:artist:original")
	selected, cover, artist: string
	defer {delete(selected); delete(cover); delete(artist)}
	testing.expect(
		t,
		advance_play_item(app.play_queue[:], &app.play_index, 1, &selected, &cover, &artist),
	)
	testing.expect_value(t, selected, "spotify:track:next")
	testing.expect(
		t,
		!advance_play_item(app.play_queue[:], &app.play_index, 1, &selected, &cover, &artist),
	)
	app.play_index = reorder_play_queue(app.play_queue[:], app.play_index, false)
	testing.expect_value(t, app.play_index, 1)
	testing.expect_value(t, app.play_queue[app.play_index].uri, "spotify:track:next")
	for item, index in app.play_queue {testing.expect_value(t, item.order, index)}
}

@(test)
invalid_saved_queue_does_not_replace_the_footer_track :: proc(t: ^testing.T) {
	loaded := parse_state(
		`{"last_played":{"track":"spotify:track:current","queue_index":8,"queue":[{"uri":"spotify:track:current"}]}}`,
	)
	defer free_state(&loaded)
	testing.expect_value(t, loaded.last_played.track, "spotify:track:current")
	testing.expect_value(t, len(loaded.last_played.queue), 0)
	mismatch := parse_state(
		`{"last_played":{"track":"spotify:track:current","queue_index":0,"queue":[{"uri":"spotify:track:other"}]}}`,
	)
	defer free_state(&mismatch)
	testing.expect_value(t, len(mismatch.last_played.queue), 0)
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
