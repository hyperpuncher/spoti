package main

import "core:mem/virtual"
import "core:sync/chan"
import "core:testing"
import "core:thread"
import "core:time"
import library "spotify/library"
import clay "vendor/clay"
import sdl "vendor:sdl3"

@(test)
release_feed_layout_keeps_big_covers_and_bounded_rows :: proc(t: ^testing.T) {
	errors := 0
	density: f32 = 1
	memory := layout_test_init(&density, &errors, {1280, 820})
	defer {clay.SetCurrentContext(nil); delete(memory)}
	client := library.Client {
		state = .Ready,
	}
	client.release_feed.open = true
	client.release_feed.done = true
	client.detail = {
		ready = true,
		has_more = true,
		source = .Artist,
		albums = {has_more = true},
	}
	testing.expect(t, !detail_needs_more(&client, {}))
	client.release_feed.items = make([dynamic]library.New_Release, 3000)
	defer delete(client.release_feed.items)
	for &release in client.release_feed.items {
		release.entry = {
			name     = "Release",
			uri      = "spotify:album:AAAAAAAAAAAAAAAAAAAAAA",
			subtitle = "Artist",
			image    = "https://i.scdn.co/image/test",
		}
		release.kind = "Single"
		release.released_at = time.time_add(time.now(), -2 * 24 * time.Hour)
	}
	textures := Textures {
		by_key = make(map[u64]^sdl.Texture),
	}
	defer delete(textures.by_key)
	fake: sdl.Texture
	textures.by_key[cover_key(client.release_feed.items[0].entry.image)] = &fake
	app_state: State
	anims := make(map[string]Button_Fx)
	defer delete(anims)
	fx := Button_Fx_Ctx {
		anims = &anims,
	}
	for scale in ([]f32{1, 1.5, 2}) {
		density = scale
		clay.ResetMeasureTextCache()
		for _ in 0 ..< 2 {
			_, _ = layout(
				{releases = true},
				&client,
				&app_state,
				.Playlists,
				&textures,
				&fx,
				360,
				1280 * scale,
				820 * scale,
				26 * scale,
				0,
				scale,
				nil,
			)
		}
		for bottom in ([]bool{false, true}) {
			data := clay.GetScrollContainerData(clay.ID("detail_rows"))
			data.scrollPosition.y =
				bottom ? min(0, data.scrollContainerDimensions.height - data.contentDimensions.height) : 0
			commands, visible := layout(
				{releases = true},
				&client,
				&app_state,
				.Playlists,
				&textures,
				&fx,
				360,
				1280 * scale,
				820 * scale,
				26 * scale,
				0,
				scale,
				nil,
			)
			testing.expect(t, visible.feed.last - visible.feed.first < 12)
			testing.expect(t, commands.length < 500)
			testing.expect(t, !clay.GetElementData(clay.ID("hero_play")).found)
			found_cover, found_age := false, false
			for command in commands.internalArray[:commands.length] {
				if command.commandType == .Text {
					text := command.renderData.text
					if string(text.stringContents.chars[:text.stringContents.length]) ==
					   "2 days ago" {
						found_age = true
						testing.expect_value(t, text.fontId, u16(0))
					}
				}
				if command.commandType == .Image &&
				   u64(uintptr(command.renderData.image.imageData)) ==
					   cover_key(client.release_feed.items[0].entry.image) {
					found_cover = true
					testing.expect_value(
						t,
						command.boundingBox.width,
						f32(FEED_COVER_SIZE) * scale,
					)
					testing.expect_value(t, command.boundingBox.height, command.boundingBox.width)
				}
			}
			testing.expect(t, found_cover && found_age)
			clip := clay.GetElementData(clay.ID("detail_rows")).boundingBox
			menu_opened := false
			for index in visible.feed.first ..< visible.feed.last {
				row := clay.GetElementData(clay.ID("feed_row", u32(index))).boundingBox
				point := sdl.FPoint{row.x + 10 * scale, row.y + row.height / 2}
				if point.y < clip.y || point.y >= clip.y + clip.height {continue}
				menu: Context_Menu
				open_menu_at(
					&menu,
					&client,
					&client.pages[.Playlists],
					.Playlists,
					visible,
					point,
					&app_state,
				)
				testing.expect(t, menu.open && menu.track == -1)
				testing.expect_value(t, menu.uri, client.release_feed.items[index].entry.uri)
				testing.expect_value(t, menu.count, 5)
				testing.expect_value(
					t,
					menu.items,
					[MENU_ITEMS_MAX]Menu_Item {
						.Play,
						.Save_Album,
						.Add_To_Playlist,
						.Copy_Link,
						.Open_In_Spotify,
					},
				)
				free_context_menu(&menu)
				menu_opened = true
				break
			}
			testing.expect(t, menu_opened)
			if bottom {testing.expect_value(t, visible.feed.last, 3000)}
		}
	}
	testing.expect_value(t, errors, 0)
}

