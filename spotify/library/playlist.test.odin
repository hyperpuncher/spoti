package library

import ap "../ap"
import "core:encoding/json"
import "core:mem/virtual"
import "core:testing"

@(test)
internal_playlist_window_checks_position_and_completeness :: proc(t: ^testing.T) {
	uri := "spotify:track:0000000000000000000000"
	item := make([dynamic]u8)
	defer delete(item)
	ap.put_bytes(&item, 1, transmute([]u8)uri)
	contents := make([dynamic]u8)
	defer delete(contents)
	ap.put_number(&contents, 1, 50)
	ap.put_number(&contents, 2, 0)
	for timestamp in ([]u64{1726617600000, 1726704000000}) {
		attributes := make([dynamic]u8)
		defer delete(attributes)
		ap.put_number(&attributes, 2, timestamp)
		occurrence := make([dynamic]u8)
		defer delete(occurrence)
		ap.put_bytes(&occurrence, 1, transmute([]u8)uri)
		ap.put_bytes(&occurrence, 2, attributes[:])
		ap.put_bytes(&contents, 3, occurrence[:])
	}
	body := make([dynamic]u8)
	defer delete(body)
	ap.put_number(&body, 2, 52)
	ap.put_bytes(&body, 5, contents[:])
	window, ok := parse_playlist_window(body[:], 50)
	testing.expect(t, ok && window.total == 52 && window.next_offset == 52)
	testing.expect_value(t, len(window.uris), 2)
	testing.expect_value(t, window.added_at[0], 1726617600000)
	testing.expect_value(t, window.added_at[1], 1726704000000)
	_, ok = parse_playlist_window(body[:], 0)
	testing.expect(t, !ok, "a different window must not be appended")
	body[1] = 53
	_, ok = parse_playlist_window(body[:], 50)
	testing.expect(t, !ok, "a short window must not skip unseen items")
	_, ok = parse_playlist_window([]u8{0x12, 0xff}, 0)
	testing.expect(t, !ok)
}

@(test)
internal_playlist_metadata_deduplicates_requests_but_preserves_rows :: proc(t: ^testing.T) {
	uri := "spotify:track:0000000000000000000000"
	uris := []string{uri, "spotify:local:unsupported", uri}
	request := playlist_metadata_request(uris)
	defer delete(request)
	entity, found, valid := ap.get_bytes(request[:], 2)
	testing.expect(t, found && valid, "only one entity should be requested")
	query, _, _ := ap.get_bytes(entity, 2)
	kind, _, _ := ap.get_number(query, 1)
	testing.expect_value(t, kind, 10)

	metadata := make([dynamic]u8)
	defer delete(metadata)
	gid: [16]u8
	ap.put_bytes(&metadata, 1, gid[:])
	ap.put_bytes(&metadata, 2, transmute([]u8)string("Example"))
	ap.put_number(&metadata, 7, 2000)
	ap.put_number(&metadata, 9, 1)
	any := make([dynamic]u8)
	defer delete(any)
	ap.put_bytes(&any, 2, metadata[:])
	answer := make([dynamic]u8)
	defer delete(answer)
	ap.put_bytes(&answer, 2, transmute([]u8)uri)
	ap.put_bytes(&answer, 3, any[:])
	array := make([dynamic]u8)
	defer delete(array)
	ap.put_number(&array, 2, 10)
	ap.put_bytes(&array, 3, answer[:])
	body := make([dynamic]u8)
	defer delete(body)
	ap.put_bytes(&body, 2, array[:])

	arena: virtual.Arena
	if virtual.arena_init_growing(&arena) != nil {testing.fail_now(t, "arena")}
	defer virtual.arena_destroy(&arena)
	allocator := virtual.arena_allocator(&arena)
	rows, ok := parse_playlist_metadata(
		body[:],
		uris,
		allocator,
		[]i64{1726617600000, 0, 1726704000000},
	)
	if !testing.expect(t, ok && len(rows) == 2) {return}
	for i in 0 ..< len(body) {body[i] = 0}
	testing.expect_value(t, rows[0].name, "Example")
	testing.expect_value(t, rows[1].name, "Example")
	testing.expect_value(t, rows[0].duration_ms, 1000)
	testing.expect(t, rows[0].explicit && rows[1].explicit)
	testing.expect_value(t, rows[0].added_at, 1726617600000)
	testing.expect_value(t, rows[1].added_at, 1726704000000)
	_, ok = parse_playlist_metadata(nil, uris, allocator)
	testing.expect(t, !ok, "a missing metadata answer must not silently remove tracks")
}

