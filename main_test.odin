package main

import "base:runtime"
import "core:math"
import "core:sync/chan"
import "core:testing"
import "core:thread"
import library "spotify/library"
import clay "vendor/clay"

layout_test_measure :: proc "c" (
	text: clay.StringSlice,
	config: ^clay.TextElementConfig,
	user_data: rawptr,
) -> clay.Dimensions {
	d := (^f32)(user_data)^
	return {f32(text.length) * f32(config.fontSize) * 0.5 * d, f32(config.fontSize) * d}
}

layout_test_error :: proc "c" (error: clay.ErrorData) {
	context = runtime.default_context()
	counter := (^int)(error.userData)
	counter^ += 1
}

@(test)
large_library_grid_layout_is_bounded :: proc(t: ^testing.T) {
	memory := make([]u8, int(clay.MinMemorySize()))
	defer delete(memory)
	errors := 0
	clay.Initialize(
		clay.CreateArenaWithCapacityAndMemory(uint(len(memory)), &memory[0]),
		{1280, 820},
		{handler = layout_test_error, userData = &errors},
	)
	density: f32 = 1
	clay.SetMeasureTextFunction(layout_test_measure, &density)

	client: library.Client
	client.pages[.Albums].items = make([dynamic]library.Entry, 3000)
	defer delete(client.pages[.Albums].items)
	for &entry in client.pages[.Albums].items {
		entry.name = "Album title"
		entry.subtitle = "Artist name"
	}
	client.detail.ready = true
	client.detail.name = "Album"
	client.detail.label = "Album"
	client.detail.has_more = true
	client.detail.rows = make([dynamic]library.Track_Row, 3000)
	defer delete(client.detail.rows)
	for &row in client.detail.rows {
		row.name = "Track title"
		row.artists = "Artist"
		row.duration_ms = 180_000
	}
	client.detail.releases = make([dynamic]library.Entry, 3000)
	defer delete(client.detail.releases)
	for &release in client.detail.releases {
		release.name = "Release"
		release.subtitle = "2026"
	}
	textures: Textures
	defer {
		delete(textures.by_key)
		delete(textures.requested)
	}
	for d in ([]f32{1, 1.5}) {
		density = d
		clay.ResetMeasureTextCache()
		clay.SetLayoutDimensions({1280 * d, 820 * d})
		for width in ([]f32{SIDEBAR_MIN, SIDEBAR_MAX}) {
			for source in ([]library.Source{.Album, .Artist}) {
				client.detail.source = source
				// Allow dimensions from the previous layout to settle after resizing.
				for _ in 0 ..< 2 {
					clay.UpdateScrollContainers(false, {}, 0)
					_, _ = layout(
						{},
						&client,
						.Albums,
						&textures,
						width,
						1280 * d,
						820 * d,
						26 * d,
						0,
						d,
					)
				}
				for fraction in ([]f32{0, 0.5, 1}) {
					clay.UpdateScrollContainers(false, {}, 0)
					for id in ([]string{"library_grid", "detail_rows"}) {
						scroll := clay.GetScrollContainerData(clay.ID(id))
						scroll.scrollPosition.y =
							fraction *
							min(
								0,
								scroll.scrollContainerDimensions.height -
								scroll.contentDimensions.height,
							)
					}
					commands, visible := layout(
						{},
						&client,
						.Albums,
						&textures,
						width,
						1280 * d,
						820 * d,
						26 * d,
						0,
						d,
					)
					testing.expect_value(t, errors, 0)
					testing.expect(
						t,
						commands.length < 1000,
						"layout work must be bounded by the viewport",
					)
					testing.expect(t, visible.cards.last - visible.cards.first < 40)
					if fraction > 0 {testing.expect(t, visible.cards.first > 0)}
					if fraction == 1 {testing.expect_value(t, visible.cards.last, 3000)}
					grid := clay.GetScrollContainerData(clay.ID("library_grid"))
					usable := width * d - 36 * d
					columns := clamp(int(usable / (140 * d)), 2, 4)
					expected :=
						f32((3000 + columns - 1) / columns) *
						card_row_height(usable / f32(columns), 26 * d, d)
					testing.expect(
						t,
						math.abs(grid.contentDimensions.height - expected) < 0.5,
						"spacers must preserve the complete grid height",
					)
					if source == .Album {
						rows := clay.GetScrollContainerData(clay.ID("detail_rows"))
						expected_rows :=
							36 * d + 3000 * (44 * d + f32(u16(2 * d))) + 38 * d + f32(u16(2 * d))
						testing.expect(
							t,
							math.abs(rows.contentDimensions.height - expected_rows) < 0.5,
							"track spacers must preserve row gaps and the load-more button",
						)
						if fraction == 1 {testing.expect_value(t, visible.tracks.last, 3000)}
					} else if fraction == 1 {
						testing.expect_value(t, visible.releases.last, 3000)
					}
				}
			}
		}
	}
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
		requested = make(map[u64]bool),
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
	// Already-requested covers must not be queued every frame.
	ensure_covers(&client, &textures, .Albums, "player", visible)
	testing.expect_value(t, client.covers_pending, 2)
}

@(test)
visible_items_preserve_partial_rows_and_overscan :: proc(t: ^testing.T) {
	start := visible_items(2995, 4, 200, 0, 450)
	testing.expect_value(t, start.first, 0)
	testing.expect_value(t, start.last, 16)
	testing.expect_value(t, start.before + 4 * 200 + start.after, f32(749 * 200))
	middle := visible_items(2995, 4, 200, 10_050, 450)
	testing.expect_value(t, middle.first, 196)
	testing.expect_value(t, middle.last, 216)
	testing.expect_value(t, middle.before + 5 * 200 + middle.after, f32(749 * 200))
	end := visible_items(2995, 4, 200, 1e6, 450)
	testing.expect_value(t, end.last, 2995)
	testing.expect_value(t, end.after, f32(0))
	short := visible_items(3, 4, 200, -100, 450)
	testing.expect_value(t, short.first, 0)
	testing.expect_value(t, short.last, 3)
	testing.expect_value(t, visible_items(0, 4, 200, 0, 450), Visible_Items{})
}
