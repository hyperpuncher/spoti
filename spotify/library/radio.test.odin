package library

import session "../session"
import "core:encoding/json"
import "core:testing"

@(test)
radio_accepts_song_and_artist_seeds_only :: proc(t: ^testing.T) {
	id :: "0000000000000000000001"
	testing.expect_value(t, radio_uri("spotify:track:" + id), "spotify:station:track:" + id)
	testing.expect_value(t, radio_uri("spotify:artist:" + id), "spotify:station:artist:" + id)
	testing.expect_value(t, radio_uri("spotify:album:" + id), "")
	testing.expect_value(t, radio_uri("spotify:track:" + id + "?x"), "")
	testing.expect_value(t, radio_uri("spotify:track:short"), "")
}

@(test)
radio_keeps_station_order_and_resolves_tracks_by_uri_or_gid :: proc(t: ^testing.T) {
	body := `{"pages":[{"tracks":[
		{"uri":"spotify:track:0000000000000000000003"},
		{"gid":"AAAAAAAAAAAAAAAAAAAAAA=="},
		{"uri":"spotify:episode:0000000000000000000001"},
		{"gid":"not a gid"}
	]},{"tracks":[
		{"uri":"spotify:track:0000000000000000000003"},
		{"uri":"spotify:track:0000000000000000000002"}
	]}]}`
	ctx: session.Playback_Context
	if !testing.expect(
		t,
		json.unmarshal(transmute([]u8)body, &ctx, allocator = context.temp_allocator) == nil,
	) {return}
	uris := radio_tracks(ctx)
	if !testing.expect_value(t, len(uris), 3) {return}
	testing.expect_value(t, uris[0], "spotify:track:0000000000000000000003")
	testing.expect_value(t, uris[1], "spotify:track:0000000000000000000000")
	testing.expect_value(t, uris[2], "spotify:track:0000000000000000000002")
}
