package main

import "base:runtime"
import "core:math"
import "core:sync/chan"
import "core:testing"
import "core:thread"
import library "spotify/library"
import ui "ui"
import clay "vendor/clay"
import sdl "vendor:sdl3"

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

// Caller-owned pointers stay valid until the test releases Clay's arena.
layout_test_init :: proc(density: ^f32, errors: ^int, dimensions: clay.Dimensions) -> []u8 {
	memory := make([]u8, int(clay.MinMemorySize()))
	clay.Initialize(
		clay.CreateArenaWithCapacityAndMemory(uint(len(memory)), raw_data(memory)),
		dimensions,
		{handler = layout_test_error, userData = errors},
	)
	clay.SetMeasureTextFunction(layout_test_measure, density)
	return memory
}

@(test)
large_library_grid_layout_is_bounded :: proc(t: ^testing.T) {
	errors := 0
	density: f32 = 1
	memory := layout_test_init(&density, &errors, {1280, 820})
	defer {clay.SetCurrentContext(nil); delete(memory)}

	client: library.Client
	client.pages[.Albums].items = make([dynamic]library.Entry, 3000)
	defer delete(client.pages[.Albums].items)
	for &entry in client.pages[.Albums].items {
		entry.name = "Album title"
		entry.subtitle = "Artist name"
	}
	client.pages[.Albums].items[0].uri = "spotify:album:selected"
	client.detail.id = "selected"
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
	client.detail.albums.items = make([dynamic]library.Entry, 3000)
	defer delete(client.detail.albums.items)
	for &release in client.detail.albums.items {
		release.name = "Release"
		release.subtitle = "2026"
	}
	client.detail.albums.total = 3000
	client.detail.albums.has_more = true
	client.detail.singles.items = make([dynamic]library.Entry, 3000)
	defer delete(client.detail.singles.items)
	for &release in client.detail.singles.items {
		release.name = "Single"
		release.subtitle = "2026"
	}
	client.detail.singles.total = 3000
	client.detail.singles.has_more = true
	textures := Textures {
		by_key = make(map[u64]^sdl.Texture),
	}
	// A software texture exercises banner layout without a window or desktop.
	surface := sdl.CreateSurface(14, 6, .RGBA32)
	if !testing.expect(t, surface != nil) {return}
	defer sdl.DestroySurface(surface)
	renderer := sdl.CreateSoftwareRenderer(surface)
	if !testing.expect(t, renderer != nil) {return}
	defer sdl.DestroyRenderer(renderer)
	fade_state := ui.State {
		renderer = renderer,
	}
	load_fades(&fade_state, &textures)
	for key in ([]u64{textures.fade_top, textures.fade_bottom, textures.hero_fade, textures.fade_detail_top, textures.fade_detail_bottom}) {
		texture := textures.by_key[key]
		if !testing.expect(t, key != 0 && texture != nil) {continue}
		r, g, b: u8
		testing.expect(t, sdl.GetTextureColorMod(texture, &r, &g, &b))
		color := key == textures.fade_top || key == textures.fade_bottom ? theme.sidebar : theme.bg
		testing.expect(t, r == u8(color.r) && g == u8(color.g) && b == u8(color.b))
	}
	banner_texture := sdl.CreateTextureFromSurface(renderer, surface)
	if !testing.expect(t, banner_texture != nil) {return}
	defer sdl.DestroyTexture(banner_texture)
	textures.by_key[cover_key("banner")] = banner_texture
	fake_icon: sdl.Texture
	textures.by_key[icon_key("play-filled", .Dark)] = &fake_icon
	textures.by_key[icon_key("pause-filled", .Dark)] = &fake_icon
	defer {
		delete(textures.by_key)
		delete(textures.requested)
	}
	footer_overlap_found := false
	defer testing.expect(
		t,
		footer_overlap_found,
		"regression must exercise a clipped row overlapping next",
	)
	app_state: State
	anims := make(map[string]Button_Fx)
	defer delete(anims)
	fx := Button_Fx_Ctx {
		anims = &anims,
	}
	for d in ([]f32{1, 1.5}) {
		density = d
		clay.ResetMeasureTextCache()
		clay.SetLayoutDimensions({1280 * d, 820 * d})
		for width in ([]f32{SIDEBAR_MIN, SIDEBAR_MAX}) {
			input_box, player_box: clay.BoundingBox
			for source in ([]library.Source{.Album, .Artist}) {
				client.detail.source = source
				client.detail.name = source == .Artist ? "Starfoxlaflare" : "Album"
				client.detail.banner = source == .Artist ? "banner" : ""
				// Allow dimensions from the previous layout to settle after resizing.
				for _ in 0 ..< 2 {
					clay.UpdateScrollContainers(false, {}, 0)
					_, _ = layout(
						{button = "pause"},
						&client,
						&app_state,
						.Albums,
						&textures,
						&fx,
						width,
						1280 * d,
						820 * d,
						26 * d,
						0,
						d,
						nil,
					)
				}
				if source == .Artist {
					banner := clay.GetElementData(clay.ID("hero_banner")).boundingBox
					caption := clay.GetElementData(clay.ID("hero_caption")).boundingBox
					testing.expect(
						t,
						caption.y >= banner.y &&
						caption.y + caption.height < banner.y + banner.height,
					)
				}
				input := clay.GetElementData(clay.ID("track_input")).boundingBox
				player := clay.GetElementData(clay.ID("footer_play")).boundingBox
				if source == .Album {
					input_box, player_box = input, player
				} else {
					testing.expect(t, input == input_box, "page changes must not move search")
					testing.expect(
						t,
						player == player_box,
						"page changes must not move playback controls",
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
						{button = "pause"},
						&client,
						&app_state,
						.Albums,
						&textures,
						&fx,
						width,
						1280 * d,
						820 * d,
						26 * d,
						0,
						d,
						nil,
					)
					testing.expect_value(t, errors, 0)
					if source == .Album && fraction == 0 {
						button := clay.GetElementData(clay.ID("footer_next")).boundingBox
						point := sdl.FPoint {
							button.x + button.width / 2,
							button.y + button.height / 2,
						}
						testing.expect(t, hit("footer_next", point))
						overlapped := false
						for index in visible.tracks.first ..< visible.tracks.last {
							if hit_index("track_row", point, u32(index)) {overlapped = true}
							testing.expect(
								t,
								!hit_clipped("track_row", "detail_rows", point, u32(index)),
								"footer clicks must not select clipped overscan rows",
							)
						}
						footer_overlap_found = footer_overlap_found || overlapped
					}
					if source == .Album && fraction == 0 {
						found_selected, hero_play, footer_pause := false, false, false
						for command in commands.internalArray[:commands.length] {
							if command.commandType == .Image {
								key := u64(uintptr(command.renderData.image.imageData))
								if key == icon_key("play-filled", .Dark) {hero_play = true}
								if key == icon_key("pause-filled", .Dark) {footer_pause = true}
							}
							if command.id == clay.ID("card", 0).id &&
							   command.commandType == .Rectangle {
								found_selected =
									command.renderData.rectangle.backgroundColor == theme.selected
							}
						}
						testing.expect(
							t,
							hero_play && footer_pause,
							"detail play must remain play while the footer shows pause",
						)
						testing.expect(
							t,
							found_selected,
							"selected cards need a persistent subtle background",
						)
					}
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
						expected_rows := 36 * d + 3000 * (ROW_HEIGHT * d + f32(u16(2 * d)))
						testing.expect(
							t,
							math.abs(rows.contentDimensions.height - expected_rows) < 0.5,
							"track spacers must preserve row gaps with no load-more button",
						)
						if fraction == 1 {testing.expect_value(t, visible.tracks.last, 3000)}
					} else if fraction == 1 {
						testing.expect_value(t, visible.singles.last, 3000)
					}
				}
			}
		}
	}
}

