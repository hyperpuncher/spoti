package main

import "core:sync/chan"
import "core:testing"
import "core:thread"
import library "spotify/library"

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
