// Library card ordering: the user's pins lead, then cards played most recently,
// then Spotify's own library order for everything else.
package main

import "core:fmt"
import "core:slice"
import "core:strings"
import library "spotify/library"

Rated_Entry :: struct {
	index:       int,
	pin_rank:    int,
	recent_rank: int,
}

// One stable pass orders pins, then optional play history. Equal ranks
// keep Spotify's existing order.
sort_library_page :: proc(page: ^library.Page, kind: library.Kind, app_state: ^State) {
	if len(page.items) < 2 {return}
	rated := make([]Rated_Entry, len(page.items), context.temp_allocator)
	for entry, index in page.items {
		rated[index] = {
			index       = index,
			pin_rank    = state_rank(app_state.pinned, entry.uri),
			recent_rank = app_state.sort[kind] == .Played ? state_rank(app_state.recent, entry.uri) : max(int),
		}
	}
	slice.stable_sort_by(rated, proc(a, b: Rated_Entry) -> bool {
		if a.pin_rank != b.pin_rank {return a.pin_rank < b.pin_rank}
		return a.recent_rank < b.recent_rank
	})
	indices := make([]int, len(rated), context.temp_allocator)
	for entry, index in rated {indices[index] = entry.index}
	slice.sort_from_permutation_indices(page.items[:], indices)
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
		if !force && !client.pages_dirty[kind] && len(page.items) == counts[kind] {continue}
		sort_library_page(page, kind, app_state)
		counts[kind] = len(page.items)
	}
	client.pages_dirty = {}
}

// Compare a detail page with its grid URI without building a temporary URI.
detail_matches_uri :: proc(detail: library.Detail, uri: string) -> bool {
	switch detail.source {
	case .Playlist:
		prefix := "spotify:playlist:"
		return strings.has_prefix(uri, prefix) && uri[len(prefix):] == detail.id
	case .Album:
		prefix := "spotify:album:"
		return strings.has_prefix(uri, prefix) && uri[len(prefix):] == detail.id
	case .Artist:
		prefix := "spotify:artist:"
		return strings.has_prefix(uri, prefix) && uri[len(prefix):] == detail.id
	case .Liked:
		return uri == ""
	}
	return false
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
		client.detail.albums.error == 0 &&
		client.detail.singles.error == 0 &&
		detail_matches_uri(client.detail, uri) \
	)
}
