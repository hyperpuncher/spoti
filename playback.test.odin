package main

import "core:mem/virtual"
import "core:strings"
import "core:sync"
import "core:sync/chan"
import "core:testing"
import "core:thread"
import connect "spotify/connect"
import library "spotify/library"
import player "spotify/player"

@(test)
player_state_adopts_a_remote_device_only_without_local_playback :: proc(t: ^testing.T) {
	app := App {
		app_state = State{connect_device = "local"},
	}
	remote := library.Result {
		kind = .Player_State,
		ok = true,
		player = {device_id = "phone", playing = true},
	}
	app_library_result(&remote, &app)
	testing.expect(t, app.remote_control)

	// A failed poll must not send the next play click to the local player.
	failed := library.Result {
		kind   = .Player_State,
		status = 429,
	}
	app_library_result(&failed, &app)
	testing.expect(t, app.remote_control)

	local := library.Result {
		kind = .Player_State,
		ok = true,
		player = {device_id = "local"},
	}
	app_library_result(&local, &app)
	testing.expect(t, !app.remote_control)

	worker: thread.Thread
	app.worker = &worker
	app.stage = .Playing
	app.library_client.remote.device_id = "phone"
	app_library_result(&remote, &app)
	testing.expect(t, !app.remote_control)
	testing.expect_value(t, footer_active_device(&app), "local")
}

@(test)
accepted_connect_load_publishes_even_when_state_matches :: proc(t: ^testing.T) {
	worker: thread.Thread
	states, allocation := chan.create_buffered(chan.Chan(connect.Snapshot), 1, context.allocator)
	if !testing.expect(t, allocation == nil) {return}
	defer chan.destroy(states)
	app := App {
		worker = &worker,
		stage = .Paused,
		selected = "spotify:track:fixture",
		connect_client = {worker = &worker, states = states},
		connect_snapshot = {
			active = true,
			paused = true,
			uri = strings.clone("spotify:track:fixture"),
		},
	}
	defer connect.free_snapshot(&app.connect_snapshot)
	app_connect_publish(&app)
	unexpected, published := chan.try_recv(states)
	connect.free_snapshot(&unexpected)
	testing.expect(t, !published, "unchanged state should not publish without a new load")
	app.connect_load_pending = true
	app_connect_publish(&app)
	snapshot, got := chan.try_recv(states)
	if !testing.expect(t, got) {return}
	defer connect.free_snapshot(&snapshot)
	testing.expect(t, snapshot.active && snapshot.paused && snapshot.uri == app.selected)
	app_connect_publish(&app)
	unexpected, published = chan.try_recv(states)
	connect.free_snapshot(&unexpected)
	testing.expect(t, !published, "one accepted load must not publish the same state twice")
}

@(test)
connect_load_reuses_matching_artwork_without_changing_the_incoming_queue :: proc(t: ^testing.T) {
	app: App
	defer free_play_queue(&app.play_queue)
	detail := &app.library_client.detail
	detail.source, detail.id, detail.image = .Album, "album", "album-cover"
	detail.rows = make([dynamic]library.Track_Row, context.temp_allocator)
	append(&detail.rows, library.Track_Row{uri = "album-track", artists = "Album artist"})
	append(
		&app.play_queue,
		Play_Item{uri = strings.clone("previous"), cover = strings.clone("previous-cover")},
	)
	app.library_client.remote = {
		uri   = "remote-track",
		cover = "remote-cover",
	}

	uris := [?]string{"album-track", "unknown", "previous", "remote-track"}
	covers := [?]string{"album-cover", "", "previous-cover", "remote-cover"}
	load_connect_queue(&app, uris[:])
	if !testing.expect_value(t, len(app.play_queue), len(uris)) {return}
	for item, index in app.play_queue {
		testing.expect_value(t, item.uri, uris[index])
		testing.expect_value(t, item.cover, covers[index])
	}
	testing.expect_value(t, app.play_queue[0].artist, "Album artist")
}

