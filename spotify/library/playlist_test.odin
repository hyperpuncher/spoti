package library

import ap "../ap"
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
	ap.put_bytes(&contents, 3, item[:])
	ap.put_bytes(&contents, 3, item[:])
	body := make([dynamic]u8)
	defer delete(body)
	ap.put_number(&body, 2, 52)
	ap.put_bytes(&body, 5, contents[:])
	window, ok := parse_playlist_window(body[:], 50)
	testing.expect(t, ok && window.total == 52 && window.next_offset == 52)
	testing.expect_value(t, len(window.uris), 2)
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
	rows, ok := parse_playlist_metadata(body[:], uris, allocator)
	if !testing.expect(t, ok && len(rows) == 2) {return}
	for i in 0 ..< len(body) {body[i] = 0}
	testing.expect_value(t, rows[0].name, "Example")
	testing.expect_value(t, rows[1].name, "Example")
	testing.expect_value(t, rows[0].duration_ms, 1000)
	_, ok = parse_playlist_metadata(nil, uris, allocator)
	testing.expect(t, !ok, "a missing metadata answer must not silently remove tracks")
}
