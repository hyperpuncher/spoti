package library

import "core:mem/virtual"
import "core:strings"
import "core:testing"

@(test)
library_membership_addresses_use_unified_endpoints :: proc(t: ^testing.T) {
	check := saved_check_url(.Album, "abc")
	defer delete(check)
	testing.expect_value(
		t,
		check,
		"https://api.spotify.com/v1/me/library/contains?uris=spotify%3Aalbum%3Aabc",
	)
	artist := saved_check_url(.Artist, "def")
	defer delete(artist)
	testing.expect(t, strings.has_suffix(artist, "contains?uris=spotify%3Aartist%3Adef"))
	testing.expect_value(t, saved_check_url(.Liked, "abc"), "")
	testing.expect_value(t, saved_check_url(.Album, ""), "")
	testing.expect_value(t, saved_check_url(.Album, "not an id!"), "")

	target := like_url("spotify:playlist:abc")
	defer delete(target)
	testing.expect_value(
		t,
		target,
		"https://api.spotify.com/v1/me/library?uris=spotify%3Aplaylist%3Aabc",
	)
	testing.expect_value(t, like_url(""), "")
}

@(test)
add_items_body_builds_bounded_spotify_uris :: proc(t: ^testing.T) {
	body, ok := add_items_body([]string{"spotify:track:one"})
	testing.expect(t, ok)
	testing.expect_value(t, body, `{"uris":["spotify:track:one"]}`)

	many, many_ok := add_items_body([]string{"spotify:track:one", "spotify:track:two"})
	testing.expect(t, many_ok)
	testing.expect_value(t, many, `{"uris":["spotify:track:one","spotify:track:two"]}`)

	_, empty := add_items_body(nil)
	testing.expect(t, !empty)
	_, quoted := add_items_body([]string{`spotify:track:a"b`})
	testing.expect(t, !quoted)
	_, slashed := add_items_body([]string{`spotify:track:a\b`})
	testing.expect(t, !slashed)
	_, blank := add_items_body([]string{""})
	testing.expect(t, !blank)

	over := make([]string, ADD_ITEMS_MAX + 1, context.temp_allocator)
	for &uri in over {uri = "spotify:track:x"}
	_, too_many := add_items_body(over)
	testing.expect(t, !too_many)
}

remove_items_body_wraps_uris_in_items :: proc(t: ^testing.T) {
	body, ok := remove_items_body([]string{"spotify:track:one", "spotify:track:two"})
	testing.expect(t, ok)
	testing.expect_value(
		t,
		body,
		`{"items":[{"uri":"spotify:track:one"},{"uri":"spotify:track:two"}]}`,
	)

	_, empty := remove_items_body(nil)
	testing.expect(t, !empty)
	_, quoted := remove_items_body([]string{`spotify:track:a"b`})
	testing.expect(t, !quoted)
}

@(test)
unplayable_rows_are_hidden_without_changing_server_pagination :: proc(t: ^testing.T) {
	body := `{"total":4,"offset":50,"next":"next","items":[{"track":{"uri":"spotify:track:available","name":"Available","is_playable":true}},{"track":{"uri":"spotify:track:gone","name":"Gone","is_playable":false}},{"track":{"uri":"spotify:track:unknown","name":"Unknown"}},{"track":{"uri":"spotify:track:null","name":"Null","is_playable":null}}]}`
	arena: virtual.Arena
	if !testing.expect(t, virtual.arena_init_growing(&arena) == nil) {return}
	defer virtual.arena_destroy(&arena)
	rows, total, next, more, _, ok := parse_saved_tracks(
		transmute([]u8)body,
		virtual.arena_allocator(&arena),
	)
	if !testing.expect(t, ok) {return}
	testing.expect_value(t, len(rows), 3)
	testing.expect_value(t, rows[0].name, "Available")
	testing.expect_value(t, rows[1].name, "Unknown")
	testing.expect_value(t, rows[2].name, "Null")
	testing.expect_value(t, total, 4)
	testing.expect_value(t, next, 54)
	testing.expect(t, more)
}
