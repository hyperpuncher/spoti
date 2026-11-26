// Library card ordering: the user's pins lead, then cards played most recently,
// then save dates when available and Spotify's order as a fallback.
package main

import "core:slice"
import "core:strings"
import library "spotify/library"

Rated_Entry :: struct {
	index:       int,
	pin_rank:    int,
	recent_rank: int,
	source_rank: int,
	added_at:    i64,
}

// Order pins first, then optional play history. Break ties with the
// save date and original order, not the order left behind by the previous sort.
sort_library_page :: proc(page: ^library.Page, kind: library.Kind, app_state: ^State) {
	if len(page.items) < 2 {return}
	rated := make([]Rated_Entry, len(page.items), context.temp_allocator)
	for entry, index in page.items {
		rated[index] = {
			index       = index,
			pin_rank    = state_rank(app_state.pinned, entry.uri),
			source_rank = entry.library_order,
			added_at    = entry.added_at,
			recent_rank = app_state.sort[kind] == .Played ? state_rank(app_state.recent, entry.uri) : max(int),
		}
	}
	less :: proc(a, b: Rated_Entry) -> bool {
		if a.pin_rank != b.pin_rank {return a.pin_rank < b.pin_rank}
		if a.recent_rank != b.recent_rank {return a.recent_rank < b.recent_rank}
		if a.added_at != b.added_at {return a.added_at > b.added_at}
		return a.source_rank < b.source_rank
	}
	if slice.is_sorted_by(rated, less) {return}
	slice.stable_sort_by(rated, less)
	indices := make([]int, len(rated), context.temp_allocator)
	for entry, index in rated {indices[index] = entry.index}
	slice.sort_from_permutation_indices(page.items[:], indices)
}

// A local sort change can affect all tabs. A page update only affects its tab.
sort_library_pages :: proc(client: ^library.Client, app_state: ^State, force: bool) {
	for kind in library.Kind {
		if force ||
		   client.pages_dirty[kind] {sort_library_page(&client.pages[kind], kind, app_state)}
	}
	client.pages_dirty = {}
}

// Compare a detail page with its grid URI without building a temporary URI.
detail_matches_uri :: proc(detail: library.Detail, uri: string) -> bool {
	if detail.source == .Liked {return uri == ""}
	return library.uri_is(uri, detail.source, detail.id)
}

// The grid URI for the open detail, or "" for Liked Songs.
detail_card_uri :: proc(detail: library.Detail) -> string {
	if detail.source == .Liked {return ""}
	return strings.concatenate(
		{library.SOURCE_URI_PREFIX[detail.source], detail.id},
		context.temp_allocator,
	)
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
