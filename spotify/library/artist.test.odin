package library

import ap "../ap"
import track "../track"
import "core:fmt"
import "core:mem/virtual"
import "core:testing"

// A Track message with the fields a row needs. Only the gid matters here;
// the top_track block itself carries no name or duration.
test_top_track :: proc(gid: [16]u8, name: string, duration_ms: u64) -> [dynamic]u8 {
	bytes := gid
	message := make([dynamic]u8)
	ap.put_bytes(&message, 1, bytes[:])
	ap.put_bytes(&message, 2, transmute([]u8)name)
	ap.put_number(&message, 7, duration_ms << 1) // sint32 zigzag
	return message
}

test_gid :: proc(seed: u8) -> [16]u8 {
	gid: [16]u8
	for i in 0 ..< 16 {gid[i] = seed + u8(i)}
	return gid
}

test_top_uri :: proc(gid: [16]u8) -> string {
	return fmt.aprintf(
		"spotify:track:%s",
		track.base62_id(gid, context.temp_allocator),
		allocator = context.temp_allocator,
	)
}

// Wraps an Artist message in the BatchedExtensionResponse envelope the
// metadata service returns: field 2 array, field 2 kind, field 3 entity,
// field 3 Any, field 2 payload.
test_artist_response :: proc(artist: []u8) -> [dynamic]u8 {
	payload := make([dynamic]u8)
	defer delete(payload)
	ap.put_bytes(&payload, 2, artist)
	entity := make([dynamic]u8)
	defer delete(entity)
	ap.put_bytes(&entity, 2, transmute([]u8)string("spotify:artist:abc"))
	ap.put_bytes(&entity, 3, payload[:])
	array := make([dynamic]u8)
	defer delete(array)
	ap.put_number(&array, 2, ARTIST_V4)
	ap.put_bytes(&array, 3, entity[:])
	body := make([dynamic]u8)
	ap.put_bytes(&body, 2, array[:])
	return body
}

@(test)
artist_top_tracks_choose_the_country_block :: proc(t: ^testing.T) {
	arena: virtual.Arena
	if virtual.arena_init_growing(&arena) != nil {testing.fail_now(t, "arena")}
	defer virtual.arena_destroy(&arena)

	account_gid := test_gid(0x11)
	worldwide_gid := test_gid(0x40)
	account := test_top_track(account_gid, "Hit for the account", 200_000)
	defer delete(account)
	worldwide := test_top_track(worldwide_gid, "Hit worldwide", 180_000)
	defer delete(worldwide)

	account_block := make([dynamic]u8)
	defer delete(account_block)
	ap.put_bytes(&account_block, 1, transmute([]u8)string("US"))
	ap.put_bytes(&account_block, 2, account[:])
	worldwide_block := make([dynamic]u8)
	defer delete(worldwide_block)
	ap.put_bytes(&worldwide_block, 2, worldwide[:]) // empty country = global

	artist := make([dynamic]u8)
	defer delete(artist)
	ap.put_bytes(&artist, 4, worldwide_block[:])
	ap.put_bytes(&artist, 4, account_block[:])
	body := test_artist_response(artist[:])
	defer delete(body)

	uris, ok := parse_artist_top_uris(body[:], "US", virtual.arena_allocator(&arena))
	testing.expect(t, ok && len(uris) == 1)
	testing.expect_value(t, uris[0], test_top_uri(account_gid))

	// With no account country the worldwide block takes over.
	global_uris, global_ok := parse_artist_top_uris(body[:], "", virtual.arena_allocator(&arena))
	testing.expect(t, global_ok && len(global_uris) == 1)
	testing.expect_value(t, global_uris[0], test_top_uri(worldwide_gid))
}

@(test)
artist_overview_keeps_banner_listeners_and_playable_counts :: proc(t: ^testing.T) {
	detail := Detail {
		id = "fixture",
	}
	if !testing.expect(t, virtual.arena_init_growing(&detail.arena) == nil) {return}
	defer free_detail(&detail)
	body := `{"data":{"artistUnion":{"uri":"spotify:artist:fixture","profile":{"name":"Artist"},"visuals":{"headerImage":{"sources":[{"url":"https://i.scdn.co/image/banner","width":2660,"height":1140}]}},"stats":{"monthlyListeners":17600000},"discography":{"topTracks":{"items":[{"track":{"uri":"spotify:track:0000000000000000000001","name":"Hit","contentRating":{"label":"EXPLICIT"},"playcount":"563387486","duration":{"totalMilliseconds":142000},"playability":{"playable":true},"artists":{"items":[{"uri":"spotify:artist:fixture","profile":{"name":"Artist"}}]}}},{"track":{"uri":"spotify:track:0000000000000000000002","name":"Unavailable","playability":{"playable":false}}}]}}}}}`
	if !testing.expect(t, parse_artist_overview(transmute([]u8)body, &detail)) {return}
	testing.expect_value(t, detail.banner, "https://i.scdn.co/image/banner")
	testing.expect_value(t, detail.monthly_listeners, 17600000)
	if testing.expect_value(t, len(detail.rows), 1) {
		testing.expect_value(t, detail.rows[0].play_count, 563387486)
		testing.expect(t, detail.rows[0].explicit)
		testing.expect_value(t, detail.rows[0].duration_ms, 142000)
		testing.expect_value(t, detail.rows[0].artist_links[0].name, "Artist")
	}
	errors := `{"errors":[{"message":"PersistedQueryNotFound"}]}`
	testing.expect(t, !parse_artist_overview(transmute([]u8)errors, &detail))
	testing.expect_value(t, detail.banner, "https://i.scdn.co/image/banner")
	no_banner := `{"data":{"artistUnion":{"uri":"spotify:artist:fixture","profile":{"name":"Artist"},"visuals":{"headerImage":null},"stats":{"monthlyListeners":123},"discography":{"topTracks":{"items":[]}}}}}`
	testing.expect(t, parse_artist_overview(transmute([]u8)no_banner, &detail))
	testing.expect_value(t, detail.banner, "")
	testing.expect_value(t, detail.monthly_listeners, 123)
}
