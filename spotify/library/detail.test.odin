package library

import "core:strings"
import "core:testing"

@(test)
track_page_addresses_request_only_row_fields :: proc(t: ^testing.T) {
	address, ok := track_page_address(.Playlist, "abc", 50)
	testing.expect(t, ok)
	defer delete(address)
	testing.expect(
		t,
		strings.has_suffix(
			address,
			"playlists/abc/items?limit=50&offset=50&fields=total,offset,next,items(added_at,item(uri,name,duration_ms,artists(name),album(images)))",
		),
	)
	liked, liked_ok := track_page_address(.Liked, "", 0)
	testing.expect(t, liked_ok)
	defer delete(liked)
	testing.expect(t, strings.contains(liked, "me/tracks?limit=50&offset=0&fields="))
	album, album_ok := track_page_address(.Album, "def", 0)
	testing.expect(t, album_ok)
	defer delete(album)
	testing.expect(
		t,
		strings.has_suffix(
			album,
			"albums/def/tracks?limit=50&offset=0&fields=total,offset,next,items(uri,name,duration_ms,artists(name))",
		),
	)
	_, artist_ok := track_page_address(.Artist, "ghi", 0)
	testing.expect(t, !artist_ok)
}

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
