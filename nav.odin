// Back/forward history for library navigation: the active tab, the search
// query, and the open collection page. Entries own their strings; the live
// view is the entry at index, and recording a navigation drops anything
// that used to be ahead of it.
package main

import "core:strings"
import library "spotify/library"

NAV_LIMIT :: 64

Nav_State :: struct {
	filter:        library.Kind,
	searching:     bool,
	search_kind:   library.Kind,
	input:         string, // owned search text
	detail:        library.Entry, // owned preview; uri is empty when no page is open
	detail_scroll: f32, // detail_rows y offset, restored on back/forward
	releases:      bool,
}

Nav :: struct {
	states: [dynamic]Nav_State,
	index:  int, // live entry; invalid when states is empty
}

nav_capture :: proc(
	client: ^library.Client,
	filter: library.Kind,
	searching: bool,
	search_kind: library.Kind,
	input: string,
) -> Nav_State {
	state := Nav_State {
		filter      = filter,
		searching   = searching,
		search_kind = search_kind,
		input       = strings.clone(input),
		releases    = client.release_feed.open,
	}
	detail := client.detail
	if detail.ready {
		state.detail = library.clone_detail_entry(
			detail,
			detail_card_uri(detail),
			context.allocator,
		)
	}
	return state
}

nav_free_state :: proc(state: Nav_State) {
	delete(state.input)
	delete(state.detail.name)
	delete(state.detail.uri)
	delete(state.detail.image)
	delete(state.detail.subtitle)
	delete(state.detail.year)
}

nav_drop_forward :: proc(nav: ^Nav) {
	for len(nav.states) > nav.index + 1 {
		nav_free_state(pop(&nav.states))
	}
}

// Records the live detail scroll into the entry being left, so back and
// forward return to the same row instead of the top. The caller passes the
// queried offset; quarantining the Clay read keeps this unit-testable.
nav_save_scroll :: proc(nav: ^Nav, y: f32) {
	if nav.index < 0 || nav.index >= len(nav.states) {return}
	nav.states[nav.index].detail_scroll = y
}

// Records the state after a navigation.
nav_commit :: proc(nav: ^Nav, state: Nav_State) {
	nav_drop_forward(nav)
	append(&nav.states, state)
	nav.index = len(nav.states) - 1
	if len(nav.states) > NAV_LIMIT {
		nav_free_state(nav.states[0])
		copy(nav.states[:], nav.states[1:])
		pop(&nav.states)
		nav.index -= 1
	}
}

// Refining the current page (typing a query) rewrites its entry instead of
// stacking a new one; anything ahead is still dropped.
nav_replace :: proc(nav: ^Nav, state: Nav_State) {
	if nav.index < 0 || nav.index >= len(nav.states) {
		nav_commit(nav, state)
		return
	}
	nav_drop_forward(nav)
	nav_free_state(nav.states[nav.index])
	nav.states[nav.index] = state
}

nav_record_search :: proc(
	nav: ^Nav,
	client: ^library.Client,
	filter: library.Kind,
	search_kind: library.Kind,
	input: string,
) {
	state := nav_capture(client, filter, true, search_kind, input)
	if nav.index >= 0 && nav.index < len(nav.states) && nav.states[nav.index].searching {
		nav_replace(nav, state)
	} else {
		nav_commit(nav, state)
	}
}

nav_can_back :: proc(nav: ^Nav) -> bool {
	return nav.index > 0
}

nav_can_forward :: proc(nav: ^Nav) -> bool {
	return nav.index + 1 < len(nav.states)
}

nav_back :: proc(nav: ^Nav) -> (state: Nav_State, moved: bool) {
	nav_can_back(nav) or_return
	nav.index -= 1
	return nav.states[nav.index], true
}

nav_forward :: proc(nav: ^Nav) -> (state: Nav_State, moved: bool) {
	nav_can_forward(nav) or_return
	nav.index += 1
	return nav.states[nav.index], true
}

// Applies a history entry to the live view, re-fetching what is no longer in
// memory: a search that was cleared, or a collection page that was left.
nav_restore :: proc(
	state: Nav_State,
	client: ^library.Client,
	app_state: ^State,
	state_dirty: ^bool,
	filter: ^library.Kind,
	search_mode: ^bool,
	search_kind: ^library.Kind,
	input: ^string,
	detail_pinned: ^bool,
) {
	delete(input^)
	input^ = strings.clone(state.input)
	filter^ = state.filter
	if app_state.tab != state.filter {
		app_state.tab = state.filter
		state_dirty^ = true
	}
	if state.searching {
		search_kind^ = state.search_kind
		search_mode^ = true
		if client.search_query != state.input {library.search(client, state.input)}
	} else if search_mode^ {
		library.clear_search(client)
		search_mode^ = false
	}
	if state.releases {library.open_releases(client); return}
	client.release_feed.open = false
	uri := state.detail.uri
	detail_pinned^ = len(uri) > 0 && state_is_pinned(app_state, uri)
	if len(uri) == 0 {
		if client.detail.ready {library.clear_detail(client)}
	} else if !detail_matches_uri(client.detail, uri) {
		if source, id, valid := parse_card_uri(uri); valid {
			_ = library.open_detail(client, source, id, state.detail)
		}
	}
}

nav_free_all :: proc(nav: ^Nav) {
	for state in nav.states {nav_free_state(state)}
	delete(nav.states)
	nav^ = {}
}
