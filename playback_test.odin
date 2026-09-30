package main

import "core:testing"
import library "spotify/library"

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
		{uri = "first"},
		{uri = "second"},
		{uri = "third"},
		{uri = "fourth"},
	}
	items: [dynamic]Play_Item
	build_play_queue(&items, rows)
	defer free_play_queue(&items)
	selected, cover: string
	defer {delete(selected); delete(cover)}
	index := 1
	testing.expect(t, select_play_item(items[:], index, &selected, &cover))
	testing.expect_value(t, selected, "second")
	for expected in ([]string{"third", "fourth"}) {
		testing.expect(t, advance_play_item(items[:], &index, 1, &selected, &cover))
		testing.expect_value(t, selected, expected)
	}
	testing.expect(t, !advance_play_item(items[:], &index, 1, &selected, &cover))
	testing.expect_value(t, index, 3)
	testing.expect_value(t, selected, "fourth")
	testing.expect(t, advance_play_item(items[:], &index, -1, &selected, &cover))
	testing.expect_value(t, selected, "third")
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
