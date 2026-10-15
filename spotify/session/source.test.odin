package session

import ap "../ap"
import track "../track"
import "core:testing"

@(test)
resolve_cache_returns_stored_tracks_and_clears :: proc(t: ^testing.T) {
	defer clear_resolve_cache()
	id: [16]u8
	id[0] = 11
	_, found := resolve_cache_lookup(id)
	testing.expect(t, !found, "empty cache misses")
	source := Source {
		name        = "Cached Track",
		format      = .Vorbis_320,
		duration_ms = 180_000,
	}
	source.file_id[0] = 12
	source.key[0] = 13
	resolve_cache_store(id, &source)
	cancel := true
	failed, opened := open(.None, &cancel, track.base62_id(id, context.temp_allocator))
	defer close_source(&failed)
	testing.expect(t, !opened && failed.name == "", "failed opens must not return freed ownership")
	entry, ok := resolve_cache_lookup(id)
	testing.expect(t, ok, "stored track hits")
	if !ok {return}
	defer delete(entry.name)
	testing.expect(t, entry.file_id == source.file_id)
	testing.expect(t, entry.key == source.key)
	testing.expect(t, entry.format == source.format)
	testing.expect_value(t, entry.duration_ms, source.duration_ms)
	testing.expect_value(t, entry.name, source.name)
	// Overwriting frees the previous name; the tracker would flag a leak.
	other := source
	other.name = "Renamed Track"
	resolve_cache_store(id, &other)
	renamed, still := resolve_cache_lookup(id)
	testing.expect(t, still)
	defer delete(renamed.name)
	testing.expect_value(t, renamed.name, "Renamed Track")
	mark_track_unavailable(id)
	blocked, known := resolve_cache_lookup(id)
	defer delete(blocked.name)
	testing.expect(t, known && blocked.unavailable)
	testing.expect(t, blocked.key == {} && blocked.file_id == {})
	testing.expect(t, track_unavailable(track.base62_id(id, context.temp_allocator)))
	clear_resolve_cache()
	_, gone := resolve_cache_lookup(id)
	testing.expect(t, !gone, "cleared cache misses")
}

availability_extension :: proc(kind, status: u64, payload: []u8) -> [dynamic]u8 {
	header, entity, any, array, body: [dynamic]u8
	defer {delete(header); delete(entity); delete(any); delete(array)}
	ap.put_number(&header, 1, status)
	ap.put_bytes(&entity, 1, header[:])
	ap.put_bytes(&any, 2, payload)
	ap.put_bytes(&entity, 3, any[:])
	ap.put_number(&array, 2, kind)
	ap.put_bytes(&array, 3, entity[:])
	ap.put_bytes(&body, 2, array[:])
	return body
}

@(test)
only_catalogue_refusals_are_reported_as_unavailable :: proc(t: ^testing.T) {
	for status in ([]u64{404, 451, 500, 200}) {
		body := availability_extension(ap.TRACK_V4, status, nil)
		defer delete(body)
		unavailable := false
		_, ok := parse_track_response(body[:], {}, &unavailable)
		testing.expect(t, !ok)
		testing.expect_value(t, unavailable, status == 404 || status == 451)
	}
}

@(test)
empty_audio_files_are_unavailable_but_missing_extensions_are_not :: proc(t: ^testing.T) {
	id: [16]u8
	id[15] = 1
	message: [dynamic]u8
	defer delete(message)
	ap.put_bytes(&message, 1, id[:])
	ap.put_bytes(&message, 2, transmute([]u8)string("Removed track"))
	ap.put_number(&message, 7, 180_000 * 2)
	body := availability_extension(ap.TRACK_V4, 200, message[:])
	defer delete(body)
	unavailable := false
	_, ok := parse_track_response(body[:], id, &unavailable)
	testing.expect(t, !ok && !unavailable)
	files := availability_extension(ap.AUDIO_FILES, 200, nil)
	defer delete(files)
	append(&body, ..files[:])
	_, ok = parse_track_response(body[:], id, &unavailable)
	testing.expect(t, !ok && unavailable)
	append(&message, 0x5a, 2, 0x12, 0) // restriction.countries_allowed = ""
	restricted := availability_extension(ap.TRACK_V4, 200, message[:])
	defer delete(restricted)
	_, ok = parse_track_response(restricted[:], id, &unavailable)
	testing.expect(t, !ok && unavailable)
}
