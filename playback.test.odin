package main

import "core:strings"
import "core:sync"
import "core:sync/chan"
import "core:testing"
import library "spotify/library"
import player "spotify/player"

@(test)
worker_cancellation_closes_once_and_preserves_queued_packets :: proc(t: ^testing.T) {
	queue, err := chan.create_buffered(chan.Chan(player.Packet), 1, context.allocator)
	if !testing.expect(t, err == nil) {return}
	defer chan.destroy(queue)
	_ = chan.send(queue, player.Packet{kind = .End})
	cancel, closed := false, false
	cancel_worker(queue, &cancel, &closed)
	cancel_worker(queue, &cancel, &closed)
	testing.expect(t, sync.atomic_load(&cancel) && closed)
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
seek_slider_maps_drag_positions_and_clamps_to_playable_time :: proc(t: ^testing.T) {
	testing.expect_value(t, seek_position_ms(250, 100, 300, 240000), 120000)
	testing.expect_value(t, seek_position_ms(-10, 100, 300, 240000), 0)
	testing.expect_value(t, seek_position_ms(500, 100, 300, 240000), 239999)
	testing.expect_value(t, seek_position_ms(250, 100, 0, 240000), 0)
	testing.expect_value(t, seek_position_ms(250, 100, 300, 0), 0)
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
	selected, cover, artist: string
	defer {delete(selected); delete(cover); delete(artist)}
	for expected, index in ([]string{"album-cover", "album-cover", "large-cover", "small-cover"}) {
		testing.expect(t, select_play_item(items[:], index, &selected, &cover, &artist))
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
	selected, cover, artist: string
	defer {delete(selected); delete(cover); delete(artist)}
	index := 1
	testing.expect(t, select_play_item(items[:], index, &selected, &cover, &artist))
	testing.expect_value(t, selected, "second")
	testing.expect_value(t, artist, "B")
	for expected in ([]string{"third", "fourth"}) {
		testing.expect(t, advance_play_item(items[:], &index, 1, &selected, &cover, &artist))
		testing.expect_value(t, selected, expected)
	}
	testing.expect_value(t, artist, "D")
	testing.expect(t, !advance_play_item(items[:], &index, 1, &selected, &cover, &artist))
	testing.expect_value(t, index, 3)
	testing.expect_value(t, selected, "fourth")
	testing.expect(t, advance_play_item(items[:], &index, -1, &selected, &cover, &artist))
	testing.expect_value(t, selected, "third")
	testing.expect_value(t, artist, "C")
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
