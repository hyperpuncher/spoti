package library

import ap "../ap"
import oauth "../oauth"
import "core:mem/virtual"
import "core:strings"
import "core:testing"
import "core:time"

@(test)
initial_session_list_reaches_the_library_without_freeing_its_account_early :: proc(t: ^testing.T) {
	get_account := proc(_: string, _: ^bool) -> string {return strings.clone("fixture")}
	fetch := proc(
		_: string,
		account: string,
		_: int,
		_: rawptr,
		_: bool,
	) -> (
		page: Page,
		status: int,
		ok: bool,
	) {
		if account != "fixture" {return}
		if virtual.arena_init_growing(&page.arena) != nil {return}
		allocator := virtual.arena_allocator(&page.arena)
		page.ready = true
		page.account = strings.clone(account, allocator)
		page.items = make([dynamic]Entry, 1, 1, allocator)
		page.items[0].name = strings.clone("Release Radar", allocator)
		return page, 200, true
	}
	client: Client
	defer stop(&client)
	tokens := oauth.Tokens {
		access     = "fixture",
		expires_at = time.time_add(time.now(), time.Hour),
	}
	page, status, ok := read_session_rootlist(
		&client,
		&tokens,
		{},
		get_account = get_account,
		fetch = fetch,
	)
	if !testing.expect(t, ok) {free_page(&page); return}
	apply(
		&client,
		Result {
			kind = .Index,
			list = .Playlists,
			page = page,
			ok = ok,
			status = status,
			refresh = true,
		},
	)
	testing.expect_value(t, client.pages[.Playlists].account, "fixture")
	testing.expect_value(t, client.pages[.Playlists].items[0].name, "Release Radar")

	// Later requests own their account string. The reader only borrows it.
	account := strings.clone("fixture")
	defer delete(account)
	later, _, later_ok := read_session_rootlist(
		&client,
		&tokens,
		{account = account},
		get_account = get_account,
		fetch = fetch,
	)
	defer free_page(&later)
	testing.expect(t, later_ok)
	testing.expect_value(t, account, "fixture")
}

@(test)
rootlist_keeps_spotify_playlists_and_counts_folder_positions :: proc(t: ^testing.T) {
	attributes := make([dynamic]u8)
	defer delete(attributes)
	ap.put_bytes(&attributes, 1, transmute([]u8)string("Release Radar"))
	meta := make([dynamic]u8)
	defer delete(meta)
	ap.put_bytes(&meta, 2, attributes[:])
	ap.put_number(&meta, 3, 200)
	ap.put_bytes(&meta, 5, transmute([]u8)string("spotify"))
	contents := make([dynamic]u8)
	defer delete(contents)
	ap.put_number(&contents, 1, 36)
	ap.put_number(&contents, 2, 1)
	for uri in ([]string{"spotify:start-group:fixture", "spotify:playlist:0000000000000000000001"}) {
		item := make([dynamic]u8)
		defer delete(item)
		ap.put_bytes(&item, 1, transmute([]u8)uri)
		ap.put_bytes(&contents, 3, item[:])
		ap.put_bytes(&contents, 4, meta[:])
	}
	body := make([dynamic]u8)
	defer delete(body)
	ap.put_number(&body, 2, 40)
	ap.put_bytes(&body, 5, contents[:])
	page, ok := parse_rootlist(body[:], "fixture", 36)
	defer free_page(&page)
	if !testing.expect(t, ok) {return}
	// The response can be released before the page is displayed.
	for &byte in body {byte = 0}
	if testing.expect_value(t, len(page.items), 1) {
		testing.expect_value(t, page.items[0].name, "Release Radar")
		testing.expect_value(t, page.items[0].total, 200)
		testing.expect(t, page.items[0].saved && page.items[0].image == "")
	}
	testing.expect_value(t, page.account, "fixture")
	testing.expect_value(t, page.next_offset, 38)
	testing.expect(t, page.has_more)
}

@(test)
rootlist_rejects_incomplete_decorations_and_wrong_windows :: proc(t: ^testing.T) {
	contents := make([dynamic]u8)
	defer delete(contents)
	ap.put_number(&contents, 1, 36)
	ap.put_number(&contents, 2, 1)
	ap.put_bytes(&contents, 3, []u8{0x0a, 1, 'x'})
	body := make([dynamic]u8)
	defer delete(body)
	ap.put_number(&body, 2, 40)
	ap.put_bytes(&body, 5, contents[:])
	_, ok := parse_rootlist(body[:], "fixture", 36)
	testing.expect(t, !ok, "a missing decoration must not silently hide a playlist")
	_, ok = parse_rootlist(body[:], "fixture", 0)
	testing.expect(t, !ok, "a different window must not be appended")
	_, ok = parse_rootlist(body[:len(body) - 1], "fixture", 36)
	testing.expect(t, !ok)
}

@(test)
playlist_banner_is_separate_from_cover_art :: proc(t: ^testing.T) {
	attributes, field: [dynamic]u8
	defer {delete(attributes); delete(field)}
	ap.put_bytes(&attributes, 1, transmute([]u8)string("Energy Booster Rock"))
	ap.put_bytes(&field, 1, transmute([]u8)string("header_image_url_desktop"))
	ap.put_bytes(&field, 2, transmute([]u8)string("https://i.scdn.co/image/banner"))
	ap.put_bytes(&attributes, 12, field[:])
	ref, ok := playlist_attributes(attributes[:])
	testing.expect(t, ok)
	testing.expect_value(t, ref.banner, "https://i.scdn.co/image/banner")
	testing.expect_value(t, len(ref.images), 0)
}