@(test)
wide_detail_pages_keep_layout_bounded :: proc(t: ^testing.T) {
	errors := 0
	density: f32 = 1
	memory := layout_test_init(&density, &errors, {2500, 1424})
	defer {clay.SetCurrentContext(nil); delete(memory)}

	client: library.Client
	client.pages[.Albums].items = make([dynamic]library.Entry, 3000)
	defer delete(client.pages[.Albums].items)
	for &entry in client.pages[.Albums].items {entry.name = "Album title"}
	client.detail.ready = true
	client.detail.source = .Artist
	client.detail.id = "artist"
	client.detail.name = "Artist"
	client.detail.label = "Artist"
	client.detail.rows = make([dynamic]library.Track_Row, 10)
	defer delete(client.detail.rows)
	for &row in client.detail.rows {
		row.name = "Top track"
		row.artists = "Artist"
		row.duration_ms = 180_000
	}
	client.detail.albums.items = make([dynamic]library.Entry, 2000)
	defer delete(client.detail.albums.items)
	for &entry in client.detail.albums.items {
		entry.name = "Release with a fairly long name"
		entry.subtitle = "2026"
	}
	client.detail.albums.total = 2000
	client.detail.albums.has_more = true
	client.detail.singles.items = make([dynamic]library.Entry, 2000)
	defer delete(client.detail.singles.items)
	for &entry in client.detail.singles.items {
		entry.name = "Single title"
		entry.subtitle = "2026"
	}
	client.detail.singles.total = 2000
	client.detail.singles.has_more = true
	textures := Textures {
		by_key = make(map[u64]^sdl.Texture),
	}
	defer {
		delete(textures.by_key)
		delete(textures.requested)
	}
	app_state: State
	anims := make(map[string]Button_Fx)
	defer delete(anims)
	fx := Button_Fx_Ctx {
		anims = &anims,
	}
	for viewport in ([]clay.Dimensions{{2500, 1424}, {1881, 1069}}) {
		density = viewport.width == 1881 ? 1.2 : 1
		clay.ResetMeasureTextCache()
		for _ in 0 ..< 3 {
			clay.UpdateScrollContainers(false, {}, 0)
			_, _ = layout(
				{button = "pause"},
				&client,
				&app_state,
				.Albums,
				&textures,
				&fx,
				SIDEBAR_MAX,
				viewport.width,
				viewport.height,
				26 * density,
				0,
				density,
				nil,
			)
		}
		for fraction in ([]f32{0, 0.5, 1}) {
			clay.UpdateScrollContainers(false, {}, 0)
			scroll := clay.GetScrollContainerData(clay.ID("detail_rows"))
			scroll.scrollPosition.y =
				fraction *
				min(0, scroll.scrollContainerDimensions.height - scroll.contentDimensions.height)
			_, visible := layout(
				{button = "pause"},
				&client,
				&app_state,
				.Albums,
				&textures,
				&fx,
				SIDEBAR_MAX,
				viewport.width,
				viewport.height,
				26 * density,
				0,
				density,
				nil,
			)
			rows := clay.GetElementData(clay.ID("detail_rows")).boundingBox
			edge := rows.x + rows.width
			testing.expect(t, edge <= viewport.width)
			right: f32
			for index in visible.releases.first ..< visible.releases.last {
				card := clay.GetElementData(clay.ID("release_card", u32(index)))
				testing.expect(t, card.found)
				testing.expect(t, card.boundingBox.x >= rows.x - 1)
				right = max(right, card.boundingBox.x + card.boundingBox.width)
			}
			if right > 0 {testing.expect(t, right <= edge + 1)}
			// Clay prunes its 100-entry scroll container array each frame, so a
			// single frame may hold at most that many clips. Off-screen sections
			// must render no cards instead of a full viewport each.
			testing.expect_value(t, errors, 0)
		}
	}
	density = 1
	clay.ResetMeasureTextCache()
	client.detail.source = .Playlist
	client.detail.rows[0].album = "Album title"
	client.detail.rows[0].album_uri = "spotify:album:fixture"
	client.detail.rows[1].album = "Unlinked album"
	clay.GetScrollContainerData(clay.ID("detail_rows")).scrollPosition.y = 0
	_, _ = layout(
		{button = "pause"},
		&client,
		&app_state,
		.Albums,
		&textures,
		&fx,
		SIDEBAR_MAX,
		2500,
		1424,
		26,
		0,
		1,
		nil,
	)
	for ids in ([][2]string{{"album_header", "track_album"}, {"added_header", "track_added"}}) {
		header := clay.GetElementData(clay.ID(ids[0]))
		row := clay.GetElementData(clay.ID(ids[1], 0))
		testing.expect(t, header.found && row.found)
		testing.expect(t, math.abs(header.boundingBox.x - row.boundingBox.x) < 0.01)
		testing.expect_value(t, header.boundingBox.width, row.boundingBox.width)
	}
	album := clay.GetElementData(clay.ID("track_album", 0)).boundingBox
	link := clay.GetElementData(clay.ID("album_link", 0)).boundingBox
	testing.expect(t, link.width > 0 && link.width < album.width)
	testing.expect(
		t,
		hit_clipped(
			"album_link",
			"detail_rows",
			{link.x + link.width / 2, link.y + link.height / 2},
			0,
		),
	)
	testing.expect(
		t,
		!hit_index("album_link", {album.x + album.width - 1, link.y + link.height / 2}, 0),
	)
	testing.expect(t, !clay.GetElementData(clay.ID("album_link", 1)).found)
	// A collection card must use normal navigation, including a back entry.
	fake_worker: thread.Thread
	opened := library.Client {
		state  = .Ready,
		worker = &fake_worker,
	}
	opened.requests, _ = chan.create_buffered(chan.Chan(library.Request), 1, context.allocator)
	defer {for request in chan.try_recv(opened.requests) {library.free_request(request)}
		chan.destroy(opened.requests)
		library.free_detail(&opened.detail)
		delete(opened.detail_request_id)}
	nav: Nav
	defer nav_free_all(&nav)
	nav_commit(&nav, Nav_State{filter = .Artists})
	input: string
	pinned, armed := false, true
	ctx := Nav_Ctx {
		client        = &opened,
		nav           = &nav,
		app_state     = &app_state,
		textures      = &textures,
		detail_pinned = &pinned,
		scroll_armed  = &armed,
		input         = &input,
		filter        = .Artists,
	}
	entry := library.Entry {
		name = "Album title",
		uri  = "spotify:album:fixture",
	}
	testing.expect(
		t,
		open_release_card(
			&ctx,
			{link.x + 1, link.y + 1},
			"album_link",
			[]library.Entry{entry},
			{last = 1},
		),
	)
	testing.expect(t, nav_can_back(&nav) && !armed)
	testing.expect_value(t, nav.states[nav.index].detail.uri, entry.uri)
	// Tall panes must not spend Clay's 100 clip slots on individual rows.
	resize(&client.detail.rows, 2000)
	for &row in client.detail.rows {row.name = "Track title"; row.artists = "Artist"}
	for _ in 0 ..< 2 {
		_, _ = layout(
			{button = "pause"},
			&client,
			&app_state,
			.Albums,
			&textures,
			&fx,
			SIDEBAR_MIN,
			1280,
			5000,
			26,
			0,
			1,
			nil,
		)
	}
	testing.expect_value(t, errors, 0)
}