@(test)
worker_cancellation_preserves_queued_packets :: proc(t: ^testing.T) {
	queue, err := chan.create_buffered(chan.Chan(player.Packet), 1, context.allocator)
	if !testing.expect(t, err == nil) {return}
	defer chan.destroy(queue)
	_ = chan.send(queue, player.Packet{kind = .End})
	cancel := false
	cancel_worker(queue, &cancel)
	cancel_worker(queue, &cancel)
	testing.expect(t, sync.atomic_load(&cancel) && chan.is_closed(queue))
	testing.expect(t, !chan.send(queue, player.Packet{kind = .Failed}))
	packet, received := chan.try_recv(queue)
	testing.expect(t, received && packet.kind == .End)
	_, received = chan.try_recv(queue)
	testing.expect(t, !received)
}

@(test)
resolved_track_source_is_reused_only_for_the_same_track_and_cleared :: proc(t: ^testing.T) {
	cache := Play_Source {
		track = strings.clone("first"),
	}
	cache.source.name = strings.clone("title")
	cache.source.storage = make([dynamic]u8)
	append(&cache.source.storage, ..([]u8{1, 2, 3}))
	cache.source.url = string(cache.source.storage[:])
	cache.source.key[0] = 42
	testing.expect(t, cached_play_source(&cache, "first") == &cache.source)
	testing.expect(t, cached_play_source(&cache, "second") == nil)
	clear_play_source(&cache)
	testing.expect(t, cached_play_source(&cache, "first") == nil)
	testing.expect(
		t,
		cache.track == "" && len(cache.source.storage) == 0 && cache.source.key[0] == 0,
	)
	clear_play_source(&cache)
}

@(test)
album_queue_retains_owned_artwork_for_every_track :: proc(t: ^testing.T) {
	fallback := "album-cover"
	rows := []library.Track_Row {
		{uri = "first"},
		{uri = "second"},
		{uri = "third", image = "large-cover"},
		{uri = "fourth", image = "large-cover", image_small = "small-cover"},
	}
	items: [dynamic]Play_Item
	build_play_queue(&items, rows, fallback)
	defer free_play_queue(&items)
	selected, cover: string
	defer {delete(selected); delete(cover)}
	for expected, index in ([]string{"album-cover", "album-cover", "large-cover", "small-cover"}) {
		testing.expect(t, select_play_item(items[:], index, &selected, &cover))
		testing.expect_value(t, cover, expected)
	}
}

@(test)
next_after_manual_selection_advances_and_stops_at_queue_end :: proc(t: ^testing.T) {
	rows := []library.Track_Row {
		{uri = "first", artists = "A"},
		{uri = "second", artists = "B"},
		{uri = "third", artists = "C"},
		{uri = "fourth", artists = "D"},
	}
	items: [dynamic]Play_Item
	build_play_queue(&items, rows)
	defer free_play_queue(&items)
	selected, cover: string
	defer {delete(selected); delete(cover)}
	index := 1
	testing.expect(t, select_play_item(items[:], index, &selected, &cover))
	testing.expect_value(t, selected, "second")
	testing.expect_value(t, items[index].artist, "B")
	for expected in ([]string{"third", "fourth"}) {
		testing.expect(t, advance_play_item(items[:], &index, 1, &selected, &cover))
		testing.expect_value(t, selected, expected)
	}
	testing.expect_value(t, items[index].artist, "D")
	testing.expect(t, !advance_play_item(items[:], &index, 1, &selected, &cover))
	testing.expect_value(t, index, 3)
	testing.expect_value(t, selected, "fourth")
	testing.expect(t, advance_play_item(items[:], &index, -1, &selected, &cover))
	testing.expect_value(t, selected, "third")
	testing.expect_value(t, items[index].artist, "C")
}

@(test)
shuffle_preserves_current_track_duplicates_and_original_order :: proc(t: ^testing.T) {
	rows := []library.Track_Row {
		{uri = "duplicate"},
		{uri = "second"},
		{uri = "duplicate"},
		{uri = "last"},
	}
	items: [dynamic]Play_Item
	build_play_queue(&items, rows)
	defer free_play_queue(&items)
	index := reorder_play_queue(items[:], 2, true)
	testing.expect_value(t, index, 0)
	testing.expect_value(t, items[index].order, 2)
	seen: [4]bool
	for item in items {
		testing.expect(t, item.order >= 0 && item.order < len(seen))
		testing.expect(t, !seen[item.order], "shuffle must neither duplicate nor lose queue items")
		seen[item.order] = true
	}
	index = reorder_play_queue(items[:], index, false)
	testing.expect_value(t, index, 2)
	for item, original in items {testing.expect_value(t, item.order, original)}
	testing.expect_value(t, reorder_play_queue(nil, -1, true), -1)
	index = reorder_play_queue(items[:1], 0, true)
	testing.expect_value(t, index, 0)
}

