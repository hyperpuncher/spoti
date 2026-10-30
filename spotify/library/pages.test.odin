package library

import "core:mem/virtual"
import "core:testing"

@(test)
playlist_and_album_cards_keep_cover_and_metadata :: proc(t: ^testing.T) {
	playlists: string = `{"items":[{"name":"My list","uri":"spotify:playlist:abc","owner":{"display_name":"igor"},"items":{"total":14},"images":[{"url":"https://i.scdn.co/image/big","width":640},{"url":"https://i.scdn.co/image/mid","width":300}]},null,{"name":"broken","uri":"https://example.com/"}],"offset":0,"total":14,"next":"https://api.spotify.com/v1/me/playlists?offset=10"}`
	playlist_page, playlist_ok := parse_index(transmute([]u8)playlists, .Playlists)
	defer free_page(&playlist_page)
	testing.expect(t, playlist_ok && len(playlist_page.items) == 1)
	testing.expect(
		t,
		playlist_page.items[0].name == "My list" && playlist_page.items[0].subtitle == "igor",
	)
	testing.expect(t, playlist_page.items[0].image == "https://i.scdn.co/image/mid")
	testing.expect(
		t,
		playlist_page.items[0].total == 14 &&
		playlist_page.has_more &&
		playlist_page.next_offset == 3,
	)

	albums: string = `{"items":[{"album":{"name":"An Album","uri":"spotify:album:abc","artists":[{"name":"A"},{"name":"B"}],"total_tracks":9,"images":[{"url":"https://i.scdn.co/image/a","width":300}]}}],"offset":0,"total":1}`
	album_page, album_ok := parse_index(transmute([]u8)albums, .Albums)
	defer free_page(&album_page)
	testing.expect(t, album_ok && len(album_page.items) == 1)
	testing.expect(
		t,
		album_page.items[0].name == "An Album" && album_page.items[0].subtitle == "A, B",
	)
	testing.expect(t, album_page.items[0].total == 9 && !album_page.has_more)
}

@(test)
cover_selection_uses_card_and_hero_sizes :: proc(t: ^testing.T) {
	images := []Image {
		{url = "https://i.scdn.co/image/large", width = 640},
		{url = "https://i.scdn.co/image/card", width = 300},
		{url = "http://invalid/image", width = 1200},
	}
	testing.expect(t, cover_url(images) == "https://i.scdn.co/image/card")
	testing.expect(t, cover_url(images, .Smallest) == "https://i.scdn.co/image/card")
	testing.expect(t, cover_url(images, .Largest) == "https://i.scdn.co/image/large")
	images = []Image {
		{url = "https://i.scdn.co/image/unknown"},
		{url = "https://i.scdn.co/image/small", width = 32},
	}
	for size in Cover_Size {testing.expect_value(t, cover_url(images, size), "https://i.scdn.co/image/small")}
}

@(test)
artist_window_uses_its_own_cursor :: proc(t: ^testing.T) {
	artists: string = `{"artists":{"items":[{"name":"An Artist","id":"abc","uri":"spotify:artist:abc","images":[{"url":"https://i.scdn.co/image/artist","width":300}]}],"total":42,"next":"next","cursors":{"after":"abc"}}}`
	page, ok := parse_index(transmute([]u8)artists, .Artists)
	defer free_page(&page)
	testing.expect(t, ok && len(page.items) == 1 && page.cursor == "abc" && page.has_more)
	testing.expect(t, page.items[0].uri == "spotify:artist:abc")
	testing.expect(t, page.items[0].image == "https://i.scdn.co/image/artist")
}

