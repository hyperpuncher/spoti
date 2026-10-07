package main

import "core:fmt"
import "core:strings"
import "core:testing"
import library "spotify/library"

nav_state :: proc(name: string) -> Nav_State {
	return Nav_State{input = strings.clone(name)}
}

@(test)
nav_walks_back_and_forward_and_drops_stale_forward_history :: proc(t: ^testing.T) {
	nav: Nav
	defer nav_free_all(&nav)
	testing.expect(t, !nav_can_back(&nav) && !nav_can_forward(&nav))

	nav_commit(&nav, nav_state("a"))
	nav_commit(&nav, nav_state("b"))
	nav_commit(&nav, nav_state("c"))
	testing.expect(t, nav_can_back(&nav) && !nav_can_forward(&nav))

	state, ok := nav_back(&nav)
	testing.expect(t, ok && state.input == "b")
	state, ok = nav_back(&nav)
	testing.expect(t, ok && state.input == "a")
	testing.expect(t, !nav_can_back(&nav) && nav_can_forward(&nav))
	_, ok = nav_back(&nav)
	testing.expect(t, !ok)

	state, ok = nav_forward(&nav)
	testing.expect(t, ok && state.input == "b")
	state, ok = nav_forward(&nav)
	testing.expect(t, ok && state.input == "c")
	_, ok = nav_forward(&nav)
	testing.expect(t, !ok)

	// Navigating from the middle discards what was ahead.
	_, _ = nav_back(&nav)
	nav_commit(&nav, nav_state("d"))
	testing.expect(t, !nav_can_forward(&nav))
	testing.expect_value(t, len(nav.states), 3)
	testing.expect_value(t, nav.states[nav.index].input, "d")
}

@(test)
nav_replace_rewrites_the_current_entry :: proc(t: ^testing.T) {
	nav: Nav
	client: library.Client
	defer nav_free_all(&nav)
	nav_commit(&nav, nav_state("tab"))
	nav_record_search(&nav, &client, .Playlists, .Albums, "ra")
	nav_record_search(&nav, &client, .Playlists, .Albums, "radio")
	testing.expect_value(t, len(nav.states), 2)
	testing.expect_value(t, nav.states[nav.index].input, "radio")
	// A search started from a non-search page is a navigation; refining a
	// page that is already searching rewrites it and drops forward history.
	_, _ = nav_back(&nav)
	nav_record_search(&nav, &client, .Playlists, .Albums, "jazz")
	nav_record_search(&nav, &client, .Playlists, .Albums, "jazz live")
	testing.expect(t, !nav_can_forward(&nav))
	testing.expect_value(t, len(nav.states), 2)
	testing.expect_value(t, nav.states[nav.index].input, "jazz live")
	testing.expect(t, nav.states[nav.index].searching)
}

@(test)
nav_bounds_history_and_clones_captured_strings :: proc(t: ^testing.T) {
	nav: Nav
	defer nav_free_all(&nav)
	for index in 0 ..< NAV_LIMIT + 4 {
		nav_commit(&nav, nav_state(fmt.aprintf("state-%d", index)))
	}
	testing.expect_value(t, len(nav.states), NAV_LIMIT)
	testing.expect_value(t, nav.index, NAV_LIMIT - 1)

	// Capture copies the live strings and cover URL, so the detail's own
	// copies can be released afterwards without dangling.
	client: library.Client
	source := strings.clone("album")
	client.detail.ready = true
	client.detail.source = .Album
	client.detail.id = strings.clone("id")
	client.detail.name = source
	client.detail.image = strings.clone("https://i.scdn.co/image/cover")
	client.detail.subtitle = strings.clone("Artist")
	client.detail.total = 9
	defer {
		delete(client.detail.id)
		delete(client.detail.image)
		delete(client.detail.subtitle)
	}
	state := nav_capture(&client, .Albums, true, .Tracks, "query")
	defer nav_free_state(state)
	delete(source)
	testing.expect_value(t, state.detail.name, "album")
	testing.expect_value(t, state.detail.uri, "spotify:album:id")
	testing.expect_value(t, state.detail.total, 9)
	testing.expect_value(t, state.input, "query")
	testing.expect(t, state.searching && state.search_kind == .Tracks)
	testing.expect_value(t, state.filter, library.Kind.Albums)
}

@(test)
nav_saves_and_restores_detail_scroll :: proc(t: ^testing.T) {
	nav: Nav
	defer nav_free_all(&nav)
	nav_save_scroll(&nav, -500)
	nav_commit(&nav, nav_state("playlist"))
	nav_save_scroll(&nav, -1497)
	nav_commit(&nav, nav_state("artist"))
	_, _ = nav_back(&nav)
	testing.expect_value(t, nav.states[nav.index].detail_scroll, -1497)
	// Leaving again banks the live offset into the entry left behind.
	nav_save_scroll(&nav, -200)
	state, _ := nav_forward(&nav)
	testing.expect_value(t, state.detail_scroll, 0)
	testing.expect_value(t, nav.states[nav.index - 1].detail_scroll, -200)
}