@(test)
release_feed_is_a_separate_navigation_entry :: proc(t: ^testing.T) {
	client := library.Client {
		state = .Ready,
	}
	client.release_feed.done = true
	client.release_feed.open = true
	captured := nav_capture(&client, .Artists, false, .Artists, "")
	defer nav_free_state(captured)
	testing.expect(t, captured.releases)
	client.release_feed.open = false
	app_state := default_state()
	dirty, searching, pinned := false, false, false
	filter, search_kind := library.Kind.Artists, library.Kind.Artists
	input: string
	defer delete(input)
	nav_restore(
		captured,
		&client,
		&app_state,
		&dirty,
		&filter,
		&searching,
		&search_kind,
		&input,
		&pinned,
	)
	testing.expect(t, client.release_feed.open)
	nav_restore(
		{filter = .Artists},
		&client,
		&app_state,
		&dirty,
		&filter,
		&searching,
		&search_kind,
		&input,
		&pinned,
	)
	testing.expect(t, !client.release_feed.open)
}

@(test)
release_age_labels_use_minutes_hours_and_days :: proc(t: ^testing.T) {
	now := time.unix(1791979200, 0)
	cases := []struct {
		age:   time.Duration,
		label: string,
	} {
		{-time.Minute, "just now"},
		{59 * time.Second, "just now"},
		{time.Minute, "1 minute ago"},
		{59 * time.Minute, "59 minutes ago"},
		{time.Hour, "1 hour ago"},
		{8 * time.Hour, "8 hours ago"},
		{23 * time.Hour, "23 hours ago"},
		{24 * time.Hour, "1 day ago"},
		{48 * time.Hour, "2 days ago"},
		{7 * 24 * time.Hour, "7 days ago"},
	}
	for item in cases {
		testing.expect_value(t, release_age_label(time.time_add(now, -item.age), now), item.label)
	}
}

@(test)
release_play_loads_rows_without_leaving_the_feed :: proc(t: ^testing.T) {
	fake_worker: thread.Thread
	client := library.Client {
		state  = .Ready,
		worker = &fake_worker,
	}
	client.release_feed.open = true
	client.requests, _ = chan.create_buffered(chan.Chan(library.Request), 4, context.allocator)
	defer chan.destroy(client.requests)
	defer library.free_detail(&client.detail)
	defer library.free_detail(&client.prev_detail)
	defer delete(client.detail_request_id)
	entry := library.Entry {
		name = "Release",
		uri  = "spotify:album:AAAAAAAAAAAAAAAAAAAAAA",
	}
	if !testing.expect(t, release_feed_load_playback(&client, entry)) {return}
	testing.expect(t, client.release_feed.open)
	testing.expect_value(t, client.detail.source, library.Source.Album)
	request, received := chan.try_recv(client.requests)
	if !testing.expect(t, received) {return}
	defer library.free_request(request)
	testing.expect_value(t, request.source, library.Source.Album)
	testing.expect_value(t, request.id, "AAAAAAAAAAAAAAAAAAAAAA")
	client.detail.rows = make(
		[dynamic]library.Track_Row,
		1,
		virtual.arena_allocator(&client.detail.arena),
	)
	client.detail.rows[0].uri = "spotify:track:BBBBBBBBBBBBBBBBBBBBBB"
	testing.expect(t, detail_rows_ready(&client))
	testing.expect(t, !detail_play_enabled(&client), "the hidden hero must stay inactive")
	queue: [dynamic]Play_Item
	defer free_play_queue(&queue)
	queue_detail_rows(&queue, &client.detail)
	testing.expect_value(t, len(queue), 1)
	testing.expect_value(t, queue[0].uri, client.detail.rows[0].uri)
	testing.expect(t, client.release_feed.open)
}