@(test)
manual_queue_additions_keep_fifo_priority_and_collection_paging :: proc(t: ^testing.T) {
	app := App {
		play_index = 0,
		stage      = .Playing,
		selected   = strings.clone("first"),
		queue_rows = 2,
	}
	build_play_queue(&app.play_queue, []library.Track_Row{{uri = "first"}, {uri = "second"}})
	defer {free_play_queue(&app.play_queue); delete(app.selected); delete(app.toast)}
	app_enqueue_track(&app, library.Track_Row{uri = "duplicate", name = "Queued one"})
	app_enqueue_track(&app, library.Track_Row{uri = "duplicate", name = "Queued two"})
	testing.expect_value(t, app.play_index, 0)
	testing.expect_value(t, app.selected, "first")
	testing.expect_value(t, app.stage, Stage.Playing)
	testing.expect_value(t, app.queue_rows, 2)
	testing.expect_value(t, app.play_queue[1].name, "Queued one")
	testing.expect_value(t, app.play_queue[2].name, "Queued two")
	app.play_index = reorder_play_queue(app.play_queue[:], app.play_index, true)
	testing.expect_value(t, app.play_queue[1].name, "Queued one")
	testing.expect_value(t, app.play_queue[2].name, "Queued two")
	app.play_index = reorder_play_queue(app.play_queue[:], app.play_index, false)
	append_play_queue_tail(&app.play_queue, []library.Track_Row{{uri = "third"}})
	testing.expect_value(t, app.play_queue[3].uri, "second")
	testing.expect_value(t, app.play_queue[4].uri, "third")
	testing.expect(
		t,
		discard_play_track(&app.play_queue, "duplicate", &app.play_index, &app.queue_rows),
	)
	testing.expect_value(t, app.queue_rows, 2)
	testing.expect_value(t, len(app.play_queue), 3)
}

@(test)
queued_album_keeps_artist_page_and_fifo_order :: proc(t: ^testing.T) {
	worker: thread.Thread
	app := App {
		play_index = 0,
		stage      = .Playing,
		selected   = strings.clone("current"),
	}
	client := &app.library_client
	client.state, client.worker = .Ready, &worker
	client.detail = {
		ready      = true,
		source     = .Artist,
		id         = "artist",
		generation = 7,
	}
	client.requests, _ = chan.create_buffered(chan.Chan(library.Request), 1, context.allocator)
	client.results, _ = chan.create_buffered(chan.Chan(library.Result), 1, context.allocator)
	defer {
		client.worker = nil
		library.stop(client)
		free_play_queue(&app.play_queue)
		delete(app.selected)
		delete(app.toast)
	}
	build_play_queue(&app.play_queue, []library.Track_Row{{uri = "current"}, {uri = "next"}})
	if !testing.expect(t, app_enqueue_uri(&app, "spotify:album:album")) {return}
	request, received := chan.try_recv(client.requests)
	if !testing.expect(t, received && request.kind == .Queue_Album) {return}
	result := library.Result {
		request = request,
		ok      = true,
	}
	if !testing.expect(
		t,
		virtual.arena_init_growing(&result.detail.arena) == nil,
	) {library.free_request(request); return}
	allocator := virtual.arena_allocator(&result.detail.arena)
	result.detail.source, result.detail.id, result.detail.name = .Album, "album", "Album"
	result.detail.rows = make([dynamic]library.Track_Row, 2, allocator)
	for &row, index in result.detail.rows {row = library.clone_row(library.Track_Row{uri = index == 0 ? "a" : "b", name = "Added track"}, allocator)}
	_ = chan.send(client.results, result)
	_ = library.poll(client, app_library_result, &app)
	testing.expect(
		t,
		client.detail.source == .Artist &&
		client.detail.id == "artist" &&
		client.detail.generation == 7,
	)
	if testing.expect_value(t, len(app.play_queue), 4) {
		testing.expect_value(t, app.play_queue[1].uri, "a")
		testing.expect_value(t, app.play_queue[1].name, "Added track")
		testing.expect_value(t, app.play_queue[1].album_uri, "spotify:album:album")
		testing.expect_value(t, app.play_queue[2].uri, "b")
		testing.expect_value(t, app.play_queue[3].uri, "next")
	}
	_ = chan.send(client.results, library.Result{kind = .Queue_Album, status = 403})
	_ = library.poll(client, app_library_result, &app)
	testing.expect_value(t, len(app.play_queue), 4)
	testing.expect_value(t, app.toast, "Couldn't add to queue")
}

