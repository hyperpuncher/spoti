package session

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
	clear_resolve_cache()
	_, gone := resolve_cache_lookup(id)
	testing.expect(t, !gone, "cleared cache misses")
}
