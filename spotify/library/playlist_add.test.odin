package library

import "base:runtime"
import "core:fmt"
import "core:strings"
import "core:testing"

Playlist_Add_Fixture :: struct {
	total:                        int,
	reads, writes:                int,
	fail_read, fail_second_write: bool,
	added:                        [dynamic]string,
}

playlist_add_fetch :: proc(
	access: string,
	source: Source,
	id: string,
	offset: int,
	allocator: runtime.Allocator,
	session_access: string = "",
	reuse: rawptr = nil,
	cache_only: bool = false,
	refresh: bool = false,
) -> (
	rows: [dynamic]Track_Row,
	total, next: int,
	more: bool,
	status: int,
	ok: bool,
) {
	fixture := (^Playlist_Add_Fixture)(reuse)
	fixture.reads += 1
	if fixture.fail_read {return nil, 0, 0, false, 403, false}
	count := min(50, fixture.total - offset)
	rows = make([dynamic]Track_Row, count, allocator)
	for &row, index in rows {row.uri = fmt.aprintf("spotify:track:%022d", offset + index, allocator = allocator)}
	return rows, fixture.total, offset + count, offset + count < fixture.total, 200, true
}

playlist_add_write :: proc(
	access, playlist_id: string,
	uris: []string,
	reuse: rawptr = nil,
	remove: bool = false,
) -> (
	status: int,
	ok: bool,
) {
	fixture := (^Playlist_Add_Fixture)(reuse)
	if remove {return 400, false}
	fixture.writes += 1
	if fixture.fail_second_write && fixture.writes == 2 {return 429, false}
	for uri in uris {append(&fixture.added, strings.clone(uri))}
	return 201, true
}

@(test)
playlist_add_resolves_full_albums_and_reports_partial_writes :: proc(t: ^testing.T) {
	for partial in ([]bool{false, true}) {
		fixture := Playlist_Add_Fixture {
			total             = 130,
			fail_second_write = partial,
		}
		defer {for uri in fixture.added {delete(uri)}; delete(fixture.added)}
		status, ok, count := add_playlist_entry(
			"",
			"playlist",
			"spotify:album:AAAAAAAAAAAAAAAAAAAAAA",
			&fixture,
			fetch = playlist_add_fetch,
			write = playlist_add_write,
		)
		testing.expect_value(t, fixture.reads, 3)
		testing.expect_value(t, fixture.writes, 2)
		testing.expect_value(t, count, partial ? 100 : 130)
		testing.expect_value(t, len(fixture.added), count)
		testing.expect_value(t, ok, !partial)
		testing.expect_value(t, status, partial ? 429 : 201)
		for uri, index in fixture.added {
			testing.expect_value(
				t,
				uri,
				fmt.aprintf("spotify:track:%022d", index, allocator = context.temp_allocator),
			)
		}
	}
	fixture := Playlist_Add_Fixture {
		total     = 1,
		fail_read = true,
	}
	status, ok, count := add_playlist_entry(
		"",
		"playlist",
		"spotify:album:AAAAAAAAAAAAAAAAAAAAAA",
		&fixture,
		fetch = playlist_add_fetch,
		write = playlist_add_write,
	)
	testing.expect(t, status == 403 && !ok && count == 0 && fixture.writes == 0)
	// A track uses the same add path, with no album lookup.
	status, ok, count = add_playlist_entry(
		"",
		"playlist",
		"spotify:track:AAAAAAAAAAAAAAAAAAAAAA",
		&fixture,
		fetch = playlist_add_fetch,
		write = playlist_add_write,
	)
	defer {for uri in fixture.added {delete(uri)}; delete(fixture.added)}
	testing.expect(t, status == 201 && ok && count == 1 && fixture.reads == 1)
	client: Client
	defer delete(client.stale_playlist)
	defer delete(client.write_name)
	apply(
		&client,
		Result {
			kind = .Add_To_Playlist,
			ok = false,
			status = 429,
			total = 100,
			playlist_id = strings.clone("playlist"),
			playlist_name = strings.clone("Name"),
		},
	)
	testing.expect(t, !client.write_ok && client.write_partial)
	testing.expect_value(t, client.stale_playlist, "playlist")
}
