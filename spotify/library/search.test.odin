package library

import "core:testing"

@(test)
search_results_split_into_four_relevance_pages :: proc(t: ^testing.T) {
	body: string = `{"tracks":{"items":[{"name":"Song","uri":"spotify:track:abc","duration_ms":1000,"artists":[{"name":"X"}],"album":{"images":[{"url":"https://i.scdn.co/image/c","width":300}]}}],"total":1,"offset":0},"albums":{"items":[{"name":"An Album","uri":"spotify:album:abc","artists":[{"name":"A"}],"total_tracks":9,"images":[{"url":"https://i.scdn.co/image/a","width":300}]}],"total":1,"offset":0},"artists":{"items":[{"name":"An Artist","id":"abc","uri":"spotify:artist:abc","images":[{"url":"https://i.scdn.co/image/artist","width":300}]}],"total":1,"offset":0},"playlists":{"items":[{"name":"My list","uri":"spotify:playlist:abc","owner":{"display_name":"igor"},"items":{"total":14},"images":[{"url":"https://i.scdn.co/image/mid","width":300}]}],"total":1,"offset":0}}`
	pages, ok := parse_search(transmute([]u8)body)
	defer free_search_pages(&pages)
	testing.expect(t, ok)
	for kind in Kind {
		testing.expect(t, pages[kind].ready && len(pages[kind].items) == 1)
		testing.expect(t, !pages[kind].has_more)
	}
	testing.expect(
		t,
		pages[.Tracks].items[0].name == "Song" && pages[.Tracks].items[0].subtitle == "X",
	)
	testing.expect(t, pages[.Tracks].items[0].uri == "spotify:track:abc")
	testing.expect(
		t,
		pages[.Albums].items[0].name == "An Album" && pages[.Albums].items[0].total == 9,
	)
	testing.expect(t, pages[.Artists].items[0].uri == "spotify:artist:abc")
	testing.expect(
		t,
		pages[.Playlists].items[0].name == "My list" &&
		pages[.Playlists].items[0].subtitle == "igor" &&
		pages[.Playlists].items[0].total == 14,
	)
}

@(test)
search_rejects_malformed_bodies :: proc(t: ^testing.T) {
	invalid: string = "not json"
	_, ok := parse_search(transmute([]u8)invalid)
	testing.expect(t, !ok)
	too_large: string = `{"tracks":{"items":[],"total":1000001,"offset":0},"albums":{"items":[],"total":0,"offset":0},"artists":{"items":[],"total":0,"offset":0},"playlists":{"items":[],"total":0,"offset":0}}`
	_, ok = parse_search(transmute([]u8)too_large)
	testing.expect(t, !ok)
}
