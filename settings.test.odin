package main

import "core:slice"
import "core:testing"
import library "spotify/library"

@(test)
settings_round_trip_preserves_order_and_clamps_input :: proc(t: ^testing.T) {
	loaded := parse_settings(
		"sidebar_width=99999\ntab=artists\npin=spotify:playlist:a\npin=spotify:playlist:b\nrecent=spotify:playlist:c\n",
	)
	defer free_settings(&loaded)
	testing.expect_value(t, loaded.sidebar_width, f32(SIDEBAR_MAX))
	testing.expect_value(t, loaded.tab, library.Kind.Artists)
	testing.expect_value(t, len(loaded.pinned), 2)
	testing.expect_value(t, loaded.pinned[0], "spotify:playlist:a")
	testing.expect_value(t, loaded.pinned[1], "spotify:playlist:b")
	testing.expect_value(t, loaded.recent[0], "spotify:playlist:c")

	encoded := format_settings(&loaded)
	defer delete(encoded)
	decoded := parse_settings(encoded)
	defer free_settings(&decoded)
	testing.expect_value(t, decoded.sidebar_width, loaded.sidebar_width)
	testing.expect_value(t, decoded.tab, loaded.tab)
	testing.expect(t, slice.equal(decoded.pinned[:], loaded.pinned[:]))
	testing.expect(t, slice.equal(decoded.recent[:], loaded.recent[:]))

	// A corrupt file must still open the app with defaults.
	fallback := parse_settings("sidebar_width=abc\ntab=unexpected\n")
	defer free_settings(&fallback)
	testing.expect_value(t, fallback.sidebar_width, DEFAULT_SIDEBAR_WIDTH)
	testing.expect_value(t, fallback.tab, library.Kind.Playlists)
}

@(test)
settings_sort_defaults_albums_to_added_and_round_trips :: proc(t: ^testing.T) {
	fresh := parse_settings("")
	defer free_settings(&fresh)
	testing.expect_value(t, fresh.sort[.Albums], Sort.Default)
	testing.expect_value(t, fresh.sort[.Playlists], Sort.Default)
	testing.expect_value(t, fresh.sort[.Artists], Sort.Default)

	loaded := parse_settings("sort_albums=played\nsort_playlists=default\nsort_artists=played\n")
	defer free_settings(&loaded)
	testing.expect_value(t, loaded.sort[.Albums], Sort.Played)
	testing.expect_value(t, loaded.sort[.Playlists], Sort.Default)
	testing.expect_value(t, loaded.sort[.Artists], Sort.Played)

	encoded := format_settings(&loaded)
	defer delete(encoded)
	decoded := parse_settings(encoded)
	defer free_settings(&decoded)
	testing.expect_value(t, decoded.sort[.Albums], Sort.Played)
	testing.expect_value(t, decoded.sort[.Playlists], Sort.Default)
	testing.expect_value(t, decoded.sort[.Artists], Sort.Played)

	// A retired serial from an older file falls back to the default.
	retired := parse_settings("sort_albums=added\n")
	defer free_settings(&retired)
	testing.expect_value(t, retired.sort[.Albums], Sort.Default)
}

@(test)
settings_volume_round_trips_and_clamps :: proc(t: ^testing.T) {
	fresh := parse_settings("")
	defer free_settings(&fresh)
	testing.expect_value(t, fresh.volume, DEFAULT_VOLUME)

	loaded := parse_settings("volume=0.8\n")
	defer free_settings(&loaded)
	testing.expect_value(t, loaded.volume, f32(0.8))

	clamped := parse_settings("volume=7\n")
	defer free_settings(&clamped)
	testing.expect_value(t, clamped.volume, f32(1))

	encoded := format_settings(&loaded)
	defer delete(encoded)
	decoded := parse_settings(encoded)
	defer free_settings(&decoded)
	testing.expect_value(t, decoded.volume, f32(0.8))
}

@(test)
settings_toggle_pin_and_recent_keep_most_recent_first :: proc(t: ^testing.T) {
	settings := Settings{}
	defer free_settings(&settings)
	testing.expect(t, settings_toggle_pin(&settings, "u1"))
	testing.expect(t, settings_toggle_pin(&settings, "u2"))
	testing.expect(t, settings_is_pinned(&settings, "u1"))
	testing.expect(t, !settings_toggle_pin(&settings, "u1"))
	testing.expect(t, !settings_is_pinned(&settings, "u1"))
	testing.expect_value(t, settings.pinned[0], "u2")

	settings_note_recent(&settings, "r1")
	settings_note_recent(&settings, "r2")
	settings_note_recent(&settings, "r1")
	settings_note_recent(&settings, "")
	testing.expect_value(t, len(settings.recent), 2)
	testing.expect_value(t, settings.recent[0], "r1")
	testing.expect_value(t, settings.recent[1], "r2")
}

@(test)
settings_last_played_round_trips_and_rejects_bad_values :: proc(t: ^testing.T) {
	loaded := parse_settings(
		"last_track=spotify:track:abc\nlast_title=Song = Live\nlast_artist=X, Y\nlast_cover=https://i.scdn.co/image/c\nlast_collection=spotify:album:abc\nlast_name=An Album\nlast_track=https://evil\n",
	)
	defer free_settings(&loaded)
	testing.expect_value(t, loaded.last_track, "spotify:track:abc")
	testing.expect_value(t, loaded.last_title, "Song = Live")
	testing.expect_value(t, loaded.last_artist, "X, Y")
	testing.expect_value(t, loaded.last_cover, "https://i.scdn.co/image/c")
	testing.expect_value(t, loaded.last_collection, "spotify:album:abc")
	testing.expect_value(t, loaded.last_name, "An Album")

	encoded := format_settings(&loaded)
	defer delete(encoded)
	decoded := parse_settings(encoded)
	defer free_settings(&decoded)
	testing.expect_value(t, decoded.last_track, loaded.last_track)
	testing.expect_value(t, decoded.last_title, loaded.last_title)
	testing.expect_value(t, decoded.last_artist, loaded.last_artist)
	testing.expect_value(t, decoded.last_cover, loaded.last_cover)
	testing.expect_value(t, decoded.last_collection, loaded.last_collection)
	testing.expect_value(t, decoded.last_name, loaded.last_name)

	bad := parse_settings(
		"last_track=spotify:album:abc\nlast_cover=http://insecure\nlast_collection=spotify:track:abc\n",
	)
	defer free_settings(&bad)
	testing.expect_value(t, bad.last_track, "")
	testing.expect_value(t, bad.last_cover, "")
	testing.expect_value(t, bad.last_collection, "")
}