@(test)
saved_tracks_use_current_shapes :: proc(t: ^testing.T) {
	arena: virtual.Arena
	if virtual.arena_init_growing(&arena) != nil {
		testing.fail_now(t, "arena")
	}
	defer virtual.arena_destroy(&arena)
	allocator := virtual.arena_allocator(&arena)

	saved: string = `{"items":[{"track":{"name":"Song","uri":"spotify:track:1TifAMm1r1MascYZ5xGiQk","duration_ms":1000,"artists":[{"name":"X"}],"album":{"images":[{"url":"https://i.scdn.co/image/c","width":300}]}}}],"offset":0,"total":1}`
	saved_rows, saved_total, saved_next, saved_more, saved_status, saved_ok := parse_track_rows(
		Saved_Track,
		transmute([]u8)saved,
		allocator,
	)
	testing.expect(
		t,
		saved_ok && saved_status == 200 && saved_total == 1 && !saved_more && saved_next == 1,
	)
	testing.expect(
		t,
		len(saved_rows) == 1 &&
		saved_rows[0].name == "Song" &&
		saved_rows[0].artists == "X" &&
		saved_rows[0].duration_ms == 1000,
	)
}

@(test)
artist_discography_uses_current_album_page :: proc(t: ^testing.T) {
	arena: virtual.Arena
	if virtual.arena_init_growing(&arena) != nil {
		testing.fail_now(t, "arena")
	}
	defer virtual.arena_destroy(&arena)

	body: string = `{"items":[{"name":"A Release","uri":"spotify:album:abc","release_date":"2026-09-12","total_tracks":6,"album_type":"single","images":[{"url":"https://i.scdn.co/image/release","width":300}]}],"offset":0,"total":11,"next":"next"}`
	releases, total, next, more, status, ok := parse_artist_albums(
		transmute([]u8)body,
		virtual.arena_allocator(&arena),
	)
	testing.expect(t, ok && status == 200 && total == 11 && next == 1 && more)
	testing.expect(
		t,
		len(releases) == 1 &&
		releases[0].name == "A Release" &&
		releases[0].uri == "spotify:album:abc" &&
		releases[0].subtitle == "2026 • EP" &&
		releases[0].total == 6,
	)
}

@(test)
album_tracks_decode_without_album_art :: proc(t: ^testing.T) {
	arena: virtual.Arena
	if virtual.arena_init_growing(&arena) != nil {
		testing.fail_now(t, "arena")
	}
	defer virtual.arena_destroy(&arena)

	album: string = `{"items":[{"name":"Song","uri":"spotify:track:1TifAMm1r1MascYZ5xGiQk","duration_ms":1000,"explicit":true,"artists":[{"name":"Y"}]}],"offset":0,"total":1}`
	rows, total, next, more, status, ok := parse_track_rows(
		Track_Ref,
		transmute([]u8)album,
		virtual.arena_allocator(&arena),
	)
	testing.expect(t, ok && status == 200 && total == 1 && !more && next == 1)
	testing.expect(
		t,
		len(rows) == 1 &&
		rows[0].artists == "Y" &&
		rows[0].explicit &&
		rows[0].duration_ms == 1000 &&
		rows[0].image == "",
	)
}

@(test)
malformed_and_unsafe_responses_are_rejected :: proc(t: ^testing.T) {
	too_large: string = `{"items":[],"total":1000001}`
	_, ok := parse_index(transmute([]u8)too_large, .Tracks)
	testing.expect(t, !ok)
	invalid: string = "not json"
	_, ok = parse_index(transmute([]u8)invalid, .Playlists)
	testing.expect(t, !ok)
	arena: virtual.Arena
	if virtual.arena_init_growing(&arena) != nil {testing.fail_now(t, "arena")}
	defer virtual.arena_destroy(&arena)
	allocator := virtual.arena_allocator(&arena)
	negative_offset := `{"items":[],"total":0,"offset":-1}`
	_, _, _, _, _, valid := parse_track_rows(Track_Ref, transmute([]u8)negative_offset, allocator)
	testing.expect(t, !valid)
	_, _, _, _, _, valid = parse_track_rows(
		Playlist_Item,
		transmute([]u8)negative_offset,
		allocator,
	)
	testing.expect(t, !valid)
	testing.expect(t, safe_id("abcdef0123456789"))
	testing.expect(t, !safe_id("../../etc/passwd"))
	testing.expect(t, !safe_id("a b"))
}