@(test)
web_playlist_items_parse_track_objects :: proc(t: ^testing.T) {
	body := `{"total":2,"offset":0,"limit":50,"next":null,"items":[{"added_at":"2024-01-01T00:00:00Z","item":{"uri":"spotify:track:aaa","name":"Song A","explicit":true,"duration_ms":200000,"artists":[{"name":"Art A"}],"album":{"images":[{"url":"http://x","height":64,"width":64}]}}},{"added_at":null,"item":{"uri":"spotify:track:bbb","name":"Song B","duration_ms":180000,"artists":[{"name":"Art B"}],"album":{"images":[]}}}]}`
	arena: virtual.Arena
	if virtual.arena_init_growing(&arena) != nil {testing.fail_now(t, "arena")}
	defer virtual.arena_destroy(&arena)
	rows, total, next_offset, has_more, status, ok := parse_track_rows(
		Playlist_Item,
		transmute([]u8)body,
		virtual.arena_allocator(&arena),
	)
	if !testing.expect(
		t,
		ok && status == 200 && total == 2 && next_offset == 2 && !has_more,
	) {return}
	if !testing.expect(t, len(rows) == 2) {return}
	testing.expect_value(t, rows[0].uri, "spotify:track:aaa")
	testing.expect_value(t, rows[0].name, "Song A")
	testing.expect_value(t, rows[0].artists, "Art A")
	testing.expect(t, rows[0].explicit && !rows[1].explicit)
	testing.expect_value(t, rows[1].uri, "spotify:track:bbb")
	testing.expect_value(t, rows[0].added_at, 1704067200000)
	testing.expect_value(t, rows[1].added_at, 0)
}

@(test)
web_playlist_header_reads_track_total :: proc(t: ^testing.T) {
	body := `{"id":"x","name":"Noice","uri":"spotify:playlist:x","images":[],"owner":{"id":"hyper_puncher","display_name":"hyper_puncher"},"items":{"total":1512}}`
	header: Playlist_Ref
	if !testing.expect(
		t,
		json.unmarshal(transmute([]u8)body, &header, allocator = context.temp_allocator) == nil,
	) {return}
	testing.expect_value(t, header.items.total, 1512)
	testing.expect_value(t, header.owner.display_name, "hyper_puncher")
}

@(test)
internal_playlist_row_links_artists_and_albums :: proc(t: ^testing.T) {
	track_gid: [16]u8
	track_gid[15] = 1
	artist_gid: [16]u8
	artist_gid[15] = 2
	album_gid: [16]u8
	album_gid[15] = 3
	artist := make([dynamic]u8)
	defer delete(artist)
	ap.put_bytes(&artist, 1, artist_gid[:])
	ap.put_bytes(&artist, 2, transmute([]u8)string("Art A"))
	album := make([dynamic]u8)
	defer delete(album)
	ap.put_bytes(&album, 1, album_gid[:])
	ap.put_bytes(&album, 2, transmute([]u8)string("Album A"))
	track := make([dynamic]u8)
	defer delete(track)
	ap.put_bytes(&track, 1, track_gid[:])
	ap.put_bytes(&track, 2, transmute([]u8)string("Song A"))
	ap.put_bytes(&track, 4, artist[:])
	ap.put_bytes(&track, 3, album[:])
	ap.put_number(&track, 7, 2000)

	arena: virtual.Arena
	if virtual.arena_init_growing(&arena) != nil {testing.fail_now(t, "arena")}
	defer virtual.arena_destroy(&arena)
	row, ok := playlist_track_row(
		track[:],
		"spotify:track:0000000000000000000001",
		virtual.arena_allocator(&arena),
	)
	if !testing.expect(t, ok) {return}
	testing.expect_value(t, row.album, "Album A")
	testing.expect_value(t, row.album_uri, "spotify:album:0000000000000000000003")
	if !testing.expect(t, len(row.artist_links) == 1) {return}
	testing.expect_value(t, row.artist_links[0].name, "Art A")
	testing.expect_value(t, row.artist_links[0].uri, "spotify:artist:0000000000000000000002")
}
