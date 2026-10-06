package library

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
