package main

import "core:strings"
import "core:sync"
import "core:sync/chan"
import "core:testing"
import library "spotify/library"
import player "spotify/player"

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