@(test)
stamp_queue_album_fills_missing_links_without_freeing_temps :: proc(t: ^testing.T) {
	detail := library.Detail {
		source = .Album,
		id     = "abc",
		name   = "An Album",
	}
	items: [dynamic]Play_Item
	append(&items, Play_Item{uri = strings.clone("spotify:track:1")})
	append(&items, Play_Item{uri = strings.clone("spotify:track:2")})
	defer {
		for &item in items {
			delete(item.uri)
			delete(item.album)
			delete(item.album_uri)
		}
		delete(items)
	}
	// Freeing the temp scratch URI used to abort the process here.
	stamp_queue_album(&items, &detail)
	stamp_queue_album(&items, &detail)
	for item in items {
		testing.expect_value(t, item.album, "An Album")
		testing.expect_value(t, item.album_uri, "spotify:album:abc")
	}
}

@(test)
unavailable_queue_entries_are_removed_and_the_following_track_is_selected :: proc(t: ^testing.T) {
	rows := []library.Track_Row {
		{uri = "gone"},
		{uri = "good-one"},
		{uri = "gone"},
		{uri = "good-two"},
	}
	queue: [dynamic]Play_Item
	build_play_queue(&queue, rows)
	defer free_play_queue(&queue)
	index := 2
	testing.expect(t, discard_play_track(&queue, "gone", &index))
	testing.expect_value(t, len(queue), 2)
	testing.expect_value(t, index, 1)
	testing.expect_value(t, queue[index].uri, "good-two")
	testing.expect_value(t, queue[0].order, 1)
	testing.expect_value(t, queue[1].order, 3)
}

@(test)
unavailable_queue_ends_without_retrying_when_nothing_follows :: proc(t: ^testing.T) {
	queue: [dynamic]Play_Item
	build_play_queue(&queue, []library.Track_Row{{uri = "good"}, {uri = "gone"}})
	defer free_play_queue(&queue)
	index := 1
	testing.expect(t, !discard_play_track(&queue, "gone", &index))
	testing.expect_value(t, len(queue), 1)
	testing.expect_value(t, index, -1)
	index = 0
	testing.expect(t, !discard_play_track(&queue, "good", &index))
	testing.expect_value(t, len(queue), 0)
}

// A volume drag on a remote device sends the newest value at most once per
// REMOTE_VOLUME_NS, so it cannot exhaust the Web API rate limit.
@(test)
remote_volume_sends_only_the_newest_value_per_interval :: proc(t: ^testing.T) {
	worker: thread.Thread
	app := App {
		remote_control = true,
	}
	client := &app.library_client
	client.state, client.worker = .Ready, &worker
	client.requests, _ = chan.create_buffered(chan.Chan(library.Request), 8, context.allocator)
	client.results, _ = chan.create_buffered(chan.Chan(library.Result), 1, context.allocator)
	defer {client.worker = nil; library.stop(client)}
	sent :: proc(client: ^library.Client) -> (values: [dynamic]int) {
		for request in chan.try_recv(client.requests) {
			append(&values, request.command_value)
			library.free_request(request)
		}
		return
	}
	for value in ([]f32{0.2, 0.3, 0.4}) {
		app.volume, app.remote_volume_pending = value, true
		app_send_remote_volume(&app)
	}
	first := sent(client)
	defer delete(first)
	testing.expect_value(t, len(first), 1)
	if len(first) == 1 {testing.expect_value(t, first[0], 20)}
	testing.expect(t, app.remote_volume_pending)
	// Once the interval passes, only the newest value goes out.
	app.remote_volume_at = 0
	app_send_remote_volume(&app)
	second := sent(client)
	defer delete(second)
	testing.expect_value(t, len(second), 1)
	if len(second) == 1 {testing.expect_value(t, second[0], 40)}
	testing.expect(t, !app.remote_volume_pending)
}
