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
