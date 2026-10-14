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

// Pins always lead; the mode pass runs first so a second stable pass can
// lift them without a capturing comparator (nested procs cannot close over
// the sort mode).
sort_library_page :: proc(page: ^library.Page, kind: library.Kind, app_state: ^State) {
	if len(page.items) < 2 {return}
	rated := make([]Rated_Entry, len(page.items), context.temp_allocator)
	for entry, index in page.items {
		rated[index] = {
			index       = index,
			pin_rank    = state_rank(app_state.pinned, entry.uri),
			recent_rank = state_rank(app_state.recent, entry.uri),
		}
	}
	// The default order is Spotify's own, so only played needs a pass.
	if app_state.sort[kind] == .Played {slice.stable_sort_by(rated, less_played)}
	slice.stable_sort_by(rated, less_pin)
	ordered := make([]library.Entry, len(page.items), context.temp_allocator)
	for entry, index in rated {ordered[index] = page.items[entry.index]}
	copy(page.items[:], ordered)
}

less_pin :: proc(a, b: Rated_Entry) -> bool {
	return a.pin_rank < b.pin_rank
}

less_played :: proc(a, b: Rated_Entry) -> bool {
	return a.recent_rank < b.recent_rank
}

// Sorting only when a page changed keeps page merges cheap. A length check
// alone would miss a revalidation that replaces a page with the same count,
// silently dropping the pins, so any landed page forces a re-sort too.
sort_library_pages :: proc(
	client: ^library.Client,
	app_state: ^State,
	counts: ^[library.Kind]int,
	force: bool,
) {
	for kind in library.Kind {
		page := &client.pages[kind]
		if !force && !client.pages_dirty && len(page.items) == counts[kind] {continue}
		sort_library_page(page, kind, app_state)
		counts[kind] = len(page.items)
	}
	client.pages_dirty = false
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
	return(
		!client.release_feed.open &&
		client.detail.ready &&
		client.detail_error == 0 &&
		detail_card_uri(client.detail) == uri \
	)
}
