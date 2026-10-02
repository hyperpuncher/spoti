package main

import "core:sync/chan"
import "core:testing"
import "core:thread"
import library "spotify/library"
import sdl "vendor:sdl3"

@(test)
artwork_budget_preserves_player_card_and_detail_priority :: proc(t: ^testing.T) {
	requests, err := chan.create_buffered(chan.Chan(library.Cover_Request), 16, context.allocator)
	if !testing.expect(t, err == nil) {return}
	defer {
		for request in chan.try_recv(requests) {delete(request.url)}
		chan.destroy(requests)
	}
	fake_worker: thread.Thread
	client := library.Client {
		state          = .Ready,
		cover_worker   = &fake_worker,
		cover_requests = requests,
	}
	client.pages[.Albums].items = make([dynamic]library.Entry)
	defer delete(client.pages[.Albums].items)
	append(
		&client.pages[.Albums].items,
		library.Entry{image = "player"},
		library.Entry{image = "card"},
	)
	client.detail.ready = true
	client.detail.image = "hero"
	client.detail.image_preview = "preview"
	client.detail.image_small = "small"
	client.detail.rows = make([dynamic]library.Track_Row)
	defer delete(client.detail.rows)
	append(&client.detail.rows, library.Track_Row{image = "row", image_small = "row-small"})
	client.detail.releases = make([dynamic]library.Entry)
	defer delete(client.detail.releases)
	append(&client.detail.releases, library.Entry{image = "release"})
	textures := Textures {
		requested = make(map[u64]Cover_Request_State),
	}
	defer delete(textures.requested)
	visible := Frame_Visible {
		cards = {last = 2},
		tracks = {last = 1},
		releases = {last = 1},
	}
	for batch in ([][4]string{{"player", "card", "hero", "preview"}, {"small", "row", "row-small", "release"}}) {
		ensure_covers(&client, &textures, .Albums, "player", visible)
		for expected in batch {
			request, received := chan.try_recv(requests)
			testing.expect(t, received)
			testing.expect_value(t, request.url, expected)
			delete(request.url)
		}
		_, extra := chan.try_recv(requests)
		testing.expect(t, !extra, "each frame must queue at most four distinct covers")
	}
	ensure_covers(&client, &textures, .Albums, "player", visible)
	_, received := chan.try_recv(requests)
	testing.expect(t, !received, "pending requests must not be duplicated")
}

@(test)
cover_requests_follow_visible_cards_and_player :: proc(t: ^testing.T) {
	requests, err := chan.create_buffered(chan.Chan(library.Cover_Request), 4, context.allocator)
	if err != nil {testing.fail_now(t, "channel")}
	defer chan.destroy(requests)
	fake_worker: thread.Thread
	client := library.Client {
		state          = .Ready,
		cover_worker   = &fake_worker,
		cover_requests = requests,
	}
	client.pages[.Albums].items = make([dynamic]library.Entry, 3)
	defer delete(client.pages[.Albums].items)
	client.pages[.Albums].items[0].image = "offscreen-before"
	client.pages[.Albums].items[1].image = "visible"
	client.pages[.Albums].items[2].image = "offscreen-after"
	textures := Textures {
		requested = make(map[u64]Cover_Request_State),
	}
	defer delete(textures.requested)
	visible := Frame_Visible {
		cards = {first = 1, last = 2},
	}
	ensure_covers(&client, &textures, .Albums, "player", visible)
	testing.expect_value(t, client.covers_pending, 2)
	for expected in ([]string{"player", "visible"}) {
		request, received := chan.try_recv(requests)
		testing.expect(t, received)
		testing.expect_value(t, request.url, expected)
		delete(request.url)
	}
	testing.expect(t, cover_key("offscreen-before") not_in textures.requested)
	testing.expect(t, cover_key("offscreen-after") not_in textures.requested)
	ensure_covers(&client, &textures, .Albums, "player", visible)
	testing.expect_value(t, client.covers_pending, 2)
	key := cover_key("visible")
	state := textures.requested[key]
	state.pending = false
	textures.requested[key] = state
	ensure_covers(&client, &textures, .Albums, "player", visible)
	request, received := chan.try_recv(requests)
	testing.expect(t, received)
	testing.expect_value(t, request.url, "visible")
	delete(request.url)
	testing.expect_value(t, textures.requested[key].attempts, u8(2))
	state = textures.requested[key]
	state.pending = false
	textures.requested[key] = state
	ensure_covers(&client, &textures, .Albums, "player", visible)
	_, received = chan.try_recv(requests)
	testing.expect(t, !received, "exhausted failures must not loop forever")
	retry_failed_covers(&textures)
	ensure_covers(&client, &textures, .Albums, "player", visible)
	request, received = chan.try_recv(requests)
	testing.expect(t, received)
	testing.expect_value(t, request.url, "visible")
	delete(request.url)
	testing.expect(
		t,
		textures.requested[cover_key("player")].pending,
		"reselecting must not duplicate pending downloads",
	)
}

@(test)
player_cover_remains_until_the_replacement_texture_is_ready :: proc(t: ^testing.T) {
	textures := Textures {
		by_key = make(map[u64]^sdl.Texture),
	}
	defer delete(textures.by_key)
	fake: sdl.Texture
	textures.by_key[cover_key("first")] = &fake
	displayed: string
	defer delete(displayed)
	retain_player_cover(&displayed, "first", &textures)
	testing.expect_value(t, displayed, "first")
	retain_player_cover(&displayed, "next", &textures)
	testing.expect_value(t, displayed, "first")
	textures.by_key[cover_key("next")] = &fake
	retain_player_cover(&displayed, "next", &textures)
	testing.expect_value(t, displayed, "next")
}
