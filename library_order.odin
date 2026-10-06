// Library card ordering: the user's pins lead, then cards played most recently,
// then Spotify's own library order for everything else.
package main

import "core:fmt"
import "core:slice"
import library "spotify/library"

Rated_Entry :: struct {
	index:       int,
	pin_rank:    int,
	recent_rank: int,
}

sort_library_page :: proc(page: ^library.Page, settings: ^Settings) {
	if len(page.items) < 2 {return}
	rated := make([]Rated_Entry, len(page.items), context.temp_allocator)
	for entry, index in page.items {
		rated[index] = {
			index       = index,
			pin_rank    = settings_pin_rank(settings, entry.uri),
			recent_rank = settings_recent_rank(settings, entry.uri),
		}
	}
	slice.stable_sort_by(rated, proc(a, b: Rated_Entry) -> bool {
		if a.pin_rank != b.pin_rank {return a.pin_rank < b.pin_rank}
		return a.recent_rank < b.recent_rank
	})
	ordered := make([]library.Entry, len(page.items), context.temp_allocator)
	for entry, index in rated {ordered[index] = page.items[entry.index]}
	copy(page.items[:], ordered)
}

// Sorting only when a page grew (or the pins changed) keeps page merges cheap.
sort_library_pages :: proc(
	client: ^library.Client,
	settings: ^Settings,
	counts: ^[library.Kind]int,
	force: bool,
) {
	for kind in library.Kind {
		page := &client.pages[kind]
		if !force && len(page.items) == counts[kind] {continue}
		sort_library_page(page, settings)
		counts[kind] = len(page.items)
	}
}

// The grid URI for the open detail, or "" for Liked Songs.
detail_card_uri :: proc(detail: library.Detail) -> string {
	switch detail.source {
	case .Playlist:
		return fmt.aprintf("spotify:playlist:%s", detail.id, allocator = context.temp_allocator)
	case .Album:
		return fmt.aprintf("spotify:album:%s", detail.id, allocator = context.temp_allocator)
	case .Artist:
		return fmt.aprintf("spotify:artist:%s", detail.id, allocator = context.temp_allocator)
	case .Liked:
	}
	return ""
}

// Clicking the open collection is a no-op: reopening would tear down the
// loaded rows and refetch them for an identical page. A failed load stays
// retryable through the error flag.
detail_already_open :: proc(client: ^library.Client, uri: string) -> bool {
	return client.detail.ready && client.detail_error == 0 && detail_card_uri(client.detail) == uri
}
