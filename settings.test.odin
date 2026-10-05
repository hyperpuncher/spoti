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