@(test)
selected_card_matches_both_source_and_id :: proc(t: ^testing.T) {
	detail := library.Detail {
		ready  = true,
		source = .Playlist,
		id     = "same-id",
	}
	entry := library.Entry {
		uri = "spotify:playlist:same-id",
	}
	testing.expect(t, card_selected(&entry, &detail))
	entry.uri = "spotify:album:same-id"
	testing.expect(t, !card_selected(&entry, &detail))
	detail.source = .Album
	testing.expect(t, card_selected(&entry, &detail))
	detail.ready = false
	testing.expect(t, !card_selected(&entry, &detail))
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

@(test)
artist_paging_follows_visible_cards :: proc(t: ^testing.T) {
	client: library.Client
	client.detail.ready, client.detail.has_more = true, true
	client.detail.source = .Artist
	client.detail.albums.has_more, client.detail.singles.has_more = true, true
	client.detail.albums.items = make([dynamic]library.Entry, 10)
	client.detail.singles.items = make([dynamic]library.Entry, 10)
	defer {delete(client.detail.albums.items); delete(client.detail.singles.items)}
	testing.expect(t, !detail_needs_more(&client, {}))
	testing.expect(t, !detail_needs_more(&client, {releases = {last = 8}}))
	testing.expect(t, detail_needs_more(&client, {releases = {last = 10}}))
	visible := Frame_Visible {
		singles = {last = 10},
	}
	testing.expect(t, !detail_needs_more(&client, visible))
	testing.expect(t, detail_needs_more(&client, visible, .Single))
}

@(test)
scrollbar_thumb_hides_when_content_fits_and_clamps_at_both_ends :: proc(t: ^testing.T) {
	_, _, fits := scrollbar_metrics(0, 400, 800, 24, 2)
	testing.expect(t, !fits)
	thumb, top, visible := scrollbar_metrics(0, 4000, 800, 24, 2)
	testing.expect(t, visible && thumb >= 24)
	testing.expect_value(t, top, f32(2))
	_, bottom, _ := scrollbar_metrics(-3200, 4000, 800, 24, 2)
	testing.expect(t, math.abs(bottom - (800 - thumb - 2)) < 0.01)
	_, clamped, _ := scrollbar_metrics(-99999, 4000, 800, 24, 2)
	testing.expect_value(t, clamped, bottom)
}

@(test)
autoscroll_delta_deadzone_and_direction :: proc(t: ^testing.T) {
	d: f32 = 2
	testing.expect_value(t, autoscroll_delta(5 * d, 0.016, d), 0)
	testing.expect_value(t, autoscroll_delta(-5 * d, 0.016, d), 0)
	down := autoscroll_delta(60 * d, 0.016, d)
	testing.expect(t, down < 0, "steering down must scroll down")
	up := autoscroll_delta(-60 * d, 0.016, d)
	testing.expect(t, up > 0, "steering up must scroll up")
	testing.expect_value(t, down, -up)
	testing.expect_value(t, autoscroll_delta(60 * d, 0, d), 0)
}

@(test)
wheel_target_glides_to_rest :: proc(t: ^testing.T) {
	errors := 0
	density: f32 = 1
	memory := layout_test_init(&density, &errors, {1280, 820})
	defer {clay.SetCurrentContext(nil); delete(memory)}
	client: library.Client
	client.detail.ready = true
	client.detail.source = .Playlist
	client.detail.name = "Playlist"
	client.detail.label = "Playlist"
	client.detail.rows = make([dynamic]library.Track_Row, 100)
	defer delete(client.detail.rows)
	for &row in client.detail.rows {
		row.name = "Track title"
		row.artists = "Artist"
		row.duration_ms = 180_000
	}
	textures := Textures {
		by_key = make(map[u64]^sdl.Texture),
	}
	defer {
		delete(textures.by_key)
		delete(textures.requested)
	}
	app_state: State
	d: f32 = 1
	clay.SetLayoutDimensions({1280, 820})
	clay.UpdateScrollContainers(false, {}, 0)
	glide_anims := make(map[string]Button_Fx)
	defer delete(glide_anims)
	glide_fx := Button_Fx_Ctx {
		anims = &glide_anims,
	}
	_, _ = layout(
		{button = "pause"},
		&client,
		&app_state,
		.Playlists,
		&textures,
		&glide_fx,
		360,
		1280,
		820,
		26,
		0,
		d,
		nil,
	)
	rows := clay.GetElementData(clay.ID("detail_rows"))
	testing.expect(t, rows.found, "detail rows must exist for the glide test")
	clay.SetPointerState({rows.boundingBox.x + 10, rows.boundingBox.y + 10}, false)
	smooth: Smooth
	testing.expect(
		t,
		scroll_wheel("detail_rows", -1, d, &smooth),
		"wheel over the rows must arm a glide",
	)
	testing.expect(t, smooth.active)
	testing.expect_value(t, smooth.target, -120 * d)
	steps := 0
	for smooth.active && steps < 600 {
		testing.expect(t, smooth_step("detail_rows", &smooth, 1.0 / 60))
		steps += 1
	}
	testing.expect(t, !smooth.active, "glide must settle on its target")
	data := clay.GetScrollContainerData(clay.ID("detail_rows"))
	testing.expect_value(t, data.scrollPosition.y, smooth.target)
	smooth_cancel("detail_rows", &smooth)
	testing.expect(t, !smooth.active)
	testing.expect_value(t, errors, 0)
}

fx_test_layout :: proc(fx: ^Button_Fx_Ctx, d: f32) {
	clay.SetLayoutDimensions({1280, 820})
	clay.UpdateScrollContainers(false, {}, 0)
	client: library.Client
	textures := Textures {
		by_key = make(map[u64]^sdl.Texture),
	}
	defer {delete(textures.by_key); delete(textures.requested)}
	app_state: State
	_, _ = layout(
		{button = "pause"},
		&client,
		&app_state,
		.Playlists,
		&textures,
		fx,
		360,
		1280,
		820,
		26,
		0,
		d,
		nil,
	)
}

@(test)
play_counts_use_grouped_numbers :: proc(t: ^testing.T) {
	testing.expect_value(t, count_text(0), "0")
	testing.expect_value(t, count_text(999), "999")
	testing.expect_value(t, count_text(1000), "1,000")
	testing.expect_value(t, count_text(563387486), "563,387,486")
}

@(test)
playlist_columns_and_dates_handle_narrow_panes_and_unknown_dates :: proc(t: ^testing.T) {
	album, date, _ := playlist_columns(600, 1)
	testing.expect(t, album == 0 && date == 0)
	album, date, _ = playlist_columns(800, 1)
	testing.expect(t, album > 0 && date == 0)
	album, date, _ = playlist_columns(1200, 1)
	testing.expect(t, album > 0 && date > 0)
	testing.expect_value(t, added_at_text(1726617600000), "Sep 18, 2024")
	testing.expect_value(t, added_at_text(0), "")
}
